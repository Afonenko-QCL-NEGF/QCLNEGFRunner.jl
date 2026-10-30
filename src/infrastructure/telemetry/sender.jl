"""Private capability for the fixed phase/scalar pair; never a scientific receipt."""
struct _P05ObserverAdmission
    epoch::UInt64
    phase_generation::UInt64
    scalar_generation::UInt64
    phase_bytes::Int
    scalar_bytes::Int
    start_phase::Bool
    start_scalar::Bool
end
const _P05_OBSERVER_EPOCH=Threads.Atomic{UInt64}(0)
const _P05_PHASE_GENERATION=Threads.Atomic{UInt64}(0)
const _P05_SCALAR_GENERATION=Threads.Atomic{UInt64}(0)
const _P05_PHASE_RELEASE_EPOCH=Threads.Atomic{UInt64}(0)
const _P05_SCALAR_RELEASE_EPOCH=Threads.Atomic{UInt64}(0)
const _P05_EPOCH_COUNTER=Ref{UInt64}(0) # protected by both fixed metadata locks
struct _ScalarSenderUnavailable <: Exception
    reason::Symbol
end
Base.showerror(io::IO,e::_ScalarSenderUnavailable)=print(io,"scalar telemetry unavailable: ",e.reason)
struct _ScalarResidentProfile
    capacity::Int
    maximum_event_bytes::Int
    poll_seconds::Float64
    header_bytes::Int
    payload_bound_bytes::Int
end

"""Bounded, lossy telemetry. The producer never waits for the sink or an acknowledgement."""
mutable struct ScalarTelemetrySender
    sink::Function
    capacity::Int
    maximum_event_bytes::Int
    poll_seconds::Float64
    buffer::Vector{Union{Nothing,Dict{String,Any}}}
    head::Int
    tail::Int
    queued::Threads.Atomic{Int}
    lock::ReentrantLock
    closed::Threads.Atomic{Bool}
    dropped::Threads.Atomic{Int}
    sent::Threads.Atomic{Int}
    failed::Threads.Atomic{Int}
    task::Union{Nothing,Task}
    generation::UInt64
    owner_epoch::UInt64
    caller_released::Threads.Atomic{Bool}
    copying::Threads.Atomic{Bool}
    producer_state::Threads.Atomic{UInt8} # bit 0: admitted lane; bit 1: sealed forever
end
mutable struct _ScalarLifetime
    profile::Union{Nothing,_ScalarResidentProfile}
    generation::UInt64
    owner_epoch::UInt64
    started::Threads.Atomic{Bool}
    caller_released::Threads.Atomic{Bool}
    @atomic task::Union{Nothing,Task}
    @atomic owner::Union{Nothing,ScalarTelemetrySender}
end
const _SCALAR_RESIDENCY_LOCK=ReentrantLock()
const _SCALAR_RESIDENCY=Ref{Union{Nothing,_ScalarLifetime}}(nothing)
const _SCALAR_GENERATION_COUNTER=Ref{UInt64}(0)
function _observer_generation!(counter)
    counter[]==typemax(UInt64) && throw(ArgumentError("observer generation exhausted"))
    counter[]+=UInt64(1)
end
function _scalar_reap_locked!()
    r=_SCALAR_RESIDENCY[];r===nothing && return
    t=@atomic :acquire r.task
    released=r.owner_epoch==0 ? r.caller_released[] : _P05_SCALAR_RELEASE_EPOCH[]>=r.owner_epoch
    if released
        owner=@atomic :acquire r.owner
        # Seal admission before checking the lane. A producer that read open
        # before close/reap can no longer win its admission CAS after this OR.
        owner===nothing || Threads.atomic_or!(owner.producer_state,UInt8(2))
        quiet=owner===nothing || owner.producer_state[]==UInt8(2)
        quiet && (!r.started[] || t!==nothing && istaskdone(t)) && (_SCALAR_RESIDENCY[]=nothing)
    end
    nothing
end
function _scalar_profile(sink,capacity,b,poll)
    sink isa _PreparedJSONSink && sink.send_bytes isa _HTTPJSONTransport || return nothing
    capacity isa Int && capacity>0 && b isa Int && b>=2 || throw(ArgumentError("invalid scalar resource profile"))
    cadence=Float64(poll)
    isfinite(cadence) && cadence>0 && isfinite(sink.send_bytes.timeout_seconds) &&
        sink.send_bytes.timeout_seconds>0 || throw(ArgumentError("invalid scalar resource cadence"))
    h=Base.checked_add(ncodeunits(sink.send_bytes.endpoint),64)
    k=Base.checked_add(1,Base.checked_mul(2,(b-2)÷6))
    f=Base.checked_add(Base.checked_mul(512,k),Base.checked_mul(16,b))
    bytes=Base.checked_add(4096,Base.checked_add(Base.checked_mul(16,capacity),
        Base.checked_add(Base.checked_mul(Base.checked_add(capacity,3),f),
            Base.checked_add(Base.checked_mul(4,b),Base.checked_mul(16,h)))))
    _ScalarResidentProfile(capacity,b,cadence,h,bytes)
