using Test, QCLNEGFRunner, QCLNEGF
const R = QCLNEGFRunner
struct ObserverAliasBox
    value::Any
end
struct ObserverUnknownMap <: AbstractDict{String,Any}
    visits::Base.RefValue{Int}
end
Base.length(::ObserverUnknownMap)=0
Base.iterate(x::ObserverUnknownMap)=(x.visits[]+=1;nothing)

@testset "Observer epoch debits old residency and ends without metadata locks" begin
    @test isdefined(R,:_p05_begin_observers!)
    if isdefined(R,:_p05_begin_observers!)
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        try
            @test R._p05_observer_work_bound(a)==0
            @test_throws ArgumentError R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
            @test_throws Exception R.ScalarTelemetrySender(_->nothing;capacity=1)
            held=Channel{Nothing}(1);release=Channel{Nothing}(1)
            holder=Threads.@spawn lock(R._PHASE_RESIDENCY_LOCK) do
                lock(R._SCALAR_RESIDENCY_LOCK) do
                    put!(held,nothing);take!(release)
                end
            end
            take!(held)
            try
                @test R._p05_end_observers!(a)===nothing
                @test R._P05_OBSERVER_EPOCH[]==0
                @test_throws ArgumentError R._p05_observer_work_bound(a)
            finally
                put!(release,nothing);wait(holder)
            end
        finally
            R._p05_end_observers!(a)
        end
        b=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        try
            R._p05_end_observers!(a) # old/double end cannot clear new epoch
            @test R._p05_observer_work_bound(b)==0
            forged=R._P05ObserverAdmission(b.epoch+1,b.phase_generation,b.scalar_generation,0,0,false,false)
            @test_throws ArgumentError R._p05_end_observers!(forged)
            @test R._p05_observer_work_bound(b)==0
        finally
            R._p05_end_observers!(b)
        end
    end
end
@testset "Closed caller proof rejects escaped aliases before producer exclusion" begin
    sink=R.http_telemetry_sink("http://unused.invalid")
    old=R.ScalarTelemetrySender(sink;capacity=1,poll_seconds=.001)
    close(old);@test timedwait(()->istaskdone(old.task),5)==:ok
    current=R.ScalarTelemetrySender(sink;capacity=1,poll_seconds=.001)
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        @test R._p05_observer_work_bound(a)>0
        @test R._p05_stable_resident((current,),a)>0
        generation=current.generation
        current.generation+=UInt64(1)
        try
            @test_throws ArgumentError R._p05_stable_resident((current,),a)
        finally
            current.generation=generation
        end
        @test_throws ArgumentError R._p05_stable_resident((old,),a)
        @test_throws ArgumentError R._p05_stable_resident((Ref(old),),a)
        @test_throws ArgumentError R._p05_stable_resident((ObserverAliasBox(old),),a)
        for carrier in (Some(old),:escaped=>old,Set([old]),view(Any[1,old],1:1),Ref(Any[1,old],1))
            @test_throws ArgumentError R._p05_stable_resident((carrier,),a)
        end
        unknown=ObserverUnknownMap(Ref(0))
        @test_throws ArgumentError R._p05_stable_resident((unknown,),a)
        @test unknown.visits[]==0

        @test_throws ArgumentError R._p05_stable_resident((Dict(old=>1),),a)
        @test_throws ArgumentError R._p05_stable_resident((()->old,),a)
        @test_throws ArgumentError R._p05_stable_resident((current.task,),a)
        reporter=R.ProgressReporter(;human_io=nothing,clock_ns=()->(old;Int(time_ns())))
        @test_throws ArgumentError R._p05_stable_resident((reporter,),a)
        close(reporter)
        p=QCLNEGF.with_production_options(QCLNEGF.ProductionOptions();phase_request=x->(old;x))
        @test_throws ArgumentError R._p05_stable_resident((p,),a)
        plan=R.resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
        execution=only(plan.executions);c=execution.configuration
        badp=QCLNEGF.with_production_options(c.production;event_sink=event->old)
        badconfig=typeof(c)((name===:production ? badp : getfield(c,name) for name in fieldnames(typeof(c)))...)
        badexecution=typeof(execution)((name===:configuration ? badconfig : getfield(execution,name) for name in fieldnames(typeof(execution)))...)
        @test_throws ArgumentError R._p05_stable_resident((badexecution,),a)
        badplan=typeof(plan)((name===:executions ? [badexecution] : getfield(plan,name) for name in fieldnames(typeof(plan)))...)
        @test_throws ArgumentError R._p05_stable_resident((badplan,),a)
        record=R.QCLScientificWorkflow._point_result(only(plan.points),1,
            (;kind="cold",source_point_id=nothing,checkpoint=nothing,fallback_reason=nothing),:failed,:invalid,false;
            data=Dict{String,Any}("escaped"=>current))
        @test_throws ArgumentError R._p05_stable_resident((record,),a)
        record.data["escaped"]=ObserverUnknownMap(Ref(0))
        @test_throws ArgumentError R._p05_stable_resident((record,),a)
        @test record.data["escaped"].visits[]==0
        record.data["escaped"]=view(Any[1,current],1:1)
        @test_throws ArgumentError R._p05_stable_resident((record,),a)
        record.data["escaped"]=NaN
        @test R._p05_stable_resident((record,),a)>0 # IEEE display scalar is not reclassified

        ordinary=R.ProgressReporter(;human_io=nothing)
        try
            owned=R._progress_event_sink(ordinary)
            @test R._p05_stable_resident((ordinary,owned,current),a)>0
        finally
            close(ordinary)
        end
    finally
        close(current);R._p05_end_observers!(a)
        @test timedwait(()->istaskdone(current.task),5)==:ok
        b=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing);R._p05_end_observers!(b)
    end
