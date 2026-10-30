"""Runtime observation bounds, independent of numerical policy and frozen YAML inputs."""
struct PhaseObservationPolicy
    mode::Symbol
    maximum_event_bytes::Int
    capacity_bytes::Int
    batch_events::Int
    batch_bytes::Int
    flush_seconds::Float64
    snapshot_seconds::Float64
    maximum_depth::Int
    maximum_aggregate_keys::Int
    reserve_bytes::Int
    function PhaseObservationPolicy(;mode::Symbol,maximum_event_bytes::Int,capacity_bytes::Int,
        batch_events::Int,batch_bytes::Int,flush_seconds::Real,snapshot_seconds::Real,
        maximum_depth::Int,maximum_aggregate_keys::Int,reserve_bytes::Int)
        mode in (:normal,:diagnostic) || throw(ArgumentError("unknown observation mode"))
        all(>(0),(maximum_event_bytes,capacity_bytes,batch_events,batch_bytes,maximum_depth,
            maximum_aggregate_keys)) && reserve_bytes>=0 || throw(ArgumentError("invalid observation bounds"))
        maximum_event_bytes<=batch_bytes<=capacity_bytes || throw(ArgumentError("inconsistent observation byte bounds"))
        all(x->!(x isa Bool) && isfinite(x) && x>0,(flush_seconds,snapshot_seconds)) ||
            throw(ArgumentError("invalid observation cadence"))
        flush=Float64(flush_seconds);snapshot=Float64(snapshot_seconds)
        all(x->isfinite(x) && x>0,(flush,snapshot)) ||
            throw(ArgumentError("invalid observation cadence"))
        new(mode,maximum_event_bytes,capacity_bytes,batch_events,batch_bytes,flush,
            snapshot,maximum_depth,maximum_aggregate_keys,reserve_bytes)
    end
end
function _normal_phase_policy(capacity_events::Integer)
    capacity_events isa Bool && throw(ArgumentError("capacity must be an integer count"))
    capacity=Int(capacity_events);capacity>0 || throw(ArgumentError("invalid observation capacity"))
    bytes=Base.checked_mul(capacity,16384)
    PhaseObservationPolicy(;mode=:normal,maximum_event_bytes=16384,capacity_bytes=bytes,
        batch_events=min(64,capacity),batch_bytes=min(1048576,bytes),flush_seconds=1.0,
        snapshot_seconds=1.0,maximum_depth=64,maximum_aggregate_keys=128,reserve_bytes=67108864)
end

struct _PhaseQueued
    event::QCLNEGF.SolverEvent
    sequence::Int
    bytes::Int
    enqueued_ns::UInt64
end
const _PHASE_DROP_NAMES=(:capacity,:contention,:oversized,:closed,:invalid,:writer_failure)
struct _PhaseObserverUnavailable <: Exception
    reason::Symbol
end
Base.showerror(io::IO,error::_PhaseObserverUnavailable)=print(io,"phase observation unavailable: ",error.reason)
const _PHASE_WRITER_SLOT=Threads.Atomic{Bool}(false)
struct _NoPhasePublicationHook <: Function end
(::_NoPhasePublicationHook)(stage,path)=nothing
const _NO_PHASE_PUBLICATION_HOOK=_NoPhasePublicationHook()
struct _PhaseResidentProfile
    policy::PhaseObservationPolicy
    capacity_events::Int
    header_bytes::Int
    payload_bound_bytes::Int
end
mutable struct _NativePhaseObserver
    directory::String
    root::String
    identity::Dict{String,Any}
    source::Dict{String,Any}
    policy::PhaseObservationPolicy
    ring::Vector{Union{Nothing,_PhaseQueued}}
    head::Int
    tail::Int
    last_sequence::Int
    consumed_sequence::Int
    lock::ReentrantLock
    closed::Threads.Atomic{Bool}
    failed::Threads.Atomic{Bool}
    seen::Threads.Atomic{Int}
    enqueued::Threads.Atomic{Int}
    sealed::Threads.Atomic{Int}
    coalesced::Threads.Atomic{Int}
    queued::Threads.Atomic{Int}
    buffered::Threads.Atomic{Int}
    peak::Threads.Atomic{Int}
    inflight::Threads.Atomic{Int}
    inflight_events::Threads.Atomic{Int}
    oldest_ns::Threads.Atomic{UInt64}
    drops::NTuple{6,Threads.Atomic{Int}}
    fault::Threads.Atomic{Int}
    encoded::Threads.Atomic{Int}
    encode_ns::Threads.Atomic{Int}
    write_ns::Threads.Atomic{Int}
    hash_ns::Threads.Atomic{Int}
    sync_ns::Threads.Atomic{Int}
    enqueue_ns::Threads.Atomic{Int}
    bytes_written::Threads.Atomic{Int}
    stack::Vector{Tuple{Symbol,String,String}}
    generation::Int
    publication::Union{Nothing,Dict{String,Any}}
    hook::Function
    task::Union{Nothing,Task}
    lifetime_generation::UInt64
    owner_epoch::UInt64
    caller_released::Threads.Atomic{Bool}
    admitting::Threads.Atomic{Bool}
    producer_state::Threads.Atomic{UInt8} # same closed/admitted linearization as scalar
