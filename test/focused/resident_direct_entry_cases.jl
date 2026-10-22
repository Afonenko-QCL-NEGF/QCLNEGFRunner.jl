# Handwritten finite cases. All named writers are called directly, no optional
# with_storage_operation wrapper around them. Tests intentionally fail on I4.
# Execution creates only tiny ordinary fixture files, never scientific arrays.
const CASE_ROOT = get(ENV, "SCI08_CASE_ROOT", "")
@test !isempty(CASE_ROOT) && isabspath(CASE_ROOT) && isdir(CASE_ROOT)
const CASE_NUMBER = Ref(0)
function fresh_case()
    CASE_NUMBER[] += 1
    parent = joinpath(CASE_ROOT, "case-" * string(CASE_NUMBER[]))
    Base.mkdir(parent)
    for (name, bytes) in (("current", "verified current"), ("previous", "verified previous"), ("final", "protected final"))
        Base.write(joinpath(parent,name), bytes)
    end
    R.reset_hooks!()
    return parent
end
protected(parent) = Dict(name=>bytes2hex(sha256(read(joinpath(parent,name)))) for name in ("current","previous","final"))
function caught(call)
    try
        call(); nothing
    catch failure
        failure
    end
end
causeof(failure) = failure isa R.ResidentGrowthRefusal && failure.cause !== nothing ? failure.cause : failure
releases(a) = count(e -> e[1] === :release, a.events)
mutations() = filter(e -> e[1] in (:mkdir_before,:temp_before,:tempdir_before,:write_after,:chmod_before,:delete),R.EVENTS)
function check_frozen(context, primary)
    @test context.primary === primary
    @test context.permit.state === :needs_reconcile
    @test context.permit.ledger.inflight == 0
end
function check_retry_closed(context, primary, path)
    before = copy(R.EVENTS)
    failure = caught(() -> R.require_growth!(context,context.permit.descriptor.writer,path;payload=:again))
    @test failure isa Exception
    @test causeof(failure) === primary
    @test R.EVENTS == before
end

# Controls are based on canonical cause identity and literal bytes/events,
# not the estimator/permit implementation under test.
@testset "SCI08-R2 named direct-entry RED/GREEN" begin
@testset "test-only unit macro fails fast if scientific branch executes" begin
    failure=caught(() -> R.unit_literal_guard_control())
    @test failure isa ErrorException
    @test occursin("TEST-ONLY SCI08 unit literal reached scientific branch",sprint(showerror,failure))
end

@testset "initial require/preflight exact throw and false freeze" begin
    for entry in (:require,:preflight), mode in (:throw,:false)
        parent=fresh_case(); a,c=R.fixture(parent,:atomic_text)
        primary=ErrorException("literal initial validator cause")
        a.writer_hook=(args...)->(mode===:throw ? throw(primary) : false)
        failure=caught(() -> entry===:require ?
            R.require_growth!(c,:atomic_text,joinpath(parent,"new");payload=:literal) :
            R._resident_writer_preflight(:campaign_strict,:atomic_text,c,joinpath(parent,"new");payload=:literal))
        @test failure isa Exception
        first=mode===:throw ? primary : causeof(failure)
        @test causeof(failure) === first
        @test isempty(mutations())
        check_frozen(c,first)
        check_retry_closed(c,first,joinpath(parent,"again"))
        @test releases(a)==0
        @test !any(x->x===failure && x!==first,c.secondary)
    end
end

@testset "child first refusal freezes root and affected scope once" begin
    parent=fresh_case(); a,root=R.fixture(parent,:point;slots=(:atomic_text,))
    child=R.resident_child_context!(root,:atomic_text)
    primary=ErrorException("literal child initial failure")
    a.writer_hook=(args...)->throw(primary)
    failure=caught(() -> R.require_growth!(child,:atomic_text,joinpath(parent,"child");payload=:literal))
    @test failure===primary
    check_frozen(child,primary)
    check_frozen(root,primary)
    R._resident_failure!(child,primary)
    R._resident_failure!(root,primary)
    @test child.primary===root.primary===primary
    @test !any(x->x===primary,child.secondary)
    @test !any(x->x===primary,root.secondary)
    check_retry_closed(root,primary,joinpath(parent,"root-retry"))
    @test caught(() -> R.resident_child_context!(root,:atomic_text)) isa Exception
    @test caught(() -> R.resident_materialized!(child,1)) isa Exception
    @test releases(a)==0
