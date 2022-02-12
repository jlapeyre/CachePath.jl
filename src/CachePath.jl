__precompile__(false)

module CachePath

Base.include(Base, "cache_path.jl")

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
Base.require(package::AbstractString, depot_path::AbstractString) =
    Base.require(Base.identify_package(package), depot_path)

end