end
mutable struct _PhaseLifetime
    profile::Union{Nothing,_PhaseResidentProfile}
    generation::UInt64
    owner_epoch::UInt64
    started::Threads.Atomic{Bool}
    caller_released::Threads.Atomic{Bool}
    @atomic task::Union{Nothing,Task}
    @atomic owner::Union{Nothing,_NativePhaseObserver}
end
const _PHASE_RESIDENCY_LOCK=ReentrantLock()
const _PHASE_RESIDENCY=Ref{Union{Nothing,_PhaseLifetime}}(nothing)
const _PHASE_GENERATION_COUNTER=Ref{UInt64}(0)
function _phase_reap_locked!()
    r=_PHASE_RESIDENCY[]
    r===nothing && return
    t=@atomic :acquire r.task
    released=r.owner_epoch==0 ? r.caller_released[] : _P05_PHASE_RELEASE_EPOCH[]>=r.owner_epoch
    if released
        owner=@atomic :acquire r.owner
        owner===nothing || Threads.atomic_or!(owner.producer_state,UInt8(2))
        quiet=owner===nothing || owner.producer_state[]==UInt8(2)
        if quiet && (!r.started[] || t!==nothing && istaskdone(t))
            _PHASE_RESIDENCY[]=nothing;_PHASE_WRITER_SLOT[]=false
        end
    end
    nothing
end
function _phase_profile(directory,root,identity,session,p::PhaseObservationPolicy,c;
    hook=_NO_PHASE_PUBLICATION_HOOK)
    hook===_NO_PHASE_PUBLICATION_HOOK || return nothing
    c isa Int && c>0 && p.batch_events<=c || throw(ArgumentError("invalid phase capacity"))
    add=Base.checked_add;mul=Base.checked_mul
    h=256
    for text in (directory,root,session,values(identity)...)
        text isa String && isvalid(text) || throw(ArgumentError("unknown phase header"))
        h=add(h,ncodeunits(text))
    end
    n=min(c,p.capacity_bytes÷256);ur=min(mul(128,n),p.capacity_bytes÷128)
    q,b,d=p.batch_events,p.batch_bytes,p.maximum_depth
    a=min(q,p.maximum_aggregate_keys);u=min(mul(128,q),b÷128)
    w=p.mode===:diagnostic ? u : mul(5,a)
    kr=add(add(add(64,mul(5,n)),ur),mul(2,d))
    tr=add(add(p.capacity_bytes,mul(d,add(add(p.maximum_event_bytes,h),128))),mul(8,h))
    kw=add(add(add(add(add(64,mul(5,q)),u),mul(2,w)),mul(32,a)),mul(2,d))
    tw=add(add(mul(8,b),mul(512,kw)),mul(16,h));jw=add(mul(6,tw),mul(512,kw))
    bytes=add(add(add(add(4096,mul(16,c)),mul(512,kr)),mul(4,tr)),add(add(mul(4096,kw),mul(16,tw)),mul(4,jw)))
    _PhaseResidentProfile(p,c,h,bytes)
end
function _phase_reserve_locked!(profile,epoch)
    g=_observer_generation!(_PHASE_GENERATION_COUNTER)
    r=_PhaseLifetime(profile,g,epoch,Threads.Atomic{Bool}(false),Threads.Atomic{Bool}(false),nothing,nothing)
    _PHASE_RESIDENCY[]=r;_PHASE_WRITER_SLOT[]=true;r
end
_phase_closed(o)=o.closed[] || o.owner_epoch!=0 && _P05_PHASE_RELEASE_EPOCH[]>=o.owner_epoch

# Counters saturate honestly instead of wrapping; fault bit 4 marks unavailable totals.
function _phase_add!(value::Threads.Atomic{Int}, amount::Int=1)
    while true
        old=value[]
        next=amount>0 && old>typemax(Int)-amount ? typemax(Int) : old+amount
        Threads.atomic_cas!(value,old,next)==old && return next
    end
end
_phase_note!(o,bit)=Threads.atomic_or!(o.fault,bit)
function _phase_drop!(o,index)
    _phase_add!(o.drops[index]);nothing
end
function _phase_portable_id(x)
    x isa String && occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",x) &&
        !endswith(x,'\n') || throw(ArgumentError("invalid phase identity"))
    x
