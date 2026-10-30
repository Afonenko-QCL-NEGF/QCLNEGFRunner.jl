using Test, QCLNEGFRunner
const R=QCLNEGFRunner
const A=R.QCLApplicationRuntime
const W=R.QCLScientificWorkflow
@testset "Prepared execution keeps the exact selected configuration and plan" begin
    @test isdefined(R,:_p05_prepared_execution)
    if isdefined(R,:_p05_prepared_execution)
        c=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
        pair=R.resolve_execution_strategy(c)
        selected,plan=pair
        @test R._p05_prepared_execution(selected,pair)===pair
        @test R._p05_prepared_execution(selected,pair)[1].production===selected.production
        @test_throws ArgumentError R._p05_prepared_execution(deepcopy(selected),pair)
        function altered(;chunk=plan.energy_chunk,budget=plan.memory_budget_bytes)
            R.ExecutionPlan(plan.requested_strategy,plan.parallel_backend,plan.worker_count,plan.blas_threads,
                chunk,plan.hilbert_columns,plan.residual_chunk,budget,plan.estimated_peak_bytes,
                plan.contraction_jobs,plan.active_contraction_workers,plan.hardware,copy(plan.reasons))
        end
        @test_throws ArgumentError R._p05_prepared_execution(selected,(selected,altered(chunk=plan.energy_chunk+1)))
        @test_throws ArgumentError R._p05_prepared_execution(selected,(selected,altered(budget=0)))
        @test_throws ArgumentError R.run_from_configuration("unread-directory";prepared_execution=pair)
        standalone=R._p05_prepared_execution(c,nothing)
        @test standalone[1].production.memory_budget_bytes==standalone[2].memory_budget_bytes # actual fixture uses auto_exact
        @test standalone[2]!==plan # actual fresh selection, no cached authority alias
    end
end
@testset "configured telemetry uses the canonical typed runtime policy" begin
    configuration=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    default=R.QCLProductionPointRunner(configuration)
    @test default.phase_telemetry==W.ScientificOutputs().telemetry
    disabled=R.QCLProductionPointRunner(configuration;phase_telemetry=W.TelemetryOutputPolicy(false,4))
    @test disabled.phase_telemetry.enabled===false && disabled.phase_telemetry.buffer_events==4
    @test_throws ArgumentError R.QCLProductionPointRunner(configuration;phase_telemetry=W.TelemetryOutputPolicy(true,0))
    oversized=R._normal_phase_policy(8)
    @test_throws ArgumentError R.QCLProductionPointRunner(configuration;
        phase_telemetry=W.TelemetryOutputPolicy(true,4),phase_observation_policy=oversized)
end
@testset "configured phase descriptor reaches current and terminal point carriers" begin
    plan=NestedSweepPlan("phase",SweepLevel("operating",[SweepAxis("bias",[1])],SweepLeaf("solve")))
    definition=RunDefinition(plan;scientific_identity=Dict("physics"=>"fixture"),software_identity=Dict("source"=>repeat("c",64)))
    point=only(planned_points(plan,definition.identity.run_id))
    for outcome in (:completed,:interrupted,:failed,:busy)
        mktempdir() do root
            repo=FilesystemRunRepository(root)
            descriptor=Dict{String,Any}("status"=>"available","session_id"=>"session",
                "current_path"=>"points/point/artifacts/progress/phases/session/phase-current.json","reason"=>nothing)
            outcome===:busy && (descriptor=Dict{String,Any}("status"=>"unavailable","session_id"=>nothing,
                "current_path"=>nothing,"reason"=>"previous_phase_writer_pending"))
            expected=deepcopy(descriptor)
            runner=FunctionPointRunner() do context
                A._set_context_phase_source!(context,descriptor)
                A._publish_context_phase_source!(context)
                current=A.read_point_status(repo,definition.identity.run_id,point.point_id)
                @test current["phase_source"]==descriptor
                descriptor["reason"]="mutated"
                @test context.phase_source==expected
                outcome===:interrupted && throw(A.SweepInterrupted("fixture interruption"))
                outcome===:failed && throw(ArgumentError("fixture failure"))
                PointExecutionResult(:completed;metadata=Dict("phase_source"=>context.phase_source))
            end
            if outcome===:interrupted
                @test_throws A.SweepInterrupted run_sweep!(repo,definition,runner)
            elseif outcome===:failed
                run_sweep!(repo,definition,runner;fail_fast=false)
            else
                run_sweep!(repo,definition,runner)
            end
            terminal=A.read_point_status(repo,definition.identity.run_id,point.point_id)
            @test terminal["phase_source"]==expected
            if outcome in (:completed,:busy)
                saved=A.read_point_result(repo,definition.identity.run_id,point.point_id)
                @test saved["result"]["phase_source"]==expected
                @test terminal["status"]=="completed"
            end
        end
    end
