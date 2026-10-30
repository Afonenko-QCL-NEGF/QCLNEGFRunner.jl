using Test, QCLNEGF, QCLNEGFRunner, Unitful, LinearAlgebra
const R04=QCLNEGFRunner; const C04=QCLNEGF; const P04_ROOT=tempdir()
include(joinpath(@__DIR__,"..","support","exact_persistence_fixture.jl"))
@testset "stored report limits use public diagnostics without a fresh solve" begin
    for path in ("src/composition/configured_run.jl","src/composition/production_workflow.jl","src/infrastructure/persistence/light_results.jl","src/infrastructure/persistence/physics_diagnostics.jl")
        src=read(joinpath(dirname(dirname(pathof(R04))),path),String)
        @test !occursin(r"\b_(solution_report_metrics|solution_validation_limits|approximate_options)\b",src)
    end
    f=p04_exact_fixture()
    report=ConvergenceReport(false,Dict(:r_D=>0.001,:r_K=>Inf),String[])
    sol=NEGFSolution(f.problem,f.bind.options,f.state.published_U,f.state.published_n,
        f.state.scba,f.state.outer_history,Dict{Symbol,Any}(),report,false,:running)
    public_metrics=solution_metric_diagnostics(sol)
    data=R04._light_validation_data(sol)
    rows=Dict(row["metric"]=>row for row in data["metrics"])
    @test rows["r_D"]["value"] == 0.001
    @test rows["r_D"]["strict_threshold"] == get(public_metrics.strict_limits,:r_D,nothing)
    @test rows["r_K"]["value"] === nothing
    @test rows["r_K"]["strict_passed"] == false
end