end
function _phase_identity(identity)
    fields=("run_id","execution_id","point_id","attempt","branch_id","model_sha256","plan_sha256")
    Set(keys(identity))==Set(fields) || throw(ArgumentError("phase identity fields differ"))
    result=Dict{String,Any}(name=>String(identity[name]) for name in fields)
    for name in ("run_id","execution_id","point_id","branch_id")
        _phase_portable_id(result[name])
    end
    attempt=result["attempt"]
    occursin(r"^[1-9][0-9]*$",attempt) && !endswith(attempt,'\n') &&
        tryparse(UInt64,attempt)!==nothing || throw(ArgumentError("invalid phase attempt"))
    for name in ("model_sha256","plan_sha256")
        occursin(r"^[0-9a-f]{64}$",result[name]) && ncodeunits(result[name])==64 ||
            throw(ArgumentError("invalid phase digest"))
    end
    result
end
function _phase_relative(root,path)
    relative=replace(relpath(path,root),'\\'=>'/')
    relative!="." && !startswith(relative,"../") && relative!=".." &&
        !isabspath(relative) || throw(ArgumentError("phase path escapes artifact root"))
    relative
end

"""Configure one source without any filesystem operation or collector acknowledgement.

`publication_hook` is a private publication-boundary seam, also used for fault qualification.
The descriptor locates a configured source; its initial Current may still be pending.
"""
function _start_phase_observer(directory::AbstractString;artifact_root::AbstractString,
    identity::AbstractDict,source_session::AbstractString,policy::PhaseObservationPolicy,
    capacity_events::Int,proc_root::String="/proc",publication_hook::Function=_NO_PHASE_PUBLICATION_HOOK,
    admission::Union{Nothing,_P05ObserverAdmission}=nothing)
    capacity_events>0 && policy.batch_events<=capacity_events || throw(ArgumentError("invalid event capacity"))
    root=abspath(artifact_root);directory=abspath(directory);_phase_relative(root,directory)
    session=_phase_portable_id(String(source_session));owned=_phase_identity(identity)
    profile=_phase_profile(directory,root,owned,session,policy,capacity_events;hook=publication_hook)
    trylock(_PHASE_RESIDENCY_LOCK) || throw(_PhaseObserverUnavailable(:observer_residency_snapshot_contended))
    local r
    try
        _P05_OBSERVER_EPOCH[]==0 && _phase_reap_locked!()
        if admission===nothing
            _P05_OBSERVER_EPOCH[]==0 || throw(_PhaseObserverUnavailable(:observer_epoch_active))
            (_PHASE_WRITER_SLOT[] || _PHASE_RESIDENCY[]!==nothing) &&
                throw(_PhaseObserverUnavailable(:previous_phase_writer_pending))
            r=_phase_reserve_locked!(profile,UInt64(0))
        else
            r=_PHASE_RESIDENCY[]
            _P05_OBSERVER_EPOCH[]==admission.epoch && admission.start_phase && r!==nothing &&
                r.owner_epoch==admission.epoch && r.generation==admission.phase_generation &&
                profile!==nothing && r.profile==profile || throw(ArgumentError("phase admission differs"))
        end
        Threads.atomic_cas!(r.started,false,true)==false || throw(_PhaseObserverUnavailable(:previous_phase_writer_pending))
    finally
        unlock(_PHASE_RESIDENCY_LOCK)
    end
    try
    # Session-local process monotonic clock; boot identity is deliberately not fabricated/probed.
    source=Dict{String,Any}("session_id"=>session,"clock_domain_id"=>"julia-monotonic:$(getpid()):$session",
        "utc_anchor_ns"=>string(round(UInt64,time()*1e9)),"monotonic_anchor_ns"=>string(time_ns()))
    atom()=Threads.Atomic{Int}(0)
    ring=Vector{Union{Nothing,_PhaseQueued}}(nothing,capacity_events)
    o=_NativePhaseObserver(directory,root,owned,source,policy,ring,1,1,0,0,ReentrantLock(),
        Threads.Atomic{Bool}(false),Threads.Atomic{Bool}(false),atom(),atom(),atom(),atom(),
        atom(),atom(),atom(),atom(),atom(),Threads.Atomic{UInt64}(0),ntuple(_->atom(),6),atom(),atom(),atom(),atom(),atom(),
        atom(),atom(),atom(),Tuple{Symbol,String,String}[],0,nothing,publication_hook,nothing,
        r.generation,r.owner_epoch,r.caller_released,Threads.Atomic{Bool}(false),Threads.Atomic{UInt8}(0))
    @atomic :release r.owner=o
    o.task=Threads.@spawn _phase_worker!(o)
    @atomic :release r.task=o.task
    o
    catch
        # Known pre-spawn allocation failure; a task with an uncertain attachment is retained.
        if (@atomic :acquire r.owner)===nothing
            r.started[]=false;r.caller_released[]=true
        end
        rethrow()
    end
end
function _phase_source_descriptor(o::_NativePhaseObserver)
    (status=:available,session_id=String(o.source["session_id"]),
        current_path=_phase_relative(o.root,joinpath(o.directory,"phase-current.json")),reason=nothing)
