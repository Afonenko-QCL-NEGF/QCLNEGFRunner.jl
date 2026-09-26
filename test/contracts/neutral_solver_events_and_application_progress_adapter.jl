module Suite_T066
include("../support/common.jl")
using HDF5

@testset "Neutral solver events and application progress adapter" begin
    BN = QCLNEGFRunner

    # All scalar variants exercise the exact forwarding methods; without
    # those methods Julia's generated union constructor is ambiguous with the
    # AbstractFloat/Integer convenience constructors.
    metrics = BN.SolverMetric[
        BN.SolverMetric(:float, 1.25),
        BN.SolverMetric(:integer, 3),
        BN.SolverMetric(:boolean, true),
        BN.SolverMetric(:text, "ready"),
    ]
    @test getfield.(metrics, :value) == Any[1.25, 3, true, "ready"]

    events = BN.SolverEvent[]
    options = BN.ProductionOptions(event_sink = event -> begin
        push!(events, event)
        true
    end)
    owned = BN._begin_solver_stage(
        options,
        :scba;
        label = "fixture",
        total = 3,
        metrics = metrics[1],
    )
    @test owned
    @test BN._update_solver_stage(
        options,
        :scba;
        iteration = 1,
        total = 3,
        metrics = (metrics[2], metrics[3]),
        message = "advanced",
    )
    BN._end_solver_stage(
        options,
        :scba,
        owned;
        status = :completed,
        iteration = 1,
        total = 3,
        metrics = metrics[4],
    )
    @test getfield.(events, :action) == [:begin, :progress, :end]
    @test all(event -> event.stage === :scba, events)
    @test events[1].label == "fixture"
    @test events[2].message == "advanced"
    @test events[3].status === :completed
    @test all(event -> event.metrics isa Vector{BN.SolverMetric}, events)

    snapshots = BN.ProgressSnapshot[]
    reporter = BN.ProgressReporter(;
        human_io = nothing,
        csv_io = nothing,
        on_snapshot = snapshot -> push!(snapshots, snapshot),
        clock_ns = () -> 0,
    )
    BN.begin_progress_stage!(reporter, :study; label = "adapter")
    BN.begin_progress_stage!(reporter, :sweep)
    BN.begin_progress_stage!(reporter, :point)
    observed_events = BN.SolverEvent[]
    sink = BN._progress_event_sink(
        reporter;
        solver_event_observer = event -> push!(observed_events, event),
    )
    # The application owns hierarchy policy; the numerical callback simply
    # receives false when its requested child cannot be opened.
    @test !sink(
        BN.SolverEvent(:begin, :scba, "bad parent", :running, 0, 2, BN.SolverMetric[], ""),
    )
    @test sink(
        BN.SolverEvent(:begin, :poisson, "outer", :running, 0, 2, BN.SolverMetric[], ""),
    )
    @test sink(
        BN.SolverEvent(:begin, :scba, "inner", :running, 0, 4, BN.SolverMetric[], ""),
    )
    @test sink(
        BN.SolverEvent(:progress, :scba, "", :running, 1, 4, metrics[1:2], "working"),
    )
    @test sink(BN.SolverEvent(:end, :scba, "", :completed, 1, 4, metrics[1:1], "done"))
    @test sink(
        BN.SolverEvent(:end, :poisson, "", :completed, 1, 2, BN.SolverMetric[], "done"),
    )
    @test reporter.stack[end].stage === :point
    @test snapshots[end].stage_path == [:study, :sweep, :point, :poisson]
    @test snapshots[end].event === :end
    @test getfield.(observed_events, :action) == [:begin, :begin, :progress, :end, :end]
    BN.end_progress_stage!(reporter, :point)
    BN.end_progress_stage!(reporter, :sweep)
    BN.end_progress_stage!(reporter, :study)
end

end # independent suite
