const CACHE_PATH_DEBUG = false

function cachepathdebug(args...)
    if CACHE_PATH_DEBUG
        println(args...)
    end
end

using Base: require_lock, PkgId, root_module, root_module_exists, PkgOrigin,
    pkgorigins, run_package_callbacks, package_locks, toplevel_load,
    locate_package, JLOptions, PrecompilableError, @logmsg, @constprop,
    cache_file_entry, isfile_casesensitive, stale_cachefile,
    _include_from_serialized, TIMING_IMPORTS, _concrete_dependencies,
    loaded_modules, module_build_id, CoreLogging, create_expr_cache, _crc32c,
    preferences_hash, slug, MAX_NUM_PRECOMPILE_FILES, rename,
    _tryrequire_from_serialized, _require_from_serialized


"""
    Base.require(package::AbstractString, depot_path::AbstractString)
    Base.require(package::PkgId, depot_path::AbstractString)

Load `package` and store the cached precompile file in the depot specified
by `depot_path`. If it does not exist, `depot_path` is created. If the
cached precompiled file is found in `depot_path`, then it is loaded.

# Examples
```julia
const Example = Base.require("Example", "./a_depot")
```
"""
require(package::AbstractString, depot_path::AbstractString, noclobber::Bool = false) =
    require(Base.identify_package(package), depot_path, noclobber)

require(uuidkey::PkgId, depot_path::AbstractString, noclobber::Bool=false) =
    @lock require_lock _require_prelocked(uuidkey, depot_path, noclobber)

function _require_prelocked(uuidkey::PkgId, depot_path::AbstractString, noclobber::Bool)
    just_loaded_pkg = false
    if !root_module_exists(uuidkey)
        cachefile = _require(uuidkey, depot_path, noclobber)
        if cachefile !== nothing
            get!(PkgOrigin, pkgorigins, uuidkey).cachepath = cachefile
        end
        # After successfully loading, notify downstream consumers
        run_package_callbacks(uuidkey)
        just_loaded_pkg = true
    end
    if just_loaded_pkg && !root_module_exists(uuidkey)
        error("package `$(uuidkey.name)` did not define the expected \
              module `$(uuidkey.name)`, check for typos in package module name")
    end
    return root_module(uuidkey)
end

function _require(pkg::PkgId, depot_path::AbstractString, noclobber::Bool)
    # handle recursive calls to require
    loading = get(package_locks, pkg, false)
    if loading !== false
        # load already in progress for this module
        wait(loading)
        return
    end
    package_locks[pkg] = Threads.Condition(require_lock)

    last = toplevel_load[]
    try
        toplevel_load[] = false
        # perform the search operation to select the module file require intends to load
        path = locate_package(pkg)
        get!(PkgOrigin, pkgorigins, pkg).path = path
        if path === nothing
            throw(ArgumentError("""
                Package $pkg is required but does not seem to be installed:
                 - Run `Pkg.instantiate()` to install all recorded dependencies.
                """))
        end

        # attempt to load the module file via the precompile cache locations
        if JLOptions().use_compiled_modules != 0
            m = _require_search_from_serialized(pkg, depot_path, path, noclobber)
            if !isa(m, Bool)
                return
            end
        end

        # if the module being required was supposed to have a particular version
        # but it was not handled by the precompile loader, complain
        for (concrete_pkg, concrete_build_id) in _concrete_dependencies
            if pkg == concrete_pkg
                @warn """Module $(pkg.name) with build ID $concrete_build_id is missing from the cache.
                     This may mean $pkg does not support precompilation but is imported by a module that does."""
                if JLOptions().incremental != 0
                    # during incremental precompilation, this should be fail-fast
                    throw(PrecompilableError())
                end
            end
        end

        if JLOptions().use_compiled_modules != 0
            if (0 == ccall(:jl_generating_output, Cint, ())) || (JLOptions().incremental != 0)
                # spawn off a new incremental pre-compile task for recursive `require` calls
                # or if the require search declared it was pre-compiled before (and therefore is expected to still be pre-compilable)
                cachefile = compilecache(pkg, path, depot_path)
                if isa(cachefile, Exception)
                    if precompilableerror(cachefile)
                        verbosity = isinteractive() ? CoreLogging.Info : CoreLogging.Debug
                        @logmsg verbosity "Skipping precompilation since __precompile__(false). Importing $pkg."
                    else
                        @warn "The call to compilecache failed to create a usable precompiled cache file for $pkg" exception=m
                    end
                    # fall-through to loading the file locally
                else
                    m = _require_from_serialized(cachefile)
                    if isa(m, Exception)
                        @warn "The call to compilecache failed to create a usable precompiled cache file for $pkg" exception=m
                    else
                        return cachefile
                    end
                end
            end
        end

        # just load the file normally via include
        # for unknown dependencies
        uuid = pkg.uuid
        uuid = (uuid === nothing ? (UInt64(0), UInt64(0)) : convert(NTuple{2, UInt64}, uuid))
        old_uuid = ccall(:jl_module_uuid, NTuple{2, UInt64}, (Any,), __toplevel__)
        if uuid !== old_uuid
            ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), __toplevel__, uuid)
        end
        unlock(require_lock)
        try
            include(__toplevel__, path)
            return
        finally
            lock(require_lock)
            if uuid !== old_uuid
                ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), __toplevel__, old_uuid)
            end
        end
    finally
        toplevel_load[] = last
        loading = pop!(package_locks, pkg)
        notify(loading, all=true)
    end
    nothing
