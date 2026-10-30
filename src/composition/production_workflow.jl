const _P05PlanCapture = NamedTuple{(:kind,:bytes,:document,:plan_sha256),
    Tuple{Symbol,Vector{UInt8},Dict{String,Any},String}}

function _p05_capture_plan(bytes::Vector{UInt8},kind::Symbol;
    maximum_metadata_bytes::Int)::_P05PlanCapture
    maximum_metadata_bytes>0 || throw(ArgumentError("invalid plan metadata allowance"))
    kind in (:scientific_plan_v2,:nested_sweep) || throw(ArgumentError("unknown frozen plan kind"))
    Base.checked_mul(8,length(bytes))<=maximum_metadata_bytes || throw(ArgumentError("plan exceeds metadata allowance"))
    owned=copy(bytes)
    text=String(copy(owned))
    isvalid(text) || throw(ArgumentError("plan is not valid UTF-8"))
    document=if kind===:scientific_plan_v2
        # The existing bounded JSON token walk runs before parsing. Reserve
        # distinct halves for its strict DOM and configurator's own parser;
        # source bytes/copies were charged separately above.
        available=Base.checked_sub(maximum_metadata_bytes,Base.checked_mul(8,length(owned)))
        available>=2 || throw(ArgumentError("plan exceeds metadata allowance"))
        _p05_parse(text,Ref(available÷2))
        parsed=QCLScientificWorkflow._configurator_json(text;maximum=QCLScientificWorkflow.CONFIGURATOR_PLAN_BYTES)
        QCLScientificWorkflow.load_scientific_plan(parsed)
        parsed
    else
        available=Base.checked_sub(maximum_metadata_bytes,Base.checked_mul(8,length(owned)))
        available>0 || throw(ArgumentError("plan exceeds metadata allowance"))
        parsed=_p05_yaml(owned,available)
        _p05_nested_plan(parsed)
        parsed
    end
    return _P05PlanCapture((kind,owned,document,bytes2hex(sha256(owned))))
end

const _P05_LIVE_ROOT_KEYS = (:entry,:resources,:construction,:continuation,
    :history,:observers,:inputs_publication)

function _p05_begin_observers!(;phase_request,scalar_request)
    pp=if phase_request===nothing
        nothing
    else
        keys(phase_request)==(:directory,:artifact_root,:identity,:source_session,:policy,:capacity_events) ||
            throw(ArgumentError("unknown phase request profile"))
        s=phase_request
        _phase_profile(abspath(s.directory),abspath(s.artifact_root),_phase_identity(s.identity),
            _phase_portable_id(s.source_session),s.policy,s.capacity_events)
    end
    sp=if scalar_request===nothing
        nothing
    else
        keys(scalar_request)==(:sink,:capacity,:maximum_event_bytes,:poll_seconds) ||
            throw(ArgumentError("unknown scalar request profile"))
        s=scalar_request
        s.capacity isa Int && s.capacity>0 && s.maximum_event_bytes isa Int && s.maximum_event_bytes>0 &&
            s.poll_seconds isa Real && !(s.poll_seconds isa Bool) && isfinite(s.poll_seconds) && s.poll_seconds>0 ||
            throw(ArgumentError("invalid scalar resource bounds"))
        p=_scalar_profile(s.sink,s.capacity,s.maximum_event_bytes,s.poll_seconds)
        p===nothing && throw(ArgumentError("observer_capture_profile_unknown"));p
    end
    trylock(_PHASE_RESIDENCY_LOCK) || throw(ArgumentError("observer_residency_snapshot_contended"))
    try
        trylock(_SCALAR_RESIDENCY_LOCK) || throw(ArgumentError("observer_residency_snapshot_contended"))
        try
            _P05_OBSERVER_EPOCH[]==0 || throw(ArgumentError("observer epoch already active"))
            _phase_reap_locked!();_scalar_reap_locked!()
            (_PHASE_RESIDENCY[]!==nothing)==_PHASE_WRITER_SLOT[] || throw(ArgumentError("unknown phase lifetime"))
            pr,sr=_PHASE_RESIDENCY[],_SCALAR_RESIDENCY[]
            for r in (pr,sr)
                r===nothing || r.profile!==nothing || throw(ArgumentError("observer_capture_profile_unknown"))
            end
            _P05_EPOCH_COUNTER[]==typemax(UInt64) && throw(ArgumentError("observer epoch exhausted"))
            epoch=_P05_EPOCH_COUNTER[]+UInt64(1)
            startp=pr===nothing && pp!==nothing;starts=sr===nothing && sp!==nothing
            # All throwing arithmetic precedes publication of a new reservation.
            pb=pr===nothing ? (pp===nothing ? 0 : pp.payload_bound_bytes) : pr.profile.payload_bound_bytes
            sb=sr===nothing ? (sp===nothing ? 0 : sp.payload_bound_bytes) : sr.profile.payload_bound_bytes
            Base.checked_add(pb,sb)
            startp && _PHASE_GENERATION_COUNTER[]==typemax(UInt64) && throw(ArgumentError("phase generation exhausted"))
            starts && _SCALAR_GENERATION_COUNTER[]==typemax(UInt64) && throw(ArgumentError("scalar generation exhausted"))
            # Construct both records before publishing either. Allocation failure cannot
            # strand a half-reserved pair or activate an epoch without its capability.
            startp && (pr=_PhaseLifetime(pp,_PHASE_GENERATION_COUNTER[]+UInt64(1),epoch,
                Threads.Atomic{Bool}(false),Threads.Atomic{Bool}(false),nothing,nothing))
            starts && (sr=_ScalarLifetime(sp,_SCALAR_GENERATION_COUNTER[]+UInt64(1),epoch,
                Threads.Atomic{Bool}(false),Threads.Atomic{Bool}(false),nothing,nothing))
            pg=pr===nothing ? UInt64(0) : pr.generation;sg=sr===nothing ? UInt64(0) : sr.generation
            result=_P05ObserverAdmission(epoch,pg,sg,pb,sb,startp,starts)
            if startp
                _PHASE_GENERATION_COUNTER[]=pg;_PHASE_RESIDENCY[]=pr;_PHASE_WRITER_SLOT[]=true
            end
            if starts
                _SCALAR_GENERATION_COUNTER[]=sg;_SCALAR_RESIDENCY[]=sr
            end
            _P05_EPOCH_COUNTER[]=epoch
            _P05_PHASE_GENERATION[]=pg;_P05_SCALAR_GENERATION[]=sg
            _P05_OBSERVER_EPOCH[]=epoch
            result
        finally
            unlock(_SCALAR_RESIDENCY_LOCK)
        end
    finally
        unlock(_PHASE_RESIDENCY_LOCK)
    end
end
function _p05_observer_work_bound(a::_P05ObserverAdmission)::Int
    a.epoch>0 && _P05_OBSERVER_EPOCH[]==a.epoch && _P05_PHASE_GENERATION[]==a.phase_generation &&
        _P05_SCALAR_GENERATION[]==a.scalar_generation || throw(ArgumentError("stale observer admission"))
    for (r,g,b) in ((_PHASE_RESIDENCY[],a.phase_generation,a.phase_bytes),(_SCALAR_RESIDENCY[],a.scalar_generation,a.scalar_bytes))
        if r===nothing
            g==0 && b==0 || throw(ArgumentError("missing observer reservation"))
        else
            r.generation==g && r.profile!==nothing && r.profile.payload_bound_bytes==b ||
                throw(ArgumentError("observer reservation differs"))
        end
    end
    _P05_OBSERVER_EPOCH[]==a.epoch || throw(ArgumentError("stale observer admission"))
    Base.checked_add(a.phase_bytes,a.scalar_bytes)
end
function _p05_end_observers!(a::_P05ObserverAdmission)
    if _P05_OBSERVER_EPOCH[]!=a.epoch
        0<a.epoch<=min(_P05_PHASE_RELEASE_EPOCH[],_P05_SCALAR_RELEASE_EPOCH[]) && return nothing
        throw(ArgumentError("unknown observer cleanup token"))
    end
    _P05_PHASE_GENERATION[]==a.phase_generation && _P05_SCALAR_GENERATION[]==a.scalar_generation ||
        throw(ArgumentError("observer cleanup generation differs"))
    Threads.atomic_max!(_P05_PHASE_RELEASE_EPOCH,a.epoch)
    Threads.atomic_max!(_P05_SCALAR_RELEASE_EPOCH,a.epoch)
    Threads.atomic_cas!(_P05_OBSERVER_EPOCH,a.epoch,UInt64(0))
    nothing
end

# Only the public FFT-plan port uses this declaration proof. All fields have
# static storage types except the exact FFTW cFFTWPlan.pinv memo, whose actual
# initialized value is checked separately below. No namespace is an authority.
# No private Core names/getters or observer worker-graph traversal are used.
function _p05_static_storage_type(T,seen=Set{Any}())
    T===Any && return false
    T isa Union && return all(U->_p05_static_storage_type(U,seen),Base.uniontypes(T))
    T isa DataType && isconcretetype(T) || return false
    (T<:Function || T<:Task || T<:Union{_NativePhaseObserver,ScalarTelemetrySender} || T<:Type) && return false
    isprimitivetype(T) && return true
    T===String && return true
    T in seen && return true
    push!(seen,T)
    if T<:UnitRange
        return all(U->_p05_static_storage_type(U,seen),fieldtypes(T))
    elseif T<:AbstractArray
        (T<:Array || T<:BitArray) && return _p05_static_storage_type(eltype(T),seen)
        return false
    end
    if T<:FFTW.cFFTWPlan
        fieldnames(T)==(:plan,:sz,:osz,:istride,:ostride,:ialign,:oalign,:flags,:region,:pinv) || return false
        return all(name->name===:pinv || _p05_static_storage_type(fieldtype(T,name),seen),fieldnames(T))
    end
    isstructtype(T) && all(U->_p05_static_storage_type(U,seen),fieldtypes(T))
end
function _p05_check_fft_storage(x,seen=IdDict{Any,Nothing}())
    _p05_static_storage_type(typeof(x)) || throw(ArgumentError("observer_capture_profile_unknown"))
    (isbitstype(typeof(x)) || x isa String) && return nothing
    haskey(seen,x) && return nothing
    seen[x]=nothing
    if x isa AbstractArray
        if !isbitstype(eltype(x))
            for item in x;_p05_check_fft_storage(item,seen);end
        end
    else
        for name in fieldnames(typeof(x))
            # FFTW leaves pinv uninitialized until inv(plan) memoizes a ScaledPlan.
            # A cycle is legal, but each first visited memo value is qualified.
            isdefined(x,name) && _p05_check_fft_storage(getfield(x,name),seen)
        end
    end
    nothing
end

