# SCI08-R2 synthetic contracts: definitions only, never a production binding.
mutable struct _ResidentFakeAuthority <: QCLNEGFRunner.AbstractResidentAuthority
    events::Vector{Any}
    snapshot::Any
    deletion::Symbol
end
_ResidentFakeAuthority(events) = _ResidentFakeAuthority(events, nothing, :deferred)
QCLNEGFRunner.resident_snapshot(a::_ResidentFakeAuthority, binding) = a.snapshot
QCLNEGFRunner.resident_monotonic_ns(a::_ResidentFakeAuthority) = UInt64(15)
QCLNEGFRunner.validate_resident_binding!(a::_ResidentFakeAuthority, snapshot, descriptor) = true
const _resident_fake_writer_hooks = IdDict{_ResidentFakeAuthority,Function}()
function QCLNEGFRunner.validate_resident_writer!(a::_ResidentFakeAuthority, descriptor, writer, path, payload)
    haskey(_resident_fake_writer_hooks, a) && return _resident_fake_writer_hooks[a](a,writer,path,payload)
    return true
end
QCLNEGFRunner.resident_created_identity(a::_ResidentFakeAuthority, domain, path) = "fake-object:" * path
function QCLNEGFRunner.reserve_growth!(a::_ResidentFakeAuthority, revision, descriptor)
    push!(a.events, (:reserve, revision, descriptor.digest))
    return QCLNEGFRunner.ResidentLeaseProof("fake-lease", revision, descriptor.digest)
end

const _resident_fake_materialize_hooks = IdDict{_ResidentFakeAuthority,Function}()
function QCLNEGFRunner.materialize_growth!(a::_ResidentFakeAuthority, lease, sequence, delta)
    haskey(_resident_fake_materialize_hooks, a) && _resident_fake_materialize_hooks[a](a)
    push!(a.events, (:materialize, sequence, delta))
    return nothing
end
function QCLNEGFRunner.commit_growth!(a::_ResidentFakeAuthority, lease, evidence)
    push!(a.events, (:commit, evidence))
    return nothing
end
function QCLNEGFRunner.release_unmaterialized!(a::_ResidentFakeAuthority, lease, evidence)
    push!(a.events, (:release, evidence))
    return nothing
end

function _resident_fake_fixture(writer; E=60, U=0, H=40, growth=40, slots=(),
    parent="/synthetic", A=100)
    R = QCLNEGFRunner
    identity = R.ResidentIdentity("fake-campaign", "fake-plan", "fake-run", "fake-attempt",
        "fake-point", "fake-source", "fake-admission", "fake-operation", 1)
    domain = R.StorageDomain("fake-fs", "fake-namespace", "fake-boot", "fake-owner",
        parent, "fake-binding")
    descriptor = R.StorageOperationInventory(identity, domain, writer, "fake-descriptor",
        "fake-payload", "fake-stop", growth, growth, 10, slots)
    authority = _ResidentFakeAuthority(Any[])
    authority.snapshot = R.StorageSnapshot(identity, domain, "fake-revision", 10, 20,
        (E,E,0), (U,U,0), (0,0,0), (0,0,0), (A,A,100), (H,H,100),
        "fake-complete-inventory", "fake-epoch")
    return authority, descriptor
end

@testset "four synthetic partial traces retain debt then deny next growth" begin
    R = QCLNEGFRunner
    for writer in (:point, :operator, :stage, :history)
        authority, descriptor = _resident_fake_fixture(writer)
        context = R.reserve_storage_operation(authority, descriptor)
        R.require_growth!(context, writer, "/synthetic/partial"; payload=:fake)
        R.resident_created!(context, "/synthetic/partial")
        R.resident_materialized!(context, 10)
        R._resident_failure!(context, ErrorException("fake partial failure"))
        @test context.phase === :partial_unknown
        @test context.permit.state === :needs_reconcile
        @test context.permit.ledger.resident == 70
        @test context.permit.ledger.outstanding == 30
        @test context.permit.ledger.cumulative == 10
        @test !any(event -> event[1] === :release, authority.events)
        next_authority, next_descriptor = _resident_fake_fixture(writer; E=70,U=30,H=30,growth=1)
        @test_throws R.ResidentGrowthRefusal R.reserve_storage_operation(next_authority, next_descriptor)
    end
