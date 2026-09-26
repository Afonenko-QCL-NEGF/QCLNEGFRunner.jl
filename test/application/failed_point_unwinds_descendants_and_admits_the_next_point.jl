module Suite_T096
include("../support/common.jl")

@testset "Failed point unwinds descendants and admits the next point" begin
    BN = QCLNEGFRunner
    snapshots = BN.ProgressSnapshot[]
    observed = BN.SolverEvent[]
    physical_stack = Symbol[]
    reporter = BN.ProgressReporter(;
        human_io = nothing,
        csv_io = nothing,
        clock_ns = () -> 0,
        on_snapshot = snapshot -> push!(snapshots, snapshot),
    )
    # Model the runtime observer's LIFO requirement as well as the real
    # reporter hierarchy. An out-of-order synthetic close must fail here.
    observer = function (event)
        push!(observed, event)
        if event.stage in (:poisson, :scba)
            if event.action === Symbol("begin")
                push!(physical_stack, event.stage)
            elseif event.action === :end
                @test !isempty(physical_stack)
                @test pop!(physical_stack) === event.stage
            end
        end
    end
    sink = BN._progress_event_sink(reporter; solver_event_observer = observer)
    event(action, stage, status, iteration, total) = BN.SolverEvent(
        action,
        stage,
        String(stage),
        status,
        iteration,
        total,
        BN.SolverMetric[],
        "",
    )
    BN.begin_progress_stage!(reporter, :study; label = "independent cases")
    # Exercise the real producer: an unstarted, bounded sweep reports 0 / N.
    # A synthetic nothing / N event would violate the progress contract.
    options = BN.ProductionOptions(; event_sink = sink)
    @test BN._begin_solver_stage(options, :sweep; label = "sweep", total = 2)
    @test snapshots[end].iteration == 0
    @test snapshots[end].total == 2
    @test sink(event(:begin, :point, :running, 1, 2))
    @test sink(event(:begin, :poisson, :running, 1, 4))
    @test sink(event(:begin, :scba, :running, 0, 20))
    @test sink(event(:progress, :scba, :running, 3, 20))

    # Unrelated closes and successful out-of-order closes do not unwind.
    before = length(snapshots)
    @test !sink(event(:end, :unknown, :failed, nothing, nothing))
    @test !sink(event(:end, :point, :completed, 1, 2))
    @test length(snapshots) == before
    @test getfield.(reporter.stack, :stage) == [:study, :sweep, :point, :poisson, :scba]

    @test sink(event(:end, :point, :failed, 1, 2))
    @test getfield.(observed[(end-2):end], :stage) == [:scba, :poisson, :point]
    @test all(e -> e.action === :end && e.status === :failed, observed[(end-2):end])
    @test observed[end-2].iteration == 3
    @test observed[end-2].total == 20
    @test getfield.(reporter.stack, :stage) == [:study, :sweep]
    @test isempty(physical_stack)
    @test snapshots[end-2].stage_path == [:study, :sweep, :point, :poisson, :scba]
    @test snapshots[end-1].stage_path == [:study, :sweep, :point, :poisson]
    @test all(s -> s.status === :failed, snapshots[(end-2):end])

    @test sink(event(:begin, :point, :running, 2, 2))
    @test reporter.stack[end].iteration == 2
    @test sink(event(:begin, :poisson, :running, 1, 4))
    @test sink(event(:begin, :scba, :running, 0, 20))
    @test sink(event(:progress, :scba, :running, 2, 20))
    @test snapshots[end].stage_path == [:study, :sweep, :point, :poisson, :scba]
    @test snapshots[end].status === :running
    @test sink(event(:end, :scba, :completed, 2, 20))
    @test sink(event(:end, :poisson, :completed, 1, 4))
    @test sink(event(:end, :point, :completed, 2, 2))
    @test sink(event(:end, :sweep, :completed, 2, 2))
    BN.end_progress_stage!(reporter, :study)
    @test isempty(reporter.stack)
    @test isempty(physical_stack)
end

end # independent suite