# This catalogue is a source-bound port closure, never namespace authority.
# The immutable P04 schema contributes its exact concrete public record types.
# Other public numerical roots and owning caller records are explicit below;
# all of their actual fields still undergo the same capture validation.
function _p05_closed_record(x)
    any(T->T===typeof(x),values(_p04_types().types)) && return true
    for name in (:NEGFProblem,:NEGFSolution,:ProductionCache,:ProductionFFTHilbertPlan,
        :ProductionMemoryEstimate,:ProductionKernelOptions,:ProductionResidualWorkspace,
        :DenseProductionKernel,:LowRankProductionKernel,:MomentumIndependentProductionKernel,
        :LiteralProductionKernel,:EnergyShiftPlan,:BasisData,:ModelGrids,:MaterialProfiles,
        :KernelSet,:PhysicalParameters,:NumericalParameters,:PhysicalModelOptions,
        :DomainAdaptationPolicy,:AlgorithmOptions,:ScatteringOptions,:SolverOptions,
        :SolverTolerances,:ConvergencePolicy,:DiagnosticQualityPolicy,
        :ScaleSystem,:ScatteringAssemblyContext,:ScatteringAssemblyResult,
        :LOPhononModel,:AcousticPhononModel,:IonizedImpurityModel,:InterfaceRoughnessModel,
        :AlloyDisorderModel,:ElectronElectronOptions,:ProductionKernelDiagnostics,
        :KernelInterpolationDiagnostic)
        x isa getproperty(QCLNEGF,name) && return true
    end
    for name in (:ScientificHistoryRecorder,:VerifiedExactCheckpoint,:FinalPointRequest,
        :ConfiguredProblem,:HardwareProfile,:ExecutionPlan,:ExecutionEnvelope,
        :ConfigurationProvenance,:ExecutionConfiguration,:AutomaticExecutionConfiguration,
        :ProgressOutputConfiguration,:DeviceGeometryConfiguration,:OutputConfiguration,
        :StudyConfiguration,:StudyMethodConfiguration,:ConvergenceStudyConfiguration,
        :PhaseObservationPolicy,:_P05ObserverAdmission)
        x isa getproperty(@__MODULE__,name) && return true
    end
    for name in (:FunctionPointRunner,:RunDefinition,:RunIdentity,:NestedSweepPlan,:SweepLevel,
        :SweepLeaf,:SweepAxis,:SweepPoint,:IterationRetentionPolicy,:CheckpointReference,
        :PointExecutionResult,:_SpanFrame,:_CoreTimingAccumulator)
        x isa getproperty(QCLApplicationRuntime,name) && return true
    end
    if isdefined(@__MODULE__,:QCLScientificWorkflow)
        for name in (:ScientificPoint,:ScientificPolicies,:VoltageContinuation,:ScientificOutputs,
            :RecoveryOutputPolicy,:TelemetryOutputPolicy,:ScientificInclusion,:ScientificExecutionNode,
            :_TrustedResourcePolicy,:_ResourceExecutionEntry)
            x isa getproperty(QCLScientificWorkflow,name) && return true
        end
    end
    false
end

# This validates only the closed caller's containers/callback captures, not a Julia heap.
# Producers are identity-checked leaves; Tasks and unknown callback owners are rejected.
function _p05_check_observer_roots(x,a,seen=IdDict{Any,Nothing}())
    if x isa Union{_NativePhaseObserver,ScalarTelemetrySender}
        r=x isa _NativePhaseObserver ? _PHASE_RESIDENCY[] : _SCALAR_RESIDENCY[]
        r!==nothing && (@atomic :acquire r.owner)===x || throw(ArgumentError("unreserved observer alias"))
        generation=x isa _NativePhaseObserver ? x.lifetime_generation : x.generation
        generation==r.generation && x.owner_epoch==r.owner_epoch || throw(ArgumentError("observer owner generation differs"))
        return nothing
    end
    x isa Task && throw(ArgumentError("observer Task escaped closed caller"))
    x===nothing && return nothing
    !(x isa Function) && (isbitstype(typeof(x)) || x isa Union{String,SubString{String},Symbol,Type,VersionNumber}) && return nothing
    haskey(seen,x) && return nothing
    seen[x]=nothing
    if x isa Function
        if x!==identity && x!==time_ns
            owner=parentmodule(typeof(x))
            owner===(@__MODULE__) || owner===QCLApplicationRuntime ||
                isdefined(@__MODULE__,:QCLScientificWorkflow) && owner===QCLScientificWorkflow ||
                throw(ArgumentError("observer_capture_profile_unknown"))
        end
        if x isa _PreparedJSONSink
            x.send_bytes isa _HTTPJSONTransport || throw(ArgumentError("observer_capture_profile_unknown"))
        end
        for i in 1:fieldcount(typeof(x));_p05_check_observer_roots(getfield(x,i),a,seen);end
    elseif x isa Core.Box
        isdefined(x,:contents) && _p05_check_observer_roots(x.contents,a,seen)
    elseif x isa Ref
        x isa Base.RefValue || throw(ArgumentError("observer_capture_profile_unknown"))
        isassigned(x) && _p05_check_observer_roots(x[],a,seen)
    elseif x isa Some
        _p05_check_observer_roots(something(x),a,seen)
    elseif x isa Pair
        _p05_check_observer_roots(first(x),a,seen);_p05_check_observer_roots(last(x),a,seen)
    elseif x isa AbstractDict
        x isa Union{Dict,IdDict} || throw(ArgumentError("observer_capture_profile_unknown"))
        for (key,value) in x
            _p05_check_observer_roots(key,a,seen);_p05_check_observer_roots(value,a,seen)
        end
    elseif x isa QCLNEGF.EnergyShiftPlan
        for name in fieldnames(typeof(x));_p05_check_observer_roots(getfield(x,name),a,seen);end
    elseif x isa AbstractArray
        x isa Union{Array,BitArray} || throw(ArgumentError("observer_capture_profile_unknown"))
        if !isbitstype(eltype(x))
            for value in x;_p05_check_observer_roots(value,a,seen);end
        end
    elseif x isa Set
        for value in x;_p05_check_observer_roots(value,a,seen);end
    elseif x isa Union{Tuple,NamedTuple}
        for value in x;_p05_check_observer_roots(value,a,seen);end
    elseif x isa QCLNEGF.ProductionFFTHilbertPlan
        _p05_check_fft_storage(x)
    elseif x isa QCLNEGF.ProductionOptions
        _p05_check_observer_roots(x.event_sink,a,seen);_p05_check_observer_roots(x.checkpoint_request,a,seen)
        _p05_check_observer_roots(x.phase_request,a,seen)
    elseif x isa ProgressReporter
        _p05_check_observer_roots(x.on_snapshot,a,seen);_p05_check_observer_roots(x.clock_ns,a,seen)
        all(io->io===nothing || io isa Union{IOStream,IOBuffer,Base.TTY,Base.PipeEndpoint},
            (x.human_io,x.csv_io)) || throw(ArgumentError("observer_capture_profile_unknown"))
    elseif x isa RuntimeTracer
        _p05_check_observer_roots(x.monotonic_clock_ns,a,seen)
        _p05_check_observer_roots(x.wall_clock_seconds,a,seen)
        _p05_check_observer_roots(x.repository,a,seen)
    elseif x isa AbstractRunRepository
        x isa FilesystemRunRepository || throw(ArgumentError("observer_capture_profile_unknown"))
    elseif x isa CallbackCheckpointCodec
        for callback in (x.writer,x.reader,x.validator);_p05_check_observer_roots(callback,a,seen);end
    elseif x isa AbstractCheckpointCodec
        x isa YamlCheckpointCodec || throw(ArgumentError("observer_capture_profile_unknown"))
    elseif x isa PointExecutionContext
        for name in fieldnames(typeof(x));_p05_check_observer_roots(getfield(x,name),a,seen);end
    elseif x isa QCLApplicationRuntime.LoadedCheckpoint
        _p05_metadata_cost(x.metadata,typemax(Int);portable=true)
        for name in fieldnames(typeof(x));_p05_check_observer_roots(getfield(x,name),a,seen);end
    elseif isdefined(@__MODULE__,:QCLProductionPointRunner) && x isa QCLProductionPointRunner
        for name in fieldnames(typeof(x));_p05_check_observer_roots(getfield(x,name),a,seen);end
    elseif isdefined(@__MODULE__,:ResolvedRunConfiguration) && x isa ResolvedRunConfiguration
        _p05_portable(x.raw)
        for name in fieldnames(typeof(x));_p05_check_observer_roots(getfield(x,name),a,seen);end
    elseif isdefined(@__MODULE__,:QCLScientificWorkflow) && x isa QCLScientificWorkflow.ScientificPlan
        for name in fieldnames(typeof(x));_p05_check_observer_roots(getfield(x,name),a,seen);end
    elseif isdefined(@__MODULE__,:QCLScientificWorkflow) && x isa QCLScientificWorkflow.ScientificExecution
        for name in fieldnames(typeof(x));_p05_check_observer_roots(getfield(x,name),a,seen);end
    elseif isdefined(@__MODULE__,:QCLScientificWorkflow) && x isa QCLScientificWorkflow.ScientificPointResult
        # Returned display/history metadata cannot retain even the currently
        # admitted producer. IEEE scalars are accepted without reclassification.
        visited=IdDict{Any,Nothing}()
        function display_payload(value,depth)
            depth<=256 || throw(ArgumentError("observer_capture_profile_unknown"))
            if value===nothing || value isa Union{Bool,Symbol,String} ||
                value isa Number && isbitstype(typeof(value))
                return nothing
            end
            haskey(visited,value) && return nothing
            visited[value]=nothing
            if value isa AbstractDict
                value isa Dict || throw(ArgumentError("observer_capture_profile_unknown"))
                for (key,item) in value;display_payload(key,depth+1);display_payload(item,depth+1);end
            elseif value isa AbstractArray
                value isa Array || throw(ArgumentError("observer_capture_profile_unknown"))
                if !isbitstype(eltype(value))
                    for item in value;display_payload(item,depth+1);end
                end
            elseif value isa Union{Tuple,NamedTuple}
                for item in value;display_payload(item,depth+1);end
            else
                throw(ArgumentError("observer_capture_profile_unknown"))
            end
            nothing
        end
        for value in (x.warnings,x.observables,x.data,x.postprocessing);display_payload(value,0);end
    elseif _p05_closed_record(x)
        # Every value pocket is traversed, including Function/Any/container
        # fields. Membership alone never exempts a public owning record.
        for name in fieldnames(typeof(x))
            isdefined(x,name) && _p05_check_observer_roots(getfield(x,name),a,seen)
        end
    elseif !isbitstype(typeof(x)) && !(x isa Union{String,SubString{String},Symbol,Type,VersionNumber})
        throw(ArgumentError("observer_capture_profile_unknown"))
    end
    nothing