end
@testset "public estimate enforces configured budget before build" begin
    numerical = QCLNEGF.tutorial_numerics()
    scattering = QCLNEGF.ScatteringOptions(LO=false,acoustic=false,impurity=false,IFR=false,alloy=false)
    accepted = QCLNEGF.ProductionOptions(memory_budget_bytes=typemax(Int))
    estimate = R._configured_public_memory_preflight(numerical, scattering, accepted)
    @test estimate.peak_bytes == QCLNEGF.estimate_production_memory(numerical,scattering;options=accepted).peak_bytes
    refused = QCLNEGF.ProductionOptions(memory_budget_bytes=1)
    @test_throws ArgumentError R._configured_public_memory_preflight(numerical,scattering,refused)
end
@testset "input allowance counts shared live roots once" begin
    shared = zeros(UInt8, 32768)
    distinct = copy(shared)
    roots = (;entry=(shared,),resources=(),construction=(shared,),continuation=(),
        history=(),observers=(),inputs_publication=())
    separate = merge(roots,(;construction=(distinct,)))
    @test isdefined(R,:_p05_input_metadata_limit)
    if isdefined(R,:_p05_input_metadata_limit)
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        try
        shared_limit=R._p05_input_metadata_limit(128*1024^2,roots;observer_admission=a)
        separate_limit=R._p05_input_metadata_limit(128*1024^2,separate;observer_admission=a)
        @test shared_limit > separate_limit
        @test shared_limit - separate_limit >= length(distinct)
        @test_throws ArgumentError R._p05_input_metadata_limit(128*1024^2,(;entry=());observer_admission=a)
        @test_throws ArgumentError R._p05_input_metadata_limit(1,roots;observer_admission=a)
        finally
            R._p05_end_observers!(a)
        end
    end
end
@testset "bounded observer future work is distinct from disk reserve" begin
    @test isdefined(R,:_p05_observer_work_bound)
    if isdefined(R,:_p05_observer_work_bound)
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        @test R._p05_observer_work_bound(a)==0
        R._p05_end_observers!(a)
        p=R._normal_phase_policy(8)
        q=R.PhaseObservationPolicy(;mode=p.mode,maximum_event_bytes=p.maximum_event_bytes,
            capacity_bytes=p.capacity_bytes,batch_events=p.batch_events,batch_bytes=p.batch_bytes,
            flush_seconds=p.flush_seconds,snapshot_seconds=p.snapshot_seconds,maximum_depth=p.maximum_depth,
            maximum_aggregate_keys=p.maximum_aggregate_keys,reserve_bytes=p.reserve_bytes+1)
        id=Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point","attempt"=>"1","branch_id"=>"branch","model_sha256"=>"a"^64,"plan_sha256"=>"b"^64)
        phase(p)=R._phase_profile("/tmp/phase","/tmp",id,"session",p,8).payload_bound_bytes
        @test phase(p)>0
        @test phase(p)==phase(q)
        @test R._scalar_profile(R.http_telemetry_sink("http://unused.invalid"),2,100,.01).payload_bound_bytes>0
        @test_throws ArgumentError R._p05_begin_observers!(;phase_request=nothing,
            scalar_request=(sink=R.http_telemetry_sink("http://unused.invalid"),capacity=0,maximum_event_bytes=1,poll_seconds=.01))
    end
end

@testset "literal bounded phase batch allocation profile" begin
    for mode in (:normal,:diagnostic)
        mktempdir() do root
            policy=R.PhaseObservationPolicy(;mode,maximum_event_bytes=65536,capacity_bytes=262144,
                batch_events=4,batch_bytes=262144,flush_seconds=60.0,snapshot_seconds=60.0,
                maximum_depth=4,maximum_aggregate_keys=4,reserve_bytes=0)
            identity=Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point",
                "attempt"=>"1","branch_id"=>"branch","model_sha256"=>repeat("a",64),"plan_sha256"=>repeat("b",64))
            observer=R._start_phase_observer(joinpath(root,"phases","session");artifact_root=root,
                identity,source_session="session",policy,capacity_events=4)
            try
                metrics=Tuple(QCLNEGF.SolverMetric(Symbol("metric_",i),Float64(i),repeat("\\\"",8)) for i in 1:128)
                labels=["phase-$i"*repeat("p",96) for i in 1:4]
                events=[QCLNEGF.SolverEvent(:phase_end,:scba,labels[5-i],:running,1,nothing,metrics,repeat("\\\"",128)) for i in 1:4]
                charges=[R._phase_event_charge(e,policy.maximum_event_bytes) for e in events]
                @test all(length(e.metrics)==128 for e in events)
                @test sum(charges)<=policy.batch_bytes
                batch=[R._PhaseQueued(events[i],i,charges[i],UInt64(1)) for i in 1:4]
                function produce()
                    observer.consumed_sequence=0; empty!(observer.stack)
                    append!(observer.stack,[(:scba,labels[i],"session:$i") for i in 1:4])
                    rows=R._phase_rows!(observer,batch)
                    buffers=[R._phase_encode(observer,Dict("rows"=>rows)) for _ in 1:4]
                    return rows,buffers
                end
                produce() # compile before measuring this allocation sample
                measured=@allocated produce()
                allowance=R._phase_profile(observer.directory,observer.root,identity,"session",policy,4).payload_bound_bytes
                @test measured<=allowance
                println("phase_profile mode=",mode," events=4 metrics_per_event=128 groups=4 depth=4 admitted_bytes=",sum(charges)," allocated_bytes=",measured," allowance_bytes=",allowance)
                scalar=Dict("level1"=>Dict("level2"=>Dict("level3"=>Dict("k$i"=>repeat("z",8) for i in 1:128))))
                function scalar_produce()
                    tree=R._telemetry_scalar_copy(scalar,0,Ref(16384))
                    bytes=R._phase_encode(observer,tree)
                    return tree,bytes
                end
                scalar_produce()
                scalar_measured=@allocated scalar_produce()
                scalar_allowance=R._scalar_profile(R.http_telemetry_sink("http://unused.invalid"),4,16384,.01).payload_bound_bytes
                @test scalar_measured<=scalar_allowance
                println("scalar_profile mode=",mode," keys=128 depth=4 allocated_bytes=",scalar_measured," allowance_bytes=",scalar_allowance)
            finally
                R._close_phase_observer!(observer)
                @test timedwait(()->istaskdone(observer.task),10;pollint=0.01)==:ok
                a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing);R._p05_end_observers!(a)
            end
        end
    end
