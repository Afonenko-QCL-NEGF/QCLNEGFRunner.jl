module BatchedPhaseSegments
using Test, QCLNEGFRunner, QCLNEGF, YAML, SHA
const R=QCLNEGFRunner
const C=QCLNEGF
const output=get(ENV,"QCL_P29_TEST_ROOT","")
isabspath(output) && isdir(output) || error("Supply fresh QCL_P29_TEST_ROOT")
function identity()
    Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point","attempt"=>"1",
        "branch_id"=>"branch","model_sha256"=>"a"^64,"plan_sha256"=>"b"^64)
end
function policy(;mode=:normal,capacity=4,keys=8,depth=4,cadence=0.01,snapshot=0.01)
    R.PhaseObservationPolicy(;mode,maximum_event_bytes=16384,capacity_bytes=capacity*16384,
        batch_events=capacity,batch_bytes=capacity*16384,flush_seconds=cadence,
        snapshot_seconds=snapshot,maximum_depth=depth,maximum_aggregate_keys=keys,reserve_bytes=0)
end
function event(action,start,stop;phase="mixing",sequence=0,extra=(),clocks=true,
    allocated=Int64(9007199254740993),cpu=C.SolverMetric(:cpu_seconds,0.25,"s"))
    metrics=C.SolverMetric[C.SolverMetric(:task_width,2),
        C.SolverMetric(:duration_seconds,(stop-start)/1e9,"s"),
        cpu,C.SolverMetric(:allocated_bytes,allocated,"bytes"),
        C.SolverMetric(:gc_seconds,0.0,"s"),C.SolverMetric(:gc_count,Int64(0),"")]
    clocks && append!(metrics,[C.SolverMetric(:producer_monotonic_ns,stop,"ns"),
        C.SolverMetric(:start_monotonic_ns,start,"ns"),C.SolverMetric(:end_monotonic_ns,stop,"ns")])
    append!(metrics,extra)
    C.SolverEvent(action,:scba,phase,action===:phase_begin ? :running : :completed,
        1,nothing,Tuple(metrics),"",sequence,1,1)
end
function observer(name;mode=:normal,capacity=8,hook=(stage,path)->nothing,keys=8,depth=4,cadence=0.01)
    root=joinpath(output,name);mkpath(root)
    directory=joinpath(root,"attempt","progress","phases","session")
    R._start_phase_observer(directory;artifact_root=root,identity=identity(),
        source_session="session",policy=policy(;mode,capacity,keys,depth,cadence),
        capacity_events=capacity,publication_hook=hook)
end
function finish(o)
    R._close_phase_observer!(o)
    @test timedwait(()->istaskdone(o.task),10;pollint=0.01)==:ok
    fetch(o.task)
    lock(R._PHASE_RESIDENCY_LOCK) do
        R._phase_reap_locked!()
    end
end
load(path)=YAML.load_file(path;dicttype=Dict{String,Any})
function segments(o)
    [load(joinpath(o.directory,f)) for f in sort(readdir(o.directory)) if startswith(f,"segment-")]
end
@testset "Phase charge lane rejects oversized symbols before formatting" begin
    o=observer("charge-lane";hook=R._NO_PHASE_PUBLICATION_HOOK)
    try
        e=C.SolverEvent(:phase_begin,Symbol(repeat("k",2*1024^2)),"row",:running,1,1,(),"")
        R._enqueue_phase!(o,e)
        allocated=@allocated R._enqueue_phase!(o,e)
        @test allocated<65536
        println("phase_oversized_symbol_allocation=",allocated)
        o.admitting[]=true;before=o.drops[2][]
        jobs=[Threads.@spawn R._enqueue_phase!(o,event(:phase_end,1,2)) for _ in 1:32]
        @test all(!fetch(t) for t in jobs)
        @test o.drops[2][]==before+32
        o.admitting[]=false
    finally
        o.admitting[]=false;finish(o)
    end
