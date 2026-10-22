"""Structured refusal; unknown capacity is never encoded as free bytes."""
struct ResidentGrowthRefusal <: Exception
    operation::Symbol
    reason::Symbol
    verified_state::Symbol
    phase::Symbol
    identity::Any
    cause::Any
end
ResidentGrowthRefusal(operation, reason, verified_state) =
    ResidentGrowthRefusal(operation, reason, verified_state, :before_mutation, nothing, nothing)
Base.showerror(io::IO, failure::ResidentGrowthRefusal) = print(io,
    "campaign_strict resident growth refused: ", failure.operation, ": ",
    failure.reason, "; verified_state=", failure.verified_state)

"""Resident authority port. No production authority is installed by R2."""
abstract type AbstractResidentAuthority end
struct UnavailableResidentAuthority <: AbstractResidentAuthority end

# Deliberately no snapshot/permit constructors or native probe fallback. A typed
# port is not an authority implementation and cannot prove a finite writer bound.
resident_snapshot(::AbstractResidentAuthority, binding) =
    throw(ResidentGrowthRefusal(:snapshot, :authority_unavailable, :unknown))
reserve_growth!(::AbstractResidentAuthority, snapshot_revision, descriptor) =
    throw(ResidentGrowthRefusal(:reserve, :authority_unavailable, :unknown))
materialize_growth!(::AbstractResidentAuthority, lease, sequence, delta) =
    throw(ResidentGrowthRefusal(:materialize, :authority_unavailable, :unknown))
commit_growth!(::AbstractResidentAuthority, lease, evidence) =
    throw(ResidentGrowthRefusal(:commit, :authority_unavailable, :unknown))
release_unmaterialized!(::AbstractResidentAuthority, lease, evidence) =
    throw(ResidentGrowthRefusal(:release, :authority_unavailable, :unknown))

"""Logical baseline predicate only; this never grants a writer capability.

E is already materialized; H is remaining before exactly the disjoint U/P/S.
No future unlink, cumulative-written counter or R1 forecast enters this predicate.
Physical allocation/inodes and authoritative freshness remain separate obligations.
"""
function _resident_budget_predicate(E, U, P, S, A, H)
    values = (E, U, P, S, A, H)
    all(x -> x isa Integer && !(x isa Bool) && 0 <= x <= typemax(Int), values) ||
        return false
    try
        growth = Base.checked_add(Base.checked_add(Int(U), Int(P)), Int(S))
        total = Base.checked_add(Int(E), growth)
        return total <= Int(A) && growth <= Int(H)
    catch failure
        failure isa OverflowError || rethrow()
        return false
    end
end

function _resident_writer_preflight(policy::Symbol, operation::Symbol)
    policy in (:standalone, :campaign_strict) ||
        throw(ArgumentError("unknown resource policy"))
    policy === :standalone && return nothing
    # Guard must dominate even mkdir/create: failed creation can leave an
    # unknown footprint. Do not create a refusal receipt without a capability.
    throw(ResidentGrowthRefusal(operation,
        :authority_and_finite_growth_bound_unavailable, :unknown))
end

# Application-local proof objects. These are not a wire schema or a native
# authority implementation. The authority that issues them owns freshness,
# atomic reservation, complete inventory and independently enforced writer bounds.
_resident_nonempty(value) = value isa AbstractString && !isempty(value)
function _resident_count(value)
    value isa Integer && !(value isa Bool) && 0 <= value <= typemax(Int) ||
        throw(ResidentGrowthRefusal(:proof, :needs_admission, :unknown))
    return Int(value)
end

struct ResidentIdentity
    campaign::String
    plan::String
    execution::String
    attempt::String
    point::String
    source::String
    admission::String
    operation::String
    generation::Int
    function ResidentIdentity(campaign, plan, execution, attempt, point, source,
        admission, operation, generation)
        all(_resident_nonempty, (campaign, plan, execution, attempt, point,
            source, admission, operation)) ||
            throw(ResidentGrowthRefusal(:identity, :identity_mismatch, :unknown))
        new(campaign, plan, execution, attempt, point, source, admission,
            operation, _resident_count(generation))
    end
end