end

@testset "unknown draining phase resident is not zero" begin
    @test !R._PHASE_WRITER_SLOT[]
    R._PHASE_WRITER_SLOT[]=true
    try
        @test_throws ArgumentError R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    finally
        R._PHASE_WRITER_SLOT[]=false
    end
end

@testset "Exact generations, starting/tail states and cleanup races" begin
    sink=R.http_telemetry_sink("http://unused.invalid")
    request=(;sink,capacity=2,maximum_event_bytes=16384,poll_seconds=.001)
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=request)
    resident=R._SCALAR_RESIDENCY[]
    @test a.start_scalar && (@atomic :acquire resident.task)===nothing && !resident.started[]
    @test R._p05_observer_work_bound(a)>0
    # An abandoned, never-started reservation is cancellable without waiting on a task.
    R._p05_end_observers!(a)
    b=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    @test R._p05_observer_work_bound(b)==0;R._p05_end_observers!(b)
    for lockname in (:_PHASE_RESIDENCY_LOCK,:_SCALAR_RESIDENCY_LOCK)
        ready=Channel{Nothing}(1);release=Channel{Nothing}(1)
        holder=Threads.@spawn lock(getfield(R,lockname)) do
            put!(ready,nothing);take!(release)
        end
        take!(ready)
        try
            @test_throws ArgumentError R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
            @test R._P05_OBSERVER_EPOCH[]==0
        finally
            put!(release,nothing);wait(holder)
        end
    end
    # A literal starting entry has no completion evidence. Ending its caller is insufficient.
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=request)
    resident=R._SCALAR_RESIDENCY[];resident.started[]=true
    R._p05_end_observers!(a)
    b=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    @test b.scalar_bytes==a.scalar_bytes && !b.start_scalar
    R._p05_end_observers!(b)
    entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
    task=Threads.@spawn begin put!(entered,nothing);take!(release) end
    @atomic :release resident.task=task
    take!(entered)
    try
        b=R._p05_begin_observers!(;phase_request=nothing,scalar_request=request)
        @test b.scalar_generation==a.scalar_generation && !b.start_scalar
        @test R._p05_observer_work_bound(b)==a.scalar_bytes
        R._p05_end_observers!(b)
    finally
        put!(release,nothing);wait(task)
    end
    b=R._p05_begin_observers!(;phase_request=nothing,scalar_request=request)
    try
        @test b.start_scalar && b.scalar_generation>a.scalar_generation
        jobs=[Threads.@spawn R._p05_end_observers!(a) for _ in 1:32]
        foreach(fetch,jobs)
        @test R._P05_OBSERVER_EPOCH[]==b.epoch
        @test R._P05_SCALAR_RELEASE_EPOCH[]<b.epoch
        forged=R._P05ObserverAdmission(b.epoch,b.phase_generation,b.scalar_generation+1,0,b.scalar_bytes,false,true)
        @test_throws ArgumentError R._p05_end_observers!(forged)
        @test R._P05_OBSERVER_EPOCH[]==b.epoch
        # Only one of two simultaneous managed starts may attach a buffer/task.
        started=[Threads.@spawn try R._start_scalar_sender(sink;capacity=2,maximum_event_bytes=16384,poll_seconds=.001,admission=b) catch error;error end for _ in 1:2]
        results=fetch.(started)
        @test count(x->x isa R.ScalarTelemetrySender,results)==1
        @test count(x->x isa Exception,results)==1
        sender=only(filter(x->x isa R.ScalarTelemetrySender,results));close(sender)
        @test timedwait(()->istaskdone(sender.task),5)==:ok
        @test R._p05_observer_work_bound(b)==b.scalar_bytes # done before caller last use still charged
    finally
        R._p05_end_observers!(b)
    end
    c=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    @test R._p05_observer_work_bound(c)==0;R._p05_end_observers!(c)
    @test_throws ArgumentError R._p05_begin_observers!(;phase_request=nothing,
        scalar_request=(;sink=(_->nothing),capacity=2,maximum_event_bytes=16384,poll_seconds=.01))
    @test_throws OverflowError R._scalar_profile(sink,typemax(Int),16384,.01)
    @test_throws OverflowError R._scalar_profile(sink,2,typemax(Int),.01)
    @test_throws ArgumentError R._p05_begin_observers!(;phase_request=nothing,
        scalar_request=(;sink,capacity=true,maximum_event_bytes=16384,poll_seconds=.01))