end

@testset "QCL point invocation publishes its actual phase source before compute" begin
    configuration=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    definition=R.configured_nested_run_definition(configuration)
    point=only(planned_points(definition.plan,definition.identity.run_id))
    graph=Dict{String,Any}("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),"components"=>[])
    for enabled in (false,true)
        mktempdir() do root
            repo=FilesystemRunRepository(root)
            runner=R.QCLProductionPointRunner(configuration;source_graph=graph,
                phase_telemetry=W.TelemetryOutputPolicy(enabled,8))
            run_sweep!(repo,definition,runner;fail_fast=false)
            status=A.read_point_status(repo,definition.identity.run_id,point.point_id)
            source=status["phase_source"]
            @test source["status"]==(enabled ? "available" : "disabled")
            @test status["status"]=="failed" # explicit final-writer gate, no numerical solve
            if enabled
                @test startswith(source["current_path"],"points/"*point.point_id*"/artifacts/")
                @test source["session_id"]!==nothing
                resident=R._PHASE_RESIDENCY[]
                @test resident!==nothing
                task=@atomic :acquire resident.task
                @test task!==nothing && timedwait(()->istaskdone(task),10;pollint=.01)==:ok
                cleanup=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
                R._p05_end_observers!(cleanup)
                @test !R._PHASE_WRITER_SLOT[]
            else
                @test source["current_path"]===nothing
            end
        end
    end
    mktempdir() do root
        @test !R._PHASE_WRITER_SLOT[]
        R._PHASE_WRITER_SLOT[]=true
        try
            repo=FilesystemRunRepository(root)
            runner=R.QCLProductionPointRunner(configuration;source_graph=graph,
                phase_telemetry=W.TelemetryOutputPolicy(true,8))
            run_sweep!(repo,definition,runner;fail_fast=false)
            status=A.read_point_status(repo,definition.identity.run_id,point.point_id)
            # Missing lifetime evidence is a pre-compute error, never a busy certificate.
            @test status["phase_source"]["status"]=="unavailable"
            @test status["phase_source"]["reason"]=="phase_source_not_initialized"
            @test R._P05_OBSERVER_EPOCH[]==0
        finally
            R._PHASE_WRITER_SLOT[]=false
        end
    end
end

@testset "Configured known busy, disabled, status-error and borrowed epoch lifetimes" begin
    configuration=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    definition=R.configured_nested_run_definition(configuration)
    point=only(planned_points(definition.plan,definition.identity.run_id))
    graph=Dict{String,Any}("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),"components"=>[])
    mktempdir() do oldroot
        id=Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point","attempt"=>"1",
            "branch_id"=>"branch","model_sha256"=>"a"^64,"plan_sha256"=>"b"^64)
        old=R._start_phase_observer(joinpath(oldroot,"old");artifact_root=oldroot,identity=id,
            source_session="old",policy=R._normal_phase_policy(8),capacity_events=8)
        @test timedwait(()->isfile(joinpath(old.directory,"phase-current.json")),5)==:ok
        lock(old.lock)
        try
            @test R._enqueue_phase!(old,R.QCLNEGF.SolverEvent(:phase_end,:scba,"row",:completed,1,1,(),""))
            R._close_phase_observer!(old)
            @test !istaskdone(old.task)
            for enabled in (true,false)
                a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
                oldbytes=R._p05_observer_work_bound(a);@test oldbytes>0 && !a.start_phase
                R._p05_end_observers!(a)
                mktempdir() do root
                    repo=FilesystemRunRepository(root)
                    runner=R.QCLProductionPointRunner(configuration;source_graph=graph,
                        phase_telemetry=W.TelemetryOutputPolicy(enabled,4))
                    run_sweep!(repo,definition,runner;fail_fast=false)
                    status=A.read_point_status(repo,definition.identity.run_id,point.point_id)
                    @test status["status"]=="failed" # unchanged native consumer gate, before Core
                    @test status["phase_source"]["status"]==(enabled ? "unavailable" : "disabled")
                    enabled && @test status["phase_source"]["reason"]=="previous_phase_writer_pending"
                    @test R._P05_OBSERVER_EPOCH[]==0
                    @test (@atomic :acquire R._PHASE_RESIDENCY[].owner)===old
                    next=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
                    @test R._p05_observer_work_bound(next)==oldbytes
                    roots=(;entry=(),resources=(),construction=(),continuation=(),history=(),observers=(),inputs_publication=())
                    @test_throws ArgumentError R._p05_input_metadata_limit(oldbytes,roots;observer_admission=next)
                    R._p05_end_observers!(next)
                end
            end
        finally
            unlock(old.lock);R._close_phase_observer!(old)
            @test timedwait(()->istaskdone(old.task),10)==:ok
            a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing);R._p05_end_observers!(a)
        end
    end
    mktempdir() do root
        repo=FilesystemRunRepository(root)
        configured=R.QCLProductionPointRunner(configuration;source_graph=graph,
            phase_telemetry=W.TelemetryOutputPolicy(true,4))
        wrapper=FunctionPointRunner() do context
            statuspath=joinpath(A.point_workspace_directory(repo,definition.identity.run_id,context.point.point_id),"status.yaml")
            original=read(statuspath);rm(statuspath);mkdir(statuspath)
            try
                failure=try R.execute_point!(configured,context);nothing catch error;error end
                @test failure isa ArgumentError
                @test occursin("native5_configured_consumer_unavailable",sprint(showerror,failure))
                @test context.phase_source["reason"]=="phase_source_status_write_failed"
                @test R._P05_OBSERVER_EPOCH[]==0
                resident=R._PHASE_RESIDENCY[]
                @test resident!==nothing && resident.owner_epoch<=R._P05_PHASE_RELEASE_EPOCH[]
                task=@atomic :acquire resident.task
                @test task!==nothing && timedwait(()->istaskdone(task),10)==:ok
            finally
                rm(statuspath);write(statuspath,original)
            end
            PointExecutionResult(:incomplete)
        end
        run_sweep!(repo,definition,wrapper)
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing);R._p05_end_observers!(a)
    end
    selected,plan=R._p05_prepared_execution(configuration,nothing)
    pair=(selected,plan);p=selected.production
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        failure=try R.run_from_configuration(selected;prepared_execution=pair,observer_admission=a);nothing catch error;error end
        @test occursin("native5_configured_consumer_unavailable",sprint(showerror,failure))
        @test R._P05_OBSERVER_EPOCH[]==a.epoch && R._p05_observer_work_bound(a)==0
        @test selected.production===p && R._p05_prepared_execution(selected,pair)===pair
    finally
        R._p05_end_observers!(a)
    end
    failure=try R.run_from_configuration(configuration);nothing catch error;error end
    @test occursin("native5_configured_consumer_unavailable",sprint(showerror,failure))
    @test R._P05_OBSERVER_EPOCH[]==0