struct StorageDomain
    filesystem::String
    namespace::String
    boot::String
    ownership::String
    parent::String
    binding::String
    function StorageDomain(filesystem, namespace, boot, ownership, parent, binding)
        all(_resident_nonempty, (filesystem, namespace, boot, ownership, parent, binding)) ||
            throw(ResidentGrowthRefusal(:domain, :needs_admission, :unknown))
        isabspath(parent) && normpath(parent) == parent ||
            throw(ResidentGrowthRefusal(:domain, :identity_mismatch, :unknown))
        new(filesystem, namespace, boot, ownership, parent, binding)
    end
end

struct StorageOperationInventory
    identity::ResidentIdentity
    domain::StorageDomain
    writer::Symbol
    digest::String
    payload_digest::String
    stop_reference::String
    logical::Int
    physical::Int
    inodes::Int
    # Complete finite child descriptors, including their own transitive slots.
    slots::Tuple
    function StorageOperationInventory(identity, domain, writer, digest,
        payload_digest, stop_reference, logical, physical, inodes, slots::Tuple)
        all(_resident_nonempty, (digest, payload_digest, stop_reference)) ||
            throw(ResidentGrowthRefusal(writer, :needs_guard, :unknown))
        bounds = (_resident_count(logical), _resident_count(physical), _resident_count(inodes))
        totals = (0, 0, 0)
        for slot in slots
            slot isa StorageOperationInventory && slot.identity == identity && slot.domain == domain ||
                throw(ResidentGrowthRefusal(writer, :needs_guard, :unknown))
            child = (slot.logical, slot.physical, slot.inodes)
            totals = ntuple(i -> Base.checked_add(totals[i], child[i]), 3)
        end
        all(i -> totals[i] <= bounds[i], 1:3) ||
            throw(ResidentGrowthRefusal(writer, :inventory_overrun, :unknown))
        new(identity, domain, writer, digest, payload_digest, stop_reference,
            bounds..., slots)
    end
end

struct StorageSnapshot
    identity::ResidentIdentity
    domain::StorageDomain
    revision::String
    issued_ns::UInt64
    expires_ns::UInt64
    # Each tuple has logical-byte, physical-byte and inode views. A/H do not
    # mix units. H is before exactly U/P/S; no net-headroom addback is guessed.
    E::NTuple{3,Int}
    U::NTuple{3,Int}
    P::NTuple{3,Int}
    S::NTuple{3,Int}
    A::NTuple{3,Int}
    H::NTuple{3,Int}
    inventory_digest::String
    authority_epoch::String
    function StorageSnapshot(identity, domain, revision, issued_ns, expires_ns,
        E, U, P, S, A, H, inventory_digest, authority_epoch)
        all(_resident_nonempty, (revision, inventory_digest, authority_epoch)) ||
            throw(ResidentGrowthRefusal(:snapshot, :needs_admission, :unknown))
        issued_ns isa Integer && !(issued_ns isa Bool) && expires_ns isa Integer &&
            !(expires_ns isa Bool) && 0 <= issued_ns < expires_ns <= typemax(UInt64) ||
            throw(ResidentGrowthRefusal(:snapshot, :stale_snapshot, :unknown))
        views = map(x -> (length(x) == 3 || throw(ArgumentError("three storage views required"));
            ntuple(i -> _resident_count(x[i]), 3)), (E, U, P, S, A, H))
        new(identity, domain, revision, UInt64(issued_ns), UInt64(expires_ns),
            views..., inventory_digest, authority_epoch)
    end
end

struct ResidentLeaseProof
    lease_id::String
    revision::String
    descriptor_digest::String
    function ResidentLeaseProof(lease_id, revision, descriptor_digest)
        all(_resident_nonempty, (lease_id, revision, descriptor_digest)) ||
            throw(ResidentGrowthRefusal(:reserve, :needs_admission, :unknown))
        new(lease_id, revision, descriptor_digest)
    end
end

# Owning backend must attest an enforced whole-operation bound, exact identity,
# payload, domain containment, snapshot and child coverage. A number is no proof.
validate_resident_binding!(::AbstractResidentAuthority, snapshot, descriptor) =
    throw(ResidentGrowthRefusal(:binding, :needs_guard, :unknown))
resident_monotonic_ns(::AbstractResidentAuthority) =
    throw(ResidentGrowthRefusal(:clock, :needs_admission, :unknown))
validate_resident_writer!(::AbstractResidentAuthority, descriptor, writer, path, payload) =
    throw(ResidentGrowthRefusal(writer, :needs_guard, :unknown))

