using Test, QCLNEGF, QCLNEGFRunner
const R = QCLNEGFRunner
@testset "public nullable metric survives application projection" begin
    event_metrics = (QCLNEGF.SolverMetric(:clock, nothing, "ns";
        measurement_status=:not_measured, reason=:clock_unavailable),)
    projected = R._application_progress_metrics(event_metrics)
    @test length(projected) == 1
    @test projected[1].value === nothing
    @test projected[1].measurement_status === :not_measured
    @test projected[1].reason === :clock_unavailable
    runtime = R._runtime_progress_metrics(event_metrics)
    @test runtime["clock"] === nothing
    @test runtime["clock_measurement_status"] == "not_measured"
    @test runtime["clock_reason"] == "clock_unavailable"
end
@testset "unavailable progress remains explicit in human and machine output" begin
    metric = R.ProgressMetric(:clock, nothing, "ns"; measurement_status=:not_measured,
        reason=:clock_unavailable)
    human = IOBuffer(); csv = IOBuffer()
    reporter = R.ProgressReporter(; human_io=human, csv_io=csv)
    snapshot = R.ProgressSnapshot(1, :begin, [:study], ["test"], nothing, nothing,
        nothing, 0.0, :running, "", [metric])
    R._emit_progress_human!(reporter, snapshot)
    R._emit_progress_csv!(reporter, snapshot)
    @test occursin("not_measured", String(take!(human)))
    csv_text = String(take!(csv))
    @test occursin("not_measured", csv_text) && occursin("clock_unavailable", csv_text)
    mapped = R._machine_progress_mapping(reporter, snapshot)["metrics"]["clock"]
    @test mapped["value"] === nothing
    @test mapped["measurement_status"] == "not_measured"
    @test mapped["reason"] == "clock_unavailable"
end
@testset "unavailable current keeps its runtime identity" begin
    values = (QCLNEGF.SolverMetric(:J, nothing, "A/cm^2";
        measurement_status=:not_measured, reason=:missing_current),)
    runtime = R._runtime_progress_metrics(values)
    @test haskey(runtime, "current_A_per_cm2")
    @test runtime["current_A_per_cm2"] === nothing
    @test runtime["current_A_per_cm2_measurement_status"] == "not_measured"
    @test runtime["current_A_per_cm2_reason"] == "missing_current"
end
@testset "append requires the current CSV header before writes" begin
    mktempdir() do dir
        path = joinpath(dir, "progress.csv")
        old = "sequence,event,legacy\n1,begin,old\n"
        write(path, old)
        companion = joinpath(dir, "events.jsonl")
        write(companion, "preserve")
        @test_throws ArgumentError R.ProgressReporter(path; append=true, human_io=nothing)
        @test read(path, String) == old
        @test read(companion, String) == "preserve"
        newpath = joinpath(dir, "fresh.csv")
        r = R.ProgressReporter(newpath; append=true, human_io=nothing)
        close(r)
        first_bytes = read(newpath, String)
        r = R.ProgressReporter(newpath; append=true, human_io=nothing)
        R.begin_progress_stage!(r, :study; metrics=R.ProgressMetric(:clock,nothing,"ns";
            measurement_status=:not_measured, reason=:missing_clock))
        close(r)
        lines = split(chomp(read(newpath, String)), '\n')
        @test startswith(read(newpath, String), first_bytes)
        @test length(split(lines[1], ',')) == length(split(lines[end], ','))
        @test occursin("not_measured,missing_clock", lines[end])
        empty_path = joinpath(dir,"empty.csv"); write(empty_path, "")
        r = R.ProgressReporter(empty_path; append=true, human_io=nothing); close(r)
        @test filesize(empty_path)>0
    end
end

# F2: a public five-positional scalar must not bypass the owning Core guards.
@testset "all public ProgressMetric constructors enforce scalar measurement invariants" begin
    routes = (
        (value,unit,status,reason) -> R.ProgressMetric(:sample,value,unit,status,reason),
        (value,unit,status,reason) -> R.ProgressMetric(:sample,value,unit;
            measurement_status=status,reason),
    )
    for construct in routes
        @test_throws ArgumentError construct(nothing,"s",:measured,nothing)
        @test_throws ArgumentError construct(1.0,"s",:invented,nothing)
        for status in (:error,:not_measured,:not_applicable)
            @test_throws ArgumentError construct(12.0,"s",status,nothing)
            metric=construct(12.0,"s",status,:diagnostic)
            @test (metric.value,metric.measurement_status,metric.reason)==(12.0,status,:diagnostic)
        end
        for value in (NaN,Inf,-Inf)
            metric=construct(value,"s",:measured,nothing)
            @test isequal(metric.value,value)
            @test (metric.measurement_status,metric.reason)==(:error,:non_finite)
        end
        for value in (-0.0,1.25,Int32(3),true,"ready",Float32(1.25),SubString("value",1,5))
            unit=SubString("xs",2,2)
            metric=construct(value,unit,:measured,nothing)
            core=QCLNEGF.SolverMetric(:sample,value,unit)
            @test isequal(Tuple(getfield(metric,f) for f in fieldnames(typeof(metric))),
                Tuple(getfield(core,f) for f in fieldnames(typeof(core))))
        end
        @test construct(nothing,"s",:not_measured,:clock_unavailable).value===nothing
    end
    @test R.ProgressMetric(:plain,3).value===Int64(3)
    @test R.ProgressMetric(:plain,true).value===true