end
@testset "Policy admission and defaults" begin
    p=R._normal_phase_policy(256)
    @test p.mode===:normal && p.batch_events==64 && p.reserve_bytes==67108864
    @test p.capacity_bytes==256*16384
    @test_throws ArgumentError policy(mode=:unknown)
    @test_throws ArgumentError R._normal_phase_policy(true)
end
# Constructor only: invalid cadences never reach observer/task/filesystem creation.
@testset "Cadence conversion preserves stored finite positive invariant" begin
    @testset "Flush underflow" begin
        @test_throws ArgumentError policy(cadence=big"1e-10000")
    end
    @testset "Flush overflow" begin
        @test_throws ArgumentError policy(cadence=big"1e10000")
    end
    @testset "Snapshot underflow" begin
        @test_throws ArgumentError policy(snapshot=big"1e-10000")
    end
    @testset "Snapshot overflow" begin
        @test_throws ArgumentError policy(snapshot=big"1e10000")
    end
    for (flush,snapshot) in ((0.25,0.5),(1//2,3//4),(big"1e-300",big"1e300"))
        p=policy(cadence=flush,snapshot=snapshot)
        @test p.flush_seconds===Float64(flush) && isfinite(p.flush_seconds) && p.flush_seconds>0
        @test p.snapshot_seconds===Float64(snapshot) && isfinite(p.snapshot_seconds) && p.snapshot_seconds>0
    end
    @test_throws ArgumentError policy(cadence=true)
    @test_throws ArgumentError policy(snapshot=true)
    @test_throws ArgumentError policy(cadence=Inf)
    @test_throws ArgumentError policy(snapshot=0.0)
end
@testset "Typed normal clocks and independent exact integers" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("normal";hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered)
    descriptor=R._phase_source_descriptor(o)
    @test descriptor.status===:available && descriptor.session_id=="session"
    @test !isfile(joinpath(o.directory,"phase-current.json")) # no initial durable-head promise
    @test R._enqueue_phase!(o,event(:phase_begin,100,100;sequence=1))
    @test R._enqueue_phase!(o,event(:phase_end,100,300;sequence=9))
    @test R._enqueue_phase!(o,event(:phase_end,400,600;sequence=15,clocks=false))
    @test !ispath(o.directory) # enqueue has no per-event filesystem operation
    @test R._phase_observer_statistics(o).encoded_documents==0
    put!(release,nothing);finish(o)
    rows=only(segments(o))["rows"];row=only(rows)
    @test row["call_count"]=="2"
    @test row["first_sequence"]=="2" && row["last_sequence"]=="3"
    @test row["time_bounds"]==Dict("min_start_monotonic_ns"=>"100",
        "max_end_monotonic_ns"=>"300","measured_calls"=>"1","unavailable_calls"=>"1",
        "reasons"=>["producer_clock_missing"])
    metrics=Dict(m["name"]=>m for m in row["metrics"])
    @test metrics["allocated_bytes"]["sum"]["decimal"]=="18014398509481986"
    @test metrics["process_cpu_seconds"]["sum"]==0.5
    current=load(joinpath(o.directory,"phase-current.json"))
    @test current["closed"] && current["publication"]!==nothing
    @test current["health"]["incomplete"] # unmatched second end visible, scientific row untouched
end
@testset "Blocked background writer pressure and nonblocking close" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("blocked";capacity=2,hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered)
    @test R._enqueue_phase!(o,event(:phase_end,10,20))
    @test R._enqueue_phase!(o,event(:phase_end,30,40))
    @test !R._enqueue_phase!(o,event(:phase_end,50,60))
    s=R._phase_observer_statistics(o)
    @test s.queued_events==2 && s.buffered_bytes<=o.policy.capacity_bytes
    @test s.dropped.capacity==1 && s.encoded_documents==0
    R._close_phase_observer!(o)
    @test !istaskdone(o.task) && !R._enqueue_phase!(o,event(:phase_end,70,80))
    put!(release,nothing);finish(o)
    @test load(joinpath(o.directory,"phase-current.json"))["health"]["dropped"]["closed"]=="1"
end
@testset "Cadence batches sparse events, not per-event file publication" begin
    o=observer("cadence";cadence=0.3)
    @test timedwait(()->isfile(joinpath(o.directory,"phase-current.json")),5)==:ok
    @test R._enqueue_phase!(o,event(:phase_end,1,10))
    sleep(0.05)
    @test isempty(segments(o))
    finish(o)
    @test length(segments(o))==1
end
@testset "Exception before Current keeps previous committed prefix" begin
    o=observer("pre-current-failure";hook=(stage,path)->stage===:before_current && error("injected before pointer"))
    @test R._enqueue_phase!(o,event(:phase_end,1,20))
    @test timedwait(()->istaskdone(o.task),5)==:ok
    current=load(joinpath(o.directory,"phase-current.json"))
    @test current["publication"]===nothing
    @test current["health"]["incomplete"]
    R._close_phase_observer!(o)
end
@testset "Existing namespace is never rewritten by initialization failure" begin
    root=joinpath(output,"collision");directory=joinpath(root,"attempt","progress","phases","session")
    mkpath(directory);path=joinpath(directory,"phase-current.json");write(path,"owned-original\n")
    o=R._start_phase_observer(directory;artifact_root=root,identity=identity(),source_session="session",
        policy=policy(),capacity_events=4)
    @test timedwait(()->istaskdone(o.task),5)==:ok
    @test read(path,String)=="owned-original\n"
    @test R._phase_observer_statistics(o).failed
    R._close_phase_observer!(o)
end
@testset "Diagnostic nested spans preserve typed availability and ordering" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("diagnostic";mode=:diagnostic,hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered)
    for e in (event(:phase_begin,10,10;sequence=1),event(:phase_begin,20,20;phase="inner",sequence=4),
        event(:phase_end,20,30;phase="inner",sequence=8,extra=(C.SolverMetric(:failed,NaN,"s"),)),
        event(:phase_end,10,40;sequence=15))
        @test R._record_native_phase!(o,e)
    end
    put!(release,nothing);finish(o)
    rows=only(segments(o))["rows"]
    @test getindex.(rows,"sequence")==["1","2","3","4"]
    @test rows[2]["parent_span_id"]==rows[1]["span_id"]==rows[4]["span_id"]
    @test rows[3]["span_id"]==rows[2]["span_id"]
    metric=only(filter(m->m["name"]=="failed",rows[3]["metrics"]))
    @test metric["value"]===nothing && metric["measurement_status"]=="error" && metric["reason"]=="non_finite"
    @test !load(joinpath(o.directory,"phase-current.json"))["health"]["incomplete"]
    for name in ("segment-000000001.json","publication-000000001.json")
        @test stat(joinpath(o.directory,name)).mode & 0o040 != 0 # collaboration group can read
        @test stat(joinpath(o.directory,name)).mode & 0o007 == 0 # unrelated users cannot read
    end
end
@testset "Multiple publications do not reopen old payload bytes" begin
    o=observer("no-prefix")
    @test R._enqueue_phase!(o,event(:phase_end,10,20))
    @test timedwait(()->o.publication!==nothing,5)==:ok
    old=joinpath(o.directory,"segment-000000001.json");held=old*".held"
    before=read(old);mv(old,held)
    @test R._enqueue_phase!(o,event(:phase_end,100,200))
    @test timedwait(()->o.generation==2 && o.publication!==nothing && endswith(o.publication["path"],"000000002.json"),5)==:ok
    mv(held,old);finish(o)
    @test read(old)==before
    @test length(segments(o))==2
end
@testset "Explicit clock reasons retain delivered calls" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("clock-cases";hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered)
    for (name,start,stop,extra) in (
        ("reversed",30,20,()),("zero",20,20,()),
        ("invalid",10,20,(C.SolverMetric(:start_monotonic_ns,10.0,"ns"),C.SolverMetric(:end_monotonic_ns,20,"ns"))),
        ("missing",10,20,()),
        ("unavailable",10,20,(C.SolverMetric(:start_monotonic_ns,nothing,"ns";measurement_status=:not_measured,reason=:not_sampled),C.SolverMetric(:end_monotonic_ns,20,"ns"))))
        valid=name in ("reversed","zero")
        @test R._enqueue_phase!(o,event(:phase_end,start,stop;phase=name,clocks=valid,extra))
    end
    put!(release,nothing);finish(o)
    rows=Dict(row["phase"]=>row for row in only(segments(o))["rows"])
    @test rows["zero"]["time_bounds"]["min_start_monotonic_ns"]=="20"
    @test rows["zero"]["time_bounds"]["measured_calls"]=="1"
    for (name,reason) in (("reversed","producer_clock_reversed"),("invalid","producer_clock_invalid"),
        ("missing","producer_clock_missing"),("unavailable","not_sampled"))
        b=rows[name]["time_bounds"]
        @test b["min_start_monotonic_ns"]===nothing && b["unavailable_calls"]=="1" && reason in b["reasons"]
        @test rows[name]["call_count"]=="1"
    end
end
@testset "Bounded key pressure, depth and oversize are visible" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("limits";keys=1,depth=1,hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered)
    @test !R._enqueue_phase!(o,event(:phase_end,1,2;phase="x"^20000))
    for e in (event(:phase_begin,1,1),event(:phase_begin,2,2;phase="inner"),
        event(:phase_end,2,3;phase="inner"),event(:phase_end,1,4))
        @test R._enqueue_phase!(o,e)
    end
    put!(release,nothing);finish(o)
    h=load(joinpath(o.directory,"phase-current.json"))["health"]
    @test h["dropped"]["oversized"]=="1" && h["dropped"]["capacity"]=="1"
    @test "phase_depth_exceeded" in h["incomplete_reasons"] && "aggregate_key_limit" in h["incomplete_reasons"]
    @test length(only(segments(o))["rows"])==1
end
@testset "Contention and byte capacity reject without waiting for writer" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("contention";hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered)
    held=Channel{Nothing}(1);unlocker=Channel{Nothing}(1)
    holder=Threads.@spawn lock(o.lock) do
        put!(held,nothing);take!(unlocker)
    end
    take!(held)
    @test !R._enqueue_phase!(o,event(:phase_end,1,2))
    @test R._phase_observer_statistics(o).dropped.contention==1
    put!(unlocker,nothing);wait(holder)
    @test R._enqueue_phase!(o,event(:phase_end,1,2))
    sleep(0.02)
    s=R._phase_observer_statistics(o)
    @test hasproperty(s,:oldest_lag_seconds)
    hasproperty(s,:oldest_lag_seconds) && @test s.oldest_lag_seconds>=0.01
    put!(release,nothing);finish(o)
    root=joinpath(output,"byte-capacity");mkpath(root)
    p=R.PhaseObservationPolicy(;mode=:normal,maximum_event_bytes=16384,capacity_bytes=16384,
        batch_events=8,batch_bytes=16384,flush_seconds=1.0,snapshot_seconds=1.0,
        maximum_depth=4,maximum_aggregate_keys=8,reserve_bytes=0)
    entered2=Channel{Nothing}(1);release2=Channel{Nothing}(1)
    b=R._start_phase_observer(joinpath(root,"attempt","progress","phases","session");
        artifact_root=root,identity=identity(),source_session="session",policy=p,capacity_events=8,
        publication_hook=(stage,path)->if stage===:initial_current
            put!(entered2,nothing);take!(release2)
        end)
    take!(entered2)
    accepted=count(_->R._enqueue_phase!(b,event(:phase_end,1,2)),1:8)
    @test 0<accepted<8
    @test R._phase_observer_statistics(b).buffered_bytes<=16384
    put!(release2,nothing);finish(b)
end
@testset "Fault barriers never publish missing dependencies or lose prior head" begin
    for stage in (:before_segment,:after_segment,:before_publication,:after_publication,:before_current)
        armed=Ref(false)
        o=observer("fault-"*String(stage);hook=(seen,path)->armed[] && seen===stage && error("injected $stage"))
        @test R._enqueue_phase!(o,event(:phase_begin,1,1))
        @test R._enqueue_phase!(o,event(:phase_end,1,2))
        @test timedwait(()->o.publication!==nothing,5)==:ok
        original=deepcopy(load(joinpath(o.directory,"phase-current.json"))["publication"])
        armed[]=true
        @test R._enqueue_phase!(o,event(:phase_begin,3,3))
        @test R._enqueue_phase!(o,event(:phase_end,3,4))
        @test timedwait(()->istaskdone(o.task),5)==:ok
        current=load(joinpath(o.directory,"phase-current.json"))
        @test current["publication"]==original
        @test current["health"]["incomplete"] && R._phase_observer_statistics(o).failed
        @test "writer_unavailable" in current["health"]["incomplete_reasons"]
        ref=current["publication"];raw=read(joinpath(o.root,ref["path"]))
        @test bytes2hex(sha256(raw))==ref["sha256"]
        R._close_phase_observer!(o)
    end
end
@testset "Invalid metric names are explicit input loss, not invalid wire" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("invalid-input";hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered)
    @test !R._enqueue_phase!(o,event(:phase_end,1,2;extra=(C.SolverMetric(Symbol(""),1,""),)))
    @test R._phase_observer_statistics(o).dropped.invalid==1
    put!(release,nothing);finish(o)
end
@testset "Prepared transport encodes Dict once and forwards sealed bytes unchanged" begin
    payloads=Vector{UInt8}[]
    sink=R._PreparedJSONSink(bytes->push!(payloads,bytes))
    raw=Vector{UInt8}(codeunits("{\"sealed\":true}\n"))
    sink(raw)
    @test only(payloads)===raw
    sink(Dict("value"=>Int128(9)))
    @test YAML.load(String(copy(last(payloads))))["value"]==9
end
@testset "One active writer slot survives close and rejects new allocations until actual exit" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("slot-old";hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered);R._close_phase_observer!(o)
    for index in 1:8
        candidate=try
            observer("slot-rejected-"*string(index))
        catch error
            error
        end
        @test candidate isa Exception
        if candidate isa Exception
            @test candidate isa R._PhaseObserverUnavailable
            @test hasproperty(candidate,:reason) && candidate.reason===:previous_phase_writer_pending
        else
            finish(candidate) # cleanup unchanged RED implementation, not a changed expectation
        end
        @test !ispath(joinpath(output,"slot-rejected-"*string(index),"attempt"))
    end
    put!(release,nothing);finish(o)
    next=observer("slot-after-exit");finish(next)
    @test !R._phase_observer_statistics(next).failed
    root=joinpath(output,"slot-init-failed");mkpath(root)
    old=joinpath(root,"attempt","progress","phases","session");mkpath(old)
    failed=R._start_phase_observer(old;artifact_root=root,identity=identity(),source_session="session",
        policy=policy(),capacity_events=4)
    @test timedwait(()->istaskdone(failed.task),5)==:ok
    @test R._phase_observer_statistics(failed).failed
    R._close_phase_observer!(failed)
    valid=observer("slot-after-init-failure");finish(valid)
    @test !R._phase_observer_statistics(valid).failed
end
@testset "Counter overflow and producer clock mismatch remain unavailable, never zero" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("overflow-and-mismatch";hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered)
    @test R._enqueue_phase!(o,event(:phase_end,10,20;allocated=typemax(Int64)))
    @test R._enqueue_phase!(o,event(:phase_end,30,40;allocated=typemax(Int64),
        cpu=C.SolverMetric(:cpu_seconds,1.25,"s";measurement_status=:error,reason=:measurement_failed)))
    @test R._enqueue_phase!(o,event(:phase_end,50,60;phase="mismatch",clocks=false,
        extra=(C.SolverMetric(:start_monotonic_ns,50,"ns"),C.SolverMetric(:end_monotonic_ns,60,"ns"),
            C.SolverMetric(:producer_monotonic_ns,61,"ns"))))
    put!(release,nothing);finish(o)
    rows=Dict(row["phase"]=>row for row in only(segments(o))["rows"])
    metrics=Dict(m["name"]=>m for m in rows["mixing"]["metrics"])
    @test metrics["allocated_bytes"]["sum"]===nothing
    @test metrics["allocated_bytes"]["measured_calls"]=="2"
    @test metrics["allocated_bytes"]["reasons"]==["counter_overflow"]
    @test metrics["process_cpu_seconds"]["sum"]==0.25
    @test metrics["process_cpu_seconds"]["unavailable_calls"]=="1"
    @test rows["mixing"]["time_bounds"]["measured_calls"]=="2"
    @test rows["mismatch"]["time_bounds"]["reasons"]==["producer_clock_mismatch"]
end
@testset "A dropped nested begin cannot close an older same-label span" begin
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    o=observer("same-label-gap";mode=:diagnostic,capacity=1,hook=(stage,path)->if stage===:initial_current
        put!(entered,nothing);take!(release)
    end)
    take!(entered)
    @test R._enqueue_phase!(o,event(:phase_begin,10,10;phase="same",sequence=1))
    @test !R._enqueue_phase!(o,event(:phase_begin,20,20;phase="same",sequence=2))
    put!(release,nothing)
    @test timedwait(()->o.publication!==nothing,5)==:ok
    @test R._enqueue_phase!(o,event(:phase_end,20,30;phase="same",sequence=8))
    @test timedwait(()->o.publication!==nothing && endswith(o.publication["path"],"000000002.json"),5)==:ok
    finish(o)
    row=only(segments(o)[2]["rows"])
    @test row["span_id"]===nothing
    @test row["context_status"]=="incomplete"
    @test row["core_sequence"]=="8" # Core gaps are preserved, not misclassified as the technical gap.
end
@testset "Phase admission seals before reap and charges the admitted lane" begin
    for managed in (false,true)
        root=mktempdir();p=policy(capacity=2)
        request=(;directory=joinpath(root,"phase"),artifact_root=root,identity=identity(),
            source_session="session",policy=p,capacity_events=2)
        owner=managed ? R._p05_begin_observers!(;phase_request=request,scalar_request=nothing) : nothing
        o=R._start_phase_observer(request.directory;artifact_root=root,identity=request.identity,
            source_session="session",policy=p,capacity_events=2,admission=owner)
        entered=Channel{Bool}(1);release=Channel{Nothing}(1)
        producer=Threads.@spawn begin
            admitted=R._phase_try_producer!(o);put!(entered,admitted)
            try take!(release) finally admitted && R._phase_release_producer!(o) end
        end
        @test take!(entered)
        managed ? R._p05_end_observers!(owner) : R._close_phase_observer!(o)
        @test timedwait(()->istaskdone(o.task),10)==:ok
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        try
            @test o.admitting[] && o.producer_state[]==3 && !istaskdone(producer)
            @test R._p05_observer_work_bound(a)==R._phase_profile(o.directory,o.root,o.identity,"session",p,2).payload_bound_bytes
            @test (@atomic :acquire R._PHASE_RESIDENCY[].owner)===o
        finally
            R._p05_end_observers!(a);put!(release,nothing);fetch(producer)
        end
        @test !o.admitting[] && o.producer_state[]==2
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        @test R._p05_observer_work_bound(a)==0
        R._p05_end_observers!(a)
    end
    o=observer("phase-stale-read-open";hook=R._NO_PHASE_PUBLICATION_HOOK)
    @test !R._phase_closed(o)
    finish(o) # closes and reaps between the producer read and its CAS
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        @test R._p05_observer_work_bound(a)==0
        @test !R._phase_try_producer!(o)
        @test !R._enqueue_phase!(o,event(:phase_end,1,2))
        @test o.producer_state[]==2 && !o.admitting[]
    finally
        R._p05_end_observers!(a)
    end
end

end
