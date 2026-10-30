using Test, QCLNEGFRunner, QCLNEGF, YAML
const W = QCLNEGFRunner.QCLScientificWorkflow
@testset "current point carries the exact attempt phase source" begin
    mktempdir() do root
        attempt = joinpath(root, "executions", "e", "p", "attempt-1")
        mkpath(attempt)
        point = (;id="p", execution_id="e")
        source = (status=:available, session_id="session1",
            current_path="executions/e/p/attempt-1/progress/phases/session1/phase-current.json",
            reason=nothing)
        W._scientific_progress(root, point, 1, :running, attempt; phase_source=source)
        current = YAML.load_file(joinpath(root,"current_point.json"))
        @test current["phase_source"] == Dict("status"=>"available", "session_id"=>"session1",
            "current_path"=>source.current_path,"reason"=>nothing)
    end
end
@testset "actual progress adapter admits each phase once without legacy journal" begin
    R=QCLNEGFRunner
    mktempdir() do root
        identity=Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point",
            "attempt"=>"1","branch_id"=>"branch","model_sha256"=>repeat("a",64),"plan_sha256"=>repeat("b",64))
        progress=joinpath(root,"attempt","progress");mkpath(progress)
        observer=R._start_phase_observer(joinpath(progress,"phases","session");artifact_root=root,
            identity,source_session="session",policy=R._normal_phase_policy(8),capacity_events=8)
        try
            delivered=Ref(0)
            reporter=R.ProgressReporter(;machine_directory=progress,human_io=nothing,strict_hierarchy=false)
            sink=R._progress_event_sink(reporter;phase_observer=observer,solver_event_observer=event->(delivered[]+=1))
            event=QCLNEGF.SolverEvent(:phase_begin,:scba,"mixing",:running,1,nothing,
                (QCLNEGF.SolverMetric(:producer_monotonic_ns,Int(time_ns()),"ns"),),"")
            @test sink(event) === true
            @test R._phase_observer_statistics(observer).events_seen == 1
            @test delivered[] == 1
            @test !isfile(joinpath(progress,"phases.jsonl"))
        finally
            R._close_phase_observer!(observer)
            @test timedwait(()->istaskdone(observer.task),10;pollint=0.01)==:ok
        end
    end
end
@testset "phase source fallback is explicit and cannot reuse previous attempt" begin
    mktempdir() do root
        attempt = joinpath(root, "attempt"); mkpath(attempt)
        point = (;id="p", execution_id="e")
        W._scientific_progress(root,point,1,:running,attempt;
            phase_source=(status=:unavailable,session_id=nothing,current_path=nothing,
                reason="previous_phase_writer_pending"))
        previous=YAML.load_file(joinpath(root,"current_point.json"))
        @test previous["phase_source"]["reason"] == "previous_phase_writer_pending"
        W._scientific_progress(root,point,2,:running,attempt)
        current=YAML.load_file(joinpath(root,"current_point.json"))
        @test current["phase_source"]["status"] == "unavailable"
        @test current["phase_source"]["session_id"] === nothing
        @test current["phase_source"]["current_path"] === nothing
        @test current["phase_source"]["reason"] == "phase_source_not_initialized"
    end
end
@testset "typed busy reason projects without changing science status" begin
    source = (status=:unavailable,session_id=nothing,current_path=nothing,
        reason=:previous_phase_writer_pending)
    projected = W._phase_source_projection(source)
    @test projected["status"] == "unavailable"
    @test projected["reason"] == "previous_phase_writer_pending"
end