mutable struct ResidentLedger
    resident::Int
    outstanding::Int
    cumulative::Int
    highwater::Int
    sequence::Int
    guard::ReentrantLock
    inflight::Int
    interference::Int
    root_context::Any
    primary::Any
    function ResidentLedger(resident, outstanding, cumulative, highwater)
        values = map(_resident_count, (resident, outstanding, cumulative, highwater))
        new(values[1], values[2], values[3], max(values[1], values[4]), 0, ReentrantLock(), 0, 0, nothing, nothing)
    end
end

mutable struct StorageGrowthPermit
    authority::AbstractResidentAuthority
    descriptor::StorageOperationInventory
    lease::ResidentLeaseProof
    remaining::NTuple{3,Int}
    sequence::Int
    ledger::ResidentLedger
    child_slots::BitVector
    state::Symbol
    parent::Union{Nothing,StorageGrowthPermit}
    mutated::Bool
    children::Vector{StorageGrowthPermit}
end
const _resident_active_permits = IdDict{StorageGrowthPermit,Nothing}()
const _resident_permit_guard = ReentrantLock()
_resident_registered(permit) = lock(_resident_permit_guard) do
    haskey(_resident_active_permits, permit)
end
_resident_register!(permit) = lock(_resident_permit_guard) do
    _resident_active_permits[permit] = nothing
end

mutable struct StorageWriteContext
    permit::StorageGrowthPermit
    phase::Symbol
    mutation_started::Bool
    paths::Dict{String,Symbol}
    object_identities::Dict{String,Union{Nothing,String}}
    primary::Any
    secondary::Vector{Any}
    last_verified::Union{Nothing,String}
end

function reserve_storage_operation(authority::AbstractResidentAuthority,
    descriptor::StorageOperationInventory)
    snapshot = resident_snapshot(authority, descriptor.domain.binding)
    snapshot isa StorageSnapshot ||
        throw(ResidentGrowthRefusal(descriptor.writer, :needs_admission, :unknown))
    snapshot.identity == descriptor.identity && snapshot.domain == descriptor.domain ||
        throw(ResidentGrowthRefusal(descriptor.writer, :identity_mismatch, :unknown))
    now = resident_monotonic_ns(authority)
    snapshot.issued_ns <= now < snapshot.expires_ns ||
        throw(ResidentGrowthRefusal(descriptor.writer, :stale_snapshot, :unknown))
    validate_resident_binding!(authority, snapshot, descriptor) === true ||
        throw(ResidentGrowthRefusal(descriptor.writer, :needs_guard, :unknown))
    growth = (descriptor.logical, descriptor.physical, descriptor.inodes)
    for i in 1:3
        pending = Base.checked_add(snapshot.U[i], growth[i])
        _resident_budget_predicate(snapshot.E[i], pending, snapshot.P[i],
            snapshot.S[i], snapshot.A[i], snapshot.H[i]) ||
            throw(ResidentGrowthRefusal(descriptor.writer, :resident_limit, :unknown))
    end
    lease = reserve_growth!(authority, snapshot.revision, descriptor)
    lease isa ResidentLeaseProof && lease.revision == snapshot.revision &&
        lease.descriptor_digest == descriptor.digest ||
        throw(ResidentGrowthRefusal(descriptor.writer, :identity_mismatch, :unknown))
    ledger = ResidentLedger(snapshot.E[1], Base.checked_add(snapshot.U[1], growth[1]), 0, snapshot.E[1])
    permit = StorageGrowthPermit(authority, descriptor, lease, growth, 0, ledger,
        falses(length(descriptor.slots)), :reserved, nothing, false, StorageGrowthPermit[])
    _resident_register!(permit)
    context = StorageWriteContext(permit, :reserved, false, Dict{String,Symbol}(),
        Dict{String,Union{Nothing,String}}(), nothing, Any[], nothing)
    ledger.root_context = context
    return context
end