end

@testset "Independent node overhead and literal coefficient expansion" begin
    # Independent node census: one mapping + one key and value per entry.
    # Text payload is charged separately; no production-bound helper is the oracle.
    for n in (0,1,2,7,8,16,32,64,128)
        d=Dict{String,Any}("k$i"=>nothing for i in 1:n)
        text=sum(ncodeunits,keys(d);init=0)
        measured=Base.summarysize(d)
        @test measured<=512*(1+2n)+16text
        println("node_census entries=",n," owned_bytes=",measured," census_bound=",512*(1+2n)+16text)
    end
    for n in (0,1,4,128,256,65536)
        v=Vector{Union{Nothing,R._PhaseQueued}}(nothing,n)
        @test Base.summarysize(v)<=128+16n
    end
    for n in (0,1,8,128,8192)
        text=repeat("\0",n)
        io=IOBuffer();R._light_json(io,text);bytes=take!(io)
        @test length(bytes)==6n+2
        @test Base.summarysize(text)<=64+2n
    end
    id=Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point","attempt"=>"1",
        "branch_id"=>"branch","model_sha256"=>"a"^64,"plan_sha256"=>"b"^64)
    for (mode,constant) in ((:normal,106852416),(:diagnostic,133050432))
        p=R.PhaseObservationPolicy(;mode,maximum_event_bytes=65536,capacity_bytes=262144,
            batch_events=4,batch_bytes=262144,flush_seconds=60.,snapshot_seconds=60.,
            maximum_depth=4,maximum_aggregate_keys=4,reserve_bytes=0)
        profile=R._phase_profile("/a/session","/a",id,"session",p,4)
        # Hand expansion: Kr604; Kw772 normal/1756 diagnostic; Tr524800+12H;
        # Tw2492416/2996224+16H. Independent final constants, not helper composition.
        h=256+sum(ncodeunits,("/a/session","/a","session",values(id)...))
        @test profile.header_bytes==h
        @test profile.payload_bound_bytes==constant+688h
    end
end
@testset "Full ring, simultaneous batch/rows/stack and four encoded buffers" begin
    # Includes actual defaults (C256,Q64,D64), byte-limited ring with sparse slots,
    # diagnostic128-metric ceiling, deep retained labels and aggregate-key ceiling.
    cases=((:normal,256,16384,256*16384,64,1048576,64,128,5),
           (:diagnostic,16,65536,16*65536,8,8*65536,4,8,128),
           (:normal,16,65536,16*65536,8,8*65536,64,2,128),
           (:diagnostic,256,16384,32768,2,32768,4,2,5))
    for (mode,c,e,r,q,b,d,a,m) in cases
        mktempdir() do root
            p=R.PhaseObservationPolicy(;mode,maximum_event_bytes=e,capacity_bytes=r,batch_events=q,
                batch_bytes=b,flush_seconds=60.,snapshot_seconds=60.,maximum_depth=d,
                maximum_aggregate_keys=a,reserve_bytes=0)
            id=Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point","attempt"=>"1",
                "branch_id"=>"branch","model_sha256"=>"a"^64,"plan_sha256"=>"b"^64)
            o=R._start_phase_observer(joinpath(root,"session");artifact_root=root,identity=id,
                source_session="session",policy=p,capacity_events=c)
            @test timedwait(()->isfile(joinpath(o.directory,"phase-current.json")),5)==:ok
            lock(o.lock)
            try
                metrics=Tuple(QCLNEGF.SolverMetric(Symbol("m",i),i%2==0 ? typemax(Int64) : Float64(i),"é\\\"") for i in 1:m)
                event(i)=QCLNEGF.SolverEvent(:phase_end,:scba,"group-"*lpad(string(i),8,'0'),:running,typemax(Int),nothing,
                    metrics,repeat("\0",max(0,(e-128*512)÷12)))
                candidate=event(1);charge=R._phase_event_charge(candidate,e)
                n=min(c,r÷charge)
                @test n>0
                for i in 1:n;@test R._enqueue_phase!(o,event(i));end
                batch=R._phase_take_batch!(o)
                @test 0<length(batch)<=q && sum(x.bytes for x in batch)<=b
                # A producer refills the ring while the batch is retained by its worker.
                for i in 1:length(batch);R._enqueue_phase!(o,event(n+i));end
                @test o.queued[]>0 && o.buffered[]<=r && length(o.ring)==c
                labels=[(:scba,"old-$i"*repeat("\0",min(1024,e÷12)),"session:$i") for i in 1:d]
                function produce()
                    o.consumed_sequence=0;empty!(o.stack);append!(o.stack,labels)
                    rows=R._phase_rows!(o,batch)
                    document=R._phase_envelope(o,"qcl-negf.producer-phase-segment.v1")
                    document["rows"]=rows;document["health"]=R._phase_health(o)
                    buffers=[R._phase_encode(o,document) for _ in 1:4]
                    return rows,buffers
                end
                produce()
                allocated=@allocated produce()
                rows,buffers=produce()
                # Count all independent overlap, including a conservative retained old stack.
                payload=(o.ring,batch,labels,rows,buffers,o.identity,o.source,o.publication,o.policy)
                retained=Base.summarysize(payload)
                bound=R._phase_profile(o.directory,o.root,id,"session",p,c).payload_bound_bytes
                @test retained+allocated<=bound
                @test length(buffers)==4 && all(!isempty, buffers)
                @test length(rows)<=q
                println("maxshape_phase mode=",mode," C=",c," Q=",q," D=",d," metrics=",m,
                    " ring_events=",o.queued[]," batch_events=",length(batch)," retained=",retained,
                    " warmed_allocated=",allocated," profile_B=",bound)
            finally
                fill!(o.ring,nothing);o.queued[]=0;o.buffered[]=0;o.inflight[]=0;o.inflight_events[]=0
                R._close_phase_observer!(o);unlock(o.lock)
                @test timedwait(()->istaskdone(o.task),10)==:ok
                admission=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
                R._p05_end_observers!(admission)
            end
        end
    end