end

@testset "actual atomic initial admission WITHOUT prior require" begin
    for mode in (:throw,:false,:caught_reentrant,:healthy)
        parent=fresh_case(); a,c=R.fixture(parent,:atomic_text)
        source=joinpath(parent,"pending"); target=joinpath(parent,"current")
        Base.write(source,"literal candidate"); Base.chmod(source,0o600)
        prior=protected(parent); primary=ErrorException("atomic initial exact cause")
        first=Ref{Any}(nothing)
        a.writer_hook=(writer,path,payload)->begin
            if writer===:atomic_text
                mode===:throw && throw(primary)
                mode===:false && return false
                if mode===:caught_reentrant
                    first[]=caught(() -> R.resident_settle!(c))
                    return true
                end
            end
            return true
        end
        failure=caught(() -> R._atomic_replace_file(source,target;resource_policy=:campaign_strict,storage_context=c))
        if mode===:healthy
            @test failure===nothing
            @test read(target,String)=="literal candidate"
            @test !ispath(source)
            @test (stat(target).mode & 0o777)==0o640
        else
            @test failure isa Exception
            @test read(source,String)=="literal candidate"
            @test (stat(source).mode & 0o777)==0o600
            @test protected(parent)==prior
            canonical=mode===:throw ? primary : mode===:caught_reentrant ? causeof(first[]) : causeof(failure)
            @test causeof(failure)===canonical
            check_frozen(c,canonical)
            check_retry_closed(c,canonical,target)
            @test releases(a)==0
        end
        if mode===:caught_reentrant
            for phase in (:initial_require_first_then_second,:atomic_callback_first_then_second)
                a2,root2=R.fixture(parent,:point;slots=(:atomic_text,))
                child2=R.resident_child_context!(root2,:atomic_text)
                source2=joinpath(parent,"pending-"*String(phase))
                Base.write(source2,"literal first-second candidate"); Base.chmod(source2,0o600)
                prior2=protected(parent)
                first2=Ref{Any}(nothing); second2=ErrorException("literal second "*String(phase))
                a2.writer_hook=(writer,path,payload)->begin
                    selected=phase===:initial_require_first_then_second ? :atomic_text : :atomic_replace
                    if writer===selected
                        first2[]=caught(() -> R.resident_settle!(root2))
                        throw(second2)
                    end
                    return true
                end
                escaped2=caught(() -> R._atomic_replace_file(source2,target;
                    resource_policy=:campaign_strict,storage_context=child2))
                @test escaped2===first2[]
                @test first2[] isa R.ResidentGrowthRefusal
                @test first2[]!==second2
                @test root2.primary===child2.primary===root2.permit.ledger.primary===first2[]
                @test count(x->x===second2,child2.secondary)==1
                @test !any(x->x===first2[],child2.secondary)
                @test root2.permit.state===child2.permit.state===:needs_reconcile
                @test root2.permit.ledger.inflight==0
                @test root2.permit.ledger.outstanding==8192
                @test root2.permit.ledger.resident==64
                @test root2.permit.ledger.cumulative==0
                @test root2.permit.ledger.highwater==64
                @test count(e->e[1] in (:release,:commit,:materialize),a2.events)==0
                @test read(source2,String)=="literal first-second candidate"
                @test (stat(source2).mode & 0o777)==0o600
                @test protected(parent)==prior2
            end
        end
    end
end

# Actual direct writer dispatch, with tiny typed payload and fake serializer.
# History flush is constructed directly to isolate its own first guard.
function entry_call(entry,parent,context;policy=:campaign_strict,checks=Dict{String,Any}())
    target=joinpath(parent,"output")
    if entry===:point
        return R.commit_point_artifacts(target,R.solution();storage_class=:archive,analysis=false,
            reserve_bytes=0,resource_policy=policy,storage_context=context)
    elseif entry===:operator
        return R.commit_operator_artifacts(target,checks;identity=Dict{String,Any}(),operation="fixture",accepted=false,
            resource_policy=policy,storage_context=context)
    elseif entry===:stage
        source=joinpath(parent,"source")
        isdir(source) || (Base.mkdir(source);Base.write(joinpath(source,"raw"),"literal retained source"))
        return R.stage_result_tree(source,target;byte_budget=8192,reserve_bytes=0,
            resource_policy=policy,storage_context=context)
    elseif entry===:history_constructor
        return R.ScientificHistoryRecorder(target,Dict{String,Any}(),Ref(0),Ref(0);
            resource_policy=policy,storage_context=context)
    elseif entry===:history
        isdir(target) || Base.mkdir(target)
        rec=R.recorder(target)
        policy===:campaign_strict && (R._resident_history_contexts[rec]=context)
        return R.flush_scientific_history!(rec;resource_policy=policy,storage_context=context)
    elseif entry===:text
        return R._observability_atomic_text(target,io->R.write(io,"literal text");
            resource_policy=policy,storage_context=context)
    end
    error("unlisted entry")
