module FinalNativeCommitTests
using Test, QCLNEGFRunner, QCLNEGF, SHA, Unitful, LinearAlgebra
const R=QCLNEGFRunner
const FINAL_ROOT=mktempdir(;prefix="qcl-final-unit-",cleanup=false)
const TRANSACTION=Ref{Any}(nothing)
const FIXTURE=Ref{Any}(nothing)

function plan_artifact(schema,media;kwargs...)
    merge(Dict{String,Any}("path"=>"inputs/plan","bytes"=>"0","sha256"=>repeat("a",64),
        "schema"=>schema,"media_type"=>media,"role"=>"plan","profile"=>"science","dependencies"=>String[]),
        Dict{String,Any}(string(k)=>v for (k,v) in kwargs))
end

@testset "Exact plan leaves remain admissible through existing P04 inventory" begin
    for (schema,media) in (("qcl-negf-scientific-plan-v2","application/json"),
            ("qcl-negf.nested-sweep-plan.v1","text/plain"))
        item=plan_artifact(schema,media)
        @test R._p04_artifact_fields(FINAL_ROOT,item)==item
    end
    for item in (
            plan_artifact("invented","application/json"),
            plan_artifact("qcl-negf-scientific-plan-v2","text/plain"),
            plan_artifact("qcl-negf.nested-sweep-plan.v1","application/json"),
            plan_artifact("qcl-negf-scientific-plan-v2","application/json";profile="local"),
            plan_artifact("qcl-negf-scientific-plan-v2","application/json";dependencies=["other"]),
            plan_artifact("qcl-negf-scientific-plan-v2","application/json";role="invented"),
            plan_artifact("qcl-negf-scientific-plan-v2","application/json";path="../unsafe"))
        @test_throws ArgumentError R._p04_artifact_fields(FINAL_ROOT,item)
    end
end