end

@testset "synthetic rename and primary preservation" begin
    R = QCLNEGFRunner
    authority, descriptor = _resident_fake_fixture(:atomic_text)
    context = R.reserve_storage_operation(authority, descriptor)
    primary = ErrorException("fake fsync after rename")
    @test_throws ErrorException R.with_storage_operation(context) do scope
        R.require_growth!(scope, :atomic_text, "/synthetic/current"; payload=:fake)
        R.resident_created!(scope, "/synthetic/tmp")
        R.resident_renamed!(scope, "/synthetic/tmp", "/synthetic/current")
        throw(primary)
    end
    @test context.phase === :published_unacknowledged
    @test context.primary === primary
    @test context.paths["/synthetic/current"] === :published_unacknowledged
    @test context.permit.ledger.outstanding == 40
end
@testset "synthetic conservative resident transitions" begin
    R = QCLNEGFRunner
    # Fake FS is an event log: no native filesystem is created by these fixtures.
    authority = _ResidentFakeAuthority(Any[])
    ledger = R.ResidentLedger(100, 0, 0, 0)
    @test ledger.resident == 100
    R._resident_attested_unlink!(ledger, 40, true)
    @test ledger.resident == 60
    @test ledger.cumulative == 0
    @test ledger.highwater == 100
    @test !R._resident_attested_unlink!(ledger, 20, false)
    @test ledger.resident == 60
    @test R._resident_budget_predicate(60, 40, 0, 0, 100, 40)
    @test !R._resident_budget_predicate(60, 40, 0, 1, 100, 40)
end

function QCLNEGFRunner.resident_delete_eligibility(a::_ResidentFakeAuthority, context, path)
    a.deletion === :deferred && return nothing
    return QCLNEGFRunner.ResidentDeletionEligibility(path, "fake-object", "fake-replacement",
        "fake-ownership", "existing-policy", "independent-fake-verifier", "fake-delete-authority",
        "fake-lifetime", a.deletion === :protected, 40)
end
function QCLNEGFRunner.resident_exact_unlink!(a::_ResidentFakeAuthority, proof)
    push!(a.events, (:unlink, proof.object_identity, proof.bytes))
    return QCLNEGFRunner.ResidentUnlinkOutcome(proof.object_identity, "fake-exact-barrier",
        proof.lifetime_proof, a.deletion === :eligible ? :unlinked_verified : :unknown)
end

@testset "synthetic duplicate cleanup conjunction and no headroom credit" begin
    R = QCLNEGFRunner
    for mode in (:deferred, :protected, :unknown, :eligible)
        authority, descriptor = _resident_fake_fixture(:point; E=100,H=0,growth=0)
        authority.deletion = mode
        context = R.reserve_storage_operation(authority, descriptor)
        outcome = R.resident_cleanup!(context, "/synthetic/duplicate")
        @test context.permit.ledger.resident == (mode === :eligible ? 60 : 100)
        @test context.permit.ledger.cumulative == 0
        @test context.permit.ledger.highwater == 100
        @test authority.snapshot.H == (0,0,100)
        if mode in (:deferred, :protected)
            @test !any(event -> event[1] === :unlink, authority.events)
            @test outcome === :deferred
        end
    end
end