end
@testset "Scalar full queue, four-level wide trees, strings and encoder overlap" begin
    sink=R.http_telemetry_sink("http://unused.invalid/"*repeat("e",1024))
    for (capacity,budget) in ((256,16384),(16,65536))
        wide=Dict("branch$i"=>Dict("k$j"=>Dict{String,Any}() for j in 1:128) for i in 1:4)
        deep=Dict("one"=>Dict("two"=>Dict("three"=>Dict("k$i"=>nothing for i in 1:128))))
        text=Dict("text"=>repeat("\0",min(8192,(budget-64)÷6)))
        values=(Dict{String,Any}(),wide,deep,text,Dict("min"=>typemin(Int128),"max"=>typemax(Int128),"nan"=>NaN,"bool"=>true))
        for value in values
            function produce()
                queue=[R._telemetry_scalar_copy(value,0,Ref(budget)) for _ in 1:capacity]
                transient=[R._telemetry_scalar_copy(value,0,Ref(budget)) for _ in 1:3]
                buffers=map(1:4) do _
                    io=IOBuffer();R._light_json(io,last(transient));take!(io)
                end
                return queue,transient,buffers
            end
            produce()
            allocated=@allocated produce()
            owned=produce();retained=Base.summarysize(owned)
            bound=R._scalar_profile(sink,capacity,budget,.01).payload_bound_bytes
            @test retained+allocated<=bound
            @test length(first(owned))==capacity && length(owned[2])==3
            @test all(length(bytes)<=budget for bytes in last(owned))
            println("maxshape_scalar C=",capacity," b=",budget," keys=",length(value),
                " retained=",retained," warmed_allocated=",allocated," profile_B=",bound)
        end
    end
end

@testset "Known closed HTTP residency survives disabled and smaller requests" begin
    sink=R.http_telemetry_sink("http://unused.invalid")
    old=R.ScalarTelemetrySender(sink;capacity=8,maximum_event_bytes=16384,poll_seconds=.001)
    lock(old.lock)
    try
        close(old)
        @test !istaskdone(old.task)
        smaller=(;sink,capacity=1,maximum_event_bytes=64,poll_seconds=.001)
        for request in (nothing,smaller)
            a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=request)
            try
                @test !a.start_scalar && a.scalar_bytes==R._scalar_profile(sink,8,16384,.001).payload_bound_bytes
                @test a.scalar_bytes>R._scalar_profile(sink,1,64,.001).payload_bound_bytes
                @test (@atomic :acquire R._SCALAR_RESIDENCY[].owner)===old
                @test R._p05_stable_resident((old,),a)==R._p05_stable_resident((old,),a)
                GC.gc()
                @test (@atomic :acquire R._SCALAR_RESIDENCY[].task)===old.task
            finally
                R._p05_end_observers!(a)
            end
        end
    finally
        unlock(old.lock);close(old)
        @test timedwait(()->istaskdone(old.task),5)==:ok
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        @test R._p05_observer_work_bound(a)==0;R._p05_end_observers!(a)
    end
