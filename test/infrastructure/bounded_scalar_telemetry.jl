module BoundedScalarTelemetry
using QCLNEGF
include("../support/common.jl")
const R=QCLNEGFRunner
@testset "Stored qualified scalar cadence and transport remain finite positive" begin
    sink=R.http_telemetry_sink("http://unused.invalid")
    @test_throws ArgumentError R._scalar_profile(sink,1,64,big"1e-10000")
    @test_throws ArgumentError R._scalar_profile(sink,1,64,big"1e10000")
    @test_throws ArgumentError R._scalar_profile(R.http_telemetry_sink("http://unused.invalid";timeout_seconds=big"1e10000"),1,64,.01)
end
@testset "Closed scalar sender cannot spawn another task before actual completion" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    sender=R.ScalarTelemetrySender(event->begin
        put!(entered,nothing);take!(release)
    end;capacity=2,poll_seconds=0.001)
    try
        @test R.emit_telemetry!(sender,Dict("value"=>1))
        take!(entered);close(sender)
        @test !istaskdone(sender.task)
        candidate=try R.ScalarTelemetrySender(_->nothing;capacity=2) catch error; error end
        @test candidate isa Exception
        if candidate isa R.ScalarTelemetrySender
            close(candidate);@test timedwait(()->istaskdone(candidate.task),5)==:ok
        end
    finally
        close(sender);put!(release,nothing)
        @test timedwait(()->istaskdone(sender.task),5)==:ok
    end
    next=R.ScalarTelemetrySender(_->nothing;capacity=2)
    close(next);@test timedwait(()->istaskdone(next.task),5)==:ok
end
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
    @test timedwait(()->istaskdone(sender.task),5)==:ok
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
    @test timedwait(()->istaskdone(failing.task),5)==:ok
end
@testset "Sender admission never serializes and close accounts queued loss" begin
    serialized=Threads.Atomic{Int}(0)
    @eval R function _light_json(io::IO,value::Int128)
        Threads.atomic_add!($serialized,1)
        invoke(_light_json,Tuple{IO,Any},io,value)
    end
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    sender=R.ScalarTelemetrySender(event->begin
        put!(entered,nothing);take!(release)
    end;capacity=4,poll_seconds=0.001)
    @test R.emit_telemetry!(sender,Dict("value"=>1))
    take!(entered)
    @test serialized[]==0
    @test R.emit_telemetry!(sender,Dict("value"=>2))
    @test R.emit_telemetry!(sender,Dict("value"=>3))
    close(sender);put!(release,nothing);wait(sender.task)
    @test R.telemetry_statistics(sender)["dropped"]==2
    @test R.telemetry_statistics(sender)["queued"]==0
end
@testset "Copy lane precedes source visits and oversized Symbol formatting" begin
    sender=R.ScalarTelemetrySender(_->nothing;capacity=2,maximum_event_bytes=64,poll_seconds=.001)
    try
        visited=Ref(0); sender.copying[]=true
        before=sender.dropped[]
        tasks=[Threads.@spawn R.emit_telemetry!(sender,CountedTelemetryMap(visited)) for _ in 1:32]
        @test all(!fetch(t) for t in tasks)
        @test visited[]==0 && sender.dropped[]==before+32
        sender.copying[]=false
        huge=Dict(Symbol(repeat("k",2*1024^2))=>1)
        R.emit_telemetry!(sender,huge) # compile the exact rejection path
        allocated=@allocated R.emit_telemetry!(sender,huge)
        @test allocated<65536 # caller's existing Symbol must not be formatted first
        println("scalar_oversized_key_copy_allocation=",allocated)
    finally
        sender.copying[]=false;close(sender)
        @test timedwait(()->istaskdone(sender.task),5)==:ok
    end
