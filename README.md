# CachePath

[![Build Status](https://github.com/jlapeyre/CachePath.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/jlapeyre/CachePath.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/jlapeyre/CachePath.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/jlapeyre/CachePath.jl)


`CachePath` allows temporarily adding a depot for saving and loading precompiled cache (`.ji`) files.
This package creates methods for exisiting functions in `Base`. It will probably break things if you use it.


    Base.require(package::AbstractString, depot_path::AbstractString)
    Base.require(package::Base.PkgId, depot_path::AbstractString)

Load `package` and store the cached precompile file in the depot specified
by `depot_path`. If it does not exist, `depot_path` is created. If the
cached precompiled file is found in `depot_path`, then it is loaded.

### Example
```julia
const Example = Base.require("Example", "./a_depot")
```
