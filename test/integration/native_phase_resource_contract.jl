module NativePhaseResourceContractTests
using Test, QCLNEGFRunner, YAML
const R=QCLNEGFRunner
const N=R.QCLNumerics
integer(metric)=parse(Int,metric["value"]["decimal"])
metrics(row)=Dict(m["name"]=>m for m in row["metrics"])

@testset "Producer clocks and ordinary phases under external memory controls" begin
    mktempdir() do root
        group=mkpath(joinpath(root,"group"))
        write(joinpath(group,"memory.max"),"1000000")
        write(joinpath(group,"memory.current"),"100")
        proc=mkpath(joinpath(root,"proc","self"))
        write(joinpath(proc,"cgroup"),"0::/group")
        fake_proc=dirname(proc)
        boot=joinpath(fake_proc,"sys","kernel","random","boot_id")
        mkpath(dirname(boot));write(boot,"00000000-0000-4000-8000-000000000001\n")
        width=Threads.nthreads(:default)
        observer=nothing
        primary=nothing
        try
            # A stale measured grant must not become an ordinary fit claim.
            R._NATIVE_PHASE_ADMISSIONS[root]=Dict{String,Any}(
                "memory_admission_mode"=>"cgroup_v2","memory_granted_additional_bytes"=>123)
            callback=R._native_phase_request(root;proc_root=fake_proc,cgroup_root=root)
            @test callback((task_width=1,elastic=true))==1
            @test R._NATIVE_PHASE_ADMISSIONS[root]==
                Dict("memory_admission_mode"=>"external_controls_not_predicted_fit")
            @test callback((task_width=width+1,))==width
            for bad in (true,0,-1,1.0,big(typemax(Int))+1)
                @test_throws ArgumentError callback((task_width=bad,))
            end
            for bad in (true,-1,1.0,big(typemax(Int))+1)
                @test_throws ArgumentError callback((task_width=1,memory_burst_bytes=bad))
            end
            @test callback((task_width=1,memory_burst_bytes=0))==1
            no_observer=R._native_phase_request(nothing;proc_root=fake_proc,cgroup_root=root)
            @test no_observer((task_width=width+1,))==width

            # Current P29 persistence is an explicit observer with sealed segments,
            # not the removed implicit String-directory JSONL journal.
            identity=Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point",
                "attempt"=>"1","branch_id"=>"branch","model_sha256"=>"a"^64,"plan_sha256"=>"b"^64)
            policy=R.PhaseObservationPolicy(mode=:diagnostic,maximum_event_bytes=16384,
                capacity_bytes=16*16384,batch_events=16,batch_bytes=16*16384,
                flush_seconds=0.01,snapshot_seconds=0.01,maximum_depth=4,
                maximum_aggregate_keys=16,reserve_bytes=0)
            observer=R._start_phase_observer(joinpath(root,"phases");artifact_root=root,
                identity,source_session="ordinary",policy,capacity_events=16,proc_root=fake_proc)
            source=copy(observer.source)
            options=ProductionOptions(worker_count=width,phase_timing=true,
                event_sink=event->R._record_native_phase!(observer,event),phase_request=callback)
            outer=N._production_phase_begin(options,:mixing,3;task_width=width,
                work_units=512,memory_burst_bytes=1024,workspace_bytes=256)
            inner=N._production_phase_begin(options,:mixing_gram,3;task_width=1,work_units=16)
            N._production_phase_end(options,inner);N._production_phase_end(options,outer)
            write(boot,"00000000-0000-4000-8000-000000000002\n")
            @test observer.source==source
            @test startswith(source["clock_domain_id"],"julia-monotonic:")
            write(joinpath(group,"memory.current"),"999999")
            continued=Ref(false)
            @test begin
                granted=callback((name=:mixing,iteration=4,task_width=width,memory_burst_bytes=2))
                continued[]=true;granted
            end==width
            @test continued[]
            near=N._production_phase_begin(options,:mixing,4;task_width=width,memory_burst_bytes=2)
            N._production_phase_end(options,near)
            @test R._NATIVE_PHASE_ADMISSIONS[root]==
                Dict("memory_admission_mode"=>"external_controls_not_predicted_fit")
            @test !isfile(joinpath(root,"resource-pressure.json"))
            strict_directory=joinpath(root,"strict")
            @test_throws ArgumentError R._native_phase_request(strict_directory;
                proc_root=fake_proc,cgroup_root=root,resource_policy=:campaign_strict)
            @test !ispath(strict_directory)
            R._close_phase_observer!(observer)
            @test timedwait(()->istaskdone(observer.task),10;pollint=.01)==:ok
            fetch(observer.task)
            segments=[YAML.load_file(joinpath(observer.directory,name)) for name in
                sort(readdir(observer.directory)) if startswith(name,"segment-")]
            rows=vcat((segment["rows"] for segment in segments)...)
            @test length(rows)==6
            @test all(segment["sealed"] && segment["source"]==source for segment in segments)
            @test rows[1]["span_id"]==rows[4]["span_id"]
            @test rows[2]["parent_span_id"]==rows[1]["span_id"]
            @test rows[2]["span_id"]==rows[3]["span_id"]
            @test rows[5]["span_id"]==rows[6]["span_id"]
            last_outer=metrics(rows[4]);inner_end=metrics(rows[3])
            @test last_outer["duration_seconds"]["value"]≈
                (integer(last_outer["end_monotonic_ns"])-integer(last_outer["start_monotonic_ns"]))/1e9
            @test integer(last_outer["allocated_bytes"])>=0
            @test integer(last_outer["gc_count"])>=0
            @test integer(last_outer["memory_burst_bytes"])==1024
            @test integer(last_outer["workspace_bytes"])==256
            @test !haskey(inner_end,"memory_burst_bytes")
            @test inner_end["memory_estimate_status"]["value"]=="unavailable"
            @test all(integer(metrics(row)["memory_burst_bytes"])==2 for row in rows[5:6])
            @test !any(haskey(metrics(row),"memory_granted_additional_bytes") for row in rows)
            current=YAML.load_file(joinpath(observer.directory,"phase-current.json"))
            @test current["closed"] && !current["health"]["incomplete"]
            @test current["current_phase"]===nothing
        catch error
            primary=error
            rethrow()
        finally
            try
                if observer!==nothing
                    R._close_phase_observer!(observer)
                    done=timedwait(()->istaskdone(observer.task),10;pollint=.01)==:ok
                    @test done
                    if done
                        fetch(observer.task)
                        @test !observer.failed[]
                        lock(R._PHASE_RESIDENCY_LOCK) do;R._phase_reap_locked!();end
                    end
                end
            catch secondary
                primary===nothing && rethrow()
                @error "Observer teardown failed after primary fixture failure" exception=(secondary,catch_backtrace())
            finally
                pop!(R._NATIVE_PHASE_ADMISSIONS,root,nothing)
            end
        end
    end
end
end
