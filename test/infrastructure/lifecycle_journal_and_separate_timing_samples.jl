module Suite_T051
include("../support/common.jl")
using HDF5

@testset "Lifecycle journal and separate timing samples" begin
    mktempdir() do directory
        human=IOBuffer()
        reporter=ProgressReporter(
            joinpath(directory, "events.csv");
            human_io = human,
            strict_hierarchy = false,
        )
        begin_progress_stage!(reporter, :scba; iteration = 20, total = 80)
        for iteration = 21:23
            update_progress!(
                reporter;
                iteration,
                total = 80,
                metrics = [
                    ProgressMetric(:r_K, 7.71e-4),
                    ProgressMetric(:t_dyson, 0.1*iteration, "s"),
                ],
            )
        end
        end_progress_stage!(
            reporter,
            :scba;
            iteration = 23,
            total = 80,
            status = :incomplete,
        )
        close(reporter)
        @test !occursin("r_K", String(take!(human)))
        @test length(readlines(joinpath(directory, "events.jsonl")))==2
        @test length(readlines(joinpath(directory, "timings.csv")))==4
        latest=QCLNEGFRunner.YAML.load_file(joinpath(directory, "progress.yaml"))
        @test latest["iteration"]==23
        @test latest["remaining"]==57
        timing=QCLNEGFRunner.YAML.load_file(joinpath(directory, "timing_summary.yaml"))
        @test timing["cores"]["dyson"]["count"]==3
        @test timing["cores"]["dyson"]["median"]≈2.25
        @test timing["exclusive"]===false
    end
end

@testset "Canonical machine reporter has no duplicate scientific CSV or quantile cache" begin
    mktempdir() do directory
        reporter=ProgressReporter(;
            machine_directory = directory,
            human_io = nothing,
            strict_hierarchy = false,
        )
        begin_progress_stage!(reporter, :scba; iteration = 0, total = 2)
        for iteration = 1:2
            update_progress!(
                reporter;
                iteration,
                total = 2,
                metrics = [
                    ProgressMetric(:r_K, 1/iteration),
                    ProgressMetric(:t_dyson, 0.25*iteration, "s"),
                ],
            )
        end
        end_progress_stage!(reporter, :scba; iteration = 2, total = 2, status = :incomplete)
        close(reporter)
        @test reporter.csv_io===nothing
        @test isempty(reporter.timing_samples)
        @test reporter.timing_calls["dyson"]==2
        @test !isfile(joinpath(directory, "events.csv"))
        @test !isfile(joinpath(directory, "timing_summary.yaml"))
        @test length(readlines(joinpath(directory, "events.jsonl")))==2
        timing=readlines(joinpath(directory, "timings.csv"))
        @test first(timing)=="session_id,sequence,stage_path,iteration,core,seconds,warmup,exclusive"
        @test length(timing)==3
        @test !occursin("r_K", join(timing))
        latest=QCLNEGFRunner.YAML.load_file(joinpath(directory, "progress.yaml"))
        resumed=ProgressReporter(;
            machine_directory = directory,
            append = true,
            human_io = nothing,
        )
        @test resumed.sequence==latest["sequence"]
        close(resumed)
        @test_throws ArgumentError ProgressReporter(;
            machine_directory = joinpath(directory, "progress.yaml"),
        )
        symlink(joinpath(directory, "progress.yaml"), joinpath(directory, "unsafe"))
        @test_throws ArgumentError ProgressReporter(;
            machine_directory = joinpath(directory, "unsafe"),
        )
    end
end

end # independent suite