end
@testset "Metadata cleanup preserves primary exceptions and rejects incomplete evidence" begin
    for primary in (ErrorException("primary sink/IO failure"),InterruptException())
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        held=Channel{Nothing}(1);release=Channel{Nothing}(1)
        holder=Threads.@spawn lock(R._PHASE_RESIDENCY_LOCK) do
            lock(R._SCALAR_RESIDENCY_LOCK) do
                put!(held,nothing);take!(release)
            end
        end
        take!(held)
        try
            caught=try
                try throw(primary) finally R._p05_end_observers!(a) end
            catch error;error end
            @test caught===primary
            @test R._P05_OBSERVER_EPOCH[]==0
            @test min(R._P05_PHASE_RELEASE_EPOCH[],R._P05_SCALAR_RELEASE_EPOCH[])>=a.epoch
        finally
            put!(release,nothing);wait(holder)
        end
    end
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        wrong=R._P05ObserverAdmission(a.epoch,a.phase_generation+1,a.scalar_generation,0,0,false,false)
        @test_throws ArgumentError R._p05_observer_work_bound(wrong)
        @test R._p05_observer_work_bound(a)==0
    finally
        R._p05_end_observers!(a)
    end
    id=Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point","attempt"=>"1",
        "branch_id"=>"branch","model_sha256"=>"a"^64,"plan_sha256"=>"b"^64)
    profile=R._phase_profile("/tmp/session","/tmp",id,"session",R._normal_phase_policy(2),2)
    @test R._phase_profile("/tmp/session","/tmp",id,"session",R._normal_phase_policy(2),2;hook=((_,__)->nothing))===nothing
    previous=R._PHASE_RESIDENCY[];bit=R._PHASE_WRITER_SLOT[]
    R._PHASE_RESIDENCY[]=R._PhaseLifetime(profile,UInt64(99),UInt64(0),Threads.Atomic{Bool}(false),Threads.Atomic{Bool}(false),nothing,nothing)
    R._PHASE_WRITER_SLOT[]=false
    try
        @test_throws ArgumentError R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        @test R._P05_OBSERVER_EPOCH[]==0
    finally
        R._PHASE_RESIDENCY[]=previous;R._PHASE_WRITER_SLOT[]=bit
    end
    sink=R.http_telemetry_sink("http://unused.invalid")
    request=(;sink,capacity=2,maximum_event_bytes=16384,poll_seconds=.001)
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=request)
    try
        @test_throws ArgumentError R._start_scalar_sender(sink;capacity=1,maximum_event_bytes=16384,poll_seconds=.001,admission=a)
        @test !R._SCALAR_RESIDENCY[].started[]
        @test R._p05_observer_work_bound(a)==a.scalar_bytes
    finally
        R._p05_end_observers!(a)
    end
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing);R._p05_end_observers!(a)
end

@testset "Scientific joint admission is before configured allocations" begin
    source=read(joinpath(dirname(dirname(@__DIR__)),"src/composition/scientific_execution.jl"),String)
    preparation=split(split(source,"configured=nothing",limit=2)[2],"previous=nothing",limit=2)[1]
    gate=findfirst("_p05_scientific_build_admission!",preparation)
    build=findfirst("configured=build_configured_problem(config)",preparation)
    cache=findfirst("build_production_cache(",preparation)
    @test gate!==nothing
    if gate!==nothing
        @test first(gate)<first(build)<first(cache)
        @test occursin("_p05_end_observers!(build_admission)",preparation)
    end
    @test occursin("native5_final_writer_unavailable",source)
    cleanup=split(split(source,"# No callback-bearing object escapes",limit=2)[2],"_p05_end_observers!(observer_admission)",limit=2)[1]
    for release in ("solution=nothing;problem=nothing;cache=nothing",
        "parent_state=nothing;restored=nothing;prepared_final_request=nothing",
        "response=nothing;photon_energies=nothing")
        @test occursin(release,cleanup)
    end
    @test !occursin("previous=nothing",cleanup) # warm-start owner retained until execution last use
end

@testset "Exact owning records inspect callback and dynamic pockets" begin
    sink=R.http_telemetry_sink("http://unused.invalid")
    old=R.ScalarTelemetrySender(sink;capacity=1,poll_seconds=.001)
    close(old);@test timedwait(()->istaskdone(old.task),5)==:ok
    current=R.ScalarTelemetrySender(sink;capacity=1,poll_seconds=.001)
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        @test R._p05_stable_resident((R.FunctionPointRunner(identity),),a)>0
        callback=let previous=old; ctx->previous end
        @test_throws ArgumentError R._p05_stable_resident((R.FunctionPointRunner(callback),),a)
        mktempdir() do root
            id=Dict("run_id"=>"run","execution_id"=>"exec","point_id"=>"point","attempt"=>"1",
                "branch_id"=>"branch","model_sha256"=>"a"^64,"plan_sha256"=>"b"^64)
            provenance=Dict("format"=>"qcl-negf.git-graph.v1","revision"=>"a"^40,"components"=>[])
            absent()=Dict("state"=>"not_measured","reason"=>"constructor_only","evidence"=>nothing)
            status=Dict("process"=>Dict("state"=>"running","exit_code"=>nothing,"reason"=>nothing),
                (s=>absent() for s in ("convergence","physics","discretization","experimental"))...)
            recorder=R.ScientificHistoryRecorder(joinpath(root,"history");artifact_root=root,
                identity=id,source_epoch="ordinary",provenance,status,maximum_scba_rows=1)
            @test R._p05_stable_resident((recorder,),a)>0
            recorder.clock_ns=let previous=old; ()->(previous.closed[];time_ns()) end
            @test_throws ArgumentError R._p05_stable_resident((recorder,),a)
            recorder.clock_ns=time_ns
            for pocket in (old,Ref(old),Dict("nested"=>Any[old]),R.FunctionPointRunner(callback))
                recorder.pending=pocket
                @test_throws ArgumentError R._p05_stable_resident((recorder,),a)
            end
            recorder.pending=nothing
            @test R._p05_stable_resident((recorder,current),a)>0
        end
    finally
        close(current);R._p05_end_observers!(a)
        @test timedwait(()->istaskdone(current.task),5)==:ok
        b=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing);R._p05_end_observers!(b)
    end