end

@testset "positional normalization reaches public CSV YAML and human projections" begin
    mktempdir() do dir
        human=IOBuffer()
        reporter=R.ProgressReporter(joinpath(dir,"progress.csv");human_io=human)
        try
            R.begin_progress_stage!(reporter,:study;metrics=[
                R.ProgressMetric(:nonfinite,NaN,"s",:measured,nothing),
                R.ProgressMetric(:diagnostic,12.0,"s",:error,:invalid_sample),
                R.ProgressMetric(:unavailable,nothing,"s",:not_measured,:clock_unavailable),
            ])
            mapped=R.YAML.load_file(joinpath(dir,"progress.yaml"))["metrics"]
            @test mapped["nonfinite"]["value"]=="NaN"
            @test mapped["nonfinite"]["measurement_status"]=="error"
            @test mapped["nonfinite"]["reason"]=="non_finite"
            @test mapped["diagnostic"]["value"]==12.0
            @test mapped["diagnostic"]["reason"]=="invalid_sample"
            @test mapped["unavailable"]["value"]===nothing
            csv=read(joinpath(dir,"progress.csv"),String)
            @test occursin("NaN,float64,error,non_finite,s",csv)
            @test occursin("12.0,float64,error,invalid_sample,s",csv)
            @test occursin(",null,not_measured,clock_unavailable,s",csv)
            text=String(take!(human))
            @test occursin("error: non_finite",text)
            @test occursin("not_measured: clock_unavailable",text)
            R.end_progress_stage!(reporter,:study)
        finally
            close(reporter)
        end
    end
end

@testset "only measured timing samples advance first-call and steady statistics" begin
    mktempdir() do dir
        reporter=R.ProgressReporter(joinpath(dir,"progress.csv");human_io=nothing)
        diagnostics=(R.ProgressMetric(:t_error,12.0,"s";measurement_status=:error,reason=:invalid_sample),
            R.ProgressMetric(:t_unavailable,23.0,"s";measurement_status=:not_measured,reason=:clock_unavailable),
            R.ProgressMetric(:t_inapplicable,41.0,"s";measurement_status=:not_applicable,reason=:no_clock))
        try
            R.begin_progress_stage!(reporter,:study)
            R.update_progress!(reporter;metrics=diagnostics)
            @test isempty(reporter.timing_calls)
            @test isempty(reporter.timing_samples)
            @test !isfile(joinpath(dir,"timings.csv"))
            for (i,seconds) in enumerate((5.0,3.0,1.0))
                # The same clock's non-measured value must not consume its warmup slot.
                R.update_progress!(reporter;metrics=R.ProgressMetric(:t_clock,99.0,"s";
                    measurement_status=:error,reason=:invalid_sample))
                @test get(reporter.timing_calls,"clock",0)==i-1
                R.update_progress!(reporter;metrics=(R.ProgressMetric(:t_clock,seconds,"s"),diagnostics...))
                mapped=R.YAML.load_file(joinpath(dir,"progress.yaml"))["metrics"]
                @test mapped["t_error"]["value"]==12.0
                @test mapped["t_error"]["measurement_status"]=="error"
                @test mapped["t_error"]["reason"]=="invalid_sample"
                @test mapped["t_unavailable"]["value"]==23.0
                @test mapped["t_unavailable"]["measurement_status"]=="not_measured"
                @test mapped["t_unavailable"]["reason"]=="clock_unavailable"
                @test mapped["t_inapplicable"]["measurement_status"]=="not_applicable"
            end
            @test reporter.timing_calls==Dict("clock"=>3)
            @test reporter.timing_samples==Dict("clock"=>[3.0,1.0])
            R.end_progress_stage!(reporter,:study)
            rows=split.(readlines(joinpath(dir,"timings.csv")),',')
            @test length(rows)==4
            @test [row[5] for row in rows[2:end]]==fill("clock",3)
            @test [row[6] for row in rows[2:end]]==["5.0","3.0","1.0"]
            @test [row[7] for row in rows[2:end]]==["true","false","false"]
            summary=R.YAML.load_file(joinpath(dir,"timing_summary.yaml"))["cores"]
            @test Set(keys(summary))==Set(["clock"])
            @test summary["clock"]["count"]==3
            @test summary["clock"]["retained_steady_samples"]==2
            @test summary["clock"]["minimum"]==1.0
            @test summary["clock"]["maximum"]==3.0
            @test summary["clock"]["median"]==2.0
            csv=read(joinpath(dir,"progress.csv"),String)
            @test occursin("99.0,float64,error,invalid_sample",csv)
            @test occursin("23.0,float64,not_measured,clock_unavailable",csv)
        finally
            close(reporter)
        end
    end
    mktempdir() do dir
        reporter=R.ProgressReporter(;machine_directory=dir,human_io=nothing,timing_summary=false)
        try
            R.begin_progress_stage!(reporter,:study)
            for value in (2.0,4.0)
                R.update_progress!(reporter;metrics=(R.ProgressMetric(:t_clock,value,"s"),
                    R.ProgressMetric(:t_bad,12.0,"s";measurement_status=:error,reason=:invalid_sample)))
            end
            R.end_progress_stage!(reporter,:study)
            @test reporter.timing_calls==Dict("clock"=>2)
            @test isempty(reporter.timing_samples)
            @test !isfile(joinpath(dir,"timing_summary.yaml"))
            @test length(readlines(joinpath(dir,"timings.csv")))==3
        finally
            close(reporter)
        end
    end