end
writer_for(entry)=entry===:history_constructor ? :history_recorder : entry===:text ? :atomic_text : entry

@testset "actual six entries missing context and initial refusal" begin
    for entry in (:point,:operator,:stage,:history_constructor,:history,:text), mode in (:missing,:throw,:false)
        parent=fresh_case(); writer=writer_for(entry); a,c=R.fixture(parent,writer)
        prior=protected(parent); primary=ErrorException("direct entry literal refusal")
        a.writer_hook=(args...)->(mode===:throw ? throw(primary) : false)
        failure=caught(() -> entry_call(entry,parent,mode===:missing ? nothing : c))
        @test failure isa Exception
        @test isempty(mutations())
        @test protected(parent)==prior
        if mode!==:missing
            canonical=mode===:throw ? primary : causeof(failure)
            @test causeof(failure)===canonical
            check_frozen(c,canonical)
            check_retry_closed(c,canonical,joinpath(parent,"retry"))
            @test releases(a)==0
        end
    end
end

@testset "actual argument checks belong to strict direct scope" begin
    for entry in (:point,:operator,:stage,:history_constructor)
        parent=fresh_case();a,c=R.fixture(parent,writer_for(entry));prior=protected(parent)
        failure = if entry===:point
            caught(() -> R.commit_point_artifacts(joinpath(parent,"bad"),R.solution();
                storage_class=:invalid,resource_policy=:campaign_strict,storage_context=c))
        elseif entry===:operator
            output=joinpath(parent,"output");Base.mkpath(joinpath(output,"artifacts","generation-000001"))
            caught(() -> R.commit_operator_artifacts(output,Dict();identity=Dict(),operation="fixture",accepted=false,
                resource_policy=:campaign_strict,storage_context=c))
        elseif entry===:stage
            caught(() -> R.stage_result_tree(joinpath(parent,"absent"),joinpath(parent,"bad");
                resource_policy=:campaign_strict,storage_context=c))
        else
            caught(() -> R.ScientificHistoryRecorder(joinpath(parent,"bad"),Dict{String,Any}(),Ref(0),Ref(0);
                flush_interval_seconds=0,resource_policy=:campaign_strict,storage_context=c))
        end
        @test failure isa ArgumentError
        check_frozen(c,failure)
        @test releases(a)==0 && protected(parent)==prior
        check_retry_closed(c,failure,joinpath(parent,"retry"))
    end
end

@testset "actual entries create/identity faults preserve uncertain footprint" begin
    for entry in (:point,:operator,:stage,:history_constructor,:history,:text), edge in (:mkdir_after,:temp_after,:identity)
        # A constructor has mkdir only; point/operator/stage use tempdir.
        entry===:history_constructor && edge!==:mkdir_after && continue
        entry===:history && edge===:mkdir_after && continue
        parent=fresh_case(); writer=writer_for(entry); a,c=R.fixture(parent,writer;slots=(:atomic_text,))
        prior=protected(parent); primary=ErrorException("literal $(entry) $(edge)")
        actualedge=entry in (:point,:operator,:stage) && edge===:temp_after ? :tempdir_after : edge
        if edge===:identity
            a.identity_hook=path->throw(primary)
        else
            R.FS_HOOK[]=(kind,args...)->(kind===actualedge ? throw(primary) : nothing)
        end
        failure=caught(() -> entry_call(entry,parent,c))
        R.FS_HOOK[]=(kind,args...)->nothing
        @test causeof(failure)===primary
        @test !any(e->e[1]===:delete,R.EVENTS)
        @test protected(parent)==prior
        check_frozen(c,primary)
        @test releases(a)==0
        if entry===:text && edge===:identity
            @test all(stream->!isopen(stream),keys(R.STREAM_PATHS))
        end
        check_retry_closed(c,primary,joinpath(parent,"retry"))
    end