end
function _p05_stable_resident(roots,a::_P05ObserverAdmission)
    _p05_observer_work_bound(a)
    _p05_check_observer_roots(roots,a)
    Base.summarysize((roots,a);exclude=Union{DataType,Core.TypeName,Core.MethodInstance,_NativePhaseObserver,ScalarTelemetrySender})
end

function _p05_input_metadata_limit(grant_bytes::Int,live_roots::NamedTuple;
    observer_admission::_P05ObserverAdmission)::Int
    keys(live_roots)==_P05_LIVE_ROOT_KEYS || throw(ArgumentError("incomplete final live-root groups"))
    all(x->x isa Union{Tuple,NamedTuple},values(live_roots)) ||
        throw(ArgumentError("live-root groups must be tuples"))
    grant_bytes>0 || throw(ArgumentError("invalid resource allowance"))
    observer_work_bytes=_p05_observer_work_bound(observer_admission)
    resident=_p05_stable_resident(live_roots,observer_admission)
    slab=Base.checked_mul(8,_SERIALIZATION_SLAB_BYTES)
    remaining=Base.checked_sub(grant_bytes,Base.checked_add(resident,Base.checked_add(observer_work_bytes,slab)))
    remaining>0 || throw(ArgumentError("input metadata exceeds admitted grant"))
    return remaining
end

function _p05_final_limits(solution::QCLNEGF.NEGFSolution,
    terminal::QCLNEGF.ExactSolverState,r::ScientificHistoryRecorder,
    request::FinalPointRequest,status::AbstractDict;
    production_options::QCLNEGF.ProductionOptions,grant_bytes::Int,
    live_roots::NamedTuple,input_documents::NamedTuple,
    observer_admission::_P05ObserverAdmission)::NamedTuple
    keys(live_roots)==_P05_LIVE_ROOT_KEYS || throw(ArgumentError("incomplete final live-root groups"))
    all(x->x isa Union{Tuple,NamedTuple},values(live_roots)) || throw(ArgumentError("live-root groups must be tuples"))
    grant_bytes>0 && production_options.memory_budget_bytes>0 ||
        throw(ArgumentError("invalid resource allowance"))
    grant=min(grant_bytes,production_options.memory_budget_bytes)
    observer_work_bytes=_p05_observer_work_bound(observer_admission)
    live=_p05_stable_resident((solution,terminal,r,request,status,live_roots,input_documents),observer_admission)
    slab=Base.checked_mul(8,_SERIALIZATION_SLAB_BYTES)
    remaining=Base.checked_sub(grant,Base.checked_add(live,Base.checked_add(observer_work_bytes,slab)))
    remaining>0 || throw(ArgumentError("final observation exceeds admitted grant"))
    estimate=QCLNEGF.final_observation_memory_estimate(solution,terminal;maximum_metadata_bytes=remaining)
    input_cost=_p05_metadata_cost(input_documents,grant;portable=true)
    metadata=Base.checked_sub(remaining,Base.checked_add(estimate.peak_additional_bytes,input_cost))
    metadata>0 && metadata>=estimate.metadata_bytes || throw(ArgumentError("final metadata exceeds admitted grant"))
    return (maximum_observation_bytes=estimate.peak_additional_bytes,maximum_metadata_bytes=metadata)
end

function _p05_final_status_input(process::AbstractDict,prior::AbstractDict)
    return Dict{String,Any}(
        "process"=>deepcopy(process),
        "discretization"=>deepcopy(prior["discretization"]),
        "experimental"=>deepcopy(prior["experimental"]))
end

function _p05_commit_final_with_presentation!(recorder::ScientificHistoryRecorder,
    solution::QCLNEGF.NEGFSolution,terminal::QCLNEGF.ExactSolverState;
    options::QCLNEGF.SolverOptions,production_options::QCLNEGF.ProductionOptions,
    execution::QCLNEGF.ExactExecutionIdentity,domain_adaptation::QCLNEGF.DomainAdaptationPolicy,
    kernel_options::Union{Nothing,QCLNEGF.ProductionKernelOptions},status::AbstractDict,
    request::FinalPointRequest,source_mode::Symbol,maximum_observation_bytes::Int,
    maximum_metadata_bytes::Int)
    presentation=Ref{Union{Nothing,NamedTuple}}(nothing)
    function retain(bundle)
        presentation[]===nothing || throw(ArgumentError("duplicate final presentation"))
        presentation[]=bundle
        nothing
    end
    result=commit_final!(recorder,solution,terminal;options,production_options,execution,
        domain_adaptation,kernel_options,status,request,source_mode,maximum_observation_bytes,
        maximum_metadata_bytes,presentation_sink=retain)
    presentation[]===nothing && throw(ArgumentError("final presentation missing"))
    return result,presentation[]
end

# Runner-owned sweep/point lifecycle events, separate from Core solver observations.
function _runner_stage_event(options::ProductionOptions, action::Symbol, stage::Symbol,
    label::AbstractString, status::Symbol, iteration, total, metrics, message::AbstractString)
    values = metrics === nothing ? () : metrics isa SolverMetric ? (metrics,) : Tuple(metrics)
    outer = options.outer_iteration > 0 ? options.outer_iteration :
        stage === :poisson && iteration !== nothing && iteration > 0 ? iteration : nothing
    inner = stage === :scba && iteration !== nothing && iteration > 0 ? iteration : nothing
    return SolverEvent(action,stage,String(label),status,iteration,total,values,String(message),0,outer,inner)
end
function _runner_begin_stage(options::ProductionOptions, stage::Symbol;
    label::AbstractString="", iteration=0, total=nothing, metrics=nothing)
    sink=options.event_sink
    sink === nothing && return false
    return sink(_runner_stage_event(options,:begin,stage,label,:running,iteration,total,metrics,"")) === true
end
function _runner_update_stage(options::ProductionOptions, stage::Symbol;
    iteration=nothing,total=nothing,metrics=nothing,message::AbstractString="")
    sink=options.event_sink
    sink === nothing && return false
    return sink(_runner_stage_event(options,:progress,stage,"",:running,iteration,total,metrics,message)) === true
end
function _runner_end_stage(options::ProductionOptions, stage::Symbol, owned::Bool;
    status::Symbol=:completed,iteration=nothing,total=nothing,metrics=nothing,message::AbstractString="")
    owned || return nothing
    sink=options.event_sink
    sink === nothing && return nothing
    return sink(_runner_stage_event(options,:end,stage,"",status,iteration,total,metrics,message))
end

function _validate_production_checkpoint_prefix(checkpoint_prefix::AbstractString)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", checkpoint_prefix) ||
        throw(ArgumentError("checkpoint_prefix is not a portable filename stem"))
    return checkpoint_prefix
end

function _production_checkpoint_name(
    output_directory::AbstractString,
    checkpoint_prefix::AbstractString,
    temperature_index::Integer,
    voltage_index::Integer,
)
    _validate_production_checkpoint_prefix(checkpoint_prefix)
    return joinpath(
        output_directory,
        "$(checkpoint_prefix)_T$(temperature_index)_V$(voltage_index).h5",
    )
end

function _configured_optical_response!(
    metrics::Dict{Symbol,Float64},
    solution::NEGFSolution,
    photon_energies,
    path::Union{Nothing,AbstractString};
    edge_tolerance::Real = 1e-4,
    threaded::Bool = true,
)
    response =
        bare_bubble_optical_response(solution, photon_energies; edge_tolerance, threaded)
    path === nothing || save_optical_response(path, response)
    metrics[:optical_trusted_fraction] = count(response.trusted) / length(response.trusted)
    metrics[:optical_max_edge_loss] = maximum(response.edge_loss)
    eligible = findall(response.trusted)
    if isempty(eligible)
        metrics[:gain_peak_per_cm] = NaN
        metrics[:gain_peak_energy_eV] = NaN
        metrics[:gain_peak_frequency_Hz] = NaN
    else
        peak = peak_gain(response)
        metrics[:gain_peak_per_cm] = Float64(ustrip(u"cm^-1", peak.gain))
        metrics[:gain_peak_energy_eV] = _runner_electronvolts(peak.photon_energy)
        metrics[:gain_peak_frequency_Hz] = Float64(ustrip(u"Hz", peak.frequency))
    end
    return response
end

function _p05_parent_root_check(parent::VerifiedExactCheckpoint, artifact_root::AbstractString)
    parent.root == abspath(artifact_root) ||
        throw(ArgumentError("native5_recovery_import_unavailable: parent belongs to a different artifact root"))
    return nothing
end

function _p05_science_callbacks(recorder::ScientificHistoryRecorder, problem::NEGFProblem;
    options::SolverOptions, production_options::ProductionOptions,
    execution::QCLNEGF.ExactExecutionIdentity, domain_adaptation::DomainAdaptationPolicy,
    kernel_options::Union{Nothing,ProductionKernelOptions}, status::Function,
    request::FinalPointRequest,maximum_metadata_bytes::Int,
    external_history::Union{Nothing,Function}=nothing)
    _p05_cap(maximum_metadata_bytes)
    _p04_require(!recorder.failed && !recorder.closed,"recorder closed or needs reconciliation")
    _p05_checkpoint_inputs(recorder.root,recorder.identity,request.plan_ref,request.model_ref,maximum_metadata_bytes;request)
    domain_adaptation.mode === :none || kernel_options !== nothing ||
        throw(ArgumentError("adaptive checkpoint requires actual kernel options"))
    latest=Ref{Union{Nothing,VerifiedExactCheckpoint}}(nothing)
    terminal=Ref{Union{Nothing,QCLNEGF.ExactSolverState}}(nothing)
    failure=Ref{Any}(nothing)
    history_observer = function(snapshot)
        try
            record_scientific_history!(recorder,snapshot)
            external_history===nothing || external_history(snapshot)
            nothing
        catch error
            failure[]=error
            rethrow()
        end
    end
    checkpoint_context_sink = function (actual_problem, state)
        try
        if state.boundary === :final
            terminal[] === nothing || throw(ArgumentError("duplicate global final checkpoint"))
            terminal[]=state
            return nothing
        end
        latest[]=commit_exact_checkpoint!(recorder,actual_problem,state;options,production_options,
            execution,domain_adaptation,kernel_options,status=status(),request,maximum_metadata_bytes)
        return nothing
        catch error
            failure[]=error
            rethrow()
        end
    end
    return (;history_observer,checkpoint_context_sink,latest,terminal,failure)
end

