module P05ParentCheckpoint
using Test, QCLNEGFRunner, QCLNEGF, SHA, Unitful, LinearAlgebra
const R04=QCLNEGFRunner
const C04=QCLNEGF
const P04_ROOT=mktempdir(;prefix="qcl-p05-parent-",cleanup=true)
include("../support/exact_persistence_fixture.jl")
function input_recorder(name,f;kwargs...)
    T=Float64(ustrip(u"K",f.problem.physical.Tᴸ));V=0.05
    plan=Dict("name"=>"configured_operating_points","root"=>Dict("kind"=>"level","name"=>"temperature","axes"=>[
        Dict("name"=>"temperature_K","values"=>[T])],"child"=>Dict("kind"=>"level","name"=>"voltage","axes"=>[
        Dict("name"=>"voltage_per_period_V","values"=>[V])],"child"=>Dict("kind"=>"leaf","name"=>"poisson_scba"))))
    bytes=Vector{UInt8}(codeunits("# original fixture input\r\n"*R04.YAML.write(plan)))
    inputs=Dict{String,Any}(n=>Dict{String,Any}() for n in ("physical","numerical","scales","solver","kernel_construction","algorithms","physical_models","domain_adaptation"))
    inputs["scattering"]=Dict(string(n)=>getfield(f.problem.scattering,n) for n in fieldnames(ScatteringOptions))
    inputs["production"]=Dict("physics_markers"=>Dict(),"verify_fft_roundoff"=>false)
    model=Dict("scope"=>"stationary_transport_inputs_v1","inputs"=>inputs,"derived"=>Dict("effective_seed_eV"=>0.01))
    identity=p04_identity();identity["plan_sha256"]=bytes2hex(sha256(bytes));identity["model_sha256"]=bytes2hex(sha256(R04.canonical_bytes(model)))
    r=ScientificHistoryRecorder(joinpath(P04_ROOT,name);artifact_root=P04_ROOT,identity,source_epoch="epoch1",provenance=p04_provenance(),status=p04_status(),maximum_scba_rows=3,kwargs...)
    request=publish_final_point_request!(r;plan_bytes=bytes,model_preimage=model,temperature_K=T,voltage_per_period_V=V,
        scattering_requested=f.problem.scattering,kind=:nested_sweep,maximum_metadata_bytes=32*1024^2)
    (;r,request)
end
@testset "context callbacks retain only the global final state" begin
    f = p04_exact_fixture()
    final = p04_final_fixture()
    rr=input_recorder("context-callback",f);recorder=rr.r
    cb = R04._p05_science_callbacks(recorder, f.problem; f.bind..., status=()->p04_status(),request=rr.request,maximum_metadata_bytes=32*1024^2)
    # Constructor-only public sweep boundary: no numerical entry is opened here.
    failure=try R04.run_production_sweep(f.problem,(),();production_options=f.bind.production_options);nothing catch error;error end
    @test failure isa ArgumentError && occursin("native5_configured_consumer_unavailable",sprint(showerror,failure))
    @test R04._P05_OBSERVER_EPOCH[]==0
    admission=R04._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        @test_throws ArgumentError R04.run_production_sweep(f.problem,(),();production_options=f.bind.production_options,observer_admission=admission)
        @test R04._P05_OBSERVER_EPOCH[]==admission.epoch
    finally
        R04._p05_end_observers!(admission)
    end
    @test hasproperty(cb, :checkpoint_context_sink)
    @test hasproperty(cb, :terminal)
    if hasproperty(cb, :checkpoint_context_sink)
        @test all(name->getfield(cb.checkpoint_context_sink,name) !== f.problem,
            fieldnames(typeof(cb.checkpoint_context_sink)))
    end
    if hasproperty(cb, :checkpoint_context_sink) && hasproperty(cb, :terminal)
        @test cb.terminal[] === nothing
        @test cb.checkpoint_context_sink(final.problem, final.state) === nothing
        @test cb.terminal[] === final.state
        @test cb.latest[] === nothing
        @test_throws ArgumentError cb.checkpoint_context_sink(final.problem, final.state)
    end