# This carrier is constructed through public Core APIs; no selected map or solve.
function final_fixture(;scba_status=:invalid_candidate,scba_quality=:invalid,status=:scba_invalid_candidate)
    base=tutorial_numerics();changes=(N_z=25,N_b=2,P_basis=1,N_E=9,N_k=3,N_qz=3,N_φ=4)
    numerical=NumericalParameters(;(name=>(hasproperty(changes,name) ? getproperty(changes,name) : getfield(base,name)) for name in fieldnames(NumericalParameters))...)
    flags=ScatteringOptions(LO=false,acoustic=false,impurity=false,IFR=false,alloy=false)
    problem=build_problem(;physical=reference_parameters(f_ion=1/450),numerical,scattering=flags)
    options=SolverOptions(max_scba=3,max_poisson=3)
    production_options=ProductionOptions(worker_count=1,checkpoint_every_scba=1,checkpoint_every_outer=1,
        progress_every_scba=0,progress_every_outer=0)
    p=production_options
    execution=ExactExecutionIdentity(core_code="8d3b4c8f60df6e4fa08a93f979c1c5e81ad1c2c9",julia=string(VERSION),
        blas=string(BLAS.get_config()),fftw=string(Base.pkgversion(R.FFTW)),scalar_type="Float64/ComplexF64",index_type=string(Int),
        reduction="static_chunks_v1",worker_count=1,blas_threads=BLAS.get_num_threads(),energy_chunk=p.energy_chunk,
        hilbert_columns=p.hilbert_columns,residual_chunk=p.residual_chunk,parallel_backend=p.parallel_backend)
    domain_adaptation=DomainAdaptationPolicy();shape=(9,3,2,2)
    green=GreenState(fill(1.0-1im,shape),fill(0.5im,shape),fill(-1.5im,shape),fill(2.0+0im,shape),ones(9,3),ones(9,3))
    family()=SelfEnergyFamily(ntuple(_->zeros(ComplexF64,shape),3)...)
    row=SCBAIteration(1,0.2,0.3,0.4,0.5,0.,1.,0.,0.,0.,Inf,Inf,3.,1.,1.,1.,NaN,nothing,nothing)
    names=fieldnames(SCBAIteration)
    failed=merge(NamedTuple{names}(Tuple(getfield(row,n) for n in names)),(;r_K=Inf,r_Σ=Inf))
    row=SCBAIteration((getfield(failed,n) for n in names)...)
    # Separate constructor-only unresolved fixture: the literal budget is three
    # contiguous, nonpassing rows. The original invalid one-row carrier is intact.
    history=scba_quality===:unresolved ? [SCBAIteration(i,0.2,0.3,0.4,0.5,0.,1.,0.,0.,0.,Inf,Inf,3.,1.,1.,1.,NaN,nothing,nothing) for i in 1:3] : [row]
    restart_value(x::Symbol)=String(x)
    restart_value(x::Union{Real,AbstractString,Nothing})=x
    restart_value(x)=Dict{String,Any}(string(k)=>restart_value(getfield(x,k)) for k in fieldnames(typeof(x)))
    contract=Dict{String,Any}("schema"=>"qcl-negf-exact-restart-v1","algorithms"=>restart_value(p.algorithms),
        "solver"=>Dict{String,Any}(string(k)=>restart_value(getfield(options,k)) for k in fieldnames(SolverOptions) if k ∉ (:max_scba,:max_poisson)))
    scba=SCBAResult(green,Dict{Symbol,SelfEnergyFamily}(),family(),family(),family(),history,false,scba_status,scba_quality,contract,SCBAMixerState())
    report=ConvergenceReport(false,Dict(:r_K=>NaN,:r_U=>Inf),["constructor current/original report"])
    observations=Dict{Symbol,Any}(:quality=>scba_quality,:warnings=>Any[],:acceptance_measurement_context=>Dict(
        "backend"=>"production","hilbert_roundoff_measured"=>true,"map_kernels_shared_with_solver"=>true,"final_state_alignment"=>"producer_aligned"))
    solution=NEGFSolution(problem,options,zeros(25),ones(25),scba,OuterIteration[],observations,report,false,status)
    identity=exact_restart_identity(problem,options,p,execution;domain_adaptation,kernel_options=nothing)
    state=ExactSolverState(;identity,boundary=:final,published_U=solution.Uᴴ,published_n=solution.n,scba,
        mixer_position=MixerPosition(;applied_mixes=length(history)-1,retained_mix_indices=(),last_reset_mix=0,last_reset_reason=:none,last_coefficient_fallback=:none),
        family_order=(:embedding_plus,:embedding_minus),outer_history=OuterIteration[],progress=SolverProgress(;completed_outer=0,current_outer=1,accepted_scba=length(history),outer_strict_streak=0,inner_strict_streak=0,diagnostic_streak=0),
        continuation=nothing,status,warnings=(),policy_evaluations=(),adaptation=nothing,
        measurement_context=AcceptanceContext(backend=:production,algorithms=p.algorithms,hilbert_roundoff_measured=true,
            map_kernels_shared_with_solver=true,final_state_alignment=:producer_aligned),
        final_evidence=FinalEvidenceSnapshot(;report,original_converged=false,original_status=solution.status,
            observations=CoreRecord(Dict(:quality=>scba_quality,:acceptance_measurement_context=>observations[:acceptance_measurement_context]))))
    binding=(;options,production_options,execution,domain_adaptation,kernel_options=nothing)
    (;solution,state,binding,flags)