# Intermediate persistence and external state notification share the same
# mandatory failure lane. No borrowed problem is retained by this function.
function _p05_checkpoint_delivery!(callbacks,actual_problem,state,observer,it,iv)
    try
        callbacks.checkpoint_context_sink(actual_problem,state)
        state.boundary===:final || observer===nothing || observer(state,it,iv)
    catch error
        callbacks.failure[]=error
        rethrow()
    end
    nothing
end

# Cleanup cannot replay a failed publication or flush an already final recorder.
# On a new flush error the original caller failure remains explicitly retained.
function _p05_flush_open_history!(recorder,primary)
    recorder===nothing && return nothing
    (recorder.closed || recorder.failed) && return nothing
    try
        flush_scientific_history!(recorder)
    catch error
        primary===nothing && rethrow()
        throw(CompositeException(Any[primary,error]))
    end
    nothing
end

# Identity context supplies no resource authority. The already selected plan
# can only tighten the fresh hardware/unchanged-P ceiling.
function _p05_direct_execution_plan(plan)
    plan isa Union{Nothing,ExecutionPlan} || throw(ArgumentError("execution_plan must be an actual ExecutionPlan or nothing"))
    plan===nothing || plan.memory_budget_bytes>0 || throw(ArgumentError("execution_plan memory ceiling must be positive"))
    plan
end
function _p05_direct_memory_grant(production_options::ProductionOptions,hardware,execution_plan)
    plan=_p05_direct_execution_plan(execution_plan)
    hardware isa HardwareProfile || throw(ArgumentError("actual HardwareProfile required"))
    p=production_options.memory_budget_bytes
    0<p<typemax(Int) && production_options.worker_count>0 || throw(ArgumentError("selected production allowance required"))
    grant=min(p,hardware.total_memory_bytes,hardware.available_memory_bytes)
    plan===nothing || (grant=min(grant,plan.memory_budget_bytes))
    grant>0 || throw(ArgumentError("actual direct allowance unavailable"))
    grant
end

# Same admitted metadata algebra at a read-only/transport phase; no P selection.
function _p05_closed_metadata_limit(declared::Int,roots::NamedTuple;envelope=nothing)
    declared>0 || throw(ArgumentError("invalid declared metadata upper bound"))
    hardware=default_hardware_profile()
    grant=envelope===nothing ? min(declared,hardware.total_memory_bytes,hardware.available_memory_bytes) :
        min(declared,first(execution_budget(hardware,envelope)))
    grant>0 || throw(ArgumentError("actual metadata allowance unavailable"))
    admission=_p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        actual=merge(roots,(;resources=(roots.resources...,hardware,envelope,admission)))
        _p05_input_metadata_limit(grant,actual;observer_admission=admission)
    finally
        actual=nothing
        _p05_end_observers!(admission)
    end
end

# Closed invocation metadata is checked before any selected filesystem traversal.
function _p05_outward_path(value;root=false)
    root && value=="." && return nothing
    value isa String && !isempty(value) && !isabspath(value) && !occursin(r"[\\\x00]",value) &&
        all(part->!(part in ("",".","..")),split(value,'/')) || throw(ArgumentError("unsafe native invocation path"))
    nothing
end
function _p05_native_source_profile(source)
    _p04_keys(source,("schema","kind","artifact_root","relation","selected_state","diagnostics","observations","reason"))
    source["schema"]=="qcl-negf.native-point-source.v1" || throw(ArgumentError("unsupported native point source"))
    _p05_outward_path(source["artifact_root"];root=true)
    reason=source["reason"]
    if source["kind"]=="absent"
        all(source[n]===nothing for n in ("relation","selected_state","diagnostics","observations")) &&
            reason isa String && !isempty(reason) || throw(ArgumentError("invalid absent native source"))
        return nothing
    end
    source["kind"] in ("checkpoint","final") && source["relation"] in ("current_point_attempt","retained_source") || throw(ArgumentError("native source kind/relation differs"))
    state=source["selected_state"]
    _p04_keys(state,("identity","state_id","state_sequence","manifest"));_p04_identity(state["identity"])
    _p04_id(state["state_id"]);_p04_u64(state["state_sequence"];positive=true)
    ref=state["manifest"];_p04_file_fields(ref);_p05_outward_path(ref["path"])
    (ref["schema"],ref["media_type"])==(_P04_SCHEMAS["manifest"],"application/json") || throw(ArgumentError("native manifest FileRef format differs"))
    if source["kind"]=="checkpoint"
        source["diagnostics"]===source["observations"]===nothing && reason isa String && !isempty(reason) || throw(ArgumentError("invalid checkpoint-only source"))
        return nothing
    end
    (source["relation"]=="current_point_attempt" ? reason===nothing : reason isa String && !isempty(reason)) || throw(ArgumentError("invalid final source reason"))
    paths=String[ref["path"]]
    for name in ("diagnostics","observations")
        ref=source[name];_p04_file_fields(ref);_p05_outward_path(ref["path"])
        (ref["schema"],ref["media_type"])==(_P05_ANALYSIS_SCHEMA,"application/x-hdf5") || throw(ArgumentError("native analysis FileRef format differs"))
        push!(paths,ref["path"])
    end
    length(unique(paths))==length(paths) || throw(ArgumentError("native selected paths alias"))
    nothing
end

function _p05_verify_native_source(root::AbstractString,source::AbstractDict,maximum_metadata_bytes::Int)
    limit=_p05_cap(maximum_metadata_bytes)
    budget=Ref(limit)
    _p05_charge!(budget,_p05_metadata_cost(source,budget[];portable=true))
    _p05_native_source_profile(source)
    _p04_keys(source,("schema","kind","artifact_root","relation","selected_state","diagnostics","observations","reason"))
    source["schema"]=="qcl-negf.native-point-source.v1" || throw(ArgumentError("unsupported native point source"))
    artifact_root=source["artifact_root"]
    artifact_root isa String || throw(ArgumentError("native artifact root must be a string"))
    actual_root=artifact_root=="." ? abspath(root) : _p04_path(abspath(root),artifact_root)
    source["kind"]=="absent" && begin
        all(source[n]===nothing for n in ("relation","selected_state","diagnostics","observations")) &&
            source["reason"] isa String && !isempty(source["reason"]) || throw(ArgumentError("invalid absent native source"))
        return nothing
    end
    source["kind"] in ("checkpoint","final") && source["relation"] in ("current_point_attempt","retained_source") || throw(ArgumentError("native source kind/relation differs"))
    checkpoint=open_exact_checkpoint(actual_root,source["selected_state"];maximum_metadata_bytes=budget[])
    _p05_charge!(budget,_p05_metadata_cost(checkpoint,budget[]))
    if source["kind"]=="checkpoint"
        source["diagnostics"]===source["observations"]===nothing && source["reason"] isa String && !isempty(source["reason"]) || throw(ArgumentError("invalid checkpoint-only source"))
        return checkpoint
    end
    (source["relation"]=="current_point_attempt" ? source["reason"]===nothing : source["reason"] isa String && !isempty(source["reason"])) || throw(ArgumentError("invalid final source reason"))
    manifest=_p04_parse(checkpoint.manifest_json)
    parent_ref=manifest["lineage"]["parent_state"]
    parent=parent_ref===nothing ? nothing : open_exact_checkpoint(actual_root,parent_ref;maximum_metadata_bytes=budget[])
    parent===nothing || _p05_charge!(budget,_p05_metadata_cost(parent,budget[]))
    verify_final_artifacts(checkpoint;diagnostics_ref=source["diagnostics"],observations_ref=source["observations"],maximum_metadata_bytes=budget[],parent)
    checkpoint
end

# Literal bounded profile of published outward v4. This is transport grammar;
# criteria remain exclusively Core-owned. The writer's display encoding is kept.
function _p05_outward_carrier(value,depth=0)
    depth<=256 || throw(ArgumentError("outward carrier depth exceeds256"))
    if value isa AbstractDict
        all(k->k isa String && isvalid(k),keys(value)) || throw(ArgumentError("outward keys must be UTF-8 strings"))
        for child in values(value);_p05_outward_carrier(child,depth+1);end
    elseif value isa Union{NamedTuple,Tuple,AbstractVector}
        for child in value;_p05_outward_carrier(child,depth+1);end
    else
        value===nothing || value isa Union{Bool,Integer,AbstractFloat,Symbol} || value isa String && isvalid(value) ||
            throw(ArgumentError("unsupported outward carrier value"))
    end
    nothing