end
@testset "final limits use actual joint grant without changing options" begin
    f=p04_final_fixture()
    solution=NEGFSolution(f.problem,f.bind.options,f.state.published_U,f.state.published_n,
        f.state.scba,f.state.outer_history,Dict{Symbol,Any}(),f.state.final_evidence.report,
        false,f.state.status)
    recorder=p04_recorder("final-limits")
    ref(schema,media,path)=Dict("path"=>path,"bytes"=>"0","sha256"=>repeat("a",64),"media_type"=>media,"schema"=>schema)
    request=FinalPointRequest(;plan_ref=ref("qcl-negf-scientific-plan-v2","application/json","p.json"),
        model_ref=ref("qcl-negf-resolved-configuration-v3","application/json","m.json"),
        temperature_K=70.0,voltage_per_period_V=0.0,scattering_requested=ScatteringOptions(LO=false,acoustic=false,impurity=false,IFR=false,alloy=false),kind=:scientific_plan_v2)
    status=p04_status()
    shared=zeros(UInt8,8192)
    roots=(;entry=(shared,),resources=(),construction=(shared,),continuation=(),history=(),observers=(),inputs_publication=())
    docs=(;plan=Dict("schema"=>"fixture"),model=Dict("schema"=>"fixture"))
    @test isdefined(R04,:_p05_final_limits)
    if isdefined(R04,:_p05_final_limits)
        p=f.bind.production_options; budget=128*1024^2
        a=R04._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        local limits, live
        try
        limits=R04._p05_final_limits(solution,f.state,recorder,request,status;production_options=p,
            grant_bytes=budget,live_roots=roots,input_documents=docs,observer_admission=a)
        @test keys(limits)==(:maximum_observation_bytes,:maximum_metadata_bytes)
        @test limits.maximum_observation_bytes>0 && limits.maximum_metadata_bytes>0
        live=Base.summarysize(((solution,f.state,recorder,request,status,roots,docs),a))
        slab=8*R04._SERIALIZATION_SLAB_BYTES
        remaining=budget-live-slab
        estimate=QCLNEGF.final_observation_memory_estimate(solution,f.state;maximum_metadata_bytes=remaining)
        input_cost=R04._p05_metadata_cost(docs,budget;portable=true)
        @test limits.maximum_observation_bytes==estimate.peak_additional_bytes
        @test limits.maximum_metadata_bytes==remaining-estimate.peak_additional_bytes-input_cost
        threshold=live+slab+estimate.peak_additional_bytes+input_cost+estimate.metadata_bytes
        @test_throws ArgumentError R04._p05_final_limits(solution,f.state,recorder,request,status;production_options=p,
            grant_bytes=threshold-1,live_roots=roots,input_documents=docs,observer_admission=a)
        @test p === f.bind.production_options
        @test_throws ArgumentError R04._p05_final_limits(solution,f.state,recorder,request,status;production_options=p,
            grant_bytes=1,live_roots=roots,input_documents=docs,observer_admission=a)
        finally
            R04._p05_end_observers!(a)
        end
        profile=R04.PhaseObservationPolicy(;mode=:normal,maximum_event_bytes=16384,capacity_bytes=32768,
            batch_events=2,batch_bytes=32768,flush_seconds=1.0,snapshot_seconds=1.0,
            maximum_depth=4,maximum_aggregate_keys=2,reserve_bytes=0)
        req=(;directory=joinpath(P04_ROOT,"reserved-observer"),artifact_root=P04_ROOT,
            identity=p04_identity(),source_session="session",policy=profile,capacity_events=2)
        b=R04._p05_begin_observers!(;phase_request=req,scalar_request=nothing)
        try
            @test b.phase_bytes>0
            with_observer=R04._p05_final_limits(solution,f.state,recorder,request,status;production_options=p,
                grant_bytes=budget,live_roots=roots,input_documents=docs,observer_admission=b)
            # Same stable roots/capability layout; the actual reserved payload is debited once.
            @test Base.summarysize(((solution,f.state,recorder,request,status,roots,docs),b))==live
            @test with_observer.maximum_metadata_bytes==limits.maximum_metadata_bytes-b.phase_bytes
            @test p===f.bind.production_options
            @test !ispath(req.directory) # planned reservation never spawned or performed IO
        finally
            R04._p05_end_observers!(b)
        end
    end
