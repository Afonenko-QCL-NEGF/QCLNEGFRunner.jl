module Suite_T081
include("../support/common.jl")
using HDF5
include("../support/production_backend.jl")

@testset "Production files replace an existing destination in one rename" begin
    mktempdir() do directory
        destination = joinpath(directory, "checkpoint.h5")
        source = joinpath(directory, "checkpoint.new")
        write(destination, "last valid state")
        write(source, "new complete state")
        @test QCLNEGFRunner._atomic_replace_file(source, destination) == destination
        @test !isfile(source)
        @test read(destination, String) == "new complete state"

        other_directory = mktempdir()
        other_source = joinpath(other_directory, "state.new")
        write(other_source, "state")
        @test_throws ArgumentError QCLNEGFRunner._atomic_replace_file(other_source, destination)
    end
end

end # independent suite
