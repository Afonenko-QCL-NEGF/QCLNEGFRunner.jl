module Suite_T075
include("../support/common.jl")
using HDF5
include("../support/production_backend.jl")

@testset "Production sweep records require complete diagnostics" begin
    @test_throws MethodError ProductionSweepRecord(
        200.0,
        0.056,
        1.89e6,
        1.4e7,
        true,
        :converged,
        9,
        40,
        2_000_000,
        12.5,
        Dict{Symbol,Float64}(:self_energy => 1e-9),
        "state.h5",
    )
    record = ProductionSweepRecord(
        200.0,
        0.056,
        1.89e6,
        1.4e7,
        true,
        :converged,
        :strictly_converged,
        9,
        40,
        2_000_000,
        12.5,
        Dict{Symbol,Float64}(:self_energy => 1e-9),
        "state.h5",
    )
    @test record.wall_seconds == 12.5
    @test record.scba_quality == :strictly_converged
    @test record.metrics[:self_energy] == 1e-9
    @test_throws ArgumentError ProductionSweepRecord(
        200.0,
        0.056,
        1.89e6,
        1.4e7,
        true,
        :converged,
        :approximate_fixed_point,
        9,
        40,
        2_000_000,
        12.5,
        Dict{Symbol,Float64}(:self_energy => 1e-3),
        "state.h5",
    )
    @test_throws ArgumentError ProductionSweepRecord(
        200.0,
        0.056,
        1.89e6,
        1.4e7,
        false,
        :max_iterations,
        :unknown,
        9,
        40,
        2_000_000,
        12.5,
        Dict{Symbol,Float64}(:self_energy => 1e-3),
        "state.h5",
    )
    mktempdir() do directory
        path = joinpath(directory, "summary.csv")
        save_production_summary(path, ProductionSweepResult([record], path))
        header, row = readlines(path)
        @test occursin(",scba_quality,", header)
        @test occursin(",strictly_converged,", row)
    end
end

end # independent suite