end

function find_all_in_cache_path(pkg::PkgId, depot_path::String)
    paths = String[]
    entrypath, entryfile = cache_file_entry(pkg)
# Use the second line to require that the cache file is in depot_path
#   for path in (joinpath(depot_path, entrypath), joinpath.(DEPOT_PATH, entrypath)...)
    for path in (joinpath(depot_path, entrypath), )
        isdir(path) || continue
        for file in readdir(path, sort = false) # no sort given we sort later
            if !((pkg.uuid === nothing && file == entryfile * ".ji") ||
                 (pkg.uuid !== nothing && startswith(file, entryfile * "_")))
                 continue
            end
            filepath = joinpath(path, file)
            isfile_casesensitive(filepath) && push!(paths, filepath)
        end
    end
    if length(paths) > 1
        # allocating the sort vector is less expensive than using sort!(.. by=mtime), which would
        # call the relatively slow mtime multiple times per path
        p = sortperm(mtime.(paths), rev = true)
        return paths[p]
    else
        return paths
    end
end

# returns `true` if require found a precompile cache for this sourcepath, but couldn't load it
# returns `false` if the module isn't known to be precompilable
# returns the set of modules restored if the cache load succeeded
@constprop :none function _require_search_from_serialized(pkg::PkgId, depot_path::String, sourcepath::String, noclobber::Bool, depth::Int = 0)
    t_before = time_ns()
    paths = find_all_in_cache_path(pkg, depot_path)
    for path_to_try in paths::Vector{String}
        cachepathdebug("path_to_try ", path_to_try)
        cachepathdebug("sourcepath ", sourcepath)
        staledeps = stale_cachefile(sourcepath, path_to_try)
#        cachepathdebug("Staledeps $staledeps")
        if staledeps === true #  && ! noclobber
            continue
        end
        try
            touch(path_to_try) # update timestamp of precompilation file
        catch # file might be read-only and then we fail to update timestamp, which is fine
        end
        # finish loading module graph into staledeps
#        if staledeps !== true
            for i in 1:length(staledeps)
                dep = staledeps[i]
                dep isa Module && continue
                modpath, modkey, build_id = dep::Tuple{String, PkgId, UInt64}
                dep = _tryrequire_from_serialized(modkey, build_id, modpath, depth + 1)
                if dep === nothing
                    @debug "Required dependency $modkey failed to load from cache file for $modpath."
                    staledeps = true
                    break
                end
                staledeps[i] = dep::Module
            end
 #       end
        if staledeps === true # && ! noclobber
            continue
        end
        cachepathdebug("_include_from_serialized($path_to_try, staledeps)")
        restored = _include_from_serialized(path_to_try, staledeps)
        if isa(restored, Exception)
            @debug "Deserialization checks failed while attempting to load cache from $path_to_try" exception=restored
        else
            if TIMING_IMPORTS[] > 0
                elapsed = round((time_ns() - t_before) / 1e6, digits = 1)
                tree_prefix = depth == 0 ? "" : "  "^(depth-1)*"┌ "
                print(lpad(elapsed, 9), " ms  ")
                printstyled(tree_prefix, color = :light_black)
                println(pkg.name)
            end
            cachepathdebug("Restored ", restored)
            return restored
        end
    end
    return !isempty(paths)