end
@testset "configured identity uses captured plan and actual model preimage" begin
    configuration=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    definition=R.configured_nested_run_definition(configuration)
    mktempdir() do root
        repo=FilesystemRunRepository(root)
        configured=R.QCLProductionPointRunner(configuration)
        runner=FunctionPointRunner() do context
            run_root=A.run_workspace_directory(repo,definition.identity.run_id)
            path=joinpath(run_root,"execution_plan.yaml")
            capture=R._p05_capture_plan(read(path),:nested_sweep;maximum_metadata_bytes=8*1024^2)
            temperature=R._runtime_coordinate(context.point,"temperature.temperature_K")
            voltage=R._runtime_coordinate(context.point,"voltage.voltage_per_period_V")
            raw=deepcopy(configuration.raw); sources=deepcopy(configuration.provenance.sources)
            W._deep_merge!(raw,W._point_axis_inputs(temperature,voltage),sources,"fixture")
            resolved=W._resolve_configuration(raw,R.ConfigurationProvenance(copy(configuration.provenance.manifests),copy(configuration.provenance.files),sources))
            model=W._snapshot_model(resolved)
            old=R._configured_point_identity(configured,context,run_root)
            @test isdefined(R,:_configured_plan_capture)
            if isdefined(R,:_configured_plan_capture)
                bound=R._configured_plan_capture(configured,context,run_root;source_capture=capture,parent=nothing,maximum_metadata_bytes=8*1024^2)
                @test bound === capture
            end
            @test applicable(R._configured_point_identity,configured,context,capture,model)
            if applicable(R._configured_point_identity,configured,context,capture,model)
                id=R._configured_point_identity(configured,context,capture,model)
                @test id==old
                write(path,"replaced after capture")
                @test R._configured_point_identity(configured,context,capture,model)==id
            end
            PointExecutionResult(:completed)
        end
        run_sweep!(repo,definition,runner)
    end