end
function final_recorder(name,f;attempt=1,parent=nothing,kind=:nested_sweep)
    T=Float64(ustrip(u"K",f.solution.problem.physical.Tᴸ));V=0.05
    plan=Dict("name"=>"configured_operating_points","root"=>Dict("kind"=>"level","name"=>"temperature","axes"=>[
        Dict("name"=>"temperature_K","values"=>[T])],"child"=>Dict("kind"=>"level","name"=>"voltage","axes"=>[
        Dict("name"=>"voltage_per_period_V","values"=>[V])],"child"=>Dict("kind"=>"leaf","name"=>"poisson_scba"))))
    bytes=Vector{UInt8}(codeunits("# frozen original plan\r\n"*R.YAML.write(plan)))
    inputs=Dict{String,Any}(n=>Dict{String,Any}() for n in ("physical","numerical","scales","solver","kernel_construction","algorithms","physical_models","domain_adaptation"))
    inputs["scattering"]=Dict(string(n)=>getfield(f.flags,n) for n in fieldnames(ScatteringOptions))
    inputs["production"]=Dict("physics_markers"=>Dict(),"verify_fft_roundoff"=>false)
    model=Dict("scope"=>"stationary_transport_inputs_v1","inputs"=>inputs,"derived"=>Dict("effective_seed_eV"=>0.01))
    identity=Dict("run_id"=>"run","execution_id"=>"exec","point_id"=>"point","attempt"=>string(attempt),"branch_id"=>"branch$(attempt)",
        "model_sha256"=>bytes2hex(sha256(R.canonical_bytes(model))),"plan_sha256"=>bytes2hex(sha256(bytes)))
    missing()=Dict("state"=>"not_measured","reason"=>"constructor_only","evidence"=>nothing)
    initial_status=Dict{String,Any}("process"=>Dict("state"=>"failed","exit_code"=>1,"reason"=>"manufactured failed terminal"),
        (n=>missing() for n in ("convergence","physics","discretization","experimental"))...)
    status=Dict{String,Any}(n=>deepcopy(initial_status[n]) for n in ("process","discretization","experimental"))
    provenance=Dict("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),"components"=>Any[])
    directory=joinpath(FINAL_ROOT,name);mkdir(directory)
    r=ScientificHistoryRecorder(directory;artifact_root=FINAL_ROOT,identity,source_epoch="epoch$(attempt)",provenance,status=initial_status,
        maximum_scba_rows=3,parent_checkpoint=parent)
    request=publish_final_point_request!(r;plan_bytes=bytes,model_preimage=model,temperature_K=T,voltage_per_period_V=V,
        scattering_requested=f.flags,kind=:nested_sweep,maximum_metadata_bytes=32*1024^2)
    (;r,request,status,initial_status)
end
function final_commit(f,rr;presentation_sink,source_mode=:produced,solution=f.solution,terminal=f.state,
    maximum_observation_bytes=256*1024^2,maximum_metadata_bytes=64*1024^2,status=rr.status,kwargs...)
    commit_final!(rr.r,solution,terminal;f.binding...,status,request=rr.request,source_mode,
        maximum_observation_bytes,maximum_metadata_bytes,presentation_sink,kwargs...)
end
@testset "One final transaction carries mandatory diagnostics and observations" begin
    f=final_fixture();rr=final_recorder("transaction",f);bundles=Any[]
    result=final_commit(f,rr;presentation_sink=b->push!(bundles,b))
    @test keys(result)==(:checkpoint,:diagnostics,:observations)
    @test length(bundles)==1
    @test keys(only(bundles))==(:stationary_assessment,:validation,:positivity)
    @test only(bundles).validation["status"]=="scba_invalid_candidate"
    @test only(bundles).positivity["status"]=="invalid_candidate"
    ref=checkpoint_reference(result.checkpoint)
    opened=open_exact_checkpoint(FINAL_ROOT,ref;maximum_metadata_bytes=64*1024^2)
    @test checkpoint_reference(opened)==ref
    @test verify_final_artifacts(opened;diagnostics_ref=result.diagnostics,observations_ref=result.observations,
        maximum_metadata_bytes=64*1024^2).observations==result.observations
    @test !any(endswith(a["path"],".yaml") for a in R._p04_parse(opened.declaration_json)["payloads"])
    manifest=R._p04_parse(opened.manifest_json)
    for name in ("convergence","physics")
        @test manifest["status"][name]==Dict("state"=>"recorded","reason"=>nothing,"evidence"=>result.observations)
        @test opened.verified[result.observations["path"]].reference==result.observations
    end
    @test rr.r.status==manifest["status"]
    @test manifest["status"]["process"]["state"]=="failed"
    @test all(manifest["status"][n]==rr.status[n] for n in ("discretization","experimental"))
    TRANSACTION[]=(;result,opened,rr);FIXTURE[]=f
end

function with_solution(solution;changes...)
    names=fieldnames(NEGFSolution)
    fields=merge(NamedTuple{names}(Tuple(getfield(solution,n) for n in names)),(;changes...))
    NEGFSolution((getfield(fields,n) for n in names)...)
end
@testset "Recorded final evidence preserves unconverged facts and caller external evidence" begin
    # A successful process does not make this manufactured unresolved state converge.
    f=final_fixture(;scba_status=:max_iterations,scba_quality=:unresolved,status=:scba_max_iterations)
    rr=final_recorder("unconverged-status",f)
    rr.status["process"]=Dict("state"=>"succeeded","exit_code"=>0,"reason"=>nothing)
    external=deepcopy(TRANSACTION[].result.diagnostics)
    rr.status["discretization"]=Dict("state"=>"recorded","reason"=>"external fixture evidence","evidence"=>external)
    expected_external=deepcopy(rr.status["discretization"])
    result=final_commit(f,rr;presentation_sink=b->(rr.status["process"]["state"]="failed"),
        publication_hook=e->(e===:checkpoint_published && (rr.status["process"]["state"]="running")))
    manifest=R._p04_parse(result.checkpoint.manifest_json)
    cp=R._p04_parse(result.checkpoint.declaration_json)
    raw=R._p05_read_analysis(FINAL_ROOT,result.observations,cp["identity"],cp["invocation"],"final_observations",Ref(64*1024^2))
    @test manifest["status"]["process"]==Dict("state"=>"succeeded","exit_code"=>0,"reason"=>nothing)
    @test raw["summary"]["quality"]=="unconverged"
    @test raw["summary"]["status"]=="scba_max_iterations"
    @test !raw["summary"]["converged"]
    @test raw["summary"]["scientific_accepted"]!==true
    @test raw["summary"]["discretization_verified"]=="not_measured"
    @test manifest["status"]["discretization"]==expected_external
    @test manifest["status"]["experimental"]==Dict("state"=>"not_measured","reason"=>"constructor_only","evidence"=>nothing)
    for name in ("convergence","physics")
        @test manifest["status"][name]==Dict("state"=>"recorded","reason"=>nothing,"evidence"=>result.observations)
    end
    @test rr.r.status==manifest["status"]
    @test result.checkpoint.verified[external["path"]].reference==external
    @test result.checkpoint.verified[result.observations["path"]].reference==result.observations
end
@testset "Caller final status cannot override captured facts or defer external hashes" begin
    f=FIXTURE[]
    rr=final_recorder("intermediate-requires-full-status",f)
    @test_throws ArgumentError commit_exact_checkpoint!(rr.r,f.solution.problem,f.state;f.binding...,status=rr.status)
    @test !ispath(joinpath(rr.r.directory,"checkpoint"))
    mutations=(s->(s["convergence"]=deepcopy(TRANSACTION[].rr.initial_status["convergence"])),
        s->(s["physics"]=deepcopy(TRANSACTION[].rr.initial_status["physics"])),
        s->(s["extra"]=nothing),s->pop!(s,"experimental"),
        s->(s["process"]["state"]="running"),
        s->(s["experimental"]=Dict("state"=>"recorded","reason"=>nothing,"evidence"=>nothing)))
    for (i,mutate) in enumerate(mutations)
        rr=final_recorder("invalid-final-status-$(i)",f);status=deepcopy(rr.status);mutate(status)
        events=Symbol[];calls=Ref(0)
        @test_throws ArgumentError final_commit(f,rr;status,presentation_sink=b->(calls[]+=1),publication_hook=e->push!(events,e))
        @test calls[]==0 && isempty(events)
        @test !ispath(joinpath(rr.r.directory,"checkpoint")) && !ispath(joinpath(rr.r.directory,"current.json"))
    end
    for (i,field,change) in ((1,"discretization",r->(r["path"]="missing-future-evidence.json")),
            (2,"experimental",r->(r["sha256"]=repeat("0",64))))
        rr=final_recorder("invalid-external-evidence-$(i)",f);status=deepcopy(rr.status)
        reference=deepcopy(TRANSACTION[].result.diagnostics);change(reference)
        status[field]=Dict("state"=>"recorded","reason"=>nothing,"evidence"=>reference)
        # An invalid external hash must fail before even the capture-byte admission.
        error=try
            final_commit(f,rr;status,maximum_observation_bytes=1,presentation_sink=b->nothing)
        catch exception
            exception
        end
        @test error isa ArgumentError
        @test occursin("FileRef bytes/hash differ",sprint(showerror,error))
        @test !ispath(joinpath(rr.r.directory,"checkpoint")) && !ispath(joinpath(rr.r.directory,"current.json"))
    end
end
@testset "Bounded capture rejects conflicts before any final publication" begin
    f=FIXTURE[]
    for (i,cap) in enumerate((1,4096))
        rr=final_recorder("budget-$(i)",f);calls=Ref(0)
        @test_throws ArgumentError final_commit(f,rr;maximum_metadata_bytes=cap,presentation_sink=b->(calls[]+=1))
        @test calls[]==0
        @test !ispath(joinpath(rr.r.directory,"checkpoint"))
        @test !ispath(joinpath(rr.r.directory,"current.json"))
    end
    rr=final_recorder("numeric-budget",f)
    @test_throws ArgumentError final_commit(f,rr;maximum_observation_bytes=1,presentation_sink=b->nothing)
    @test !ispath(joinpath(rr.r.directory,"checkpoint"))
    rr=final_recorder("mismatched-state",f);density=copy(f.solution.n);density[1]+=1
    @test_throws ArgumentError final_commit(f,rr;solution=with_solution(f.solution;n=density),presentation_sink=b->nothing)
    @test !ispath(joinpath(rr.r.directory,"checkpoint"))
    rr=final_recorder("metadata-overflow",f)
    @test_throws OverflowError final_commit(f,rr;maximum_metadata_bytes=typemax(Int),presentation_sink=b->nothing)
    @test !ispath(joinpath(rr.r.directory,"checkpoint"))
end
@testset "Completed carrier keeps original evidence and distinct current receipts" begin
    f=FIXTURE[];parent=TRANSACTION[].opened
    report=ConvergenceReport(false,Dict(:r_K=>Inf),["CURRENT restored receipt message"])
    context=AcceptanceContext(backend=:not_executed,algorithms=f.binding.production_options.algorithms,
        hilbert_roundoff_measured=nothing,map_kernels_shared_with_solver=nothing,final_state_alignment=:restored_aligned)
    selected=RevalidationReceipt(;status=:error,reason=:nonfinite_state,detail="constructor receipt only",context,report)
    independent=IndependentOracleReceipt(;status=:not_measured,reason=:not_requested,detail="constructor receipt only",context=nothing,report=nothing)
    observations=copy(f.solution.observables)
    observations[:acceptance_measurement_context]=Dict("backend"=>"not_executed","hilbert_roundoff_measured"=>false,
        "map_kernels_shared_with_solver"=>nothing,"final_state_alignment"=>"restored_aligned")
    observations[:restoration_evidence]=CompletedStateEvidence(;original=f.state.final_evidence,revalidation=selected,independent_oracle=independent)
    solution=with_solution(f.solution;observables=observations,report,status=:validation_failed)
    rr=final_recorder("completed-child",f;attempt=2,parent);bundles=Any[]
    result=final_commit(f,rr;solution,source_mode=:completed_restore,presentation_sink=b->push!(bundles,b))
    opened=open_exact_checkpoint(FINAL_ROOT,checkpoint_reference(result.checkpoint);maximum_metadata_bytes=64*1024^2)
    @test verify_final_artifacts(opened;diagnostics_ref=result.diagnostics,observations_ref=result.observations,parent,
        maximum_metadata_bytes=64*1024^2).checkpoint===opened
    @test only(bundles).validation["messages"]==["CURRENT restored receipt message"]
    child=R._p04_parse(opened.declaration_json);old=R._p04_parse(parent.declaration_json)
    @test child["identity"]["attempt"]=="2"
    @test child["identity"]["branch_id"]!=old["identity"]["branch_id"]
    @test child["invocation"]!=old["invocation"]
    @test all(child["state"]["fields"][n]==old["state"]["fields"][n] for n in ("identity","integrity","final_evidence"))
    @test_throws ArgumentError verify_final_artifacts(opened;diagnostics_ref=result.diagnostics,observations_ref=result.observations,
        maximum_metadata_bytes=64*1024^2)
    raw=R._p05_read_analysis(FINAL_ROOT,result.observations,child["identity"],child["invocation"],"final_observations",Ref(64*1024^2))
    dm=R._p05_read_analysis(FINAL_ROOT,result.diagnostics,child["identity"],child["invocation"],"final_diagnostics",Ref(64*1024^2))
    manifest=R._p04_parse(opened.manifest_json)
    for name in ("convergence","physics")
        @test manifest["status"][name]["state"]=="recorded"
        @test manifest["status"][name]["evidence"]==result.observations
        @test manifest["status"][name]["evidence"]!=TRANSACTION[].result.observations
    end
    @test raw["summary"]["status"]=="validation_failed"
    @test child["state"]["fields"]["final_evidence"]["fields"]["original_status"]["value"]=="scba_invalid_candidate"
    @test raw["restoration"]["revalidation"]["fields"]["report"]["fields"]["messages"]==Dict(
        "kind"=>"array","eltype"=>"String","shape"=>["1"],"order"=>"F","values"=>["CURRENT restored receipt message"])
    @test rr.r.status==manifest["status"]
    @test opened.verified[result.observations["path"]].reference==result.observations
    budget=Ref(64*1024^2);plan=R._p05_input_ref(FINAL_ROOT,rr.request.plan_ref,budget);model=R._p05_input_ref(FINAL_ROOT,rr.request.model_ref,budget)
    for alter in (v->(v["restoration"]["revalidation"]["fields"]["report"]["fields"]["passed"]=true),
            v->(v["restoration"]["parent_checkpoint"]["sha256"]=repeat("0",64)),
            v->(v["restoration"]["history"]["records"]="1"),v->(v["restoration"]["original"]["field"]="report"))
        bad=deepcopy(raw);alter(bad)
        @test_throws ArgumentError R._p05_observation_check(bad,dm,manifest,child,result.observations,plan,model,parent)
    end
    rr2=final_recorder("produced-with-parent",f;attempt=3,parent)
    produced=final_commit(f,rr2;presentation_sink=b->nothing)
    @test verify_final_artifacts(produced.checkpoint;diagnostics_ref=produced.diagnostics,observations_ref=produced.observations,
        maximum_metadata_bytes=64*1024^2).observations==produced.observations
    @test_throws ArgumentError verify_final_artifacts(opened;diagnostics_ref=result.diagnostics,observations_ref=result.observations,parent=produced.checkpoint,
        maximum_metadata_bytes=64*1024^2)
end
@testset "Publication failures retain old heads or valid divergent generations" begin
    f=FIXTURE[]
    for stage in (:payload_closed,:checkpoint_published,:final_diagnostics_published,:final_observations_published,
            :manifest_published,:presentation_transferred,:recovery_pointer_published,:current_pointer_published,:acknowledged,:sink)
        rr=final_recorder("fault-$(stage)",f)
        prior=commit_exact_checkpoint!(rr.r,f.solution.problem,f.state;f.binding...,status=rr.initial_status)
        old_live=read(joinpath(rr.r.directory,"current.json"));old_recovery=read(joinpath(rr.r.directory,"recovery","current.json"))
        calls=Ref(0)
        sink=b->begin calls[]+=1;stage===:sink && error("sink failure");nothing;end
        hook=event->event===stage && error("injected $(stage)")
        @test_throws ErrorException final_commit(f,rr;presentation_sink=sink,publication_hook=hook)
        before_pointer=!(stage in (:recovery_pointer_published,:current_pointer_published,:acknowledged))
        if before_pointer
            @test read(joinpath(rr.r.directory,"current.json"))==old_live
            @test read(joinpath(rr.r.directory,"recovery","current.json"))==old_recovery
        else
            recovery=open_exact_checkpoint(FINAL_ROOT,R._p04_relative(FINAL_ROOT,joinpath(rr.r.directory,"recovery","current.json"));
                expected_identity=rr.r.identity,maximum_metadata_bytes=64*1024^2)
            @test checkpoint_reference(recovery)!=checkpoint_reference(prior)
            @test stage!==:recovery_pointer_published || read(joinpath(rr.r.directory,"current.json"))==old_live
        end
        @test calls[]==(stage in (:presentation_transferred,:recovery_pointer_published,:current_pointer_published,:acknowledged,:sink) ? 1 : 0)
        if stage in (:manifest_published,:presentation_transferred,:recovery_pointer_published,:current_pointer_published,:sink)
            pending=rr.r.pending
            @test pending!==nothing
            full=pending.manifest["status"]
            @test Set(keys(full))==Set(("process","convergence","physics","discretization","experimental"))
            evidence=full["convergence"]["evidence"]
            @test full["physics"]["evidence"]==evidence
            @test full["convergence"]["state"]==full["physics"]["state"]=="recorded"
            @test R._p04_check_ref(FINAL_ROOT,evidence)==joinpath(FINAL_ROOT,evidence["path"])
        end
        if stage===:recovery_pointer_published
            expected=deepcopy(rr.r.pending.manifest["status"])
            @test R._p04_reconcile!(rr.r)
            @test rr.r.closed
            @test rr.r.status==expected
            @test rr.r.verified[expected["physics"]["evidence"]["path"]].reference==expected["physics"]["evidence"]
        elseif stage===:acknowledged
            @test rr.r.pending===nothing
            @test rr.r.status==R._p04_parse(recovery.manifest_json)["status"]
        elseif stage===:sink
            @test !R._p04_reconcile!(rr.r)
            @test_throws ArgumentError final_commit(f,rr;presentation_sink=sink)
            @test calls[]==1
        end
    end
end
@testset "Selected closure and keyed scattering preserve actual Core order" begin
    inventory=Dict("root"=>Dict("dependencies"=>["left","right"]),"left"=>Dict("dependencies"=>["leaf"]),
        "right"=>Dict("dependencies"=>["leaf"]),"leaf"=>Dict("dependencies"=>String[]))
    @test R._p05_dag(inventory,"root")===nothing
    cycle=Dict(string(i)=>Dict("dependencies"=>i==2000 ? ["1"] : [string(i+1)]) for i in 1:2000)
    @test_throws ArgumentError R._p05_dag(cycle,"1")
    cycle["2000"]["dependencies"]=String[]
    @test R._p05_dag(cycle,"1")===nothing
    declaration=R._p04_parse(TRANSACTION[].opened.declaration_json)
    scba=declaration["state"]["fields"]["scba"]["fields"]
    family=deepcopy(scba["embedding"])
    order=["LO","acoustic","impurity","IFR","alloy","electron_electron"]
    scba["scattering"]["entries"]=[Dict("key"=>Dict("kind"=>"symbol","value"=>name),"value"=>deepcopy(family)) for name in sort(order)]
    declaration["state"]["fields"]["family_order"]=[Dict("kind"=>"symbol","value"=>name) for name in [order;"embedding_plus";"embedding_minus"]]
    @test [row["family"] for row in R._p05_state_bindings(declaration)["scattering"]]==order
    for alter in (d->push!(d["state"]["fields"]["scba"]["fields"]["scattering"]["entries"],deepcopy(first(scba["scattering"]["entries"]))),
            d->pop!(d["state"]["fields"]["family_order"]),
            d->pop!(d["state"]["fields"]["scba"]["fields"]["scattering"]["entries"]))
        bad=deepcopy(declaration);alter(bad)
        @test_throws ArgumentError R._p05_state_bindings(bad)
    end
    for status in (Symbol("x"^256),)
        snapshot_summary=FinalScientificSummary(status,:invalid,false,"registry",false,false,false,false,nothing,:not_measured,"fixture",0)
        @test R._p05_summary(snapshot_summary)["status"]=="x"^256
    end
    @test_throws ArgumentError R._p05_summary(FinalScientificSummary(Symbol("x"^257),:invalid,false,"registry",false,false,false,false,nothing,:not_measured,"fixture",0))
end
@testset "Closed declarations bind full refs, ordered dependencies and exact unavailable causes" begin
    f=FIXTURE[];t=TRANSACTION[];result=t.result;cp=t.opened
    declaration=R._p04_parse(cp.declaration_json);manifest=R._p04_parse(cp.manifest_json)
    observations=R._p05_read_analysis(FINAL_ROOT,result.observations,declaration["identity"],declaration["invocation"],"final_observations",Ref(64*1024^2))
    diagnostics=R._p05_read_analysis(FINAL_ROOT,result.diagnostics,declaration["identity"],declaration["invocation"],"final_diagnostics",Ref(64*1024^2))
    budget=Ref(64*1024^2);plan=R._p05_input_ref(FINAL_ROOT,t.rr.request.plan_ref,budget);model=R._p05_input_ref(FINAL_ROOT,t.rr.request.model_ref,budget)
    check(v,m=manifest)=R._p05_observation_check(v,diagnostics,m,declaration,result.observations,plan,model,nothing)
    @test check(observations)===nothing
    for mutate in (v->(v["context"]["extra"]=nothing),v->(v["summary"]["status"]="x"^257),
            v->(v["context"]["inputs"]["g_s"]["decimal"]="-1"),
            v->(v["request"]["plan"]["sha256"]=repeat("0",64)),
            v->(v["binding"]["terminal_integrity"][1]["decimal"]=v["binding"]["terminal_integrity"][1]["decimal"]=="0" ? "1" : "0"),
            v->(v["context"]["energy_reference"]="invented"),v->(v["request"]["coordinate_checks"]["voltage"]["status"]="verified"),
            v->push!(v["issues"],Dict("target"=>"positivity","status"=>"not_measured","reason"=>"positivity_measurement_failed","detail"=>"invented")))
        bad=deepcopy(observations);mutate(bad)
        @test_throws ArgumentError check(bad)
    end
    for mutate in (m->reverse!(only(filter(a->a["path"]==result.observations["path"],m["artifacts"]))["dependencies"]),
            m->pop!(only(filter(a->a["path"]==result.observations["path"],m["artifacts"]))["dependencies"]),
            m->(only(filter(a->a["path"]==t.rr.request.model_ref["path"],m["artifacts"]))["sha256"]=repeat("0",64)),
            m->push!(only(filter(a->a["path"]==t.rr.request.plan_ref["path"],m["artifacts"]))["dependencies"],result.observations["path"]))
        bad=deepcopy(manifest);mutate(bad)
        @test_throws ArgumentError check(observations,bad)
    end
    wrong=deepcopy(result.diagnostics);wrong["sha256"]=repeat("0",64)
    @test_throws ArgumentError verify_final_artifacts(cp;diagnostics_ref=wrong,observations_ref=result.observations,maximum_metadata_bytes=64*1024^2)
    @test_throws ArgumentError verify_final_artifacts(cp;diagnostics_ref=result.observations,observations_ref=result.diagnostics,maximum_metadata_bytes=64*1024^2)
    @test_throws ArgumentError R._p05_json(Dict("forbidden"=>NaN),1024)
end
@testset "actual returned problem is validated before final publication" begin
    f=final_fixture();rr=final_recorder("wrong-returned-problem",f)
    # Public positional constructors manufacture only the mismatched negative
    # carrier; this does not claim static admission of a new physical problem.
    problem=f.solution.problem
    changed=NEGFProblem(reference_parameters(f_ion=1/450,V_period=0.06u"V"),
        (getfield(problem,n) for n in fieldnames(typeof(problem))[2:end])...)
    old=f.solution
    wrong=NEGFSolution(changed,old.options,old.Uᴴ,old.n,old.scba,old.outer_history,
        old.observables,old.report,old.converged,old.status)
    @test_throws ArgumentError final_commit(f,rr;solution=wrong,presentation_sink=b->error("must not transfer"))
    @test !isfile(joinpath(rr.r.directory,"current.json"))
    @test !isfile(joinpath(rr.r.directory,"recovery","current.json"))
    @test !rr.r.closed
end

end