end

@testset "actual missing nested slot freezes shared root" begin
    for entry in (:text,:history)
        parent=fresh_case(); a,root=R.fixture(parent,:point)
        prior=protected(parent)
        failure=caught(() -> entry_call(entry,parent,root))
        @test failure isa R.ResidentGrowthRefusal
        @test isempty(mutations())
        check_frozen(root,causeof(failure))
        check_retry_closed(root,causeof(failure),joinpath(parent,"retry"))
        @test releases(a)==0 && protected(parent)==prior
    end
end

# Literal partial payloads are test data, not a scientific/HDF5 encoding.
# Operator's serializer-fault double deliberately replaces ONLY its owned test
# temp content with a fixed literal before throwing; no production body changes.
partial_literal(entry) = entry===:point ? "literal partial fixture payload" :
    entry===:operator ? "literal partial operator diagnostic" :
    entry===:stage ? "literal retained source" :
    entry===:history ? "literal partial history rows" : "literal text"
debt_snapshot(context) = (outstanding=context.permit.ledger.outstanding,
    resident=context.permit.ledger.resident,cumulative=context.permit.ledger.cumulative,
    highwater=context.permit.ledger.highwater)
function capture_partial!(witness,path,literal)
    for (stream,registered) in R.STREAM_PATHS
        registered==path && isopen(stream) && Base.flush(stream)
    end
    @test isfile(path)
    observed=read(path)
    @test observed==collect(codeunits(literal))
    push!(R.EVENTS,(:partial_witness,path,copy(observed)))
    witness[]=(path=String(path),bytes=copy(observed))
end
function expected_partial_path(entry,parent)
    if entry in (:point,:stage)
        containers=[e[2] for e in R.EVENTS if e[1]===:tempdir_after]
        @test length(containers)==1
        isempty(containers) && return "missing-container"
        @test dirname(only(containers))==(entry===:point ? joinpath(parent,"output","archive") : parent)
        @test startswith(basename(only(containers)),entry===:point ? "pending-" : ".qcl-negf-stage-")
        return entry===:point ? joinpath(only(containers),"physics.h5") :
            joinpath(only(containers),"result","raw")
    end
    paths=[e[2] for e in R.EVENTS if e[1]===:temp_after]
    @test length(paths)==1
    isempty(paths) && return "missing-temp"
    path=only(paths)
    if entry===:operator
        containers=[e[2] for e in R.EVENTS if e[1]===:tempdir_after]
        @test length(containers)==1
        if !isempty(containers)
            @test dirname(path)==only(containers)
            @test dirname(only(containers))==joinpath(parent,"output","artifacts")
            @test startswith(basename(only(containers)),"pending-")
        end
    else
        @test dirname(path)==(entry===:history ? joinpath(parent,"output") : parent)
    end
    return path
end
cleanup_covers(path,deleted) = path==deleted ||
    startswith(path,deleted*string(Base.Filesystem.path_separator))