@testset "synthetic parent child disjoint reservation" begin
    R = QCLNEGFRunner
    authority, base = _resident_fake_fixture(:point)
    child = R.StorageOperationInventory(base.identity, base.domain, :atomic_text,
        "fake-child", base.payload_digest, base.stop_reference, 10,10,1,())
    root = R.StorageOperationInventory(base.identity, base.domain, :point,
        "fake-parent", base.payload_digest, base.stop_reference, 40,40,10,(child,))
    context = R.reserve_storage_operation(authority, root)
    nested = R.resident_child_context!(context, :atomic_text)
    @test context.permit.remaining == (30,30,9)
    @test nested.permit.ledger === context.permit.ledger
    R.require_growth!(nested, :atomic_text, "/synthetic/tmp";payload=:fake)
    primary = ErrorException("nested primary")
    R._resident_failure!(nested, primary)
    escaped = try R.resident_settle!(context); nothing catch failure; failure end
    @test escaped === primary
    @test context.permit.state === :needs_reconcile
    @test context.permit.ledger.outstanding == 40

    duplicate_root = R.reserve_storage_operation(authority, root)
    duplicate_child = R.resident_child_context!(duplicate_root, :atomic_text)
    first = try R.resident_child_context!(duplicate_root, :atomic_text); nothing catch failure; failure end
    @test first isa R.ResidentGrowthRefusal
    @test duplicate_root.primary === duplicate_root.permit.ledger.primary === first
    @test duplicate_root.permit.state === duplicate_child.permit.state === :needs_reconcile
    retry = try R.require_growth!(duplicate_child, :atomic_text, "/synthetic/denied"); nothing catch failure; failure end
    @test retry === first
    @test duplicate_child.primary === first
    @test duplicate_root.permit.ledger.inflight == 0
    @test duplicate_root.permit.ledger.outstanding == 40
    @test duplicate_root.permit.ledger.resident == 60
    @test duplicate_root.permit.ledger.cumulative == 0
    @test !any(event -> event[1] in (:release,:commit,:materialize), authority.events)
end

# These definitions call the actual operator entry when this file is eventually
# authorized for execution. Both branches use a deterministic serializer fault;
# no production proof, native bound or scientific payload is represented.
struct _ResidentJSONFault
    primary::Exception
end
Base.string(value::_ResidentJSONFault) = throw(value.primary)

@testset "actual operator first JSON strict partial vs standalone cleanup" begin
    R = QCLNEGFRunner
    for policy in (:standalone, :campaign_strict)
        directory = mktempdir(; cleanup=false)
        primary = ErrorException("first operator JSON fixture fault")
        authority, base = _resident_fake_fixture(:operator; E=0,H=4096,growth=4096,
            parent=directory,A=4096)
        child = R.StorageOperationInventory(base.identity,base.domain,:atomic_text,
            "fake-operator-first-json",base.payload_digest,base.stop_reference,2048,2048,1,())
        descriptor = R.StorageOperationInventory(base.identity,base.domain,:operator,
            "fake-operator",base.payload_digest,base.stop_reference,4096,4096,10,(child,))
        context = policy === :campaign_strict ? R.reserve_storage_operation(authority,descriptor) : nothing
        caught = try
            R.commit_operator_artifacts(directory,_ResidentJSONFault(primary);
                identity=Dict{String,Any}(),operation="fixture",accepted=false,
                resource_policy=policy,storage_context=context)
            nothing
        catch failure
            failure
        end
        @test caught === primary
        stages = readdir(joinpath(directory,"artifacts");join=true)
        if policy === :campaign_strict
            @test context.primary === primary
            @test length(stages) == 1
            partials = readdir(only(stages);join=true)
            @test length(partials) == 1
            @test isfile(only(partials)) && filesize(only(partials)) > 0
            @test context.permit.child_slots == trues(1)
            @test context.permit.ledger.outstanding == 4096
        else
            @test isempty(stages)
        end
    end
end

function _resident_nested_lifetime_fixture()
    R = QCLNEGFRunner
    authority, base = _resident_fake_fixture(:point)
    leaf = R.StorageOperationInventory(base.identity,base.domain,:atomic_text,
        "fake-leaf",base.payload_digest,base.stop_reference,10,10,1,())
    middle = R.StorageOperationInventory(base.identity,base.domain,:history,
        "fake-middle",base.payload_digest,base.stop_reference,20,20,2,(leaf,))
    root = R.StorageOperationInventory(base.identity,base.domain,:point,
        "fake-lifetime-root",base.payload_digest,base.stop_reference,40,40,10,(middle,))
    context = R.reserve_storage_operation(authority,root)
    child = R.resident_child_context!(context,:history)
    grandchild = R.resident_child_context!(child,:atomic_text)
    return authority, context, child, grandchild