end
@testset "Public default FFT storage retains a closed numeric type closure" begin
    plan=QCLNEGF.ProductionFFTHilbertPlan(collect(range(-1.0,1.0,length=8)),1;
        column_chunk=1,worker_count=1)
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        @test R._p05_stable_resident((plan,),a)>0
        @test R._p05_stable_resident((trues(17),),a)>0
        @test !R._p05_static_storage_type(Any)
        @test !R._p05_static_storage_type(Vector{Any})
        @test !R._p05_static_storage_type(Function)
        @test !R._p05_static_storage_type(Task)
        @test !R._p05_static_storage_type(R.ScalarTelemetrySender)
        for payload in (Ref{Any}(nothing),R.FunctionPointRunner(identity),()->nothing)
            poisoned=QCLNEGF.ProductionFFTHilbertPlan{typeof(payload)}(plan.energy_count,
                plan.column_count,plan.energy_spacing,plan.column_chunk,payload,nothing)
            @test_throws ArgumentError R._p05_stable_resident((poisoned,),a)
        end
    finally
        R._p05_end_observers!(a)
    end
end

@testset "FFTW memo initialization, cycles and open captures" begin
    forward=R.FFTW.plan_fft!(zeros(ComplexF64,8,1),1;flags=R.FFTW.ESTIMATE,num_threads=1)
    @test !isdefined(forward,:pinv)
    @test R._p05_check_fft_storage(forward)===nothing
    forward.pinv=R.FFTW.ScaledPlan{ComplexF64}(forward,1.0)
    @test isdefined(forward,:pinv) && forward.pinv.p===forward
    @test R._p05_check_fft_storage(forward)===nothing # manufactured storage cycle, no FFT execution
    for payload in (Ref{Any}(nothing),R.FunctionPointRunner(identity),()->nothing)
        forward.pinv=R.FFTW.ScaledPlan{ComplexF64}(payload,1.0)
        @test_throws ArgumentError R._p05_check_fft_storage(forward)
    end
    sink=R.http_telemetry_sink("http://unused.invalid")
    sender=R.ScalarTelemetrySender(sink;capacity=1,poll_seconds=.001)
    try
        forward.pinv=R.FFTW.ScaledPlan{ComplexF64}(sender,1.0)
        @test_throws ArgumentError R._p05_check_fft_storage(forward)
    finally
        close(sender);@test timedwait(()->istaskdone(sender.task),5)==:ok
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing);R._p05_end_observers!(a)
    end
end
@testset "Scientific pre-build grant charges known old B and joint captures" begin
    c=R.load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    selected,resource_plan=R.resolve_execution_strategy(c)
    p=selected.production
    reservation=R.QCLScientificWorkflow._scientific_memory_reservation(selected,resource_plan)
    sink=R.http_telemetry_sink("http://unused.invalid")
    old=R.ScalarTelemetrySender(sink;capacity=2,maximum_event_bytes=128,poll_seconds=.001)
    lock(old.lock) # known ordinary draining worker; never invoke HTTP
    try
        close(old)
        @test !istaskdone(old.task)
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
        try
            shared=zeros(UInt8,8192)
            exact=copy(reservation)
            roots=(;entry=(selected,),resources=(resource_plan,exact,p),construction=(shared,),
                continuation=(),history=(shared,),observers=(old,),inputs_publication=())
            live=R._p05_stable_resident(roots,a)
            B=R._p05_observer_work_bound(a)
            @test B==R._scalar_profile(sink,2,128,.001).payload_bound_bytes
            threshold=live+B+8*R._SERIALIZATION_SLAB_BYTES+reservation["estimated_peak_bytes"]
            @test threshold<=min(resource_plan.memory_budget_bytes,p.memory_budget_bytes)
            exact["memory_budget_bytes"]=threshold
            available=R.QCLScientificWorkflow._p05_scientific_build_admission!(selected,resource_plan,exact,roots;
                observer_admission=a)
            @test available==reservation["estimated_peak_bytes"]
            below=copy(exact);below["memory_budget_bytes"]-=1
            below_roots=merge(roots,(;resources=(resource_plan,below,p)))
            @test_throws ArgumentError R.QCLScientificWorkflow._p05_scientific_build_admission!(selected,resource_plan,below,below_roots;
                observer_admission=a)
            distinct=merge(roots,(;history=(copy(shared),)))
            @test_throws ArgumentError R.QCLScientificWorkflow._p05_scientific_build_admission!(selected,resource_plan,exact,distinct;
                observer_admission=a)
            @test selected.production===p
            @test selected.production.memory_budget_bytes==p.memory_budget_bytes
            @test R._P05_OBSERVER_EPOCH[]==a.epoch
        finally
            R._p05_end_observers!(a)
        end
    finally
        unlock(old.lock);close(old)
        @test timedwait(()->istaskdone(old.task),5)==:ok
        a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing);R._p05_end_observers!(a)
    end
end

@testset "read and staging metadata admission closes its temporary epoch" begin
    shared=zeros(UInt8,4096)
    roots=(;entry=(shared,),resources=(),construction=(shared,),continuation=(),history=(),observers=(),inputs_publication=())
    limit=R._p05_closed_metadata_limit(128*1024^2,roots)
    @test 0<limit<128*1024^2
    @test R._P05_OBSERVER_EPOCH[]==0
    @test_throws ArgumentError R._p05_closed_metadata_limit(1,roots)
    @test R._P05_OBSERVER_EPOCH[]==0
    channel=Channel{Int}(1);callback=()->isready(channel)
    bad=merge(roots,(;observers=(callback,)))
    @test_throws ArgumentError R._p05_closed_metadata_limit(128*1024^2,bad)
    @test R._P05_OBSERVER_EPOCH[]==0