end
function _phase_event_charge(event,limit)
    length(event.metrics)<=128 || throw(ArgumentError("too many phase metrics"))
    remaining=Ref(limit)
    _telemetry_charge!(remaining,256)
    for text in (event.action,event.stage,event.label,event.status,event.message)
        bytes=text isa Symbol ? sizeof(text) : ncodeunits(text)
        _telemetry_charge!(remaining,Base.checked_add(Base.checked_mul(6,bytes),8))
        isvalid(String(text)) || throw(ArgumentError("invalid phase text"))
    end
    isempty(event.label) && throw(ArgumentError("phase name missing"))
    !isempty(String(event.stage)) && !isempty(String(event.status)) ||
        throw(ArgumentError("phase context name missing"))
    event.sequence>=0 && all(x->x===nothing || x>=0,
        (event.iteration,event.total,event.outer_iteration,event.inner_iteration)) ||
        throw(ArgumentError("invalid phase context"))
    for (index,m) in enumerate(event.metrics)
        sizeof(m.name)>0 && (m.reason===nothing || sizeof(m.reason)>0) ||
            throw(ArgumentError("metric name/reason missing"))
        for text in (m.name,m.unit,m.reason===nothing ? "" : m.reason)
            bytes=text isa Symbol ? sizeof(text) : ncodeunits(text)
            _telemetry_charge!(remaining,Base.checked_add(Base.checked_mul(6,bytes),8))
            isvalid(String(text)) || throw(ArgumentError("invalid metric text"))
        end
        m.value isa String && !isvalid(m.value) && throw(ArgumentError("invalid metric value text"))
        _telemetry_charge!(remaining,m.value isa String ? 6*ncodeunits(m.value)+2 : 96)
        _telemetry_charge!(remaining,128)
        for previous in 1:index-1
            other=event.metrics[previous]
            other.name===m.name && other.unit==m.unit && throw(ArgumentError("duplicate phase metric"))
        end
    end
    limit-remaining[]
end

"""Bounded scalar admission only. Returns false for technical loss, never waits for the writer."""
function _phase_try_producer!(o::_NativePhaseObserver)::Bool
    state=Threads.atomic_cas!(o.producer_state,UInt8(0),UInt8(1))
    if state!=0
        _phase_drop!(o,state & UInt8(2)!=0 ? 4 : 2);return false
    end
    if _phase_closed(o) || Threads.atomic_cas!(o.admitting,false,true)
        _phase_drop!(o,_phase_closed(o) ? 4 : 2)
        Threads.atomic_and!(o.producer_state,UInt8(2)) # last admitted-lane access
        return false
    end
    true
end
function _phase_release_producer!(o::_NativePhaseObserver)
    o.admitting[]=false
    Threads.atomic_and!(o.producer_state,UInt8(2))
    nothing
end
function _enqueue_phase!(o::_NativePhaseObserver,event::QCLNEGF.SolverEvent)::Bool
    event.action in (:phase_begin,:phase_end) || return false
    started=time_ns();sequence=_phase_add!(o.seen)
    _phase_try_producer!(o) || return false
    try
        if _phase_closed(o) || o.failed[]
            _phase_drop!(o,_phase_closed(o) ? 4 : 6);return false
        end
        bytes=try
            _phase_event_charge(event,o.policy.maximum_event_bytes)
        catch error
            _phase_drop!(o,error isa ArgumentError && occursin("budget",error.msg) ? 3 : 5)
            return false
        end
        if !trylock(o.lock)
            _phase_drop!(o,2);return false
        end
        try
            if _phase_closed(o) || o.failed[]
                _phase_drop!(o,_phase_closed(o) ? 4 : 6);return false
            elseif o.queued[]==length(o.ring) || bytes>o.policy.capacity_bytes-o.buffered[]
                _phase_drop!(o,1);return false
            elseif sequence<=o.last_sequence
                # Concurrent out-of-order admissions are loss, never reordered across batches.
                _phase_drop!(o,2);return false
            end
            o.ring[o.tail]=_PhaseQueued(event,sequence,bytes,started)
            o.tail=mod1(o.tail+1,length(o.ring));o.last_sequence=sequence
            o.queued[]==0 && (o.oldest_ns[]=started)
            current=o.buffered[]+bytes
            current>o.peak[] && (o.peak[]=current)
            _phase_add!(o.buffered,bytes);_phase_add!(o.queued)
            _phase_add!(o.enqueued)
            return true
        finally
            unlock(o.lock)
        end
    finally
        _phase_add!(o.enqueue_ns,Int(time_ns()-started))
        _phase_release_producer!(o)
    end
end
_record_native_phase!(o::_NativePhaseObserver,event::QCLNEGF.SolverEvent)=_enqueue_phase!(o,event)
function _close_phase_observer!(o::_NativePhaseObserver)
    Threads.atomic_or!(o.producer_state,UInt8(2))
    o.closed[]=true
    o.owner_epoch==0 && (o.caller_released[]=true)
    nothing