end

@testset "released root invalidates unused child and grandchild before events" begin
    R = QCLNEGFRunner
    authority, root, child, grandchild = _resident_nested_lifetime_fixture()
    @test R.resident_settle!(root) === :no_mutation_proven
    @test root.permit.state === child.permit.state === grandchild.permit.state === :released
    before = copy(authority.events)
    for scope in (child,grandchild)
        @test_throws R.ResidentGrowthRefusal R.require_growth!(scope,
            scope.permit.descriptor.writer,"/synthetic/no-write";payload=:fake)
        @test_throws R.ResidentGrowthRefusal R.resident_materialized!(scope,1)
        @test_throws R.ResidentGrowthRefusal R.resident_settle!(scope;verified="fake-invalid")
    end
    @test_throws R.ResidentGrowthRefusal R.resident_settle!(root)
    @test authority.events == before
    @test count(event -> event[1] === :release,authority.events) == 1
    @test root.permit.ledger.cumulative == 0
    @test root.permit.ledger.outstanding == 40 # local ledger never refunds itself
end

@testset "healthy ancestry debit and acknowledgement" begin
    R = QCLNEGFRunner
    authority, root, child, grandchild = _resident_nested_lifetime_fixture()
    R.require_growth!(grandchild,:atomic_text,"/synthetic/live";payload=:fake)
    R.resident_materialized!(grandchild,1)
    @test root.permit.ledger.inflight == 0
    @test root.permit.ledger.resident == 61
    @test root.permit.ledger.outstanding == 39
    @test root.permit.ledger.cumulative == 1
    @test !any(event -> event[1] === :release,authority.events)
    R.resident_settle!(grandchild;verified="fake-child-ack")
    @test root.permit.state === :reserved
    @test last(authority.events)[2].scope === :child
    R.resident_settle!(root;verified="fake-root-ack")
    @test child.permit.state === grandchild.permit.state === :committed
    @test last(authority.events)[2].scope === :root
    @test_throws R.ResidentGrowthRefusal R.resident_materialized!(grandchild,1)
    @test !any(event -> event[1] === :release,authority.events)
end

@testset "caught inflight root refusal freezes uncertain debit" begin
    R = QCLNEGFRunner
    authority, root, child, grandchild = _resident_nested_lifetime_fixture()
    R.require_growth!(grandchild,:atomic_text,"/synthetic/live";payload=:fake)
    first = Ref{Any}(nothing)
    _resident_fake_materialize_hooks[authority] = a -> begin
        first[] = try R.resident_settle!(root); nothing catch failure; failure end
        push!(a.events,(:root_release_blocked,))
    end
    escaped = try R.resident_materialized!(grandchild,1); nothing catch failure; failure end
    @test first[] isa R.ResidentGrowthRefusal
    @test escaped === first[]
    @test root.primary === grandchild.primary === root.permit.ledger.primary === first[]
    @test root.permit.state === child.permit.state === grandchild.permit.state === :needs_reconcile
    @test root.permit.ledger.inflight == 0
    @test root.permit.ledger.resident == 60
    @test root.permit.ledger.outstanding == 40
    @test root.permit.ledger.cumulative == 0
    @test root.permit.ledger.highwater == 60
    @test count(event -> event[1] === :materialize,authority.events) == 1 # attempted, uncertain; no refund
    @test !any(event -> event[1] in (:release,:commit),authority.events)
    for scope in (grandchild,root)
        retry = try R.resident_settle!(scope;verified="denied"); nothing catch failure; failure end
        @test retry === first[]
    end
end