end

@testset "seconds timing excludes other units and retains raw public diagnostics" begin
    for unit in ("ms","","ns","S","s ","s⁻¹")
        mktempdir() do dir
            snapshots=R.ProgressSnapshot[]
            human=IOBuffer()
            reporter=R.ProgressReporter(joinpath(dir,"progress.csv");human_io=human,
                on_snapshot=snapshot->push!(snapshots,snapshot))
            try
                diagnostic=R.ProgressMetric(:diagnostic,7.0,unit;
                    measurement_status=:error,reason=:invalid_sample)
                R.begin_progress_stage!(reporter,:study;metrics=diagnostic)
                R.update_progress!(reporter;metrics=R.ProgressMetric(:t_clock,1000.0,unit))
                @test isempty(reporter.timing_calls)
                @test isempty(reporter.timing_samples)
                @test !isfile(joinpath(dir,"timings.csv"))
                @test !isfile(joinpath(dir,"timing_summary.yaml"))
                mapped=R.YAML.load_file(joinpath(dir,"progress.yaml"))["metrics"]["t_clock"]
                @test mapped["value"]==1000.0
                @test mapped["unit"]==unit
                @test mapped["measurement_status"]=="measured"
                @test mapped["reason"]===nothing
                @test only(snapshots[end].metrics).unit==unit
                @test only(snapshots[end].metrics).value==1000.0
                @test occursin("diagnostic=7.0 [error: invalid_sample]",String(take!(human)))
                # Neither the initial sample nor intervening non-s values spend a warmup slot.
                for (seconds,other) in ((1.0,500.0),(0.5,250.0),(0.25,125.0))
                    R.update_progress!(reporter;metrics=R.ProgressMetric(:t_clock,seconds,"s"))
                    R.update_progress!(reporter;metrics=R.ProgressMetric(:t_clock,other,unit))
                end
                @test reporter.timing_calls==Dict("clock"=>3)
                @test reporter.timing_samples==Dict("clock"=>[0.5,0.25])
                csv=read(joinpath(dir,"progress.csv"),String)
                @test occursin("1000.0,float64,measured",csv)
                @test occursin("500.0,float64,measured",csv)
                @test only(snapshots[end].metrics).unit==unit
                R.end_progress_stage!(reporter,:study)
                rows=split.(readlines(joinpath(dir,"timings.csv")),',')
                @test [row[6] for row in rows[2:end]]==["1.0","0.5","0.25"]
                @test [row[7] for row in rows[2:end]]==["true","false","false"]
                summary=R.YAML.load_file(joinpath(dir,"timing_summary.yaml"))
                @test summary["unit"]=="s"
                @test summary["cores"]["clock"]["count"]==3
                @test summary["cores"]["clock"]["retained_steady_samples"]==2
                @test summary["cores"]["clock"]["median"]==0.375
            finally
                close(reporter)
            end
        end
    end
    for enabled in (false,true)
        mktempdir() do dir
            reporter=R.ProgressReporter(;machine_directory=dir,human_io=nothing,timing_summary=enabled)
            try
                R.begin_progress_stage!(reporter,:study)
                for value in (1000.0,500.0,250.0)
                    R.update_progress!(reporter;metrics=R.ProgressMetric(:t_clock,value,"ms"))
                end
                R.end_progress_stage!(reporter,:study)
                @test isempty(reporter.timing_calls)
                @test isempty(reporter.timing_samples)
                @test !isfile(joinpath(dir,"timings.csv"))
                @test !isfile(joinpath(dir,"timing_summary.yaml"))
            finally
                close(reporter)
            end
        end
    end
end