end
function _p05_native_result_profile(result,maximum_metadata_bytes)
    budget=Ref(_p05_cap(maximum_metadata_bytes))
    _p05_charge!(budget,_p05_metadata_cost(result,budget[];portable=true))
    _p05_outward_carrier(result)
    io=_P05JSONBuffer(IOBuffer(),budget[]);_light_json(io,result)
    wire=_p05_parse(String(take!(io.buffer)),budget)
    required=("schema","plan_fingerprint","plan_scientific_fingerprint","root_definition_id","name","status","model_version",
        "inclusions","executions","expected_point_count","available_point_count","points","contract_set")
    optional=("attempt_history","selected_execution_id","evidence")
    _p04_keys(wire,(required...,filter(k->haskey(wire,k),optional)...))
    wire["schema"]=="qcl-negf-series-result-v4" && wire["contract_set"]==_P04_CONTRACT || throw(ArgumentError("explicit native v4 result selection required"))
    if haskey(wire,"evidence")
        _p05_strings(wire["evidence"];unique=true)
    end
    for k in ("plan_fingerprint","plan_scientific_fingerprint","name","model_version");wire[k] isa String || throw(ArgumentError("invalid native series string"));end
    _p04_id(wire["root_definition_id"])
    wire["status"] in ("running","completed","completed_with_warnings","failed","cancelled","paused") || throw(ArgumentError("invalid native series status"))
    for k in ("expected_point_count","available_point_count");_p05_integer(wire[k]);end
    all(wire[k] isa AbstractVector for k in ("points","inclusions","executions")) || throw(ArgumentError("invalid native series lists"))
    wire["available_point_count"]==length(wire["points"])<=wire["expected_point_count"] || throw(ArgumentError("native point count differs"))
    for inclusion in wire["inclusions"]
        _p04_keys(inclusion,("id","definition_id","parent_id","path","execution_ids","label"))
        _p04_id(inclusion["id"]);_p04_id(inclusion["definition_id"])
        inclusion["parent_id"]===nothing || _p04_id(inclusion["parent_id"])
        _p05_strings(inclusion["path"]);_p05_strings(inclusion["execution_ids"];ids=true);_p05_string(inclusion["label"])
    end
    executions=Dict{String,Any}()
    for execution in wire["executions"]
        _p04_keys(execution,("id","definition_id","variant_id","method_id","purpose","label","operation","point_ids","repetition"))
        for k in ("id","definition_id","variant_id","method_id","purpose","label","operation");execution[k] isa String || throw(ArgumentError("invalid execution string"));end
        _p05_strings(execution["point_ids"];unique=true);_p05_integer(execution["repetition"];minimum=1)
        haskey(executions,execution["id"]) && throw(ArgumentError("duplicate native execution"))
        executions[execution["id"]]=execution
    end
    selected=get(wire,"selected_execution_id",nothing)
    selected===nothing || haskey(executions,selected) || throw(ArgumentError("native selected execution absent"))
    history=get(wire,"attempt_history",Any[]);history isa AbstractVector || throw(ArgumentError("native attempt history must be list"))
    for row in Iterators.flatten((wire["points"],history))
        _p04_keys(row,("id","execution_id","attempt","coordinates","initialization","status","quality","converged","warnings","observables","data","postprocessing"))
        _p04_id(row["id"]);_p04_id(row["execution_id"]);_p05_integer(row["attempt"];minimum=1)
        haskey(executions,row["execution_id"]) && row["id"] in executions[row["execution_id"]]["point_ids"] || throw(ArgumentError("native point absent from execution"))
        row["status"] in ("saving","completed","failed","skipped","cancelled","completed_with_warnings","paused") &&
            row["quality"] in ("strict","approximate","unconverged","invalid","unresolved","strictly_converged","not_evaluated") && row["converged"] isa Bool || throw(ArgumentError("invalid native point classification"))
        coordinate=row["coordinates"];_p04_keys(coordinate,("temperature_K","voltage_per_period_V","branch","order"))
        for k in ("temperature_K","voltage_per_period_V");coordinate[k] isa Real && !(coordinate[k] isa Bool) || throw(ArgumentError("invalid native coordinate"));end
        coordinate["temperature_K"]>0 && coordinate["voltage_per_period_V"]>=0 && coordinate["branch"] isa String && !isempty(coordinate["branch"]) || throw(ArgumentError("invalid native coordinates"))
        _p05_integer(coordinate["order"];minimum=1)
        init=row["initialization"];_p04_keys(init,("kind","source_point_id","checkpoint","fallback_reason"))
        init["kind"] isa String && !isempty(init["kind"]) || throw(ArgumentError("invalid native initialization"))
        for k in ("source_point_id","checkpoint","fallback_reason");init[k]===nothing || init[k] isa String && !isempty(init[k]) || throw(ArgumentError("invalid initialization reference"));end
        row["warnings"] isa AbstractVector && all(x->x isa AbstractDict,row["warnings"]) && row["observables"] isa AbstractDict || throw(ArgumentError("invalid native point metadata"))
        data=row["data"];data isa AbstractDict && all(haskey(data,k) for k in ("native_source","phase_source","optical_attachment")) || throw(ArgumentError("native point source fields missing"))
        for (k,v) in data
            k in ("native_source","phase_source","optical_attachment") && continue
            v===nothing || v isa String || (k=="checkpoint_source_attempt" && v isa Integer && !(v isa Bool) && v>0) || throw(ArgumentError("nonportable native data extension"))
        end
        source=data["native_source"];_p05_native_source_profile(source)
        data["optical_attachment"]===nothing || throw(ArgumentError("native5_optical_codec_verification_pending"))
        if source["kind"]!="absent"
            any(k->haskey(data,k),("result_commit","full_state","analysis_physics","optical","checkpoint_source_attempt")) && throw(ArgumentError("legacy slots alias native source"))
        end
        operation=executions[row["execution_id"]]["operation"]
        operation=="stationary" && haskey(data,"result_commit") && throw(ArgumentError("native stationary cannot use legacy result_commit"))
        operation=="stationary" && row["status"] in ("completed","completed_with_warnings") && source["kind"]!="final" && throw(ArgumentError("completed stationary source lacks final triple"))
        phase=data["phase_source"];_p04_keys(phase,("status","session_id","current_path","reason"))
        phase["status"] in ("available","disabled","unavailable") || throw(ArgumentError("invalid native phase status"))
        phase["status"]=="available" ? (_p04_id(phase["session_id"]);_p05_outward_path(phase["current_path"]);phase["reason"]===nothing || throw(ArgumentError("invalid phase reason"))) :
            (phase["session_id"]===phase["current_path"]===nothing && phase["reason"] isa String && !isempty(phase["reason"]) || throw(ArgumentError("invalid unavailable phase")))
        post=row["postprocessing"];post isa AbstractDict && haskey(post,"optical") || throw(ArgumentError("optical lifecycle missing"))
        optical=post["optical"];_p04_keys(optical,("status","error"))
        optical["status"] in ("not_requested","pending","running","completed","failed") || throw(ArgumentError("invalid optical lifecycle"))
        optical["error"]===nothing || optical["error"] isa String && !isempty(optical["error"]) || throw(ArgumentError("invalid optical error"))
        (optical["error"]!==nothing)==(optical["status"]=="failed") || throw(ArgumentError("optical status/error differs"))
        (data["optical_attachment"]!==nothing)==(optical["status"]=="completed") || throw(ArgumentError("optical attachment/lifecycle differs"))
        optical["status"]=="failed" && !(optical["error"] isa String && any(w->get(w,"code",nothing)=="OPTIONAL_OPTICS_FAILED",row["warnings"])) && throw(ArgumentError("optical failure evidence absent"))
        row["status"]=="saving" || !(optical["status"] in ("pending","running")) || throw(ArgumentError("terminal optical publication unfinished"))
    end
    selected_points=Dict{Tuple{String,String},Any}()
    for row in wire["points"]
        key=(row["execution_id"],row["id"])
        haskey(selected_points,key) && throw(ArgumentError("duplicate selected native point"))
        selected_points[key]=row
    end
    previous_attempt=Dict{Tuple{String,String},Int}()
    for row in history
        key=(row["execution_id"],row["id"])
        row["attempt"]>get(previous_attempt,key,0) || throw(ArgumentError("duplicate or nonchronological native history"))
        previous_attempt[key]=row["attempt"]
        current=get(selected_points,key,nothing)
        if current!==nothing
            row["attempt"]<=current["attempt"] || throw(ArgumentError("native history exceeds selected latest point"))
            row["attempt"]==current["attempt"] && row!=current && throw(ArgumentError("same native attempt differs from selected row"))
        end
    end
    _p05_portable(wire)
    (;wire,remaining=budget[])
end
function _p05_verify_native_result(root::AbstractString,result::AbstractDict,maximum_metadata_bytes::Int)
    checked=_p05_native_result_profile(result,maximum_metadata_bytes)
    seen=Set{String}()
    for row in Iterators.flatten((checked.wire["points"],get(checked.wire,"attempt_history",Any[])))
        source=row["data"]["native_source"]
        key=_p04_json(source)
        if source["kind"]!="absent"
            identity=source["selected_state"]["identity"];_p04_identity(identity)
            identity["point_id"]==row["id"] && identity["execution_id"]==row["execution_id"] || throw(ArgumentError("native source row identity differs"))
            source["relation"]=="current_point_attempt" ? identity["attempt"]==string(row["attempt"]) || throw(ArgumentError("native attempt differs")) :
                parse(UInt64,identity["attempt"])<row["attempt"] || throw(ArgumentError("retained source must precede point attempt"))
        end
        if !(key in seen)
            _p05_verify_native_source(root,source,checked.remaining)
            push!(seen,key)
        end
        row["data"]["optical_attachment"]===nothing || throw(ArgumentError("native5_optical_codec_verification_pending"))
    end
    nothing
end

function _p05_native_source(artifact_root::AbstractString;checkpoint=nothing,diagnostics=nothing,
    observations=nothing,relation="current_point_attempt",reason="solver_has_not_published_state")
    artifact_root=="." || (artifact_root isa String && !isabspath(artifact_root) && !occursin(r"[\\\x00]",artifact_root) &&
        all(x->!(x in ("",".","..")),split(artifact_root,'/'))) || throw(ArgumentError("unsafe native source root"))
    relation in ("current_point_attempt","retained_source") || throw(ArgumentError("native source relation differs"))
    final=diagnostics!==nothing || observations!==nothing
    final && (checkpoint===nothing || diagnostics===nothing || observations===nothing) &&
        throw(ArgumentError("native final source requires exact triple"))
    checkpoint===nothing || checkpoint isa VerifiedExactCheckpoint || throw(ArgumentError("verified checkpoint required"))
    if final
        _p04_file_fields(diagnostics);_p04_file_fields(observations)
        diagnostics["schema"]==observations["schema"]==_P05_ANALYSIS_SCHEMA || throw(ArgumentError("native analysis format differs"))
    end
    Dict{String,Any}("schema"=>"qcl-negf.native-point-source.v1","kind"=>checkpoint===nothing ? "absent" : final ? "final" : "checkpoint",
        "artifact_root"=>String(artifact_root),"relation"=>checkpoint===nothing ? nothing : relation,
        "selected_state"=>checkpoint===nothing ? nothing : checkpoint_reference(checkpoint),
        "diagnostics"=>final ? deepcopy(diagnostics) : nothing,"observations"=>final ? deepcopy(observations) : nothing,
        "reason"=>final && relation=="current_point_attempt" ? nothing : String(reason))
end

# Read only already stored scalar records. The only physics/PSD capture was commit_final!.
function _p05_recorded_final(result::NamedTuple,maximum_metadata_bytes::Int)
    keys(result)==(:checkpoint,:diagnostics,:observations) || throw(ArgumentError("exact final triple required"))
    budget=Ref(_p05_cap(maximum_metadata_bytes))
    declaration=_p05_parse(result.checkpoint.declaration_json,budget)
    observation=_p05_read_analysis(result.checkpoint.root,result.observations,declaration["identity"],
        declaration["invocation"],"final_observations",budget)
    diagnostic=_p05_read_analysis(result.checkpoint.root,result.diagnostics,declaration["identity"],
        declaration["invocation"],"final_diagnostics",budget)
    summary=observation["summary"]
    metrics=Dict{Symbol,Float64}(Symbol(row["name"])=>_p05_decode(row["value"],Float64)
        for row in diagnostic["solution_metrics"]["summary_metrics"])
    (;summary,current=_p05_decode(observation["views"]["current_density_A_per_m2"],Float64),
        sheet_density=_p05_decode(observation["views"]["sheet_density_per_m2"],Float64),metrics)
end

function _p05_deliver_final!(committed::NamedTuple,presentation::NamedTuple,terminal::QCLNEGF.ExactSolverState,
    it::Integer,iv::Integer;checkpoint_observer,native_publication_sink,final_presentation_sink)
    keys(committed)==(:checkpoint,:diagnostics,:observations) &&
        keys(presentation)==(:stationary_assessment,:validation,:positivity) || throw(ArgumentError("final publication carriers differ"))
    checkpoint_observer===nothing || checkpoint_observer(terminal,it,iv)
    native_publication_sink===nothing || native_publication_sink(committed,it,iv)
    final_presentation_sink===nothing || final_presentation_sink(presentation,it,iv)
    nothing