@testset "actual partial four writers plus helper strict/standalone pairs" begin
    for entry in (:point,:operator,:stage,:history,:text), policy in (:campaign_strict,:standalone)
        parent=fresh_case(); a,c=R.fixture(parent,writer_for(entry);slots=(:atomic_text,:atomic_text))
        prior=protected(parent); primary=ErrorException("literal partial $(entry)")
        before=debt_snapshot(c)
        @test before==(outstanding=8192,resident=64,cumulative=0,highwater=64)
        witness=Ref{Any}(nothing); literal=partial_literal(entry)
        checks=entry===:operator ? R.FaultJSON(primary) : Dict{String,Any}()
        if entry in (:point,:history)
            R.PAYLOAD_HOOK[]=(path,stream)->begin
                capture_partial!(witness,path,literal)
                throw(primary)
            end
        elseif entry in (:stage,:text)
            R.FS_HOOK[]=(kind,args...)->begin
                if kind===:write_after
                    capture_partial!(witness,args[1],literal)
                    throw(primary)
                end
                nothing
            end
        else
            R.JSON_FAULT_HOOK[]=()->begin
                streams=[(stream,path) for (stream,path) in R.STREAM_PATHS if isopen(stream)]
                @test length(streams)==1
                stream,path=only(streams)
                Base.seekstart(stream); Base.truncate(stream,0)
                written=Base.write(stream,literal); Base.flush(stream)
                R.event(:fixture_literal_write,path,written)
                capture_partial!(witness,path,literal)
            end
        end
        failure=caught(() -> entry_call(entry,parent,policy===:campaign_strict ? c : nothing;policy,checks))
        R.FS_HOOK[]=(kind,args...)->nothing
        R.JSON_FAULT_HOOK[]=()->nothing
        @test failure===primary
        @test protected(parent)==prior
        @test witness[]!==nothing
        known_path=expected_partial_path(entry,parent)
        if witness[]!==nothing
            @test normpath(witness[].path)==normpath(known_path)
            @test witness[].bytes==collect(codeunits(literal))
        end
        @test any(e->e[1] in (:write_after,:fixture_literal_write) && normpath(e[2])==normpath(known_path),R.EVENTS)
        @test count(e->e[1]===:partial_witness && normpath(e[2])==normpath(known_path),R.EVENTS)==1
        @test debt_snapshot(c)==before
        @test releases(a)==0
        deletes=[e[2] for e in R.EVENTS if e[1]===:delete]
        if policy===:campaign_strict
            @test isempty(deletes)
            @test isfile(known_path)
            if isfile(known_path)
                @test read(known_path)==collect(codeunits(literal))
                @test bytes2hex(sha256(read(known_path)))==bytes2hex(sha256(literal))
            end
            check_frozen(c,primary)
            check_retry_closed(c,primary,joinpath(parent,"later"))
            events_before_child=copy(R.EVENTS)
            child_failure=caught(() -> R.resident_child_context!(c,:atomic_text))
            @test child_failure isa Exception
            @test causeof(child_failure)===primary
            @test R.EVENTS==events_before_child
            @test debt_snapshot(c)==before
            @test releases(a)==0
            @test isfile(known_path)
            isfile(known_path) && @test read(known_path)==collect(codeunits(literal))
        else
            @test !ispath(known_path)
            @test any(deleted->cleanup_covers(known_path,deleted),deletes)
            @test debt_snapshot(c)==before
        end
    end
end

@testset "text identity close failure is secondary and primary is stable" begin
    parent=fresh_case(); a,c=R.fixture(parent,:atomic_text)
    primary=ErrorException("literal identity primary"); secondary=ErrorException("literal late close")
    a.identity_hook=path->throw(primary)
    R.FS_HOOK[]=(kind,args...)->(kind===:close_after ? throw(secondary) : nothing)
    failure=caught(() -> entry_call(:text,parent,c))
    R.FS_HOOK[]=(kind,args...)->nothing
    @test failure===primary
    check_frozen(c,primary)
    @test count(x->x===secondary,c.secondary)==1
    @test all(stream->!isopen(stream),keys(R.STREAM_PATHS))
    R._resident_failure!(c,primary)
    @test c.primary===primary
    @test !any(x->x===primary,c.secondary)
    @test releases(a)==0
end

@testset "actual stage postrename acknowledgement error retains destination" begin
    parent=fresh_case();a,c=R.fixture(parent,:stage)
    primary=ErrorException("literal after rename ack failure")
    a.settle_hook=kind->(kind===:commit ? throw(primary) : nothing)
    prior=protected(parent)
    failure=caught(() -> entry_call(:stage,parent,c))
    @test failure===primary
    @test isfile(joinpath(parent,"output","raw"))
    @test read(joinpath(parent,"output","raw"),String)=="literal retained source"
    @test isfile(joinpath(parent,"source","raw"))
    @test !any(e->e[1]===:delete,R.EVENTS)
    @test protected(parent)==prior
    check_frozen(c,primary)
    @test releases(a)==0
end