# Caller holds the one ledger lock for the entire tree. A scoped capability
# cannot outlive any ancestor or migrate to another lease, identity or ledger.
function _resident_live_ancestry!(permit::StorageGrowthPermit)
    permit.ledger.primary === nothing || throw(permit.ledger.primary)
    leaf = permit
    while true
        _resident_registered(permit) && permit.state === :reserved &&
            permit.ledger === leaf.ledger && permit.lease === leaf.lease &&
            permit.authority === leaf.authority &&
            permit.descriptor.identity == leaf.descriptor.identity &&
            permit.descriptor.domain == leaf.descriptor.domain ||
            throw(ResidentGrowthRefusal(leaf.descriptor.writer, :needs_guard, :unknown))
        parent = permit.parent
        parent === nothing && return permit
        any(child -> child === permit, parent.children) &&
            any(i -> parent.child_slots[i] && parent.descriptor.slots[i] === permit.descriptor,
                eachindex(parent.child_slots)) ||
            throw(ResidentGrowthRefusal(leaf.descriptor.writer, :identity_mismatch, :unknown))
        permit = parent
    end
end

function _resident_close_tree!(permit::StorageGrowthPermit, state::Symbol)
    permit.state = state
    for child in permit.children
        _resident_close_tree!(child, state)
    end
    return nothing
end

function _resident_tree_scopes(permit::StorageGrowthPermit)
    return (descriptor=permit.descriptor.digest, remaining=permit.remaining,
        children=Tuple(_resident_tree_scopes(child) for child in permit.children))
end

function require_growth!(context::StorageWriteContext, writer::Symbol, path::AbstractString; payload=nothing)
    permit = context.permit
    return lock(permit.ledger.guard) do
        try
            root = _resident_live_ancestry!(permit)
            permit.ledger.inflight == 0 || throw(ResidentGrowthRefusal(writer, :needs_guard, :unknown))
            _resident_registered(permit) && permit.state === :reserved && context.phase === :reserved ||
                throw(ResidentGrowthRefusal(writer, :inventory_overrun, :unknown))
            domain = permit.descriptor.domain
            target = abspath(path)
            relative = relpath(target, domain.parent)
            (relative == ".." || startswith(relative, ".." * string(Base.Filesystem.path_separator))) &&
                throw(ResidentGrowthRefusal(writer, :identity_mismatch, :unknown))
            writer === permit.descriptor.writer ||
                throw(ResidentGrowthRefusal(writer, :identity_mismatch, :unknown))
            permit.ledger.inflight += 1
            try
                validate_resident_writer!(permit.authority, permit.descriptor, writer, target, payload) === true ||
                    throw(ResidentGrowthRefusal(writer, :needs_guard, :unknown))
            finally
                permit.ledger.inflight -= 1
            end
            _resident_live_ancestry!(permit)
            # Marker is before create/open/chmod/copy, including partially failing create.
            context.mutation_started = true
            ancestor = permit
            while ancestor !== nothing
                ancestor.mutated = true
                ancestor = ancestor.parent
            end
            context.phase = :partial_unknown
            context.paths[target] = :partial_unknown
            return context
        catch failure
            canonical = _resident_failure!(context, failure)
            canonical === nothing || canonical === failure || throw(canonical)
            rethrow()
        end
    end
end

function resident_child_context!(context::StorageWriteContext, writer::Symbol,
    descriptor::StorageOperationInventory)
    parent = context.permit
    return lock(parent.ledger.guard) do
        try
            _resident_live_ancestry!(parent)
            parent.ledger.inflight == 0 || throw(ResidentGrowthRefusal(writer, :needs_guard, :unknown))
            _resident_registered(parent) && parent.state === :reserved && descriptor.identity == parent.descriptor.identity &&
                descriptor.domain == parent.descriptor.domain && descriptor.writer === writer ||
                throw(ResidentGrowthRefusal(writer, :identity_mismatch, :unknown))
            bound = (descriptor.logical, descriptor.physical, descriptor.inodes)
            slot = findfirst(i -> !parent.child_slots[i] &&
                parent.descriptor.slots[i] === descriptor, eachindex(parent.child_slots))
            slot === nothing && throw(ResidentGrowthRefusal(writer, :inventory_overrun, :unknown))
            all(i -> bound[i] <= parent.remaining[i], 1:3) ||
                throw(ResidentGrowthRefusal(writer, :inventory_overrun, :unknown))
            parent.remaining = ntuple(i -> Base.checked_sub(parent.remaining[i], bound[i]), 3)
            parent.child_slots[slot] = true
            # Parent reservation covers child; no second reserve and no second U charge.
            permit = StorageGrowthPermit(parent.authority, descriptor, parent.lease, bound,
                parent.sequence, parent.ledger, falses(length(descriptor.slots)), :reserved, parent, false,
                StorageGrowthPermit[])
            _resident_register!(permit)
            push!(parent.children, permit)
            return StorageWriteContext(permit, :reserved, false, Dict{String,Symbol}(),
                Dict{String,Union{Nothing,String}}(), nothing, Any[], context.last_verified)
        catch failure
            canonical = _resident_failure!(context, failure)
            canonical === nothing || canonical === failure || throw(canonical)
            rethrow()
        end
    end