end

function compilecache_dir(pkg::PkgId, depot_path::String)
    entrypath, entryfile = cache_file_entry(pkg)
    cachepathdebug("compilecache_dir($pkg ::PkgId, $depot_path ::String)")
    cachepathdebug("joinpath($depot_path, $entrypath)")
    return joinpath(depot_path, entrypath)
end

function compilecache(pkg::PkgId, path::String, depot_path::String, internal_stderr::IO = stderr, internal_stdout::IO = stdout,
                      ignore_loaded_modules::Bool = true)

    @nospecialize internal_stderr internal_stdout
    # decide where to put the resulting cache file
    cachepathdebug("compilecache: depot_path $depot_path")
    cachepath = compilecache_dir(pkg, depot_path)

    # build up the list of modules that we want the precompile process to preserve
    concrete_deps = copy(_concrete_dependencies)
    if ignore_loaded_modules
        for (key, mod) in loaded_modules
            if !(mod === Main || mod === Core || mod === Base)
                push!(concrete_deps, key => module_build_id(mod))
            end
        end
    end
    # run the expression and cache the result
    verbosity = isinteractive() ? CoreLogging.Info : CoreLogging.Debug
    @logmsg verbosity "Precompiling $pkg"

    # create a temporary file in `cachepath` directory, write the cache in it,
    # write the checksum, _and then_ atomically move the file to `cachefile`.
    mkpath(cachepath)
    tmppath, tmpio = mktemp(cachepath)
    local p
    try
        close(tmpio)
        p = create_expr_cache(pkg, path, tmppath, concrete_deps, internal_stderr, internal_stdout)
        if success(p)
            # append checksum to the end of the .ji file:
            open(tmppath, "a+") do f
                write(f, _crc32c(seekstart(f)))
            end
            # inherit permission from the source file (and make them writable)
            chmod(tmppath, filemode(path) & 0o777 | 0o200)

            # Read preferences hash back from .ji file (we can't precompute because
            # we don't actually know what the list of compile-time preferences are without compiling)
            prefs_hash = preferences_hash(tmppath)
            cachefile = compilecache_path(pkg, depot_path, prefs_hash)

            # prune the directory with cache files
            if pkg.uuid !== nothing
                entrypath, entryfile = cache_file_entry(pkg)
                cachefiles = filter!(x -> startswith(x, entryfile * "_"), readdir(cachepath))
                if length(cachefiles) >= MAX_NUM_PRECOMPILE_FILES[]
                    idx = findmin(mtime.(joinpath.(cachepath, cachefiles)))[2]
                    rm(joinpath(cachepath, cachefiles[idx]))
                end
            end

            # this is atomic according to POSIX:
            cachepathdebug("rename($tmppath, $cachefile; force=true)")
            rename(tmppath, cachefile; force=true)
            return cachefile
        end
    finally
        rm(tmppath, force=true)
    end
    if p.exitcode == 125
        return PrecompilableError()
    else
        error("Failed to precompile $pkg to $tmppath.")
    end
end

function compilecache_path(pkg::PkgId, depot_path::String, prefs_hash::UInt64)::String
    entrypath, entryfile = cache_file_entry(pkg)
    cachepath = joinpath(depot_path, entrypath)
    isdir(cachepath) || mkpath(cachepath)
    if pkg.uuid === nothing
         return_path = abspath(cachepath, entryfile) * ".ji"
    else
        crc = _crc32c(something(Base.active_project(), ""))
        crc = _crc32c(unsafe_string(JLOptions().image_file), crc)
        crc = _crc32c(unsafe_string(JLOptions().julia_bin), crc)
        crc = _crc32c(prefs_hash, crc)
        project_precompile_slug = slug(crc, 5)
        return_path = abspath(cachepath, string(entryfile, "_", project_precompile_slug, ".ji"))
    end
    cachepathdebug("compile_cache_path: $return_path")
    return return_path
end

# Careful to not make this a method of compilecache, else the second arg will
# be interpreted as the package path (source?)
function compilecache_depot(pkg::PkgId, depot_path::String, internal_stderr::IO = stderr, internal_stdout::IO = stdout)
    @nospecialize internal_stderr internal_stdout
    path = locate_package(pkg)
    path === nothing && throw(ArgumentError("$pkg not found during precompilation"))
    return compilecache(pkg, path, depot_path, internal_stderr, internal_stdout)
end