end
@testset "P05 builder preserves literal existing scalar display" begin
    received=Channel{Dict{String,Any}}(4)
    sender=R.ScalarTelemetrySender(x->put!(received,x);capacity=4,poll_seconds=.001)
    try
        event=QCLNEGF.SolverEvent(:progress,:scba,"row",:running,2,9,
            (QCLNEGF.SolverMetric(:raw,Int64(7),"count"),QCLNEGF.SolverMetric(:bad,NaN,"1")),"message")
        header=(;point_id="point",execution_id="execution",attempt=3)
        @test R.QCLScientificWorkflow._p05_emit_scalar!(sender,event,header)
        copied=take!(received)
        @test Set(keys(copied))==Set(["schema","event","name","status","timestamp_unix_seconds","attributes"])
        @test (copied["schema"],copied["event"],copied["name"],copied["status"])==("qcl-runtime-event-v1","progress","row","running")
        attributes=copied["attributes"]
        @test Set(keys(attributes))==Set(["point_id","execution_id","attempt","stage","iteration","total","message","metrics"])
        @test (attributes["point_id"],attributes["execution_id"],attributes["attempt"],attributes["stage"],attributes["iteration"],attributes["total"],attributes["message"])==("point","execution",3,"scba",2,9,"message")
        @test attributes["metrics"]["raw"]==Dict("value"=>7,"unit"=>"count","measurement_status"=>"measured","reason"=>nothing)
        @test attributes["metrics"]["bad"]==Dict("value"=>nothing,"unit"=>"1","measurement_status"=>"error","reason"=>"non_finite")
        sender.copying[]=true
        @test !R.QCLScientificWorkflow._p05_emit_scalar!(sender,event,header)
        sender.copying[]=false
        oversized=QCLNEGF.SolverEvent(:progress,:scba,"row",:running,1,1,
            Tuple(QCLNEGF.SolverMetric(Symbol("m",i),i,"") for i in 1:129),"")
        @test !R.QCLScientificWorkflow._p05_emit_scalar!(sender,oversized,header)
        @test !sender.copying[]
    finally
        sender.copying[]=false;close(sender)
        @test timedwait(()->istaskdone(sender.task),5)==:ok
    end
end

struct GatedScalarCopy <: AbstractDict{String,Any}
    entered::Channel{Nothing}
    release::Channel{Nothing}
end
Base.length(::GatedScalarCopy)=1
function Base.iterate(g::GatedScalarCopy,index=1)
    index>1 && return nothing
    put!(g.entered,nothing);take!(g.release)
    ("k"=>"payload",2)
end
@testset "Scalar admission seals before reap and charges admitted copy through last use" begin
    sink=R.http_telemetry_sink("http://unused.invalid")
    request=(;sink,capacity=2,maximum_event_bytes=128,poll_seconds=.001)
    for managed in (false,true)
        owner=managed ? R._p05_begin_observers!(;phase_request=nothing,scalar_request=request) : nothing
        sender=managed ? R._start_scalar_sender(sink;capacity=2,maximum_event_bytes=128,poll_seconds=.001,admission=owner) :
            R.ScalarTelemetrySender(sink;capacity=2,maximum_event_bytes=128,poll_seconds=.001)
        gate=GatedScalarCopy(Channel{Nothing}(1),Channel{Nothing}(1))
        producer=Threads.@spawn R.emit_telemetry!(sender,gate)
        take!(gate.entered)
        managed ? R._p05_end_observers!(owner) : close(sender)
        @test timedwait(()->istaskdone(sender.task),5)==:ok
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        try
            @test !istaskdone(producer) && sender.copying[]
            @test R._p05_observer_work_bound(a)==R._scalar_profile(sink,2,128,.001).payload_bound_bytes
            @test (@atomic :acquire R._SCALAR_RESIDENCY[].owner)===sender
            @test sender.producer_state[]==3 # sealed and still admitted
        finally
            R._p05_end_observers!(a);put!(gate.release,nothing);fetch(producer)
        end
        @test !sender.copying[] && sender.producer_state[]==2
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        @test R._p05_observer_work_bound(a)==0
        R._p05_end_observers!(a)
    end
    sender=R.ScalarTelemetrySender(sink;capacity=2,maximum_event_bytes=128,poll_seconds=.001)
    @test !R._scalar_closed(sender) # producer's stale read-open
    close(sender);@test timedwait(()->istaskdone(sender.task),5)==:ok
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        @test R._p05_observer_work_bound(a)==0
        @test !R._scalar_try_producer!(sender) # CAS after close/reap cannot admit payload
        visits=Ref(0)
        @test !R.emit_telemetry!(sender,CountedTelemetryMap(visits))
        @test visits[]==0
        @test !R.QCLScientificWorkflow._p05_emit_scalar!(sender,
            QCLNEGF.SolverEvent(:progress,:scba,"closed",:running,1,1,(),""),
            (;point_id="point",execution_id="execution",attempt=1))
        @test sender.producer_state[]==2
    finally
        R._p05_end_observers!(a)
    end
end

end