end

function resident_materialized!(context::StorageWriteContext, observed::Integer)
    permit = context.permit
    return lock(permit.ledger.guard) do
        try
            root = _resident_live_ancestry!(permit)
            permit.mutated && permit.ledger.inflight == 0 ||
                throw(ResidentGrowthRefusal(permit.descriptor.writer, :needs_guard, :unknown))
            delta = _resident_count(observed)
            delta <= permit.remaining[1] ||
                throw(ResidentGrowthRefusal(permit.descriptor.writer, :inventory_overrun, :unknown))
            next = Base.checked_add(permit.ledger.sequence, 1)
            # Publish authority debit first; failed/unknown debit does not free anything.
            permit.ledger.inflight += 1
            try
                materialize_growth!(permit.authority, permit.lease, next,
                    (scope=permit.descriptor.digest, logical_bytes=delta))
            catch
                _resident_close_tree!(root, :needs_reconcile)
                rethrow()
            finally
                permit.ledger.inflight -= 1
            end
            _resident_live_ancestry!(permit)
            permit.sequence = next
            permit.ledger.sequence = next
            permit.remaining = (Base.checked_sub(permit.remaining[1], delta), permit.remaining[2], permit.remaining[3])
            ledger = permit.ledger
            ledger.resident = Base.checked_add(ledger.resident, delta)
            ledger.outstanding = Base.checked_sub(ledger.outstanding, delta)
            ledger.cumulative = Base.checked_add(ledger.cumulative, delta)
            ledger.highwater = max(ledger.highwater, ledger.resident)
            return nothing
        catch failure
            canonical = _resident_failure!(context, failure)
            canonical === nothing || canonical === failure || throw(canonical)
            rethrow()
        end
    end
end

function resident_renamed!(context::StorageWriteContext, source, destination)
    return lock(context.permit.ledger.guard) do
        try
            _resident_live_ancestry!(context.permit)
            context.paths[abspath(source)] = :moved
            context.paths[abspath(destination)] = :published_unacknowledged
            context.object_identities[abspath(destination)] = get(context.object_identities, abspath(source), nothing)
            context.phase = :published_unacknowledged
            return nothing
        catch failure
            canonical = _resident_failure!(context, failure)
            canonical === nothing || canonical === failure || throw(canonical)
            rethrow()
        end
    end
end

resident_created_identity(::AbstractResidentAuthority, domain, path) = nothing

function resident_created!(context, path)
    context === nothing && return nothing
    permit = context.permit
    return lock(permit.ledger.guard) do
        try
            _resident_live_ancestry!(permit)
            context.paths[abspath(path)] = :partial_unknown
            permit.ledger.inflight += 1
            identity = try
                resident_created_identity(permit.authority, permit.descriptor.domain, abspath(path))
            finally
                permit.ledger.inflight -= 1
            end
            _resident_live_ancestry!(permit)
            context.object_identities[abspath(path)] = identity isa String ? identity : nothing
            identity isa String && !isempty(identity) ||
                throw(ResidentGrowthRefusal(permit.descriptor.writer, :needs_admission,
                    :unknown, context.phase, permit.descriptor.identity, nothing))
            return nothing
        catch failure
            canonical = _resident_failure!(context, failure)
            canonical === nothing || canonical === failure || throw(canonical)
            rethrow()
        end
    end
end