end
function _scalar_reserve_locked!(profile,epoch)
    g=_observer_generation!(_SCALAR_GENERATION_COUNTER)
    r=_ScalarLifetime(profile,g,epoch,Threads.Atomic{Bool}(false),Threads.Atomic{Bool}(false),nothing,nothing)
    _SCALAR_RESIDENCY[]=r;r
end
_scalar_closed(s)=s.closed[] || s.owner_epoch!=0 && _P05_SCALAR_RELEASE_EPOCH[]>=s.owner_epoch
function _telemetry_charge!(remaining,bytes)
    bytes<=remaining[] || throw(ArgumentError("telemetry event exceeds its scalar copy budget"))
    remaining[]-=bytes
    return nothing
end
function _telemetry_scalar_copy(value,depth=0,remaining=Ref(16384))
    depth<=4 || throw(ArgumentError("telemetry nesting exceeds limit"))
    if value isa AbstractDict
        length(value)<=128 || throw(ArgumentError("telemetry mapping exceeds limit"))
        _telemetry_charge!(remaining,2)
        copied=Dict{String,Any}()
        for (key,item) in value
            key isa Union{Symbol,AbstractString} || throw(ArgumentError("telemetry key must be text"))
            bytes=key isa Symbol ? sizeof(key) : ncodeunits(key)
            _telemetry_charge!(remaining,Base.checked_add(Base.checked_mul(6,bytes),4))
            name=String(key)
            copied[name]=_telemetry_scalar_copy(item,depth+1,remaining)
        end
        return copied
    elseif value===nothing || value isa Bool
        _telemetry_charge!(remaining,5)
        return value
    elseif value isa Integer
        # Counters are bounded machine integers; arbitrary precision strings
        # could allocate unbounded formatting work before the byte check.
        bounded=Int128(value)
        _telemetry_charge!(remaining,40)
        return bounded
    elseif value isa AbstractFloat
        _telemetry_charge!(remaining,32)
        return isfinite(value) ? Float64(value) : nothing
    elseif value isa AbstractString
        ncodeunits(value)<=8192 || throw(ArgumentError("telemetry string exceeds limit"))
        _telemetry_charge!(remaining,6*ncodeunits(value)+2)
        return String(value)
    end
    throw(ArgumentError("telemetry accepts independent scalar values, not solver arrays"))
end
function ScalarTelemetrySender(sink::Function;capacity::Int=256,maximum_event_bytes::Int=16384,poll_seconds::Real=0.01)
    _start_scalar_sender(sink;capacity,maximum_event_bytes,poll_seconds,admission=nothing)
end
function _start_scalar_sender(sink::Function;capacity::Int,maximum_event_bytes::Int=16384,
    poll_seconds::Real=0.01,admission::Union{Nothing,_P05ObserverAdmission})
    capacity>0 && maximum_event_bytes>0 && isfinite(poll_seconds) && poll_seconds>0 ||
        throw(ArgumentError("telemetry bounds must be positive"))
    profile=_scalar_profile(sink,capacity,maximum_event_bytes,poll_seconds)
    trylock(_SCALAR_RESIDENCY_LOCK) || throw(_ScalarSenderUnavailable(:observer_residency_snapshot_contended))
    local r
    try
        _P05_OBSERVER_EPOCH[]==0 && _scalar_reap_locked!()
        if admission===nothing
            _P05_OBSERVER_EPOCH[]==0 || throw(_ScalarSenderUnavailable(:observer_epoch_active))
            _SCALAR_RESIDENCY[]===nothing || throw(_ScalarSenderUnavailable(:previous_scalar_sender_pending))
            r=_scalar_reserve_locked!(profile,UInt64(0))
        else
            r=_SCALAR_RESIDENCY[]
            _P05_OBSERVER_EPOCH[]==admission.epoch && admission.start_scalar && r!==nothing &&
                r.owner_epoch==admission.epoch && r.generation==admission.scalar_generation &&
                profile!==nothing && r.profile==profile || throw(ArgumentError("scalar admission differs"))
        end
        Threads.atomic_cas!(r.started,false,true)==false || throw(_ScalarSenderUnavailable(:previous_scalar_sender_pending))
    finally
        unlock(_SCALAR_RESIDENCY_LOCK)
    end
    try
    sender=ScalarTelemetrySender(sink,capacity,maximum_event_bytes,Float64(poll_seconds),
        Vector{Union{Nothing,Dict{String,Any}}}(nothing,capacity),1,1,Threads.Atomic{Int}(0),
        ReentrantLock(),Threads.Atomic{Bool}(false),Threads.Atomic{Int}(0),
        Threads.Atomic{Int}(0),Threads.Atomic{Int}(0),nothing,r.generation,r.owner_epoch,r.caller_released,Threads.Atomic{Bool}(false),Threads.Atomic{UInt8}(0))
    @atomic :release r.owner=sender
    sender.task=Threads.@spawn begin
        try
        while !_scalar_closed(sender)
            event=lock(sender.lock) do
                if sender.queued[]==0
                    nothing
                else
                    event=sender.buffer[sender.head]
                    sender.buffer[sender.head]=nothing
                    sender.head=mod1(sender.head+1,sender.capacity)
                    Threads.atomic_add!(sender.queued,-1)
                    event
                end
            end
            if event===nothing
                sleep(sender.poll_seconds)
                continue
            end
            try
                sender.sink(event)
                Threads.atomic_add!(sender.sent,1)
            catch
                Threads.atomic_add!(sender.failed,1)
            end
        end
        lock(sender.lock) do
            Threads.atomic_add!(sender.dropped,sender.queued[])
            fill!(sender.buffer,nothing)
            sender.queued[]=0
        end
        finally
            sender.closed[]=true
        end
    end
    @atomic :release r.task=sender.task
    return sender
    catch
        # With no published owner, no task could have been spawned. Otherwise
        # retain the starting entry: an uncertain task attachment is never zero.
        if (@atomic :acquire r.owner)===nothing
            r.started[]=false;r.caller_released[]=true
        end
        rethrow()
    end