@testset "history rows/sequence and finalizer preserve original cause" begin
    parent=fresh_case();Base.mkdir(joinpath(parent,"history"))
    a,c=R.fixture(parent,:history;slots=(:atomic_text,));rec=R.recorder(joinpath(parent,"history"))
    R._resident_history_contexts[rec]=c
    primary=ErrorException("literal partial rows")
    R.PAYLOAD_HOOK[]=(path,stream)->throw(primary)
    failure=caught(() -> R.flush_scientific_history!(rec;resource_policy=:campaign_strict,storage_context=c))
    @test failure===primary
    @test length(rec.scba)==1 && rec.segment==1
    R.PAYLOAD_HOOK[]=(path,stream)->nothing
    retry=caught(() -> R.flush_scientific_history!(rec;resource_policy=:campaign_strict,storage_context=c))
    @test retry isa Exception
    @test causeof(retry)===primary
    finalizer=caught(() -> R.flush_scientific_history_finalizer!(rec;resource_policy=:campaign_strict,primary))
    @test finalizer===nothing
    @test c.primary===primary
    @test length(rec.scba)==1 && rec.segment==1
    @test releases(a)==0
    omitted=caught(() -> R.flush_scientific_history_finalizer!(rec;resource_policy=:campaign_strict))
    @test omitted===primary
    for policy_route in (:omitted_policy_literal_primary,:explicit_standalone_no_primary)
        a3,c3=R.fixture(parent,:history;slots=(:atomic_text,))
        rec3=R.recorder(joinpath(parent,"history"))
        R._resident_history_contexts[rec3]=c3
        literal3=ErrorException("literal bound finalizer original primary")
        fs_events3=copy(R.EVENTS); authority_events3=copy(a3.events)
        tree3=[(relpath(d,parent),sort(copy(dirs)),sort(copy(files))) for (d,dirs,files) in walkdir(parent)]
        bytes3=Dict(relpath(joinpath(d,name),parent)=>bytes2hex(sha256(read(joinpath(d,name))))
            for (d,_,files) in walkdir(parent) for name in files)
        segment3=rec3.segment; scba3=copy(rec3.scba); outer3=copy(rec3.outer)
        slots3=copy(c3.permit.child_slots); remaining3=c3.permit.remaining
        ledger3=c3.permit.ledger
        debt3=(ledger3.resident,ledger3.outstanding,ledger3.cumulative,ledger3.highwater,ledger3.sequence)
        paths3=copy(c3.paths); objects3=copy(c3.object_identities); verified3=c3.last_verified
        escaped3=caught(() -> policy_route===:omitted_policy_literal_primary ?
            R.flush_scientific_history_finalizer!(rec3;primary=literal3) :
            R.flush_scientific_history_finalizer!(rec3;resource_policy=:standalone))
        canonical3=policy_route===:omitted_policy_literal_primary ? literal3 : escaped3
        @test R.EVENTS==fs_events3
        @test a3.events==authority_events3
        @test [(relpath(d,parent),sort(copy(dirs)),sort(copy(files))) for (d,dirs,files) in walkdir(parent)]==tree3
        @test Dict(relpath(joinpath(d,name),parent)=>bytes2hex(sha256(read(joinpath(d,name))))
            for (d,_,files) in walkdir(parent) for name in files)==bytes3
        @test rec3.segment==segment3
        @test rec3.scba==scba3
        @test rec3.outer==outer3
        @test c3.permit.child_slots==slots3
        @test c3.permit.remaining==remaining3
        @test (ledger3.resident,ledger3.outstanding,ledger3.cumulative,ledger3.highwater,ledger3.sequence)==debt3
        @test c3.paths==paths3
        @test c3.object_identities==objects3
        @test c3.permit.state===:needs_reconcile
        @test ledger3.inflight==0
        @test c3.last_verified===verified3
        @test releases(a3)==0
        @test count(e->e[1] in (:commit,:materialize),a3.events)==0
        @test policy_route===:omitted_policy_literal_primary ? escaped3===nothing :
            (escaped3 isa R.ResidentGrowthRefusal && escaped3.operation===:history_finalizer)
        @test c3.primary===ledger3.primary===canonical3
        @test canonical3!==nothing
        @test policy_route===:omitted_policy_literal_primary ?
            count(x->x isa R.ResidentGrowthRefusal && x.operation===:history_finalizer,c3.secondary)==1 : isempty(c3.secondary)
    end
end

@testset "clean untouched whole-root release at most once; settlement error frozen" begin
    for mode in (:clean,:secondary_failure)
        parent=fresh_case();a,c=R.fixture(parent,:point)
        secondary=ErrorException("literal release outcome uncertain")
        mode===:secondary_failure && (a.settle_hook=kind->throw(secondary))
        failure=caught(() -> R.resident_settle!(c))
        if mode===:clean
            @test failure===nothing
            @test c.permit.state===:released
        else
            @test failure===secondary
            check_frozen(c,secondary)
        end
        @test releases(a)==1
        caught(() -> R.resident_settle!(c))
        @test releases(a)==1
    end
end
end # named suite
