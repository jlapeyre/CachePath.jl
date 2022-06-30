module CachePath

using Base: PkgId, root_module, root_module_exists, PkgOrigin,
    pkgorigins, package_locks, toplevel_load,
    locate_package, JLOptions, PrecompilableError, @logmsg,
    cache_file_entry, isfile_casesensitive, stale_cachefile,
    _include_from_serialized, _concrete_dependencies,
    loaded_modules, module_build_id, CoreLogging, create_expr_cache, _crc32c,
    preferences_hash, slug, MAX_NUM_PRECOMPILE_FILES, rename,
    _require_from_serialized,
    package_callbacks
#, @constprop, _tryrequire_from_serialized,

export @cpimport

const CACHE_PATH_DEBUG = false

function cachepathdebug(args...)
    if CACHE_PATH_DEBUG
        println(args...)
    end
end

const CACHE_PATH_COMPAT =
if VERSION < v"1.7.999"
    true
else
    false
end

# This could cause a problem, as there will be two locks when running v1.8
# _require_lock and require_lock
# Only _require_lock is used in this file
const _require_lock = ReentrantLock()

if CACHE_PATH_COMPAT
    _Condition() = Condition()
else
    _Condition() = Threads.Condition(_require_lock)
end

# run_package_callbacks not present in v1.6.5
function _run_package_callbacks(modkey::PkgId)
    unlock(_require_lock)
    try
        for callback in package_callbacks
            Base.invokelatest(callback, modkey)
        end
    catch
        # Try to continue loading if a callback errors
        errs = current_exceptions()
        @error "Error during package callback" exception=errs
    finally
        lock(_require_lock)
    end
    nothing
end

# Macro @lock not present in v1.6.5
macro _lock(l, expr)
    quote
        temp = $(esc(l))
        lock(temp)
        try
            $(esc(expr))
        finally
            unlock(temp)
        end
    end
end

"""
    @cpimport module depot_path::AbstractString

Import `module` using `depot_path` to store and retrieve the precompile
cache. Precompile caches existing elsewhere are ignored.

The semantics of `@cpimport` probably differ from those of `import` in
other ways.

# Examples:
Import the module `Example` using "./newdepot" for storing and retrieving
the precompile cache.


    julia> @cpimport Example "./newdepot"
"""
macro cpimport(mod, depot_path)
    qmod = QuoteNode(mod)
    :(const $(esc(mod)) = CachePath.require(Main, $(esc(qmod)), $depot_path); nothing)
end

"""
    CachePath.require(into::Module, module::Symbol, depot_path::AbstractString)

This function is modified from `Base.require`. The precompiled cache (`.ji` file) for
`module` will only be searched for and stored in `depot_path`.

Loads a source file, in the context of the `Main` module, on every active node, searching
standard locations for files. `require` is considered a top-level operation, so it sets the
current `include` path but does not use it to search for files (see help for [`include`](@ref)).
This function is typically used to load library code, and is implicitly called by `using` to
load packages.

When searching for files, `require` first looks for package code in the global array
[`LOAD_PATH`](@ref). `require` is case-sensitive on all platforms, including those with
case-insensitive filesystems like macOS and Windows.

For more details regarding code loading, see the manual sections on [modules](@ref modules) and
[parallel computing](@ref code-availability).
"""
function require(into::Module, mod::Symbol, depot_path::AbstractString)
    @_lock _require_lock begin
    # LOADING_CACHE[] = LoadingCache() # Does not exist in v1.6.5
    try
        uuidkey = Base.identify_package(into, String(mod))
        # Core.println("require($(PkgId(into)), $mod) -> $uuidkey")
        if uuidkey === nothing
            where = PkgId(into)
            if where.uuid === nothing
                hint, dots = begin
                    if isdefined(into, mod) && getfield(into, mod) isa Module
                        true, "."
                    elseif isdefined(parentmodule(into), mod) && getfield(parentmodule(into), mod) isa Module
                        true, ".."
                    else
                        false, ""
                    end
                end
                hint_message = hint ? ", maybe you meant `import/using $(dots)$(mod)`" : ""
                start_sentence = hint ? "Otherwise, run" : "Run"
                throw(ArgumentError("""
                    Package $mod not found in current path$hint_message.
                    - $start_sentence `import Pkg; Pkg.add($(repr(String(mod))))` to install the $mod package."""))
            else
                throw(ArgumentError("""
                Package $(where.name) does not have $mod in its dependencies:
                - You may have a partially installed environment. Try `Pkg.instantiate()`
                  to ensure all packages in the environment are installed.
                - Or, if you have $(where.name) checked out for development and have
                  added $mod as a dependency but haven't updated your primary
                  environment's manifest file, try `Pkg.resolve()`.
                - Otherwise you may need to report an issue with $(where.name)"""))
            end
        end
        if Base._track_dependencies[]
            push!(Base._require_dependencies, (into, binpack(uuidkey), 0.0))
        end
        return _require_prelocked(uuidkey, depot_path)
    finally
#        LOADING_CACHE[] = nothing
    end
    end
end

require(uuidkey::PkgId, depot_path::AbstractString) =
    @_lock _require_lock _require_prelocked(uuidkey, depot_path)

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
require(package::AbstractString, depot_path::AbstractString) =
    require(Base.identify_package(package), depot_path)