end
@testset "native5 parent remains bound to the actual artifact root" begin
    f=p04_exact_fixture(); recorder=p04_recorder("parent")
    R04.record_scientific_history!(recorder,p04_snapshot(f))
    written=R04.commit_exact_checkpoint!(recorder,f.problem,f.state;f.bind...,status=p04_status())
    parent=R04.open_exact_checkpoint(P04_ROOT,R04.checkpoint_reference(written);maximum_metadata_bytes=4*1024^2)
    rr=input_recorder("callback",f);callback_recorder=rr.r
    adaptive_bind=merge(f.bind,(domain_adaptation=DomainAdaptationPolicy(mode=:expand_energy_window),))
    @test_throws ArgumentError R04._p05_science_callbacks(callback_recorder,f.problem;adaptive_bind...,status=()->p04_status(),request=rr.request,maximum_metadata_bytes=32*1024^2)
    adaptive_with_kernel=merge(adaptive_bind,(;kernel_options=ProductionKernelOptions()))
    @test hasproperty(R04._p05_science_callbacks(callback_recorder,f.problem;adaptive_with_kernel...,status=()->p04_status(),request=rr.request,maximum_metadata_bytes=32*1024^2), :checkpoint_context_sink)
    callbacks=R04._p05_science_callbacks(callback_recorder,f.problem;f.bind...,status=()->p04_status(),request=rr.request,maximum_metadata_bytes=32*1024^2)
    @test callbacks.history_observer(p04_snapshot(f)) === nothing
    wrong_problem=retarget_problem(f.problem;V_period=0.05u"V")
    @test_throws ArgumentError callbacks.checkpoint_context_sink(wrong_problem,f.state)
    @test callbacks.latest[] === nothing
    @test callbacks.checkpoint_context_sink(f.problem,f.state) === nothing
    @test R04.checkpoint_reference(callbacks.latest[]) == R04.checkpoint_reference(
        R04.open_exact_checkpoint(P04_ROOT,"callback/recovery/current.json";
            expected_identity=callback_recorder.identity,maximum_metadata_bytes=4*1024^2))
    @test_throws Exception callbacks.history_observer(p04_snapshot(f))
    @test R04._cli_parent_checkpoint(Dict{String,String}(),P04_ROOT) === nothing
    @test_throws ArgumentError R04._cli_parent_checkpoint(Dict("--parent-pointer"=>"parent/recovery/current.json"),P04_ROOT)
    identity_path=joinpath(P04_ROOT,"selected-source-identity.json")
    write(identity_path,R04._p04_json(p04_identity()))
    args=Dict("--parent-pointer"=>"parent/recovery/current.json","--parent-identity"=>identity_path,
        "--parent-metadata-bytes"=>string(4*1024^2))
    @test R04.checkpoint_reference(R04._cli_parent_checkpoint(args,P04_ROOT))==R04.checkpoint_reference(parent)
    for amount in ("0","-1","true",repeat("9",100))
        invalid=copy(args); invalid["--parent-metadata-bytes"]=amount
        @test_throws ArgumentError R04._cli_parent_checkpoint(invalid,P04_ROOT)
    end
    @test R04._p05_parent_root_check(parent,P04_ROOT) === nothing
    plan=R04.resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    missing_attempt=try
        R04.QCLScientificWorkflow.execute_scientific_plan(plan,P04_ROOT;source_graph=p04_provenance(),parent_checkpoint=parent)
        nothing
    catch caught
        caught
    end
    @test missing_attempt isa ArgumentError
    @test occursin("explicit child attempt",sprint(showerror,missing_attempt))
    wrong_point=try
        R04.QCLScientificWorkflow.execute_scientific_plan(plan,P04_ROOT;source_graph=p04_provenance(),parent_checkpoint=parent,attempt=2)
        nothing
    catch caught
        caught
    end
    @test wrong_point isa ArgumentError
    @test occursin("does not match selected point",sprint(showerror,wrong_point))
    source_id=p04_identity(); source_id["point_id"]=only(plan.points).id
    source_id["execution_id"]=only(plan.executions).id
    source_dir=joinpath(P04_ROOT,"source-plan-test"); mkdir(source_dir)
    source_recorder=R04.ScientificHistoryRecorder(source_dir;artifact_root=P04_ROOT,identity=source_id,
        source_epoch="epoch1",provenance=p04_provenance(),status=p04_status(),maximum_scba_rows=3)
    R04.record_scientific_history!(source_recorder,p04_snapshot(f))
    selected=R04.commit_exact_checkpoint!(source_recorder,f.problem,f.state;f.bind...,status=p04_status())
    missing_plan=try
        R04.QCLScientificWorkflow.execute_scientific_plan(plan,P04_ROOT;source_graph=p04_provenance(),parent_checkpoint=selected,attempt=2)
        nothing
    catch caught
        caught
    end
    @test missing_plan isa ArgumentError
    @test occursin("native5_parent_plan_bytes_required",sprint(showerror,missing_plan))
    mktempdir() do other
        error=try R04._p05_parent_root_check(parent,other); nothing catch caught; caught end
        @test error isa ArgumentError
        @test occursin("native5_recovery_import_unavailable",sprint(showerror,error))
        graph=p04_provenance()
        for (call,path) in ((R04.QCLScientificWorkflow.execute_scientific_plan,joinpath(other,"direct")),
                            (R04.execute_scientific_plan_staged,joinpath(other,"staged")))
            refusal=try
                call(plan,path;source_graph=graph,parent_checkpoint=parent,attempt=2)
                nothing
            catch caught
                caught
            end
            @test refusal isa ArgumentError
            @test occursin("native5_recovery_import_unavailable",sprint(showerror,refusal))
            @test !ispath(path)
        end
    end
