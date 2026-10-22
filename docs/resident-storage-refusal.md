# SCI08-R2: scoped lifecycle source contract, production closed

This change does not make strict writers ready. `campaign_strict` still refuses
at scientific preflight; staged execution now performs that preflight before
creating scratch storage and forwards policy/envelope. The four low-level
writers and atomic helpers also refuse strict requests without matching context before their first
mutation. Existing standalone publication, verification, fsync, pointer and
cleanup order is unchanged.

The resident authority port has no production backend. Its default operations
refuse, including release: a failed create or unknown object is never treated
as returned capacity. `_resident_budget_predicate` uses checked logical arithmetic
`E + U + P + S <= A` and `U + P + S <= H`; it never issues a permit. Unknown,
negative, boolean or overflowing input fails closed. It does not establish
physical allocation, inode bounds, freshness or authoritative inventory.

Validated identity/domain/snapshot/inventory objects describe separate logical,
physical and inode views. Scoped parent/child permits share a monotonic ledger
and finite disjoint child slots. Unknown tails stay reserved. Explicit authority
binding must attest exact payload/domain/enforced whole-operation bound; numbers
and the earlier forecast are not proofs. No production backend is installed.

Point/operator/stage/history preserve strict partials and use non-auto-cleaned
temporaries. Atomic text consumes a covered child slot. History refuses reuse
after failed index publication; rows remain until acknowledgement. Archive import,
optical, scratch success deletion, public checkpoint and finalizer branches
without a complete context remain refused before their branch mutator.

Strict failure retains partial temporary/raw data and counts it
through reconciliation. Rename alone does not acknowledge publication. Future
cleanup needs conjunction of ownership, existing policy, independent durable
replacement verification, delete authority, exact unlink barrier and lifetime
proof. Unknown unlink outcomes retain debt. No future deletion funds admission,
no `H += filesize`, no decrease of cumulative materialization.

`test/contracts/resident_refusal_contract.jl` and
`test/contracts/resident_lifecycle_contract.jl` contain unexecuted handwritten
fixture definitions. It is intentionally not wired into the test runner pending
an execution grant and independent source review. This document makes no runtime,
native filesystem, scientific or release acceptance claim.

First refusal is now bound once to the existing shared ledger and mirrored to
its root and affected context under the ledger guard. Initial admission, nested
slot selection, argument checks, create/identity and close belong to the public
writer failure scope. A caught reentrant refusal cannot reopen admission, debit
or publication. Raw causes retain object identity; structured preflight wrappers
carry that cause without becoming a second failure. Strict failure freezes the
whole tree without releasing reservation debt. Clean explicit whole-root release
still requires authority acknowledgement; settlement uncertainty freezes it.

Direct-entry engineering RED02 established the prior failure; this candidate has
not been executed. The focused fixture retains 64 iterations and all assertion
meanings; only three path comparisons normalize both operands. Test-only unit,
HDF5 and availability seams remain unchanged and do not prove native serializers,
physical admission, full-module loading or scientific acceptance.