@testset "child admission wins before root abort: no refund or later debit" begin
    R = QCLNEGFRunner
    authority, root, child, grandchild = _resident_nested_lifetime_fixture()
    R.require_growth!(grandchild,:atomic_text,"/synthetic/admitted";payload=:fake)
    @test root.permit.mutated
    R.resident_settle!(root)
    @test root.permit.state === grandchild.permit.state === :needs_reconcile
    before = copy(authority.events)
    @test_throws R.ResidentGrowthRefusal R.resident_materialized!(grandchild,1)
    @test authority.events == before
    @test !any(event -> event[1] === :release,authority.events)
    @test root.permit.ledger.outstanding == 40
    @test root.permit.ledger.cumulative == 0
end

@testset "actual atomic transition refuses callback close or invalidation" begin
    R = QCLNEGFRunner
    for mode in (:abort_return_true, :commit_return_true, :nested_return_true, :invalidate_return_true,
                 :callback_exception, :healthy)
        directory = mktempdir(;cleanup=false)
        source = joinpath(directory,"pending")
        target = joinpath(directory,"current")
        write(source,"fixture retained raw")
        write(target,"fixture prior target")
        chmod(source,0o600)
        authority, base = _resident_fake_fixture(:point;E=64,H=4096,growth=4096,
            parent=directory,A=4160)
        child_descriptor = R.StorageOperationInventory(base.identity,base.domain,:atomic_text,
            "fake-atomic-child",base.payload_digest,base.stop_reference,2048,2048,1,())
        descriptor = R.StorageOperationInventory(base.identity,base.domain,:point,
            "fake-atomic-parent",base.payload_digest,base.stop_reference,4096,4096,10,(child_descriptor,))
        root = R.reserve_storage_operation(authority,descriptor)
        child = R.resident_child_context!(root,:atomic_text)
        R.require_growth!(child,:atomic_text,target;payload=:fake)
        R.resident_created!(child,source)
        primary = ErrorException("atomic validator fixture exception")
        _resident_fake_writer_hooks[authority] = (a,writer,path,payload) -> begin
            writer === :atomic_replace || return true
            push!(a.events,(:atomic_validate,mode))
            if mode === :callback_exception
                throw(primary)
            elseif mode === :invalidate_return_true
                # Direct synthetic invalidation distinguishes the post-callback
                # ancestry recheck from merely blocking a reentrant settle.
                R._resident_close_tree!(root.permit,:needs_reconcile)
            elseif mode !== :healthy
                try
                    if mode === :abort_return_true
                        R.resident_settle!(root)
                    elseif mode === :commit_return_true
                        R.resident_settle!(root;verified="fake-premature-root-ack")
                    else
                        R._atomic_replace_file(source,target;resource_policy=:campaign_strict,
                            storage_context=child)
                    end
                catch failure
                    @test failure isa R.ResidentGrowthRefusal
                    push!(a.events,(:reentrant_refused,))
                end
            end
            return true
        end
        caught = try
            R._atomic_replace_file(source,target;resource_policy=:campaign_strict,
                storage_context=child)
            nothing
        catch failure
            failure
        end
        @test root.permit.ledger.inflight == 0
        @test root.permit.ledger.outstanding == 4096
        @test root.permit.ledger.cumulative == 0
        @test !any(event -> event[1] in (:release,:commit),authority.events)
        if mode === :healthy
            @test caught === nothing
            @test !ispath(source)
            @test read(target,String) == "fixture retained raw"
            @test (stat(target).mode & 0o777) == 0o640
        else
            @test caught isa Exception
            @test mode === :callback_exception ? caught === primary : caught isa R.ResidentGrowthRefusal
            @test child.primary === caught
            @test root.permit.state === child.permit.state === :needs_reconcile
            @test read(source,String) == "fixture retained raw"
            @test (stat(source).mode & 0o777) == 0o600 # no chmod occurred
            @test read(target,String) == "fixture prior target" # no rename occurred
        end
    end
end