end
function _phase_observer_statistics(o::_NativePhaseObserver)
    oldest=o.oldest_ns[]
    (events_seen=o.seen[],enqueued=o.enqueued[],sealed_events=o.sealed[],coalesced_events=o.coalesced[],
        queued_events=o.queued[],buffered_bytes=o.buffered[],peak_buffered_bytes=o.peak[],
        inflight_bytes=o.inflight[],unsealed_events=o.queued[]+o.inflight_events[],
        oldest_lag_seconds=oldest==0 ? nothing : (time_ns()-oldest)/1e9,
        dropped=NamedTuple{_PHASE_DROP_NAMES}(map(x->x[],o.drops)),
        failed=o.failed[],encoded_documents=o.encoded[],bytes_written=o.bytes_written[])
end

_phase_atom(x::Int64)=Dict{String,Any}("kind"=>"integer","type"=>"Int64","decimal"=>string(x))
_phase_value(x::Int64)=_phase_atom(x)
_phase_value(x::Float64)=isfinite(x) ? x : nothing
_phase_value(x)=x
function _phase_metric_wire(m)
    Dict{String,Any}("name"=>String(m.name),"value"=>_phase_value(m.value),"unit"=>m.unit,
        "measurement_status"=>String(m.measurement_status),"reason"=>m.reason===nothing ? nothing : String(m.reason))
end
function _phase_health(o)
    s=_phase_observer_statistics(o);reasons=String[]
    any(==(typemax(Int)),(s.events_seen,s.enqueued,s.sealed_events,s.coalesced_events,values(s.dropped)...)) &&
        _phase_note!(o,4)
    for name in _PHASE_DROP_NAMES
        getproperty(s.dropped,name)>0 && push!(reasons,"dropped_$(name)")
    end
    for (bit,reason) in ((1,"phase_context_incomplete"),(2,"phase_depth_exceeded"),
        (4,"counter_overflow"),(8,"aggregate_key_limit"),(16,"writer_unavailable"),(32,"unsealed_close_tail"))
        o.fault[] & bit != 0 && push!(reasons,reason)
    end
    costs=Any[]
    for (name,value) in (("enqueue_seconds",o.enqueue_ns[]/1e9),("encode_seconds",o.encode_ns[]/1e9),
        ("write_seconds",o.write_ns[]/1e9),("hash_seconds",o.hash_ns[]/1e9),("sync_seconds",o.sync_ns[]/1e9))
        push!(costs,Dict("name"=>name,"value"=>value,"unit"=>"s","measurement_status"=>"measured","reason"=>nothing))
    end
    push!(costs,Dict("name"=>"bytes_written","value"=>_phase_atom(Int64(s.bytes_written)),
        "unit"=>"bytes","measurement_status"=>"measured","reason"=>nothing))
    push!(costs,Dict("name"=>"oldest_queued_lag_seconds","value"=>s.oldest_lag_seconds,
        "unit"=>"s","measurement_status"=>s.oldest_lag_seconds===nothing ? "not_applicable" : "measured",
        "reason"=>s.oldest_lag_seconds===nothing ? "queue_empty" : nothing))
    for (name,unit) in (("observer_process_cpu_seconds","s"),("observer_allocated_bytes","bytes"))
        push!(costs,Dict("name"=>name,"value"=>nothing,"unit"=>unit,
            "measurement_status"=>"not_measured","reason"=>"not_separately_measured"))
    end
    Dict{String,Any}("events_seen"=>string(s.events_seen),"enqueued"=>string(s.enqueued),
        "sealed_events"=>string(s.sealed_events),"coalesced_events"=>string(s.coalesced_events),
        "dropped"=>Dict(String(k)=>string(v) for (k,v) in pairs(s.dropped)),
        "queued_events"=>string(s.queued_events),"buffered_bytes"=>string(s.buffered_bytes),
        "peak_buffered_bytes"=>string(s.peak_buffered_bytes),"inflight_bytes"=>string(s.inflight_bytes),
        "unsealed_events"=>string(s.unsealed_events),
        "incomplete"=>!isempty(reasons),"incomplete_reasons"=>reasons,"self_cost"=>costs)
end
function _phase_envelope(o,schema)
    Dict{String,Any}("schema"=>schema,"contract_set"=>"qcl-negf.results.v2",
        "identity"=>o.identity,"source"=>o.source)
end
function _phase_encode(o,value)
    started=time_ns();io=IOBuffer();_light_json(io,value);println(io)
    bytes=take!(io);_phase_add!(o.encoded);_phase_add!(o.encode_ns,Int(time_ns()-started));bytes
end
function _phase_prepare_directory!(o)
    isdir(o.root) && !islink(o.root) || throw(ArgumentError("phase artifact root unavailable"))
    realpath(o.root)==o.root || throw(ArgumentError("phase artifact root is not canonical"))
    ispath(o.directory) && throw(ArgumentError("phase source namespace already used"))
    parent=o.root
    for part in split(_phase_relative(o.root,o.directory),'/')
        parent=joinpath(parent,part)
        islink(parent) && throw(ArgumentError("phase path is a symlink"))
        ispath(parent) ? (isdir(parent) || throw(ArgumentError("phase parent is not directory"))) : mkdir(parent)
    end
