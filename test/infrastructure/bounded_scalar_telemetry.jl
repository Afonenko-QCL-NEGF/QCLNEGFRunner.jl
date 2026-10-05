module BoundedScalarTelemetry
include("../support/common.jl")
const R=QCLNEGFRunner
struct CountedTelemetryMap <: AbstractDict{String,Any}
    visited::Base.RefValue{Int}
end
Base.length(::CountedTelemetryMap)=128
function Base.iterate(value::CountedTelemetryMap,index=1)
    index>128 && return nothing
    value.visited[]+=1
    return ("metric-$(index)"=>"payload",index+1)
end
@testset "Oversized scalar input is rejected before copying the entire mapping" begin
    visited=Ref(0)
    sender=R.ScalarTelemetrySender(_->nothing;maximum_event_bytes=64)
    @test !R.emit_telemetry!(sender,CountedTelemetryMap(visited))
    @test visited[]<128
    close(sender)
end
@testset "Slow or failed telemetry sink cannot block solver event publication" begin
    entered=Channel{Nothing}(1)
    release=Channel{Nothing}(1)
    received=Dict{String,Any}[]
    sender=R.ScalarTelemetrySender(event->begin
        put!(entered,nothing)
        take!(release)
        push!(received,event)
    end;capacity=4,poll_seconds=0.001)
    event=Dict{String,Any}("schema"=>"qcl-negf-runtime-event-v1","value"=>7)
    @test R.emit_telemetry!(sender,event)
    take!(entered)
    event["value"]=99
    for index in 1:100
        R.emit_telemetry!(sender,Dict("value"=>index))
    end
    @test R.telemetry_statistics(sender)["queued"]<=4
    @test R.telemetry_statistics(sender)["dropped"]>0
    @test !R.emit_telemetry!(sender,Dict("solver_array"=>zeros(100)))
    close(sender)
    put!(release,nothing)
    wait(sender.task)
    @test only(received)["value"]==7
    failing=R.ScalarTelemetrySender(_->error("collector unavailable");poll_seconds=0.001)
    @test R.emit_telemetry!(failing,Dict("value"=>1))
    @test timedwait(()->R.telemetry_statistics(failing)["failed"]==1,2;pollint=0.01)==:ok
    close(failing)
end
end
