"""Bounded, lossy telemetry. The producer never waits for the sink or an acknowledgement."""
mutable struct ScalarTelemetrySender
    sink::Function
    capacity::Int
    maximum_event_bytes::Int
    poll_seconds::Float64
    buffer::Vector{Dict{String,Any}}
    lock::ReentrantLock
    closed::Threads.Atomic{Bool}
    dropped::Threads.Atomic{Int}
    sent::Threads.Atomic{Int}
    failed::Threads.Atomic{Int}
    task::Union{Nothing,Task}
end
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
            name=String(key)
            _telemetry_charge!(remaining,6*ncodeunits(name)+4)
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
    capacity>0 && maximum_event_bytes>0 && isfinite(poll_seconds) && poll_seconds>0 ||
        throw(ArgumentError("telemetry bounds must be positive"))
    sender=ScalarTelemetrySender(sink,capacity,maximum_event_bytes,Float64(poll_seconds),
        Dict{String,Any}[],ReentrantLock(),Threads.Atomic{Bool}(false),Threads.Atomic{Int}(0),
        Threads.Atomic{Int}(0),Threads.Atomic{Int}(0),nothing)
    sender.task=Threads.@spawn begin
        while !sender.closed[]
            event=lock(sender.lock) do
                isempty(sender.buffer) ? nothing : popfirst!(sender.buffer)
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
            empty!(sender.buffer)
        end
    end
    return sender
end
function emit_telemetry!(sender::ScalarTelemetrySender,event::AbstractDict)
    sender.closed[] && return false
    copied=try
        _telemetry_scalar_copy(event,0,Ref(sender.maximum_event_bytes))
    catch
        Threads.atomic_add!(sender.dropped,1)
        return false
    end
    ncodeunits(sprint(_light_json,copied))<=sender.maximum_event_bytes || begin
        Threads.atomic_add!(sender.dropped,1)
        return false
    end
    if !trylock(sender.lock)
        Threads.atomic_add!(sender.dropped,1)
        return false
    end
    try
        if sender.closed[] || length(sender.buffer)>=sender.capacity
            Threads.atomic_add!(sender.dropped,1)
            return false
        end
        push!(sender.buffer,copied)
        return true
    finally
        unlock(sender.lock)
    end
end
function telemetry_statistics(sender::ScalarTelemetrySender)
    queued=lock(sender.lock) do
        length(sender.buffer)
    end
    return Dict("queued"=>queued,"dropped"=>sender.dropped[],"sent"=>sender.sent[],"failed"=>sender.failed[])
end
Base.close(sender::ScalarTelemetrySender) = (sender.closed[]=true;nothing)

"""Opt-in HTTP JSON transport, called exclusively from the sender task."""
function http_telemetry_sink(endpoint::AbstractString;timeout_seconds::Real=5)
    occursin(r"^https?://",endpoint) || throw(ArgumentError("telemetry endpoint must be HTTP(S)"))
    isfinite(timeout_seconds) && timeout_seconds>0 || throw(ArgumentError("telemetry timeout must be positive"))
    return event->begin
        bytes=sprint(_light_json,event)
        response=Downloads.request(String(endpoint);method="POST",headers=["Content-Type"=>"application/json"],
            input=IOBuffer(bytes),output=devnull,timeout=Float64(timeout_seconds))
        200<=response.status<300 || throw(ArgumentError("telemetry collector rejected event"))
        nothing
    end
end
