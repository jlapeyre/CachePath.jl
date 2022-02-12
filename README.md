# CachePath

[![Build Status](https://github.com/jlapeyre/CachePath.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/jlapeyre/CachePath.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/jlapeyre/CachePath.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/jlapeyre/CachePath.jl)


`CachePath` allows temporarily using a depot for saving and loading precompiled cache (`.ji`) files.

If you have ever been frustrated in trying to store and load precompiled caches from a particular
location by manipulating `DEPOT_PATH[1]`, then `CachePath` might solve your problem.
`CachePath` does not work by manipulating `DEPOT_PATH` or any other list of paths. Rather,
`CachePath.require` is a copy of `Base.require` (which is called by `using` and `import`) that takes
an additional argument, a depot path. This depot path is only valid during that call,
and only for the package `require`d.
Other lists of paths, including `DEPOT_PATH` and `LOAD_PATH` are ignored during this
call. The source and caches for other packages, (eg. dependencies) will be searched
in the usual way, with the special depot path playing no role.

### Function

    CachePath.require(package::AbstractString, depot_path::AbstractString)
    CachePath.require(package::Base.PkgId, depot_path::AbstractString)

Load `package` and store the cached precompile file in the depot specified
by `depot_path`. If it does not exist, `depot_path` is created. If the
cached precompiled file is found in `depot_path`, then it is loaded.

### Example
```julia
const Example = CachePath.require("Example", "./a_depot")
```