end

@testset "configured frozen source accepts existing canonical reorder only" begin
    configuration=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    plan=NestedSweepPlan("configured_operating_points",SweepLevel("temperature",[SweepAxis("temperature_K",[70.0,80.0])],
        SweepLevel("voltage",[SweepAxis("voltage_per_period_V",[0.0])],SweepLeaf("poisson_scba"))))
    definition=RunDefinition(plan;scientific_identity=Dict("physics"=>"fixture"),software_identity=Dict("source"=>repeat("c",64)))
    mktempdir() do root
        repo=FilesystemRunRepository(root); configured=R.QCLProductionPointRunner(configuration)
        runner=FunctionPointRunner() do context
            run_root=A.run_workspace_directory(repo,definition.identity.run_id)
            original=A._sweep_plan_dict(plan); reordered=deepcopy(original)
            reverse!(reordered["root"]["axes"][1]["values"])
            bytes=Vector{UInt8}(codeunits(R.YAML.write(reordered)))
            capture=R._p05_capture_plan(bytes,:nested_sweep;maximum_metadata_bytes=8*1024^2)
            bound=R._configured_plan_capture(configured,context,run_root;source_capture=capture,parent=nothing,maximum_metadata_bytes=8*1024^2)
            @test bound.bytes==bytes && bound===capture
            padded=vcat(UInt8[0x23],fill(UInt8('x'),1024*1024),UInt8[0x0a],bytes)
            @test R._p05_capture_plan(padded,:nested_sweep;maximum_metadata_bytes=16*length(padded)).bytes==padded
            @test_throws ArgumentError R._p05_capture_plan(padded,:nested_sweep;maximum_metadata_bytes=8*length(padded)+1)
            wrong=deepcopy(reordered); wrong["root"]["axes"][1]["values"]=[70,80]
            bad=R._p05_capture_plan(Vector{UInt8}(codeunits(R.YAML.write(wrong))),:nested_sweep;maximum_metadata_bytes=8*1024^2)
            @test_throws ArgumentError R._configured_plan_capture(configured,context,run_root;source_capture=bad,parent=nothing,maximum_metadata_bytes=8*1024^2)
            PointExecutionResult(:completed)
        end
        run_sweep!(repo,definition,runner)
    end
end

@testset "native status projection is versioned and leaves generic runner contract intact" begin
    c=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    native=R.QCLProductionPointRunner(c)
    source=A._native_point_source(native)
    @test source["kind"]=="absent" && source["selected_state"]===nothing
    @test A._native_point_source(FunctionPointRunner(identity))===nothing
    definition=R.configured_nested_run_definition(c)
    point=only(planned_points(definition.plan,definition.identity.run_id))
    status=A._point_status_mapping(definition,point,:running,1;native_source=source)
    @test status["schema"]=="qcl-negf-configured-point-status-v2"
    @test status["native_source"]==source && status["latest_checkpoint"]===nothing
    @test status["phase_source"]["status"]=="disabled"
    generic=A._point_status_mapping(definition,point,:running,1)
    @test generic["schema"]=="reference2019-point-status-v1" && !haskey(generic,"native_source")
end