end
function _phase_write!(o,name,payload;immutable=true)
    target=joinpath(o.directory,name)
    islink(target) && throw(ArgumentError("phase target symlink"))
    immutable && ispath(target) && throw(ArgumentError("immutable phase path collision"))
    available=diskstat(o.directory).available
    length(payload)<=available && o.policy.reserve_bytes<=available-length(payload) ||
        throw(ArgumentError("technical storage reserve unavailable"))
    temporary,io=mktemp(o.directory;cleanup=false)
    try
        started=time_ns();write(io,payload);flush(io)
        _phase_add!(o.write_ns,Int(time_ns()-started));started=time_ns()
        # Only this new owned temporary is changed; match the owning atomic metadata convention.
        chmod(temporary,0o640)
        Sys.isunix() && ccall(:fsync,Cint,(Cint,),fd(io))!=0 && throw(SystemError("phase fsync",Libc.errno()))
        close(io);_phase_add!(o.sync_ns,Int(time_ns()-started))
        if immutable
            mv(temporary,target;force=false)
        else
            _atomic_replace_file(temporary,target)
        end
        started=time_ns();_sync_artifact_directory(o.directory)
        _phase_add!(o.sync_ns,Int(time_ns()-started));_phase_add!(o.bytes_written,length(payload))
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary;force=true)
    end
    started=time_ns();digest=bytes2hex(sha256(payload));_phase_add!(o.hash_ns,Int(time_ns()-started))
    Dict{String,Any}("path"=>_phase_relative(o.root,target),"bytes"=>string(length(payload)),
        "sha256"=>digest,"media_type"=>"application/json")
end
function _phase_current!(o;closing=false,publication=o.publication)
    if closing && (!isempty(o.stack) || o.queued[]>0 || o.inflight[]>0)
        _phase_note!(o,32)
    end
    phase=isempty(o.stack) ? nothing : let top=last(o.stack)
        Dict("stage"=>String(top[1]),"phase"=>top[2],"span_id"=>top[3])
    end
    current=_phase_envelope(o,"qcl-negf.producer-phase-current.v1")
    merge!(current,Dict("publication"=>publication,"current_phase"=>phase,
        "health"=>_phase_health(o),"closed"=>closing))
    _phase_write!(o,"phase-current.json",_phase_encode(o,current);immutable=false)
    o.publication=publication
end
function _phase_take_batch!(o)
    batch=_PhaseQueued[];bytes=0
    lock(o.lock) do
        while o.queued[]>0 && length(batch)<o.policy.batch_events
            item=o.ring[o.head]::_PhaseQueued
            bytes+item.bytes>o.policy.batch_bytes && break
            push!(batch,item);bytes+=item.bytes;o.ring[o.head]=nothing
            o.head=mod1(o.head+1,length(o.ring));_phase_add!(o.queued,-1);_phase_add!(o.buffered,-item.bytes)
        end
        o.oldest_ns[]=o.queued[]>0 ? (o.ring[o.head]::_PhaseQueued).enqueued_ns : UInt64(0)
    end
    o.inflight[]=bytes
    o.inflight_events[]=length(batch)
    batch
end
function _phase_span!(o,q)
    e=q.event;span=nothing;parent=nothing;complete=o.fault[] & 3 == 0
    if q.sequence!=o.consumed_sequence+1
        # Only our own technical ordinals reveal dropped phase callbacks. Core delivery
        # sequence is shared with science/nonphase events and is never used for this test.
        _phase_note!(o,1);empty!(o.stack);complete=false
    end
    o.consumed_sequence=q.sequence
    if e.action===:phase_begin
        if length(o.stack)>=o.policy.maximum_depth
            _phase_note!(o,2);empty!(o.stack);complete=false
        else
            parent=isempty(o.stack) ? nothing : last(o.stack)[3]
            span=o.source["session_id"]*":"*string(q.sequence)
            push!(o.stack,(e.stage,e.label,span))
        end
    elseif isempty(o.stack) || last(o.stack)[1:2]!=(e.stage,e.label)
        _phase_note!(o,1);empty!(o.stack);complete=false
    else
        span=pop!(o.stack)[3];parent=isempty(o.stack) ? nothing : last(o.stack)[3]
    end
    (span,parent,complete)
end
function _phase_event_row(o,q,context)
    e=q.event
    Dict{String,Any}("kind"=>"event","sequence"=>string(q.sequence),
        "core_sequence"=>e.sequence==0 ? nothing : string(e.sequence),
        "action"=>String(e.action),"stage"=>String(e.stage),"label"=>e.label,"status"=>String(e.status),
        "iteration"=>e.iteration===nothing ? nothing : string(e.iteration),
        "total"=>e.total===nothing ? nothing : string(e.total),
        "outer_iteration"=>e.outer_iteration===nothing ? nothing : string(e.outer_iteration),
        "inner_iteration"=>e.inner_iteration===nothing ? nothing : string(e.inner_iteration),
        "span_id"=>context[1],"parent_span_id"=>context[2],
        "context_status"=>context[3] ? "complete" : "incomplete",
        "metrics"=>[_phase_metric_wire(m) for m in e.metrics])
