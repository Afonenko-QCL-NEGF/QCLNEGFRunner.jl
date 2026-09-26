module ScratchExecutionTests
include("../support/common.jl")
@testset "Verified scratch delivery" begin
    mktempdir() do root
        source = joinpath(root, "source")
        mkpath(joinpath(source, "nested"))
        write(joinpath(source, "nested", "data.bin"), UInt8[0,1,2,255])
        destination = joinpath(root, "shared", "result")
        @test stage_result_tree(source, destination) == destination
        @test read(joinpath(destination, "nested", "data.bin")) == UInt8[0,1,2,255]
        @test_throws ArgumentError stage_result_tree(source, destination)
        @test_throws ArgumentError stage_result_tree(source, joinpath(source, "nested", "result"))
        symlink(joinpath(source, "nested", "data.bin"), joinpath(source, "linked"))
        @test_throws ArgumentError stage_result_tree(source, joinpath(root, "linked-result"))
        @test !ispath(joinpath(root, "linked-result"))
    end
end
end