end

function _p05_point_configuration(configuration,T,V,TLO=T)
    raw=deepcopy(configuration.raw);sources=deepcopy(configuration.provenance.sources)
    axes=QCLScientificWorkflow._point_axis_inputs(T,V)
    axes["physical"]["lo_temperature"]="$(TLO) K"
    QCLScientificWorkflow._deep_merge!(raw,axes,sources,"generated:actual-native-point")
    QCLScientificWorkflow._resolve_configuration(raw,ConfigurationProvenance(
        copy(configuration.provenance.manifests),copy(configuration.provenance.files),sources))
end

function _p05_cold_direct_selection(configuration,capture,voltage_values,temperature_values,limit)
    definition=configured_nested_run_definition(configuration)
    function tree(node)
        node["kind"]=="leaf" && return SweepLeaf(node["name"])
        SweepLevel(node["name"],[SweepAxis(a["name"],a["values"]) for a in node["axes"]],tree(node["child"]))
    end
    original=NestedSweepPlan(capture.document["name"],tree(capture.document["root"]))
    canonical_bytes(QCLApplicationRuntime._sweep_plan_identity_dict(original))==
        canonical_bytes(QCLApplicationRuntime._sweep_plan_identity_dict(definition.plan)) || throw(ArgumentError("cold direct definition differs from original plan"))
    temperatures=reinterpret.(UInt64,_runner_kelvin.(temperature_values))
    voltages=reinterpret.(UInt64,Float64[ustrip(u"V",v) for v in voltage_values])
    allunique(temperatures) && allunique(voltages) || throw(ArgumentError("ambiguous direct selected coordinates"))
    budget=Ref(_p05_cap(limit))
    _p05_charge!(budget,_p05_metadata_cost(definition,budget[]))
    # Public traversal owns the exact coordinate-to-point identity projection.
    # Only requested detached point metadata is retained, charged before insertion.
    selected=Dict{Tuple{UInt64,UInt64},SweepPoint}()
    foreach_sweep_point(definition.plan,definition.identity.run_id) do point
        T=reinterpret(UInt64,_runtime_coordinate(point,"temperature.temperature_K"))
        V=reinterpret(UInt64,_runtime_coordinate(point,"voltage.voltage_per_period_V"))
        if T in temperatures && V in voltages
            key=(T,V)
            haskey(selected,key) && throw(ArgumentError("ambiguous direct plan coordinates"))
            _p05_charge!(budget,_p05_metadata_cost(point,budget[]))
            selected[key]=point
        end
    end
    length(selected)==Base.checked_mul(length(temperatures),length(voltages)) || throw(ArgumentError("direct selected point absent from actual definition"))
    (;definition,selected)
end

function _p05_sweep_inputs(configuration,voltage_values,temperature_values,output_directory,
    frozen_plan_bytes,source_graph,parent_checkpoint,run_id,native_context,maximum_metadata_bytes)
    configuration isa ResolvedRunConfiguration || throw(ArgumentError("native source_configuration is required"))
    graph=_require_source_graph(source_graph)
    capture=if native_context===nothing
        bytes=frozen_plan_bytes===nothing ? Vector{UInt8}(codeunits(YAML.write(
            QCLApplicationRuntime._sweep_plan_dict(configured_nested_sweep_plan(configuration))))) : frozen_plan_bytes
        _p05_capture_plan(bytes,:nested_sweep;maximum_metadata_bytes)
    else
        Set(keys(native_context))==Set((:artifact_root,:identity,:plan_capture,:parent_checkpoint)) || throw(ArgumentError("native context fields differ"))
        native_context.artifact_root isa AbstractString && native_context.identity isa AbstractDict &&
            native_context.plan_capture isa _P05PlanCapture &&
            native_context.parent_checkpoint isa Union{Nothing,VerifiedExactCheckpoint} || throw(ArgumentError("native context value grammar differs"))
        length(voltage_values)==length(temperature_values)==1 || throw(ArgumentError("native context requires exactly one point"))
        parent_checkpoint===nothing || native_context.parent_checkpoint===parent_checkpoint || throw(ArgumentError("native parent inputs conflict"))
        run_id===nothing || run_id==native_context.identity["run_id"] || throw(ArgumentError("native run inputs conflict"))
        frozen_plan_bytes===nothing || frozen_plan_bytes==native_context.plan_capture.bytes || throw(ArgumentError("native plan inputs conflict"))
        native_context.plan_capture
    end
    capture.kind===:nested_sweep && bytes2hex(sha256(capture.bytes))==capture.plan_sha256 || throw(ArgumentError("native captured plan differs"))
    checked=_p05_capture_plan(capture.bytes,:nested_sweep;maximum_metadata_bytes)
    canonical_bytes(checked.document)==canonical_bytes(capture.document) || throw(ArgumentError("native captured document differs"))
    plan=capture.document;_p05_nested_plan(plan)
    node=plan["root"]
    for (level,axis,values) in (("temperature","temperature_K",_runner_kelvin.(temperature_values)),
            ("voltage","voltage_per_period_V",Float64[ustrip(u"V",v) for v in voltage_values]))
        node["kind"]=="level" && node["name"]==level && length(node["axes"])==1 && node["axes"][1]["name"]==axis || throw(ArgumentError("native coordinate tree differs"))
        available=node["axes"][1]["values"]
        all(v->any(x->reinterpret(UInt64,Float64(x))==reinterpret(UInt64,v),available),values) || throw(ArgumentError("native coordinates absent from original plan"))
        node=node["child"]
    end
    node==Dict("kind"=>"leaf","name"=>"poisson_scba") || throw(ArgumentError("native leaf differs"))
    root=native_context===nothing ? abspath(output_directory) : abspath(native_context.artifact_root)
    relative=_p04_relative(root,abspath(output_directory))
    relative=="." || _p04_path(root,relative)
    parent=native_context===nothing ? parent_checkpoint : native_context.parent_checkpoint
    parent===nothing || length(voltage_values)==length(temperature_values)==1 || throw(ArgumentError("native parent requires exactly one point"))
    parent===nothing || _p05_parent_root_check(parent,root)
    parent===nothing || checkpoint_reference(parent)["identity"]["plan_sha256"]==capture.plan_sha256 || throw(ArgumentError("native parent original plan differs"))
    if native_context!==nothing
        _p04_identity(native_context.identity)
        native_context.identity["plan_sha256"]==capture.plan_sha256 || throw(ArgumentError("native plan identity differs"))
        length(configuration.study.temperatures)==length(configuration.study.voltages_per_period)==1 &&
            reinterpret(UInt64,_runner_kelvin(only(configuration.study.temperatures)))==reinterpret(UInt64,_runner_kelvin(only(temperature_values))) &&
            reinterpret(UInt64,Float64(ustrip(u"V",only(configuration.study.voltages_per_period))))==reinterpret(UInt64,Float64(ustrip(u"V",only(voltage_values)))) ||
            throw(ArgumentError("native prepared point coordinates differ"))
        bytes2hex(sha256(canonical_bytes(QCLScientificWorkflow._snapshot_model(configuration))))==native_context.identity["model_sha256"] || throw(ArgumentError("native actual point model differs"))
    end
    cold=native_context===nothing && parent===nothing ?
        _p05_cold_direct_selection(configuration,capture,voltage_values,temperature_values,maximum_metadata_bytes) : nothing
    identifier=run_id===nothing ? (native_context!==nothing ? native_context.identity["run_id"] :
        parent!==nothing ? checkpoint_reference(parent)["identity"]["run_id"] : cold.definition.identity.run_id) : String(run_id)
    _p04_id(identifier)
    parent===nothing || identifier==checkpoint_reference(parent)["identity"]["run_id"] || throw(ArgumentError("native parent run inputs conflict"))
    (;root,capture,parent,identifier,graph,definition=cold===nothing ? nothing : cold.definition,
        selected_points=cold===nothing ? nothing : cold.selected)
end