end
@testset "final point commits the exact triple before returning presentation" begin
    @test isdefined(R04,:_p05_commit_final_with_presentation!)
    if isdefined(R04,:_p05_commit_final_with_presentation!)
        include("../contracts/final_native_commit.jl")
        fixture=FinalNativeCommitTests.final_fixture()
        rr=FinalNativeCommitTests.final_recorder("composition-handoff",fixture)
        cb=R04._p05_science_callbacks(rr.r,fixture.solution.problem;fixture.binding...,status=()->rr.status,request=rr.request,maximum_metadata_bytes=64*1024^2)
        cb.checkpoint_context_sink(fixture.solution.problem,fixture.state)
        committed,display=R04._p05_commit_final_with_presentation!(rr.r,fixture.solution,cb.terminal[];
            fixture.binding...,status=rr.status,request=rr.request,source_mode=:produced,
            maximum_observation_bytes=256*1024^2,maximum_metadata_bytes=64*1024^2)
        @test keys(committed)==(:checkpoint,:diagnostics,:observations)
        @test keys(display)==(:stationary_assessment,:validation,:positivity)
        verified=R04.verify_final_artifacts(committed.checkpoint;diagnostics_ref=committed.diagnostics,
            observations_ref=committed.observations,maximum_metadata_bytes=64*1024^2)
        @test verified.observations==committed.observations
    end
end