end
function _scalar_try_producer!(sender::ScalarTelemetrySender)::Bool
    # This CAS, rather than an earlier read-open check, is the payload boundary.
    if Threads.atomic_cas!(sender.producer_state,UInt8(0),UInt8(1))!=0
        Threads.atomic_add!(sender.dropped,1);return false
    end
    if _scalar_closed(sender) || Threads.atomic_cas!(sender.copying,false,true)
        Threads.atomic_add!(sender.dropped,1)
        Threads.atomic_and!(sender.producer_state,UInt8(2)) # last admitted-lane access
        return false
    end
    true
end
function _scalar_release_producer!(sender::ScalarTelemetrySender)
    sender.copying[]=false
    # Last producer access: reap may release B only after this operation.
    Threads.atomic_and!(sender.producer_state,UInt8(2))
    nothing
end
function emit_telemetry!(sender::ScalarTelemetrySender,event::AbstractDict)
    _scalar_try_producer!(sender) || return false
    try
        return _emit_scalar_locked!(sender,event)
    finally
        _scalar_release_producer!(sender)
    end
end
function _emit_scalar_locked!(sender::ScalarTelemetrySender,event::AbstractDict)
    copied=try
        _telemetry_scalar_copy(event,0,Ref(sender.maximum_event_bytes))
    catch
        Threads.atomic_add!(sender.dropped,1)
        return false
    end
    _enqueue_scalar_copy!(sender,copied)
end
function _enqueue_scalar_copy!(sender::ScalarTelemetrySender,copied::Dict{String,Any})
    if !trylock(sender.lock)
        Threads.atomic_add!(sender.dropped,1)
        return false
    end
    try
        if _scalar_closed(sender) || sender.queued[]>=sender.capacity
            Threads.atomic_add!(sender.dropped,1)
            return false
        end
        sender.buffer[sender.tail]=copied
        sender.tail=mod1(sender.tail+1,sender.capacity)
        Threads.atomic_add!(sender.queued,1)
        return true
    finally
        unlock(sender.lock)
    end
end
function telemetry_statistics(sender::ScalarTelemetrySender)
    return Dict("queued"=>sender.queued[],"dropped"=>sender.dropped[],"sent"=>sender.sent[],"failed"=>sender.failed[])
end
function Base.close(sender::ScalarTelemetrySender)
    Threads.atomic_or!(sender.producer_state,UInt8(2))
    sender.closed[]=true
    sender.owner_epoch==0 && (sender.caller_released[]=true)
    nothing
end

"""A prepared-byte transport. Dict input encodes once; sealed bytes are never re-encoded."""
struct _PreparedJSONSink <: Function
    send_bytes::Function
end
struct _HTTPJSONTransport <: Function
    endpoint::String
    timeout_seconds::Float64
end
function (sink::_HTTPJSONTransport)(bytes::Vector{UInt8})
    response=Downloads.request(sink.endpoint;method="POST",headers=["Content-Type"=>"application/json"],
        input=IOBuffer(bytes),output=devnull,timeout=sink.timeout_seconds)
    200<=response.status<300 || throw(ArgumentError("telemetry collector rejected event"))
    nothing
end
(sink::_PreparedJSONSink)(bytes::Vector{UInt8})=sink.send_bytes(bytes)
function (sink::_PreparedJSONSink)(event::AbstractDict)
    io=IOBuffer();_light_json(io,event)
    sink.send_bytes(take!(io))
end

"""Opt-in HTTP JSON transport, called exclusively from a background sender/writer."""
function http_telemetry_sink(endpoint::AbstractString;timeout_seconds::Real=5)
    occursin(r"^https?://",endpoint) || throw(ArgumentError("telemetry endpoint must be HTTP(S)"))
    isfinite(timeout_seconds) && timeout_seconds>0 || throw(ArgumentError("telemetry timeout must be positive"))
    return _PreparedJSONSink(_HTTPJSONTransport(String(endpoint),Float64(timeout_seconds)))
end
