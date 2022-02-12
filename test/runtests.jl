using CachePath
using Test

# TODO: use filecmp to make kinda sure that
# files are not recompiled
@testset "CachePath.jl" begin
    depot1 = mktempdir()
    @test isdir(depot1)
    shortvers = string("v", VERSION.major, ".", VERSION.minor)
    com = `$(Base.julia_cmd()) --startup-file=no -e "using CachePath; CachePath.require(\"Example\", \"$depot1\")"`
    p1 = run(com)
    @test p1.exitcode == 0
    dirlist3 = readdir(joinpath(depot1, "compiled", shortvers))
    cachedir = joinpath(depot1, "compiled", shortvers, "Example")
    dirlist = readdir(cachedir)
    @test length(dirlist) == 1
    cachefile1 = only(dirlist)
    @test endswith(cachefile1, ".ji")
    cp(joinpath(cachedir, cachefile1), joinpath(depot1, cachefile1))
    p2 = run(com)
    @test p2.exitcode == 0
    # dirlist = readdir(cachedir)
    # cachefile2 = only(dirlist)
end
