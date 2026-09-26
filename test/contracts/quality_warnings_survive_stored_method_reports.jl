module Suite_T052
include("../support/common.jl")
using HDF5

@testset "Quality warnings survive stored-method reports" begin
    warning=Dict{String,Any}(
        "code"=>"SCBA_APPROXIMATE_ACCEPTED",
        "scope"=>"point",
        "thresholds"=>Dict{String,Any}("r_K"=>1e-3),
        "metrics"=>Dict{String,Any}("r_K"=>7e-4),
    )
    record=ProductionSweepRecord(
        200.0,
        0.056,
        1e6,
        1.8e7,
        false,
        :approximate,
        :approximate_fixed_point,
        2,
        30,
        1000,
        2.5,
        Dict{Symbol,Float64}(),
        "",
        [warning],
    )
    mktempdir() do directory
        summary=joinpath(directory, "sweep_summary.csv")
        save_production_summary(summary, ProductionSweepResult([record], summary))
        descriptor=MethodDescriptor(
            id = :example,
            label = "Example",
            structure_id = "reference2019",
            physics_signature = "fixture",
            modifies_physics = false,
            algorithm_family = :direct_reference,
        )
        run=load_method_run(descriptor, summary)
        @test only(run.points).warnings==[warning]
        @test only(run.points).status===:approximate
        @test !only(run.points).converged
    end
end

end # independent suite
