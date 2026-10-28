# Manufactured public rows and metadata; arrays have independently checkable literal values.
p04_identity(attempt=1)=Dict{String,Any}("run_id"=>"run","execution_id"=>"exec","point_id"=>"point",
    "attempt"=>string(attempt),"branch_id"=>"branch","model_sha256"=>repeat("a",64),"plan_sha256"=>repeat("b",64))
p04_provenance()=Dict("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),
    "components"=>[Dict("path"=>"components/QCLNEGF.jl","revision"=>repeat("b",40),
        "url"=>"https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl")])
function p04_status()
    unavailable()=Dict("state"=>"not_measured","reason"=>"manufactured_not_executed","evidence"=>nothing)
    Dict{String,Any}("process"=>Dict("state"=>"running","exit_code"=>nothing,"reason"=>nothing),
        (name=>unavailable() for name in ("convergence","physics","discretization","experimental"))...)
end
function p04_row(i=1;sequence=7,outer=1,domain=0,action=:append,stage=:scba)
    row=stage===:scba ? SCBAIteration(i,ntuple(_->0.0,16)...,nothing,nothing) :
        OuterIteration(outer,ntuple(_->0.0,9)...,[0.25,0.75],[1.0,2.0,3.0])
    ScientificHistorySnapshot(;stage,domain_revision=domain,discretization_id="grid-$(domain)",
        basis_id="basis-$(domain)",outer_iteration=outer,inner_iteration=stage===:scba ? i : nothing,
        sequence,converged=false,status=:running,quality=:unresolved,strict_streak=0,
        diagnostic_streak=0,row,action)
end
function p04_recorder(name;attempt=1,parent=nothing,kwargs...)
    path=joinpath(P04_ROOT,name);mkdir(path)
    R04.ScientificHistoryRecorder(path;artifact_root=P04_ROOT,identity=p04_identity(attempt),
        source_epoch="epoch$(attempt)",provenance=p04_provenance(),status=p04_status(),
        maximum_scba_rows=3,parent_checkpoint=parent,kwargs...)
end

