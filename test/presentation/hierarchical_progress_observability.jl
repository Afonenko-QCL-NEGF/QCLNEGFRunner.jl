module Suite_T065
include("../support/common.jl")

@testset "Hierarchical progress observability" begin
    BN = QCLNEGFRunner

    human = IOBuffer()
    csv = IOBuffer()
    ticks = Ref(0)
    snapshots = BN.ProgressSnapshot[]
    reporter = BN.ProgressReporter(;
        human_io = human,
        csv_io = csv,
        significant_digits = 4,
        human_every = 5,
        on_snapshot = snapshot -> push!(snapshots, snapshot),
        clock_ns = () -> ticks[],
    )

    BN.begin_progress_stage!(reporter, :study; label = "reference design methods")
    BN.begin_progress_stage!(reporter, :sweep; label = "exact threaded")
    BN.begin_progress_stage!(
        reporter,
        :point;
        label = "T=200 K, Vp=52 mV",
        iteration = 2,
        total = 11,
    )
    BN.begin_progress_stage!(reporter, :poisson; iteration = 1, total = 50)
    BN.begin_progress_stage!(reporter, :scba; iteration = 0, total = 1000)
    ticks[] = 2_500_000_000
    progress = BN.update_progress!(
        reporter;
        iteration = 445,
        metrics = [
            BN.ProgressMetric(:current, 1.3375074550483463e7, "A/m^2"),
            BN.ProgressMetric(:r_Σ, 0.004489342906409144),
        ],
    )
    @test progress.stage_path == [:study, :sweep, :point, :poisson, :scba]
    @test progress.iteration == 445
    @test progress.total == 1000
    @test progress.fraction == 0.445
    @test progress.elapsed_seconds == 2.5
    @test getfield.(progress.metrics, :name) == [:current, :r_Σ]
    @test BN.latest_progress(reporter) === progress

    # Iterations are absent from the lifecycle journal and remain in complete
    # CSV and callback streams.
    ticks[] = 3_000_000_000
    BN.update_progress!(
        reporter;
        iteration = 446,
        metrics = (r_D = 2.2834743281708217e-16,),
    )
    human_before_end = String(take!(human))
    @test occursin("SCBA 0/1000", human_before_end)
    @test !occursin("445/1000", human_before_end)
    @test !occursin("r_Σ", human_before_end)
    @test !occursin("446/1000", human_before_end)

    ticks[] = 4_000_000_000
    ended = BN.end_progress_stage!(
        reporter,
        :scba;
        status = :completed,
        iteration = 446,
        metrics = [BN.ProgressMetric(:r_D, 2.2834743281708217e-16)],
    )
    @test ended.status == :completed
    @test reporter.stack[end].stage == :poisson
    @test_throws ArgumentError BN.end_progress_stage!(reporter, :point)
    @test reporter.stack[end].stage == :poisson

    BN.end_progress_stage!(reporter, :poisson; status = :failed)
    BN.end_progress_stage!(reporter, :point; status = :failed)
    BN.end_progress_stage!(reporter, :sweep; status = :failed)
    BN.end_progress_stage!(reporter, :study; status = :failed)
    @test isempty(reporter.stack)
    @test length(snapshots) == 12
    @test occursin("status=failed", String(take!(human)))

    csv_text = String(take!(csv))
    @test startswith(csv_text, "sequence,event,stage_path")
    @test occursin("study/sweep/point/poisson/scba,scba", csv_text)
    @test occursin("0.004489342906409144,float64", csv_text)
    @test occursin("2.2834743281708217e-16,float64", csv_text)
    @test occursin(",446,1000,0.446,", csv_text)

    @test BN.compact_number(6.752666160000001; significant_digits = 4) == "6.753"
    @test BN.compact_number(0.0) == "0"
    @test BN.compact_number(Inf) == "Inf"
    @test BN.compact_number(-Inf) == "-Inf"
    @test BN.compact_number(NaN) == "NaN"
    @test_throws ArgumentError BN.compact_number(1.0; significant_digits = 1)
    @test BN.current_density_A_per_cm2(2.0e7) == 2.0e3
    @test_throws ArgumentError BN.current_density_A_per_cm2(Inf)

    invalid =
        BN.ProgressReporter(; human_io = nothing, csv_io = nothing, clock_ns = () -> 0)
    @test_throws ArgumentError BN.begin_progress_stage!(invalid, :scba)
    @test isempty(invalid.stack)
    BN.begin_progress_stage!(invalid, :study)
    BN.begin_progress_stage!(invalid, :point)
    @test_throws ArgumentError BN.begin_progress_stage!(invalid, :scba)
    @test_throws ArgumentError BN.update_progress!(invalid; iteration = 2, total = 1)
    @test length(invalid.stack) == 2

    mktempdir() do directory
        path = joinpath(directory, "latest", "progress.csv")
        @test BN.save_progress_snapshot(path, progress) == abspath(path)
        text = read(path, String)
        @test count(==('\n'), text) == 3 # header + two metric rows
        @test occursin("0.004489342906409144", text)

        dashboard_path = joinpath(directory, "latest", "progress.html")
        @test BN.save_progress_dashboard(dashboard_path, snapshots) ==
              abspath(dashboard_path)
        dashboard = read(dashboard_path, String)
        @test occursin("QCLNEGFRunner live", dashboard)
        @test occursin("log10 SCBA residual history", dashboard)
        @test occursin("class=\"series r_D\"", dashboard)
        @test !occursin("0.004489342906409144", dashboard)

        log_path = joinpath(directory, "events.csv")
        owned = BN.ProgressReporter(log_path; human_io = nothing, clock_ns = () -> 0)
        BN.begin_progress_stage!(owned, :study; label = "owned")
        close(owned)
        close(owned) # close is intentionally idempotent for finally blocks
        @test !isopen(owned.csv_io)
        @test length(readlines(log_path)) == 2

        appended = BN.ProgressReporter(
            log_path;
            append = true,
            human_io = nothing,
            clock_ns = () -> 0,
        )
        BN.begin_progress_stage!(appended, :study; label = "resumed")
        close(appended)
        appended_lines = readlines(log_path)
        @test length(appended_lines) == 3 # no repeated header
        @test startswith(appended_lines[end], "2,begin,study")
    end
end

@testset "Machine progress preserves nonfinite diagnostics as text" begin
    mktempdir() do directory
        reporter=ProgressReporter(;
            machine_directory = directory,
            human_io = nothing,
            strict_hierarchy = false,
        )
        begin_progress_stage!(reporter, :scba; iteration = 10, total = 100)
        snapshot=update_progress!(
            reporter;
            iteration = 11,
            metrics = [
                ProgressMetric(:fixed_point_limiting_ratio, Inf),
                ProgressMetric(:negative, -Inf),
                ProgressMetric(:unavailable, NaN),
                ProgressMetric(:finite, 2.5),
            ],
        )
        mapping=QCLNEGFRunner.YAML.load_file(joinpath(directory, "progress.yaml"))
        @test mapping["iteration"]==11
        @test mapping["metrics"]["fixed_point_limiting_ratio"]["value"]=="Inf"
        @test mapping["metrics"]["negative"]["value"]=="-Inf"
        @test mapping["metrics"]["unavailable"]["value"]=="NaN"
        @test mapping["metrics"]["finite"]["value"]==2.5
        values=Dict(metric.name=>metric.value for metric in snapshot.metrics)
        @test values[:fixed_point_limiting_ratio]==Inf
        @test isnan(values[:unavailable])
        close(reporter)
    end
end

end # independent suite