"""
    run_production_sweep(base_problem, voltages, temperatures; ...)

reference design-oriented overload that reuses one expensive static problem and one set
of flattened kernels across a sequential bias/temperature sweep.  `voltages`
must contain Unitful voltage drops per period and `temperatures` Unitful
temperatures.  Full states are checkpointed one at a time; only scalar
[`ProductionSweepRecord`](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/api/public.md)s are retained in the result.
`checkpoint_prefix` names point HDF5 files, `save_full_state=false` passes no
checkpoint path into the solver, and `save_csv=false` keeps the summary and
optical diagnostics in memory without creating CSV files.

When `resume_from_checkpoints=true`, an existing, metadata-compatible point
checkpoint has priority over the preceding-bias warm start.  A completed
checkpoint is deliberately re-evaluated from its fixed point so convergence
and validation are certified by the current package version.
An incompatible or corrupt checkpoint fails its operating point by default;
it is never silently loaded or replaced. With `fail_fast=false`, that failure
is recorded as `:execution_failed` and independent points continue without
inheriting its state. With `fail_fast=true`, the original exception propagates
and no subsequent point is started. Configuration errors detected before the
sweep and user interrupts always propagate. The optional
`incompatible_checkpoint` policy belongs only to the direct Julia API; the
configured runtimes always reject incompatible checkpoints.

See [Production sweep, warm start, and recovery](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md) and
the [HDF5 checkpoint schema](@ref native-result-formats).
"""
function run_production_sweep(
    base_problem::NEGFProblem,
    voltages,
    temperatures;
    output_directory::AbstractString = "production_results",
    options::SolverOptions = baseline_options(),
    production_options::ProductionOptions = ProductionOptions(),
    resume_from_checkpoints::Bool = true,
    checkpoint_prefix::AbstractString = "state",
    save_full_state::Bool = true,
    save_csv::Bool = true,
    Tᴸᴼ_of_Tᴸ::Function = identity,
    fail_fast::Bool = false,
    photon_energies = nothing,
    optical_edge_tolerance::Real = 1e-4,
    incompatible_checkpoint::Symbol = :error,
    solution_observer::Union{Nothing,Function} = nothing,
    checkpoint_observer::Union{Nothing,Function} = nothing,
    checkpoint_request::Union{Nothing,Function} = nothing,
    history_observer::Union{Nothing,Function} = nothing,
    domain_adaptation::DomainAdaptationPolicy = DomainAdaptationPolicy(),
    kernel_options::ProductionKernelOptions = ProductionKernelOptions(),
    observer_admission::Union{Nothing,_P05ObserverAdmission}=nothing,
    execution_plan=nothing,
    source_configuration=nothing,
    frozen_plan_bytes::Union{Nothing,Vector{UInt8}}=nothing,
    source_graph::Union{Nothing,AbstractDict}=nothing,
    parent_checkpoint::Union{Nothing,VerifiedExactCheckpoint}=nothing,
    run_id::Union{Nothing,AbstractString}=nothing,
    native_publication_sink::Union{Nothing,Function}=nothing,
    final_presentation_sink::Union{Nothing,Function}=nothing,
    native_context::Union{Nothing,NamedTuple}=nothing,
)
    execution_plan=_p05_direct_execution_plan(execution_plan)
    owns_observer_epoch=observer_admission===nothing
    owns_observer_epoch && (observer_admission=_p05_begin_observers!(;phase_request=nothing,scalar_request=nothing))
    try
    _p05_observer_work_bound(observer_admission)
    _p05_check_observer_roots((production_options,Tᴸᴼ_of_Tᴸ,solution_observer,
        checkpoint_observer,checkpoint_request,history_observer,native_publication_sink,final_presentation_sink,native_context,execution_plan),observer_admission)
    throw(ArgumentError("native5_configured_consumer_unavailable: typed Results/AiiDA/Q1 transport qualification pending"))
    voltage_values=collect(voltages);temperature_values=collect(temperatures)
    isempty(voltage_values) && throw(ArgumentError("voltage sweep is empty"))
    isempty(temperature_values) && throw(ArgumentError("temperature sweep is empty"))
    _validate_production_checkpoint_prefix(checkpoint_prefix)
    history_observer===nothing || hasmethod(history_observer,Tuple{QCLNEGF.ScientificHistorySnapshot,Int,Int}) ||
        throw(ArgumentError("native5_history_observer_requires_public_snapshot_it_iv"))
    save_full_state || throw(ArgumentError("native stationary output requires full state"))
    incompatible_checkpoint===:error || throw(ArgumentError("native recovery requires explicit compatible parent"))
    sources=_capture_solver_sources()
    0<production_options.memory_budget_bytes<typemax(Int) && production_options.worker_count>0 ||
        throw(ArgumentError("native direct caller requires selected production resource allowance"))
    hardware=default_hardware_profile()
    grant=_p05_direct_memory_grant(production_options,hardware,execution_plan)
    input_roots=(;entry=(source_configuration,voltage_values,temperature_values,source_graph,native_context),
        resources=(production_options,execution_plan,observer_admission,sources,hardware),construction=(base_problem,),continuation=(parent_checkpoint,),
        history=(),observers=(Tᴸᴼ_of_Tᴸ,solution_observer,checkpoint_observer,checkpoint_request,history_observer,native_publication_sink,final_presentation_sink),
        inputs_publication=(frozen_plan_bytes,run_id))
    input_limit=_p05_input_metadata_limit(grant,input_roots;observer_admission)
    inputs=_p05_sweep_inputs(source_configuration,voltage_values,temperature_values,output_directory,
        frozen_plan_bytes,source_graph,parent_checkpoint,run_id,native_context,input_limit)
    # Compare actual public construction inputs without building a second problem.
    for name in (:physical,:numerical,:scattering)
        canonical_bytes(_runtime_typed_identity(getproperty(base_problem,name)))==
            canonical_bytes(_runtime_typed_identity(getproperty(source_configuration,name))) || throw(ArgumentError("native source problem inputs differ: "*String(name)))
    end
    for (actual,declared,label) in ((base_problem.scales,source_configuration.scales,"scales"),
            (base_problem.models,source_configuration.physical_models,"physical_models"),
            (production_options.algorithms,source_configuration.algorithms,"algorithms"),
            (domain_adaptation,source_configuration.domain_adaptation,"domain_adaptation"),
            (kernel_options,source_configuration.kernels,"kernel_construction"),
            (options,source_configuration.solver,"solver"))
        canonical_bytes(_runtime_typed_identity(actual))==canonical_bytes(_runtime_typed_identity(declared)) ||
            throw(ArgumentError("native source inputs differ: "*label))
    end
    planned_peak=domain_adaptation.mode===:none ? _configured_production_estimate(source_configuration,production_options).peak_bytes :
        QCLScientificWorkflow.scientific_memory_estimate(QCLScientificWorkflow.FilesystemScientificDefinitions(),source_configuration;
            worker_capacity=production_options.worker_count)
    planning_roots=merge(input_roots,(;inputs_publication=(input_roots.inputs_publication...,inputs)))
    planned_peak<=_p05_input_metadata_limit(grant,planning_roots;observer_admission) || throw(ArgumentError("direct construction exceeds admitted grant"))
    mkpath(output_directory)
    base_cache=nothing
    records=ProductionSweepRecord[]
    summary_path=save_csv ? joinpath(output_directory,"sweep_summary.csv") : ""
    previous=nothing
    for (it,temperature) in pairs(temperature_values), (iv,voltage) in pairs(voltage_values)
        iv==1 && (previous=nothing)
        started=time_ns()
        point_stage=:preflight;recorder=nothing;callbacks=nothing;solution=nothing;point_primary=nothing
        try
        T=_runner_kelvin(temperature);V=Float64(ustrip(u"V",voltage))
        resolved=native_context===nothing ? _p05_point_configuration(source_configuration,T,V,_runner_kelvin(Tᴸᴼ_of_Tᴸ(temperature))) : source_configuration
        _runner_kelvin(resolved.physical.Tᴸᴼ)==_runner_kelvin(Tᴸᴼ_of_Tᴸ(temperature)) || throw(ArgumentError("native prepared LO temperature differs"))
        model_preimage=QCLScientificWorkflow._snapshot_model(resolved)
        identity=if native_context===nothing
            attempt=inputs.parent===nothing ? 1 : Base.checked_add(parse(Int,checkpoint_reference(inputs.parent)["identity"]["attempt"]),1)
            source_identity=inputs.parent===nothing ? nothing : checkpoint_reference(inputs.parent)["identity"]
            point=source_identity===nothing ? inputs.selected_points[(reinterpret(UInt64,T),reinterpret(UInt64,V))] : nothing
            point_id=source_identity===nothing ? point.point_id : source_identity["point_id"]
            execution_id=source_identity===nothing ? content_id("execution",Dict("run_id"=>inputs.identifier,"point_id"=>point_id)) : source_identity["execution_id"]
            branch_id=source_identity===nothing ? content_id("branch",Dict("execution_id"=>execution_id,"leaf"=>point.leaf)) : "branch-"*string(attempt)
            Dict{String,Any}("run_id"=>inputs.identifier,"execution_id"=>execution_id,
                "point_id"=>point_id,"attempt"=>string(attempt),"branch_id"=>branch_id,
                "model_sha256"=>bytes2hex(sha256(canonical_bytes(model_preimage))),"plan_sha256"=>inputs.capture.plan_sha256)
        else
            deepcopy(native_context.identity)
        end
        identity["model_sha256"]==bytes2hex(sha256(canonical_bytes(model_preimage))) || throw(ArgumentError("actual point model differs"))
        directory=joinpath(output_directory,"points",identity["point_id"],"attempt-"*identity["attempt"])
        ispath(directory) && throw(ArgumentError("native attempt directory already exists; choose an explicit new attempt"))
        inputs.parent===nothing || _p04_lineage(identity,checkpoint_reference(inputs.parent))
        base_cache===nothing && (base_cache=build_production_cache(base_problem;options=production_options))
        problem=retarget_problem(base_problem;V_period=voltage,Tᴸ=temperature,Tᴸᴼ=Tᴸᴼ_of_Tᴸ(temperature),energy_shift=production_options.algorithms.energy_shift)
        cache=retarget_production_cache(base_cache,problem)
        missing()=Dict{String,Any}("state"=>"not_measured","reason"=>"pending_scientific_assessment","evidence"=>nothing)
        status=Dict{String,Any}("process"=>Dict("state"=>"running","exit_code"=>nothing,"reason"=>nothing),
            (name=>missing() for name in ("convergence","physics","discretization","experimental"))...)
        recorder=ScientificHistoryRecorder(directory;artifact_root=inputs.root,identity,
            source_epoch="epoch-"*string(time_ns()),provenance=inputs.graph,status,
            maximum_scba_rows=options.max_scba,parent_checkpoint=inputs.parent)
        roots=merge(input_roots,(;construction=(base_problem,base_cache,problem,cache,resolved),continuation=(previous,inputs.parent),
            history=(records,recorder),inputs_publication=(inputs,model_preimage,status,identity)))
        cap=_p05_input_metadata_limit(grant,roots;observer_admission)
        request=publish_final_point_request!(recorder;plan_bytes=inputs.capture.bytes,model_preimage,
            temperature_K=T,voltage_per_period_V=V,scattering_requested=resolved.scattering,kind=:nested_sweep,maximum_metadata_bytes=cap)
        # Callback plumbing may change callbacks, never the selected numerical grant.
        point_options=checkpoint_request===nothing ? production_options : with_production_options(production_options;
            checkpoint_request=context->checkpoint_request(context,it,iv))
        exact=_capture_exact_execution(point_options,sources)
        kernel_binding=domain_adaptation.mode===:none ? nothing : kernel_options
        callback_roots=merge(roots,(;resources=(roots.resources...,point_options,exact),
            inputs_publication=(roots.inputs_publication...,request)))
        work_peak=domain_adaptation.mode===:none ? cache.estimate.peak_bytes :
            QCLScientificWorkflow.scientific_memory_estimate(QCLScientificWorkflow.FilesystemScientificDefinitions(),resolved;
                worker_capacity=point_options.worker_count)
        cap=min(cap,Base.checked_sub(_p05_input_metadata_limit(grant,callback_roots;observer_admission),work_peak))
        _p05_cap(cap) # reserve the owning Core forecast while intermediate input IO is live
        _p05_checkpoint_inputs(inputs.root,identity,request.plan_ref,request.model_ref,cap;request)
        callbacks=_p05_science_callbacks(recorder,problem;options,production_options=point_options,execution=exact.execution,
            domain_adaptation,kernel_options=kernel_binding,status=()->status,request,maximum_metadata_bytes=cap,
            external_history=history_observer===nothing ? nothing : snapshot->history_observer(snapshot,it,iv))
        parent_state=inputs.parent===nothing ? nothing : load_exact_solver_state(inputs.parent)
        restored=parent_state===nothing ? nothing : QCLNEGF.restore_exact_state(problem,parent_state;
            options,production_options=point_options,execution=exact.execution,domain_adaptation,kernel_options=kernel_binding)
        point_context=(actual_problem,state)->_p05_checkpoint_delivery!(callbacks,actual_problem,state,checkpoint_observer,it,iv)
        point_history=callbacks.history_observer
        point_stage=:solve
        solution=if parent_state!==nothing && parent_state.boundary===:final
            QCLNEGF.restore_completed_solution(restored;revalidation=:selected_map,independent_oracle=:if_supported)
        elseif restored===nothing
            solve_adaptive_production(problem;domain_adaptation,kernel_options,options,production_options=point_options,
                execution=exact.execution,cache,initial_Uᴴ=previous===nothing ? nothing : previous.Uᴴ,
                initial_scba=previous===nothing ? nothing : previous.scba,
                checkpoint_context_sink=point_context,
                observation_sink=point_options.event_sink,history_observer=point_history)
        else
            solve_adaptive_production(problem;restart=restored,checkpoint_context_sink=point_context,
                observation_sink=point_options.event_sink,history_observer=point_history)
        end
        point_stage=:publication
        terminal=parent_state!==nothing && parent_state.boundary===:final ? parent_state : callbacks.terminal[]
        terminal===nothing && throw(ArgumentError("global final checkpoint missing"))
        final_status=_p05_final_status_input(Dict("state"=>"succeeded","exit_code"=>0,"reason"=>nothing),status)
        roots=merge(roots,(;construction=(base_problem,base_cache,problem,cache,resolved,solution,terminal),
            continuation=(previous,inputs.parent,parent_state,restored),history=(records,recorder,callbacks),
            observers=(input_roots.observers...,point_context,point_history),inputs_publication=(inputs,model_preimage,status,identity,request,exact)))
        limits=_p05_final_limits(solution,terminal,recorder,request,final_status;production_options=point_options,
            grant_bytes=grant,live_roots=roots,input_documents=(;plan=inputs.capture.document,model=model_preimage),observer_admission)
        committed,presentation=_p05_commit_final_with_presentation!(recorder,solution,terminal;options,
            production_options=point_options,execution=exact.execution,domain_adaptation,kernel_options=kernel_binding,
            status=final_status,request,source_mode=parent_state!==nothing && parent_state.boundary===:final ? :completed_restore : :produced,limits...)
        recorded=_p05_recorded_final(committed,limits.maximum_metadata_bytes)
        counts=(;outer=length(terminal.outer_history),inner=length(terminal.scba.history),quality=terminal.scba.quality)
        point_warnings=Dict{String,Any}[deepcopy(w) for w in get(solution.observables,:warnings,Dict{String,Any}[])]
        # External observers cannot publish a terminal result before this exact commit.
        _p05_deliver_final!(committed,presentation,terminal,it,iv;
            checkpoint_observer,native_publication_sink,final_presentation_sink)
        solution_observer===nothing || solution_observer(solution,it,iv)
        push!(records,ProductionSweepRecord(T,V,_runner_volts_per_metre(solution.problem.physical.F_bias),recorded.current,
            recorded.summary["converged"],Symbol(recorded.summary["status"]),counts.quality,
            counts.outer,counts.inner,cache.estimate.peak_bytes,(time_ns()-started)*1e-9,
            recorded.metrics,checkpoint_reference(committed.checkpoint)["manifest"]["path"],
            point_warnings))
        save_csv && save_production_summary(summary_path,ProductionSweepResult(copy(records),summary_path))
        # Optics is a separate mandatory rollout; preserve its failure separately.
        if photon_energies!==nothing
            push!(records[end].warnings,Dict{String,Any}("code"=>"OPTIONAL_OPTICS_FAILED","scope"=>"postprocessing",
                "message"=>"native5_optical_provenance_join_pending: requested optics requires its owning codec/provenance rollout"))
            save_csv && save_production_summary(summary_path,ProductionSweepResult(copy(records),summary_path))
        end
        fail_fast && !(recorded.summary["converged"] || recorded.summary["status"]=="approximate") &&
            error("production point failed with status "*recorded.summary["status"])
        previous=solution.converged && solution.scba.converged && solution.scba.status===:converged && solution.scba.quality===:strictly_converged ? solution : nothing
        catch error
            point_primary=error
            # Mandatory persistence/user callback failures are never a recoverable
            # numerical case, and are never replayed under fail_fast=false.
            callback_error=callbacks===nothing ? nothing : callbacks.failure[]
            if point_stage!==:solve || fail_fast || error isa Union{InterruptException,OutOfMemoryError} || callback_error!==nothing
                callback_error===nothing || callback_error===error || throw(callback_error)
                rethrow()
            end
            failure=Dict{String,Any}("code"=>"CASE_FAILED","scope"=>"point","message"=>sprint(showerror,error),
                "temperature_K"=>_runner_kelvin(temperature),"voltage_per_period_V"=>Float64(ustrip(u"V",voltage)))
            push!(records,ProductionSweepRecord(_runner_kelvin(temperature),Float64(ustrip(u"V",voltage)),NaN,NaN,
                false,:execution_failed,:invalid,0,0,0,(time_ns()-started)*1e-9,Dict{Symbol,Float64}(),"",[failure]))
            save_csv && save_production_summary(summary_path,ProductionSweepResult(copy(records),summary_path))
            previous=nothing
        finally
            _p05_flush_open_history!(recorder,point_primary)
            solution=nothing;terminal=nothing;callbacks=nothing;restored=nothing;parent_state=nothing
            roots=nothing;presentation=nothing;committed=nothing;point_context=nothing;point_history=nothing
            point_options=nothing;callback_roots=nothing;point_warnings=nothing;recorded=nothing
        end
    end
    ProductionSweepResult(records,summary_path)
    finally
        native_publication_sink=nothing;final_presentation_sink=nothing;native_context=nothing;execution_plan=nothing
        input_roots=nothing;roots=nothing;inputs=nothing;presentation=nothing;terminal=nothing;planning_roots=nothing
        callbacks=nothing;point_context=nothing;point_history=nothing;solution=nothing;previous=nothing;callback_roots=nothing

        owns_observer_epoch && _p05_end_observers!(observer_admission)
    end