@testset "configured parent binds original bytes across canonical reorder" begin
    A=R04.QCLApplicationRuntime
    config=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    runner=R04.QCLProductionPointRunner(config)
    plan=NestedSweepPlan("configured_operating_points",SweepLevel("temperature",[SweepAxis("temperature_K",[70.0,80.0])],
        SweepLevel("voltage",[SweepAxis("voltage_per_period_V",[0.0])],SweepLeaf("poisson_scba"))))
    definition=RunDefinition(plan;scientific_identity=Dict("physics"=>"fixture"),software_identity=Dict("source"=>repeat("c",64)))
    mktempdir() do root
        repo=FilesystemRunRepository(root)
        worker=FunctionPointRunner() do context
            run_root=A.run_workspace_directory(repo,definition.identity.run_id)
            doc=A._sweep_plan_dict(plan); original=deepcopy(doc); reverse!(original["root"]["axes"][1]["values"])
            capture=R04._p05_capture_plan(Vector{UInt8}(codeunits(R04.YAML.write(original))),:nested_sweep;maximum_metadata_bytes=8*1024^2)
            current=R04._p05_capture_plan(Vector{UInt8}(codeunits(R04.YAML.write(doc))),:nested_sweep;maximum_metadata_bytes=8*1024^2)
            f=p04_exact_fixture(); identity=p04_identity(); identity["run_id"]=definition.identity.run_id
            identity["point_id"]=context.point.point_id; identity["plan_sha256"]=capture.plan_sha256
            source_dir=joinpath(run_root,"parent-"*context.point.point_id);mkdir(source_dir)
            rec=R04.ScientificHistoryRecorder(source_dir;artifact_root=run_root,identity,
                source_epoch="epoch1",provenance=p04_provenance(),status=p04_status(),maximum_scba_rows=3)
            R04.record_scientific_history!(rec,p04_snapshot(f))
            parent=R04.commit_exact_checkpoint!(rec,f.problem,f.state;f.bind...,status=p04_status())
            @test_throws ArgumentError R04._configured_plan_capture(runner,context,run_root;source_capture=nothing,parent,maximum_metadata_bytes=8*1024^2)
            @test R04._configured_plan_capture(runner,context,run_root;source_capture=capture,parent,maximum_metadata_bytes=8*1024^2)===capture
            @test_throws ArgumentError R04._configured_plan_capture(runner,context,run_root;source_capture=current,parent,maximum_metadata_bytes=8*1024^2)
            PointExecutionResult(:completed)
        end
        run_sweep!(repo,definition,worker)
    end
end

@testset "canonical public history is owned before external callback mutation" begin
    f=p04_exact_fixture();rr=input_recorder("external-history",f;clock_ns=()->UInt64(0))
    sentinel=ErrorException("external history failed")
    function mutate(snapshot)
        snapshot.row.witness.matrices["literal"][1]=99+88im
        throw(sentinel)
    end
    cb=R04._p05_science_callbacks(rr.r,f.problem;f.bind...,status=()->p04_status(),
        request=rr.request,maximum_metadata_bytes=32*1024^2,external_history=mutate)
    snapshot=p04_snapshot(f)
    failure=try cb.history_observer(snapshot);nothing catch error;error end
    @test failure===sentinel
    @test only(rr.r.buffer).row.witness.matrices["literal"][1]==1+2im
    @test snapshot.row.witness.matrices["literal"][1]==99+88im
    @test rr.r.ordinal==1 && rr.r.last_sequence==snapshot.sequence
end

@testset "intermediate external state callback preserves canonical CP and mandatory error" begin
    f=p04_exact_fixture();rr=input_recorder("external-checkpoint",f)
    cb=R04._p05_science_callbacks(rr.r,f.problem;f.bind...,status=()->p04_status(),
        request=rr.request,maximum_metadata_bytes=32*1024^2)
    cb.history_observer(p04_snapshot(f))
    primary=ErrorException("external intermediate checkpoint failure")
    calls=Ref(0)
    observer=(state,it,iv)->begin
        @test state===f.state && (it,iv)==(2,3)
        calls[]+=1
        throw(primary)
    end
    failure=try R04._p05_checkpoint_delivery!(cb,f.problem,f.state,observer,2,3);nothing catch error;error end
    @test failure===primary && cb.failure[]===primary && calls[]==1
    @test cb.latest[] isa VerifiedExactCheckpoint && cb.terminal[]===nothing
    @test !rr.r.closed && !rr.r.failed
    @test open_exact_checkpoint(P04_ROOT,checkpoint_reference(cb.latest[]);maximum_metadata_bytes=64*1024^2) isa VerifiedExactCheckpoint
    @test R04._p04_parse(cb.latest[].manifest_json)["closed"]===false
end

end