end

# P05 actual22 F1 R3 regressions: identity is never resource authority.
@testset "F1 direct grant is bounded by fresh hardware and restrictive actual plan" begin
    hardware=R.default_hardware_profile()
    makehardware(total,available)=R.HardwareProfile((name===:total_memory_bytes ? total : name===:available_memory_bytes ? available : getfield(hardware,name) for name in fieldnames(R.HardwareProfile))...)
    low=makehardware(512,256)
    p=QCLNEGF.ProductionOptions(worker_count=1,memory_budget_bytes=1024)
    saved=NamedTuple{fieldnames(QCLNEGF.ProductionOptions)}(Tuple(getfield(p,n) for n in fieldnames(QCLNEGF.ProductionOptions)))
    c=load_run_configuration(joinpath(dirname(dirname(pathof(R))),"test/fixtures/configurations/exact_cpu.yaml"))
    selected,actual_plan=R._p05_prepared_execution(c,nothing)
    makeplan(limit)=R.ExecutionPlan((name===:memory_budget_bytes ? limit : getfield(actual_plan,name) for name in fieldnames(R.ExecutionPlan))...)
    source=read(joinpath(dirname(dirname(pathof(R))),"src/composition/production_workflow.jl"),String)
    direct=split(source,"function run_production_sweep(",limit=2)[2]
    line=only(filter(x->startswith(strip(x),"grant="),split(direct,'\n')))
    expression=Meta.parse(strip(line))
    for context in (nothing,(;identity=:identity_only_not_a_grant))
        scope=Module(gensym(:DirectGrantF1))
        Core.eval(scope,:(production_options=$p));Core.eval(scope,:(hardware=$low))
        Core.eval(scope,:(native_context=$context));Core.eval(scope,:(execution_plan=nothing))
        if isdefined(R,:_p05_direct_memory_grant)
            Core.eval(scope,:(_p05_direct_memory_grant=$(R._p05_direct_memory_grant)))
        end
        @test Core.eval(scope,expression)==256
    end
    @test isdefined(R,:_p05_direct_memory_grant)
    if isdefined(R,:_p05_direct_memory_grant)
        @test R._p05_direct_memory_grant(p,low,nothing)==256
        @test R._p05_direct_memory_grant(p,low,makeplan(128))==128
        @test R._p05_direct_memory_grant(p,low,makeplan(4096))==256
        @test R._p05_direct_memory_grant(p,makehardware(128,256),makeplan(4096))==128
        small=QCLNEGF.with_production_options(p;memory_budget_bytes=64)
        @test R._p05_direct_memory_grant(small,low,makeplan(128))==64
        @test_throws ArgumentError R._p05_direct_memory_grant(p,makehardware(512,0),nothing)
        @test_throws ArgumentError R._p05_direct_memory_grant(p,low,makeplan(0))
        @test_throws ArgumentError R._p05_direct_memory_grant(p,low,(;memory_budget_bytes=1))
        @test_throws ArgumentError R._p05_direct_execution_plan((;memory_budget_bytes=1,capture=Channel{Int}(1)))
        @test R._p05_direct_execution_plan(actual_plan)===actual_plan
        @test R._P05_OBSERVER_EPOCH[]==0
        checked=findfirst("execution_plan=_p05_direct_execution_plan(execution_plan)",direct)
        observer=findfirst("_p05_check_observer_roots",direct)
        epoch=findfirst("owns_observer_epoch=",direct)
        @test checked!==nothing && observer!==nothing && epoch!==nothing && first(checked)<first(epoch)<first(observer)
        @test occursin("resources=(production_options,execution_plan,observer_admission,sources,hardware)",direct)
    end
    # Source-bound forwarding proof uses the exact keyword expression in the
    # actual configured caller; no solver body/gate is replaced or invoked.
    configured=Meta.parseall(read(joinpath(dirname(dirname(pathof(R))),"src/composition/configured_run.jl"),String))
    calls=Expr[]
    function visit(node)
        node isa Expr || return
        node.head===:call && !isempty(node.args) && node.args[1]===:run_production_sweep && push!(calls,node)
        foreach(visit,node.args)
    end
    visit(configured)
    @test length(calls)==1
    if length(calls)==1
        parameters=only(filter(x->x isa Expr && x.head===:parameters,only(calls).args))
        forwarded=filter(x->x isa Expr && x.head===:kw && x.args[1]===:execution_plan,parameters.args)
        @test length(forwarded)==1
        if length(forwarded)==1
            @test only(forwarded).args[2]===:execution_plan
            scope=Module(gensym(:ActualForwardF1));Core.eval(scope,:(execution_plan=$actual_plan))
            @test Core.eval(scope,only(forwarded).args[2])===actual_plan
        end
    end
    @test p.memory_budget_bytes==1024
    @test all(isequal(getfield(p,n),getfield(saved,n)) for n in fieldnames(QCLNEGF.ProductionOptions))
    @test R._p05_prepared_execution(selected,(selected,actual_plan))[2]===actual_plan
end
