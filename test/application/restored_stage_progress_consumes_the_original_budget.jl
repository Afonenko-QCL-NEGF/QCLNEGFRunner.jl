module Suite_T063
include("../support/common.jl")
include("../support/numerical_convergence.jl")

@testset "Restored stage progress consumes the original budget" begin
    events = SolverEvent[]
    options = ProductionOptions(
        event_sink = event -> (push!(events, event); true),
        outer_iteration = 3,
    )
    QCLNEGFRunner._begin_solver_stage(options, :scba; iteration = 20, total = 80)
    @test only(events).iteration == 20
    @test only(events).total - only(events).iteration == 60
    @test QCLNEGFRunner.with_production_options(options).outer_iteration == 3
end

end # independent suite