end

"""
    save_optical_response(path, response)

Atomically save one optical-response curve as CSV with explicit SI/eV column
names.  The file records `trusted` and `edge_loss` so plotting software cannot
silently treat an energy-window-contaminated point as final data.

See [Optical response](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/18_optical_response.md) and
[production plots and saved data](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md).
"""
function save_optical_response(path::AbstractString, response::OpticalResponse)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary, stream = mktemp(directory)
    try
        println(
            stream,
            join(
                (
                    "photon_energy_eV",
                    "frequency_Hz",
                    "susceptibility_real",
                    "susceptibility_imag",
                    "gain_per_m",
                    "gain_per_cm",
                    "trusted",
                    "edge_loss",
                ),
                ',',
            ),
        )
        for q in eachindex(response.photon_energy)
            values = (
                _runner_electronvolts(response.photon_energy[q]),
                Float64(ustrip(u"Hz", response.frequency[q])),
                real(response.susceptibility[q]),
                imag(response.susceptibility[q]),
                Float64(ustrip(u"m^-1", response.gain[q])),
                Float64(ustrip(u"cm^-1", response.gain[q])),
                response.trusted[q],
                response.edge_loss[q],
            )
            println(stream, join(_csv_field.(values), ','))
        end
        close(stream)
        _atomic_replace_file(temporary, path)
    catch
        isopen(stream) && close(stream)
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return path
end

"""
    save_kernel_diagnostics(path, diagnostics)

Atomically save the measured construction diagnostics returned by
[`build_kernels_production`](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/api/public.md).  One CSV row is written per enabled
mechanism.  Refinement histories are semicolon-separated inside their CSV
fields; residuals are dimensionless and `direct_q_evaluations` is an exact
counter for the adaptive construction and validation work.

See [Microscopic kernels](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/08_kernels.md) and
[production kernel diagnostics](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md).
"""
function save_kernel_diagnostics(
    path::AbstractString,
    diagnostics::ProductionKernelDiagnostics,
)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary, stream = mktemp(directory)
    try
        println(
            stream,
            join(
                (
                    "mechanism",
                    "construction",
                    "lookup_nodes",
                    "direct_q_evaluations",
                    "sampled_global_relative_residual",
                    "sampled_pointwise_relative_residual",
                    "sampled_angular_relative_residual",
                    "angular_quadrature_checked",
                    "angular_quadrature_relative_error",
                    "accepted",
                    "node_history",
                    "residual_history",
                ),
                ',',
            ),
        )
        for mechanism in sort!(collect(keys(diagnostics.mechanisms)); by = string)
            diagnostic = diagnostics.mechanisms[mechanism]
            values = (
                diagnostic.mechanism,
                diagnostic.construction,
                diagnostic.lookup_nodes,
                diagnostic.direct_q_evaluations,
                diagnostic.sampled_global_relative_residual,
                diagnostic.sampled_pointwise_relative_residual,
                diagnostic.sampled_angular_relative_residual,
                diagnostic.angular_quadrature_checked,
                something(diagnostic.angular_quadrature_relative_error, ""),
                diagnostic.accepted,
                join(diagnostic.node_history, ';'),
                join(diagnostic.residual_history, ';'),
            )
            println(stream, join(_csv_field.(values), ','))
        end
        close(stream)
        _atomic_replace_file(temporary, path)
    catch
        isopen(stream) && close(stream)
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return path
end


function _completed_restart_solution(problem::NEGFProblem, options::SolverOptions, restart)
    q = restart.status === :converged ? :strictly_converged : :approximate_fixed_point
    old = restart.scba
    scba = SCBAResult(
        old.green,
        old.scattering,
        old.embedding,
        old.embedding_plus,
        old.embedding_minus,
        old.history,
        q === :strictly_converged,
        q === :strictly_converged ? :converged : :approximate,
        q,
        old.restart_contract,
        old.mixer_state,
    )
    observables = _collect_observables(problem, scba, restart.Uᴴ)
    observables[:warnings] = deepcopy(get(restart, :warnings, Dict{String,Any}[]))
    push!(
        observables[:warnings],
        Dict{String,Any}(
            "code"=>"COMPLETED_CHECKPOINT_REUSED",
            "scope"=>"point",
            "message"=>"Completed compatible case reused without solver iterations.",
        ),
    )
    n = _electron_density_bar(problem, scba.green.Gˡ)
    provisional = NEGFSolution(
        problem,
        options,
        restart.Uᴴ,
        n,
        scba,
        restart.outer_history,
        observables,
        ConvergenceReport(false, Dict{Symbol,Float64}(), String[]),
        false,
        restart.status,
    )
    assessment = _final_quality_report(provisional, true)
    status =
        assessment.converged ? :converged :
        assessment.approximate ? :approximate : :validation_failed
    result = NEGFSolution(
        problem,
        options,
        restart.Uᴴ,
        n,
        scba,
        restart.outer_history,
        observables,
        assessment.report,
        assessment.converged,
        status,
    )
    observables[:quality] = solution_quality(result)
    observables[:termination_reason] = String(status)
    return result
end