end
function _phase_metric(event,name)
    for m in event.metrics
        m.name===name && return m
    end
    nothing
end
function _phase_clock(event)
    start=_phase_metric(event,:start_monotonic_ns);stop=_phase_metric(event,:end_monotonic_ns)
    reasons=String[]
    for m in (start,stop)
        if m===nothing
            push!(reasons,"producer_clock_missing")
        elseif m.measurement_status!==:measured
            push!(reasons,m.reason===nothing ? "producer_clock_invalid" : String(m.reason))
        elseif !(m.value isa Int64) || m.value<0 || m.unit!="ns"
            push!(reasons,"producer_clock_invalid")
        end
    end
    isempty(reasons) || return (nothing,nothing,unique(reasons))
    start.value<=stop.value || return (nothing,nothing,["producer_clock_reversed"])
    producer=_phase_metric(event,:producer_monotonic_ns)
    if producer!==nothing && producer.measurement_status===:measured &&
       (!(producer.value isa Int64) || producer.unit!="ns" || producer.value!=stop.value)
        return (nothing,nothing,["producer_clock_mismatch"])
    end
    (start.value,stop.value,reasons)
end
const _PHASE_ADDITIVE=((:duration_seconds,"duration_seconds","s"),
    (:cpu_seconds,"process_cpu_seconds","s"),(:allocated_bytes,"allocated_bytes","bytes"),
    (:gc_seconds,"gc_seconds","s"),(:gc_count,"gc_count",""))
function _phase_aggregate(items)
    firstq=first(items);lastq=last(items);event=firstq.event
    width=_phase_metric(event,:task_width)
    taskwidth=width!==nothing && width.measurement_status===:measured && width.value isa Int64 && width.value>0 ? string(width.value) : nothing
    known=[q.event.sequence for q in items if q.event.sequence>0]
    # Missing any Core ordinal makes this envelope unavailable; no guessed sequence.
    coreknown=length(known)==length(items)
    row=Dict{String,Any}("kind"=>"aggregate","stage"=>String(event.stage),"phase"=>event.label,
        "status"=>String(event.status),"task_width"=>taskwidth,"counter_scope"=>"process_inclusive_delta_on_end",
        "first_sequence"=>string(firstq.sequence),"last_sequence"=>string(lastq.sequence),
        "first_core_sequence"=>coreknown ? string(minimum(known)) : nothing,
        "last_core_sequence"=>coreknown ? string(maximum(known)) : nothing,"call_count"=>string(length(items)))
    metrics=Any[]
    for (source,name,unit) in _PHASE_ADDITIVE
        total=nothing;measured=0;unavailable=0;reasons=String[];broken=false
        for q in items
            m=_phase_metric(q.event,source)
            if m===nothing || m.measurement_status!==:measured ||
               !(m.value isa Union{Int64,Float64}) || !isfinite(m.value) || m.unit!=unit
                unavailable+=1
                push!(reasons,m===nothing ? "not_measured" : m.measurement_status!==:measured && m.reason!==nothing ? String(m.reason) : "metric_type_or_unit_invalid")
                continue
            end
            measured+=1
            if !broken
                try
                    if total===nothing
                        total=m.value
                    elseif typeof(total)!==typeof(m.value)
                        throw(ArgumentError("mixed counter types"))
                    else
                        total=total isa Int64 ? Base.checked_add(total,m.value) : total+m.value
                        isfinite(total) || throw(OverflowError("counter overflow"))
                    end
                catch
                    broken=true;total=nothing;push!(reasons,"counter_overflow")
                end
            end
        end
        push!(metrics,Dict("name"=>name,"unit"=>unit,"sum"=>_phase_value(total),
            "measured_calls"=>string(measured),"unavailable_calls"=>string(unavailable),"reasons"=>unique(reasons)))
    end
    starts=Int64[];ends=Int64[];reasons=String[]
    for q in items
        start,stop,why=_phase_clock(q.event)
        if start===nothing
            append!(reasons,why)
        else
            push!(starts,start);push!(ends,stop)
        end
    end
    row["metrics"]=metrics
    row["time_bounds"]=Dict("min_start_monotonic_ns"=>isempty(starts) ? nothing : string(minimum(starts)),
        "max_end_monotonic_ns"=>isempty(ends) ? nothing : string(maximum(ends)),
        "measured_calls"=>string(length(starts)),"unavailable_calls"=>string(length(items)-length(starts)),"reasons"=>unique(reasons))
    row