# Pure public constructors + problem construction; no SCBA/Poisson or map evaluation.
function p04_exact_fixture()
    base=tutorial_numerics();changes=(N_z=25,N_b=1,P_basis=1,N_E=9,N_k=2,N_qz=3,N_φ=4)
    n=NumericalParameters(;(name=>(hasproperty(changes,name) ? getproperty(changes,name) : getfield(base,name)) for name in fieldnames(NumericalParameters))...)
    problem=build_problem(physical=reference_parameters(f_ion=1/450),numerical=n,
        scattering=ScatteringOptions(LO=false,acoustic=false,impurity=false,IFR=false,alloy=false))
    options=SolverOptions(max_scba=3,max_poisson=3)
    production=ProductionOptions(worker_count=1,checkpoint_every_scba=1,checkpoint_every_outer=1,
        progress_every_scba=0,progress_every_outer=0)
    execution=ExactExecutionIdentity(core_code="103df1eb0252399d23858fc009d41c52a5f8a630",julia=string(VERSION),
        blas=string(BLAS.get_config()),fftw=string(Base.pkgversion(R04.FFTW)),scalar_type="Float64/ComplexF64",index_type=string(Int),
        reduction="static_chunks_v1",worker_count=1,blas_threads=BLAS.get_num_threads(),energy_chunk=production.energy_chunk,
        hilbert_columns=production.hilbert_columns,residual_chunk=production.residual_chunk,parallel_backend=production.parallel_backend)
    policy=DomainAdaptationPolicy();shape=(9,2,1,1)
    green=GreenState(fill(1.0-1im,shape),zeros(ComplexF64,shape),fill(-1.5im,shape),
        fill(2.0+0im,shape),ones(9,2),ones(9,2))
    family()=SelfEnergyFamily(ntuple(_->zeros(ComplexF64,shape),3)...)
    witness=SCBAPhysicsWitness(:spectral,1,1,-0.1,1.0,0.0,0.1,0.1,1.0,0.0,
        Dict("literal"=>reshape(ComplexF64[1+2im],1,1)),ComplexF64[1+0im])
    row=SCBAIteration(1,0.2,0.3,0.4,0.5,0.0,1.0,0.0,0.0,0.0,Inf,Inf,3.0,1.0,1.0,1.0,NaN,witness,nothing)
    restart_value(x::Symbol)=String(x)
    restart_value(x::Union{Real,AbstractString,Nothing})=x
    restart_value(x)=Dict{String,Any}(string(k)=>restart_value(getfield(x,k)) for k in fieldnames(typeof(x)))
    contract=Dict{String,Any}("schema"=>"qcl-negf-exact-restart-v1","algorithms"=>restart_value(production.algorithms),
        "solver"=>Dict{String,Any}(string(k)=>restart_value(getfield(options,k)) for k in fieldnames(SolverOptions) if k ∉ (:max_scba,:max_poisson)))
    scba=SCBAResult(green,Dict{Symbol,SelfEnergyFamily}(),family(),family(),family(),[row],false,:running,:unresolved,contract,SCBAMixerState())
    continuation=SCBAContinuation(decision=SCBAStopDecision(false,false,:running,:unresolved,"pending"),
        candidate=FixedPointAuditCandidate(Dict{Symbol,SelfEnergyFamily}(),family(),family(),family(),0.0),
        next_previous_current=3.0,next_previous_populations=zeros(1),seed_mu_scaled=nothing,
        seed_number_ratio=nothing,witness_retention=(1,1,1))
    identity=exact_restart_identity(problem,options,production,execution;domain_adaptation=policy,kernel_options=nothing)
    state=ExactSolverState(;identity,boundary=:scba_accepted,published_U=zeros(25),published_n=ones(25),scba,
        mixer_position=MixerPosition(;applied_mixes=0,retained_mix_indices=(),last_reset_mix=0,last_reset_reason=:none,last_coefficient_fallback=:none),
        family_order=(:embedding_plus,:embedding_minus),
        outer_history=[OuterIteration(1,ntuple(_->0.0,9)...,[0.25],fill(1.5,25))],progress=SolverProgress(1,2,1,0,0,0),
        continuation,status=:running_scba,warnings=(CoreRecord(Dict("signed_zero"=>-0.0,"nan"=>reinterpret(Float64,0x7ff8000000000002))),),
        policy_evaluations=(),adaptation=nothing,measurement_context=AcceptanceContext(backend=:production,algorithms=production.algorithms,
            hilbert_roundoff_measured=true,map_kernels_shared_with_solver=true,final_state_alignment=:producer_aligned),final_evidence=nothing)
    bind=(;options,production_options=production,execution,domain_adaptation=policy,kernel_options=nothing)
    (;problem,state,bind)
end
function p04_snapshot(f;sequence=7,action=:append)
    ScientificHistorySnapshot(;stage=:scba,domain_revision=0,discretization_id="grid-0",basis_id="basis-0",
        outer_iteration=f.state.progress.current_outer,inner_iteration=1,sequence,converged=false,status=:running,quality=:unresolved,
        strict_streak=0,diagnostic_streak=0,row=f.state.scba.history[1],action)
end

function p04_final_fixture()
    f=p04_exact_fixture();old=f.state.scba;row=last(old.history)
    names=fieldnames(C04.SCBAIteration)
    fields=merge(NamedTuple{names}(Tuple(getfield(row,n) for n in names)),(;r_K=Inf,r_Σ=Inf))
    failed=C04.SCBAIteration((getfield(fields,n) for n in names)...)
    scba=C04.SCBAResult(old.green,old.scattering,old.embedding,old.embedding_plus,old.embedding_minus,
        [failed],false,:invalid_candidate,:invalid,old.restart_contract,old.mixer_state)
    evidence=C04.FinalEvidenceSnapshot(report=C04.ConvergenceReport(false,Dict(:r_K=>NaN),["manufactured postmortem"]),
        original_converged=false,original_status=:scba_invalid_candidate,observations=C04.CoreRecord(Dict("quality"=>"unconverged")))
    state_names=fieldnames(C04.ExactSolverState)[1:end-1]
    original=NamedTuple{state_names}(Tuple(getfield(f.state,n) for n in state_names))
    state=C04.ExactSolverState(;merge(original,(;boundary=:final,scba,continuation=nothing,
        status=:scba_invalid_candidate,final_evidence=evidence))...)
    (;f.problem,state,f.bind)