function resident_settle!(context::StorageWriteContext; verified=nothing)
    permit = context.permit
    return lock(permit.ledger.guard) do
        try
            permit.ledger.primary === nothing || throw(permit.ledger.primary)
            permit.state === :needs_reconcile && verified === nothing && return context.phase
            root = _resident_live_ancestry!(permit)
            if permit.ledger.inflight != 0
                # A validating callback may catch this refusal and return true.
                # Preserve that interference so the atomic transition can refuse
                # before chmod/rename rather than silently accept the callback.
                permit.ledger.interference = Base.checked_add(permit.ledger.interference, 1)
                throw(ResidentGrowthRefusal(permit.descriptor.writer, :needs_guard, :unknown))
            end
            if verified === nothing && (permit.mutated || permit.parent !== nothing)
                # No descendant settlement can refund the shared parent lease.
                _resident_close_tree!(root, :needs_reconcile)
                return context.phase
            end
            # Close admission for the entire scoped subtree before the authority
            # call, including reentrant callbacks while this ReentrantLock is held.
            permit.state = :settling
            permit.ledger.inflight += 1
            evidence = (scope=permit.parent === nothing ? :root : :child,
                lease=permit.lease.lease_id, descriptor=permit.descriptor.digest,
                tree=_resident_tree_scopes(permit), verified=verified)
            try
                if verified !== nothing
                    commit_growth!(permit.authority, permit.lease, evidence)
                    permit.ledger.primary === nothing || throw(permit.ledger.primary)
                    context.last_verified = String(verified)
                    context.phase = :acknowledged
                    _resident_close_tree!(permit, :committed)
                else
                    # No parent/child was ever marked for mutation. This releases
                    # the original complete reservation once, including unused
                    # descendants; parent.remaining alone is not the refundable sum.
                    release_unmaterialized!(permit.authority, permit.lease,
                        merge(evidence, (outcome=:no_mutation_proven,
                            refundable=(permit.descriptor.logical, permit.descriptor.physical, permit.descriptor.inodes))))
                    permit.ledger.primary === nothing || throw(permit.ledger.primary)
                    context.phase = :no_mutation_proven
                    _resident_close_tree!(permit, :released)
                end
            catch
                _resident_close_tree!(root, :needs_reconcile)
                rethrow()
            finally
                permit.ledger.inflight -= 1
            end
            return context.phase
        catch failure
            canonical = _resident_failure!(context, failure)
            canonical === nothing || canonical === failure || throw(canonical)
            rethrow()
        end
    end
end

function resident_child_context!(context::StorageWriteContext, writer::Symbol)
    parent = context.permit
    return lock(parent.ledger.guard) do
        try
            _resident_live_ancestry!(parent)
            slot = findfirst(i -> !parent.child_slots[i] && parent.descriptor.slots[i].writer === writer,
                eachindex(parent.child_slots))
            slot === nothing && throw(ResidentGrowthRefusal(writer, :needs_guard, :unknown))
            return resident_child_context!(context, writer, parent.descriptor.slots[slot])
        catch failure
            canonical = _resident_failure!(context, failure)
            canonical === nothing || canonical === failure || throw(canonical)
            rethrow()
        end
    end
end

function _resident_nested_context(policy, context, writer)
    policy === :standalone && return nothing
    context isa StorageWriteContext || return _resident_writer_preflight(policy, writer)
    context.permit.descriptor.writer === writer && context.phase === :reserved && return context
    return resident_child_context!(context, writer)
end

function resident_acknowledged!(context, verified)
    context === nothing && return nothing
    try
        resident_settle!(context; verified)
    catch failure
        canonical = _resident_failure!(context, failure)
        canonical === nothing || canonical === failure || throw(canonical)
        rethrow()
    end
    return nothing
end

function with_storage_operation(writer::Function, context::StorageWriteContext)
    try
        lock(context.permit.ledger.guard) do
            _resident_live_ancestry!(context.permit)
        end
        result = writer(context)
        lock(context.permit.ledger.guard) do
            context.permit.ledger.primary === nothing || throw(context.permit.ledger.primary)
        end
        return result
    catch primary
        canonical = _resident_failure!(context, primary)
        canonical === nothing || canonical === primary || throw(canonical)
        rethrow()
    finally
        if context.permit.state === :reserved
            try
                resident_settle!(context)
            catch secondary
                canonical = _resident_failure!(context, secondary)
                canonical === nothing || canonical === secondary || throw(canonical)
                rethrow()
            end
        end
    end
end

function _resident_attested_unlink!(ledger::ResidentLedger, bytes, attested::Bool)
    return lock(ledger.guard) do
    attested || return false
    amount = _resident_count(bytes)
    amount <= ledger.resident || throw(ArgumentError("unlink exceeds resident attribution"))
    ledger.resident = Base.checked_sub(ledger.resident, amount)
    # Outstanding, cumulative, highwater and H never receive deletion credit.
    return true
    end