end
function _phase_rows!(o,batch)
    rows=Any[];groups=Dict{Tuple{Symbol,String,Symbol,Union{Nothing,Int64}},Vector{_PhaseQueued}}()
    for q in batch
        context=_phase_span!(o,q)
        if o.policy.mode===:diagnostic
            push!(rows,_phase_event_row(o,q,context))
        elseif q.event.action===:phase_end
            e=q.event;m=_phase_metric(e,:task_width)
            width=m!==nothing && m.measurement_status===:measured && m.value isa Int64 && m.value>0 ? m.value : nothing
            key=(e.stage,e.label,e.status,width)
            if !haskey(groups,key) && length(groups)>=o.policy.maximum_aggregate_keys
                _phase_note!(o,8);_phase_drop!(o,1)
            else
                push!(get!(groups,key,_PhaseQueued[]),q)
            end
        end
    end
    if o.policy.mode===:normal
        _phase_add!(o.coalesced,length(batch))
        for key in sort!(collect(keys(groups));by=string)
            push!(rows,_phase_aggregate(groups[key]))
        end
    end
    rows
end
function _phase_seal!(o,batch)
    isempty(batch) && return nothing
    rows=_phase_rows!(o,batch)
    if isempty(rows)
        o.inflight[]=0;o.inflight_events[]=0;return nothing
    end
    o.generation=Base.checked_add(o.generation,1)
    bounds=[row["kind"]=="event" ? (parse(Int,row["sequence"]),parse(Int,row["sequence"])) :
        (parse(Int,row["first_sequence"]),parse(Int,row["last_sequence"])) for row in rows]
    firstsequence=minimum(first.(bounds));lastsequence=maximum(last.(bounds))
    segment=_phase_envelope(o,"qcl-negf.producer-phase-segment.v1")
    merge!(segment,Dict("mode"=>String(o.policy.mode),"segment_ordinal"=>string(o.generation),
        "first_sequence"=>string(firstsequence),"last_sequence"=>string(lastsequence),
        "observed_events"=>string(length(batch)),"coalesced_events"=>o.policy.mode===:normal ? string(length(batch)) : "0",
        "rows"=>rows,"health"=>_phase_health(o),"sealed"=>true))
    suffix=lpad(string(o.generation),9,'0')
    o.hook(:before_segment,o.directory)
    segmentref=_phase_write!(o,"segment-$suffix.json",_phase_encode(o,segment))
    segmentref["schema"]=segment["schema"];o.hook(:after_segment,o.directory)
    _phase_add!(o.sealed,length(batch));o.inflight[]=0;o.inflight_events[]=0
    publication=_phase_envelope(o,"qcl-negf.producer-phase-publication.v1")
    merge!(publication,Dict("generation"=>string(o.generation),"previous"=>o.publication,
        "segment"=>segmentref,"first_sequence"=>string(firstsequence),"last_sequence"=>string(lastsequence),
        "rows"=>string(length(rows)),"health"=>_phase_health(o)))
    o.hook(:before_publication,o.directory)
    ref=_phase_write!(o,"publication-$suffix.json",_phase_encode(o,publication))
    ref["schema"]=publication["schema"];o.hook(:after_publication,o.directory)
    # The in-memory head changes only when every dependency is closed and synchronized.
    o.hook(:before_current,o.directory)
    _phase_current!(o;publication=ref)
    nothing
end
function _phase_worker!(o)
    prepared=false
    try
        o.hook(:initial_current,o.directory)
        _phase_prepare_directory!(o);prepared=true;_phase_current!(o)
        last_snapshot=time_ns();last_flush=last_snapshot
        while true
            if o.queued[]>0 && (_phase_closed(o) || o.queued[]>=o.policy.batch_events ||
                o.buffered[]>=o.policy.batch_bytes || (time_ns()-last_flush)/1e9>=o.policy.flush_seconds)
                batch=_phase_take_batch!(o)
                _phase_seal!(o,batch);last_flush=time_ns();last_snapshot=last_flush
            end
            if _phase_closed(o) && o.queued[]==0
                _phase_current!(o;closing=true);break
            end
            if (time_ns()-last_snapshot)/1e9>=o.policy.snapshot_seconds
                _phase_current!(o);last_snapshot=time_ns()
            end
            sleep(min(o.policy.flush_seconds,0.01))
        end
    catch error
        o.failed[]=true;_phase_note!(o,16)
        lock(o.lock) do
            _phase_add!(o.drops[6],o.queued[]+o.inflight_events[])
            fill!(o.ring,nothing);o.queued[]=0;o.buffered[]=0
            o.oldest_ns[]=0
        end
        o.inflight[]=0;o.inflight_events[]=0
        # One best-effort failure snapshot only; never an unbounded retry/fallback log.
        try
            prepared && isdir(o.directory) && !islink(o.directory) && _phase_current!(o;closing=true)
        catch
        end
    finally
        # Tail is not istaskdone. Only later metadata maintenance can reap this generation.
        o.closed[]=true
    end
    nothing
end