end

# Forge a new, internally hash-consistent metadata locator for negative import cases.
# Original fixtures remain immutable and available; this writes only a fresh owned test namespace.
function p04_forge(checkpoint,name;payload_mutator=nothing,declaration_mutator=d->nothing,manifest_mutator=m->nothing)
    directory=joinpath(P04_ROOT,name);mkdir(directory)
    declaration=R04._p04_parse(checkpoint.declaration_json)
    manifest=R04._p04_parse(checkpoint.manifest_json)
    replacepaths=Dict{String,String}()
    if payload_mutator!==nothing
        old=declaration["payloads"][1];path=joinpath(directory,"arrays.h5")
        cp(joinpath(P04_ROOT,old["path"]),path;force=false);payload_mutator(path)
        ref=R04._p04_ref(P04_ROOT,path,old["schema"];media=old["media_type"])
        declaration["payloads"][1]=ref;R04._p04_bind_arrays!(declaration["state"],ref)
        replacepaths[old["path"]]=ref["path"]
        for a in manifest["artifacts"]
            a["path"]==old["path"] || continue
            for (k,v) in ref;a[k]=v;end
        end
    end
    declaration_mutator(declaration)
    cpfile=joinpath(directory,"declaration.json")
    open(io->R04._p04_json(io,declaration),cpfile,"w")
    cpref=R04._p04_ref(P04_ROOT,cpfile,"qcl-negf.checkpoint-declaration.v1")
    old=manifest["checkpoint"];replacepaths[old["path"]]=cpref["path"]
    manifest["checkpoint"]=cpref
    for a in manifest["artifacts"]
        if a["path"]==old["path"];for (k,v) in cpref;a[k]=v;end;end
        a["dependencies"]=[get(replacepaths,d,d) for d in a["dependencies"]]
    end
    manifest_mutator(manifest)
    path=joinpath(directory,"manifest.json");open(io->R04._p04_json(io,manifest),path,"w")
    Dict("identity"=>manifest["identity"],"state_id"=>manifest["state_id"],"state_sequence"=>manifest["state_sequence"],
        "manifest"=>R04._p04_ref(P04_ROOT,path,"qcl-negf.result-manifest.v1"))
end