function _require_prelocked(uuidkey::PkgId, depot_path::AbstractString)
    just_loaded_pkg = false
    if !root_module_exists(uuidkey)
        cachefile = _require(uuidkey, depot_path)
        if cachefile !== nothing
            get!(PkgOrigin, pkgorigins, uuidkey).cachepath = cachefile
        end
        # After successfully loading, notify downstream consumers
        _run_package_callbacks(uuidkey)
        just_loaded_pkg = true
    end
    if just_loaded_pkg && !root_module_exists(uuidkey)
        # error("package `$(uuidkey.name)` did not define the expected \
        #       module `$(uuidkey.name)`, check for typos in package module name")
        error("package `$(uuidkey.name)` did not define the expected module `$(uuidkey.name)`, check for typos in package module name")
    end
    return root_module(uuidkey)
end

# Returns `nothing` or the name of the newly-created cachefile
function _require(pkg::PkgId, depot_path::AbstractString)
    # handle recursive calls to require
    loading = get(package_locks, pkg, false)
    if loading !== false
        # load already in progress for this module
        wait(loading)
        return
    end
    package_locks[pkg] = _Condition()

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
            m = _require_search_from_serialized(pkg, depot_path, path)
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
        if ! CACHE_PATH_COMPAT
            unlock(_require_lock)
        end
        try
            include(__toplevel__, path)
            return
        finally
            if ! CACHE_PATH_COMPAT
                lock(_require_lock)
            end
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

const _TIMING_IMPORTS =
    if CACHE_PATH_COMPAT
        Base.Threads.Atomic{Int}(0)
    else
        Base.TIMING_IMPORTS
    end

function _tryrequire_from_serialized(modkey::PkgId, build_id::UInt64, depot_path::String,
                                     modpath::Union{Nothing, String},
                                     depth::Int = 0)
    if root_module_exists(modkey)
        M = root_module(modkey)
        if PkgId(M) == modkey && module_build_id(M) === build_id
            return M
        end
    else
        if modpath === nothing
            modpath = locate_package(modkey)
            modpath === nothing && return nothing
        end
        mod = _require_search_from_serialized(modkey, depot_path, String(modpath), depth)
        get!(PkgOrigin, pkgorigins, modkey).path = modpath
        if !isa(mod, Bool)
            _run_package_callbacks(modkey)
            for M in mod::Vector{Any}
                M = M::Module
                if PkgId(M) == modkey && module_build_id(M) === build_id
                    return M
                end
            end
        end
    end
    return nothing
end

macro myconstprop(setting, ex)
    if isa(setting, QuoteNode)
        setting = setting.value
    end
    setting === :aggressive && return esc(isa(ex, Expr) ? Base.pushmeta!(ex, :aggressive_constprop) : ex)
    setting === :none && return esc(isa(ex, Expr) ? Base.pushmeta!(ex, :no_constprop) : ex)
    throw(ArgumentError("@myconstprop $setting not supported"))
end

# returns `true` if require found a precompile cache for this sourcepath, but couldn't load it
# returns `false` if the module isn't known to be precompilable
# returns the set of modules restored if the cache load succeeded
@myconstprop :none function _require_search_from_serialized(pkg::PkgId, depot_path::String, sourcepath::String, depth::Int = 0)
    t_before = time_ns()
    paths = find_all_in_cache_path(pkg, depot_path, depth)
    for path_to_try in paths::Vector{String}
        cachepathdebug("path_to_try ", path_to_try)
        cachepathdebug("sourcepath ", sourcepath)
        staledeps = stale_cachefile(sourcepath, path_to_try)
        if staledeps === true
            cachepathdebug("staledeps ", true)
        else
            cachepathdebug("length(staledeps) ", length(staledeps))
        end
        if staledeps === true
            continue
        end
        try
            touch(path_to_try) # update timestamp of precompilation file
        catch # file might be read-only and then we fail to update timestamp, which is fine
        end
        # finish loading module graph into staledeps
        for i in 1:length(staledeps)
            dep = staledeps[i]
            dep isa Module && continue
            modpath, modkey, build_id = dep::Tuple{String, PkgId, UInt64}
            dep = _tryrequire_from_serialized(modkey, build_id, depot_path, modpath, depth + 1)
            if dep === nothing
                @debug "Required dependency $modkey failed to load from cache file for $modpath."
                cachepathdebug("Required dependency $modkey failed to load from cache file for $modpath.")
                staledeps = true
                break
            end
            staledeps[i] = dep::Module
        end
        if staledeps === true
            cachepathdebug("staledeps set to true")
            continue
        end
        cachepathdebug("_include_from_serialized($path_to_try, staledeps)")
        restored = _include_from_serialized(path_to_try, staledeps)
        if isa(restored, Exception)
            @debug "Deserialization checks failed while attempting to load cache from $path_to_try" exception=restored
        else
            if _TIMING_IMPORTS[] > 0
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


function find_all_in_cache_path(pkg::PkgId, depot_path::String, depth::Int)
    cachepathdebug("find_all_in_cache_path: depth = ", depth)
    paths = String[]
    entrypath, entryfile = cache_file_entry(pkg)
    if depth == 0 # Make CachePath.require look only in specified depot.
        full_paths = (joinpath(depot_path, entrypath),)
    else # Dependencies may be found in other depots (e.g. the standard one)
        full_paths = (joinpath(depot_path, entrypath), joinpath.(DEPOT_PATH, entrypath)...)
    end
    for path in full_paths
        #    for path in (joinpath(depot_path, entrypath), )
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

end # module CachePath