end

function _resident_writer_preflight(policy::Symbol, operation::Symbol, context, path; payload=nothing)
    if policy === :standalone
        context === nothing || throw(ArgumentError("resident context requires campaign_strict"))
        return nothing
    end
    policy === :campaign_strict || throw(ArgumentError("unknown resource policy"))
    context isa StorageWriteContext || return _resident_writer_preflight(policy, operation)
    try
        return require_growth!(context, operation, path; payload)
    catch cause
        cause isa ResidentGrowthRefusal || rethrow()
        throw(ResidentGrowthRefusal(operation, cause.reason,
            context.last_verified === nothing ? :no_verified_state : :last_verified,
            context.phase, context.permit.descriptor.identity, cause))
    end
end

# First refusal belongs to the existing shared ledger, never to a retry wrapper.
# Freeze while holding the same lock used by admission and native publication.
function _resident_failure!(context, failure)
    context isa StorageWriteContext || return nothing
    ledger = context.permit.ledger
    return lock(ledger.guard) do
        ledger.primary === nothing && (ledger.primary = failure)
        is_primary = failure === ledger.primary ||
            (failure isa ResidentGrowthRefusal && failure.cause === ledger.primary)
        root = context.permit
        while root.parent !== nothing
            root = root.parent
        end
        _resident_close_tree!(root, :needs_reconcile)
        for affected in (context, ledger.root_context)
            affected === nothing && continue
            affected.primary = ledger.primary
        end
        if !is_primary && !any(x -> x === failure, context.secondary)
            push!(context.secondary, failure)
        end
        return is_primary ? failure : ledger.primary
    end
end

_resident_preserve(policy, context) = policy === :campaign_strict && context isa StorageWriteContext

with_storage_operation(writer::Function, authority::AbstractResidentAuthority,
    descriptor::StorageOperationInventory) =
    with_storage_operation(writer, reserve_storage_operation(authority, descriptor))

function with_storage_operation(writer::Function, context::StorageWriteContext,
    descriptor::StorageOperationInventory)
    scope = context.permit.descriptor === descriptor ? context :
        resident_child_context!(context, descriptor.writer, descriptor)
    return with_storage_operation(writer, scope)
end

struct ResidentDeletionEligibility
    path::String
    object_identity::String
    replacement::String
    ownership::String
    policy::String
    independent_verifier::String
    delete_authority::String
    lifetime_proof::String
    protected::Bool
    bytes::Int
    function ResidentDeletionEligibility(path, object_identity, replacement,
        ownership, policy, independent_verifier, delete_authority, lifetime_proof,
        protected, bytes)
        all(_resident_nonempty, (path, object_identity, replacement, ownership,
            policy, independent_verifier, delete_authority, lifetime_proof)) ||
            throw(ResidentGrowthRefusal(:cleanup, :needs_admission, :unknown))
        protected isa Bool || throw(ArgumentError("known protection status required"))
        new(abspath(path), object_identity, replacement, ownership, policy,
            independent_verifier, delete_authority, lifetime_proof, protected,
            _resident_count(bytes))
    end
end

struct ResidentUnlinkOutcome
    object_identity::String
    barrier::String
    lifetime_proof::String
    outcome::Symbol
end
resident_delete_eligibility(::AbstractResidentAuthority, context, path) = nothing
resident_exact_unlink!(::AbstractResidentAuthority, eligibility) = nothing

function resident_cleanup!(context::StorageWriteContext, path)
    proof = resident_delete_eligibility(context.permit.authority, context, abspath(path))
    proof isa ResidentDeletionEligibility || return :deferred
    proof.path == abspath(path) && !proof.protected || return :deferred
    # Authority performs exact-object unlink only after the whole conjunction.
    # Unknown/missing outcome retains all attribution and reservation debt.
    result = resident_exact_unlink!(context.permit.authority, proof)
    result isa ResidentUnlinkOutcome || return :unknown
    result.outcome === :unlinked_verified && result.object_identity == proof.object_identity &&
        result.lifetime_proof == proof.lifetime_proof && !isempty(result.barrier) || return :unknown
    _resident_attested_unlink!(context.permit.ledger, proof.bytes, true)
    context.paths[abspath(path)] = :unlinked_verified
    return :unlinked_verified
end