# Change one selected original's metadata and re-sign only its leaf/catalog/envelopes.
function p04_forge_record(checkpoint,name,mutator)
    declaration=R04._p04_parse(checkpoint.declaration_json)
    target=declaration["witness_targets"][1];old=target["locator"]["leaf"]
    directory=joinpath(P04_ROOT,name*"-leaf");mkdir(directory)
    path=joinpath(directory,"records.h5");cp(joinpath(P04_ROOT,old["path"]),path;force=false)
    R04.HDF5.h5open(path,"r+") do file
        offsets=read(file,"records/offsets");raw=read(file,"records/json_utf8")
        records=[R04._p04_parse(String(raw[Int(offsets[i])+1:Int(offsets[i+1])])) for i in 1:length(offsets)-1]
        mutator(records[parse(Int,target["locator"]["row_offset"])+1])
        bytes=UInt8[];positions=UInt64[0]
        for record in records
            append!(bytes,codeunits(R04._p04_json(record)));push!(positions,length(bytes))
        end
        for dataset in ("records/json_utf8","records/offsets");R04.HDF5.delete_object(file,dataset);end
        file["records/json_utf8"]=bytes;file["records/offsets"]=positions
    end
    leaf=R04._p04_ref(P04_ROOT,path,old["schema"];media=old["media_type"])
    page=R04._p04_parse(read(joinpath(P04_ROOT,declaration["history"]["head"]["path"]),String))
    for artifact in page["artifacts"]
        artifact["path"]==old["path"] && merge!(artifact,leaf)
    end
    path=joinpath(directory,"catalog.json");open(io->R04._p04_json(io,page),path,"w")
    pin=deepcopy(declaration["history"]);pin["head"]=R04._p04_ref(P04_ROOT,path,"qcl-negf.scientific-catalog.v1")
    p04_forge(checkpoint,name;declaration_mutator=d->begin
        d["history"]=pin;d["witness_targets"][1]["locator"]["leaf"]=leaf
        d["payloads"]=[v==old ? leaf : v for v in d["payloads"]]
    end,manifest_mutator=m->begin
        m["history"]=pin
        for artifact in m["artifacts"]
            artifact["path"]==old["path"] && merge!(artifact,leaf)
            artifact["dependencies"]=[v==old["path"] ? leaf["path"] : v for v in artifact["dependencies"]]
        end
    end)
end

# Finite constructors over the published graph; values test transport of every node,
# not Core numerical admission for arbitrary combinations of those nodes.
Base.@nospecializeinfer function p04_graph_value(@nospecialize(T),f)
    T===Any && return Dict{String,Any}("nothing"=>nothing,"bool"=>true,"text"=>"fixture",
        "integer"=>Int64(-1),"float"=>-0.0,"symbol"=>:fixture,"nested"=>Dict{String,Any}())
    T===C04.ExactSolverState && return f.state
    T===C04.ExactExecutionIdentity && return f.bind.execution
    T===C04.ExactRestartIdentity && return f.state.identity
    T===C04.SCBAResult && return f.state.scba
    T===C04.SolverMetric && return C04.SolverMetric(:fixture,nothing,"";measurement_status=:not_measured,reason=:fixture)
    T===C04.ScientificHistorySnapshot && return p04_snapshot(f)
    T===C04.PhysicalParameters && return f.problem.physical
    T===C04.NumericalParameters && return f.problem.numerical
    T===C04.Layer && return first(f.problem.physical.layers)
    T===C04.ScaleSystem && return f.problem.scales
    T===C04.PhysicalModelOptions && return f.problem.models
    T===C04.ElectronElectronOptions && return C04.ElectronElectronOptions()
    T===C04.DomainAdaptationPolicy && return C04.DomainAdaptationPolicy()
    T===Nothing && return nothing
    T===Bool && return true
    T===String && return "fixture"
    T===Symbol && return :fixture
    T<:Integer && return T(1)
    T<:AbstractFloat && return T(0.25)
    T<:Complex && return T(0.25-0.5im)
    T<:Unitful.AbstractQuantity && return 0.25unit(zero(T))
    if T isa Union || T===C04.CoreDatum
        variants=T isa Union ? Base.uniontypes(T) : [C04.CoreScalar]
        return p04_graph_value(first(variants),f)
    elseif T<:C04.CoreArray
        return C04.CoreArray(fill(p04_graph_value(eltype(fieldtype(T,2)),f),2))
    elseif T<:AbstractArray
        return fill(p04_graph_value(eltype(T),f),ntuple(_->1,ndims(T)))
    elseif T<:Tuple
        node=R04._p04_types().nodes[R04._p04_typeid(T)]
        ids=haskey(node,"elements") ? node["elements"] : [node["element"]]
        return convert(T,Tuple(p04_graph_value(R04._p04_types().types[id],f) for id in ids))
    elseif T<:AbstractDict
        return T([p04_graph_value(keytype(T),f)=>p04_graph_value(valtype(T),f)])
    end
    T((p04_graph_value(U,f) for U in fieldtypes(T))...)
end
