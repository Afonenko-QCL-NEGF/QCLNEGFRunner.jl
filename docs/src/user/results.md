# [Results and restart](@id native-result-formats)

The typed persistence API writes `qcl-negf.results.v2` and native HDF5 `5.0` only. Contracts owns
its closed JSON schemas and registry; Core owns the public state types and numerical admission;
Runner owns files, checkpoints and publication. The names ending in `.v1` on the new manifest,
pointer, catalog and declaration are schema identifiers within result v2. They do not enable
result-v1/native4 fallback.

This API is the P04 persistence boundary. The existing solver/CLI composition still awaits its P05
migration to typed public Core callbacks. The independent Results reader is a separate P06 delivery.
Older `save_checkpoint`/`load_production_restart` callsites are not aliases for this API; do not use
them as evidence of native5 recovery readiness.

## [Quality and continuation](@id solver-quality-contract)

Process completion, iterative convergence, physical checks, discretization evidence and experimental
validation are separate statuses. `not_measured` requires a reason; it never means pass. A
`recorded` status requires a hash-verified evidence FileRef. Runner checks its bytes and preserves
the owning evidence; it does not reinterpret the scientific criteria. A restored manufactured state
is engineering evidence, not validation of a physical model.

Exact state contains all 17 published Core state fields, including complete SCBA and outer
histories, continuation, mixer position, adaptation, warnings and final evidence when present. Every
scientific row retains all 16 snapshot fields and its complete typed row. Outer populations and
density vectors are mandatory. Serialization of the current exact state can scale with that state;
eliminating old history-file replay does not make total checkpoint cost constant.

## [Operator route: recover an interrupted execution](@id operator-recovery-route)

Resolve all relative FileRefs against one explicitly selected artifact root. Reject unsafe paths,
symlinks and changed files. A directory name or unauthenticated HDF attribute does not establish
identity. Identity includes run, execution, point, attempt, branch, the actual model SHA-256 and
frozen-plan-file SHA-256. Source epoch distinguishes invocations inside that scope.

| Locator                         | Meaning                                                               | Capability                                                                                |
| ------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `ATTEMPT/current.json`          | The selected live manifest and its current history frontier.          | History access; exact recovery only when this manifest has a matching nonnull checkpoint. |
| `ATTEMPT/recovery/current.json` | The explicitly selected last exact manifest.                          | Exact recovery after declaration, dependencies and native datasets verify.                |
| Immutable manifest StateRef     | A particular identity, state ID, positive sequence and manifest hash. | Frozen selection; later pointer updates cannot enlarge its cutoff.                        |

A history-only flush advances the live pointer to a manifest with `checkpoint=null`. It does not
attach an older checkpoint to newer history. An exact commit freezes one HistoryPin, publishes its
matching declaration and manifest, then advances recovery and live pointers in that order. A crash
between those pointer writes can leave different valid generations. Resolve either pointer against
its own manifest; the two updates are not atomic together.

The supported explicit recovery operations are:

```julia
checkpoint = open_exact_checkpoint(artifact_root, state_ref; maximum_metadata_bytes)
state = load_exact_solver_state(checkpoint)
# The consumer then calls Core's public validate_exact_state/restore_exact_state
# with the actual problem, options, runtime identity and policies.
```

Opening verifies hash-pinned metadata, payload hashes, native schema/layout, array shapes and
dtypes, history reachability and witness ancestry without materializing the full arrays. Loading
explicitly reconstructs the full public state and verifies its Core integrity. Core restore performs
numerical admission; persistence does not execute a solver or a completed-map revalidation. A failed
import is an error, never an implicit fresh calculation.

A new attempt names the exact parent StateRef, uses a greater attempt number and retains original
append identity/epoch/ordinal in carried witness locators. An update binds the immediate parent's
frozen HistoryPin even when its original append belongs to a grandparent. The original ordinal may
exceed the child's local cutoff. Up to two public continuation anchors are preloaded; the
current-stage locator map is bounded by declared `maximum_scba_rows` and cleared on outer/domain
transition. It stores compact keys/refs, never old row payloads. The writer proof cache keeps only
those current-stage original leaves and at most four status evidence refs; an exact handle keeps
only its declared payload/evidence proofs. Completed prefix files do not accumulate in a second
lifetime inventory. Retained update targets are checked by path/stat before publication, without
rereading their payload.

The parent's later committed tail remains scientific raw evidence through its original immutable
manifests and leaves. It is not spliced into the resumed trajectory or deleted. Retain both frozen
parent dependencies and the old attempt's tail. There is no automatic GC.

## Immutable scientific segments

Each append or witness update receives the next Runner scientific ordinal. Core delivery sequence is
shared with technical events and may have gaps. Regressed sequence, duplicate append, unknown
action/stage, counter mismatch and stage rebinding are explicit errors. Buffer limits trigger
lossless sealing; a single oversized row seals synchronously. An unchanged flush returns a detached
pin without writing files.

Each hash-pinned incremental catalog page contains exactly `[record_leaf]` or
`[array_payload, record_leaf]`, in that order. The last entry is always one record leaf; the
optional first entry owns its numeric arrays. The record leaf's dependencies bind that owner and
earlier append refs used by updates. Entry totals count files; ranges and row totals count records.
The previous immutable HistoryPin links the prefix without copying its artifact inventory. Import
checks global path uniqueness, including nonadjacent pages.

A reader selects the record ref from authenticated catalog order, verifies that file's hash, role,
representation and range, then reads the selected records. Arrays remain lazy until explicitly
requested. Classification must not scan/hash every array file or infer roles from filenames. Swapped
entries, wrong counts, representation or dependency mismatches fail.

Native record leaves contain `/records/offsets` (UInt64, N+1), `/records/json_utf8` (UInt8) and
`/records/stream_ordinal` (UInt64, N). Numeric fields use exact descriptors with FileRef, dataset,
scalar type, logical shape and `order=F`; all other values use closed public tags. IEEE scalar bits
preserve signed zero, infinities and NaN payloads. Complex arrays use the HDF5 `r/i` compound;
Boolean arrays use the explicit FALSE=0/TRUE=1 enum. No split-array or precision fallback exists.
Quantity units are fixed by the published Core layout.

The slab adapter compensates Julia HDF5 axis reversal: Julia dataset size is the reverse of the
logical shape; on-disk/h5py shape equals the logical shape. Python must not transpose again. Dataset
writes/reads use at most 1 MiB slabs; nonempty arrays use at most 256 KiB chunks with shuffle and
deflate level 1. Empty rank/axes are preserved. HDF external/soft links, virtual datasets and
external raw storage are rejected.

## Publication and evidence

Publication closes and fsyncs each new file, publishes an exclusive immutable path and syncs its
directory. Arrays precede record leaves; leaves precede catalogs; exact payload and frozen
dependencies precede the declaration and manifest; pointers come last. Pointer replacement is
followed by directory fsync and exact readback. Uncertain outcomes require captured-pointer
reconciliation before acknowledging buffered work or retrying. Reconciliation restores the
acknowledged manifest's status and closed flag, including a terminal publication whose recovery
pointer advanced before the writer observed success.

Unreachable temporary/orphan files are not selected by normal reads. There is no automatic salvage
or cleanup. A crash guarantees only the last committed history/checkpoint; uncommitted tail can be
lost. Local rename/fsync fixtures do not establish cross-NFS durability, installed service recovery,
worker-loss behavior or scientific acceptance.

Constructor-only fixtures and an independent Python/h5py literal checker are documented in
[`test/fixtures/result-v2/README.md`](https://github.com/Afonenko-QCL-NEGF/QCLNEGFRunner.jl/blob/HEAD/test/fixtures/result-v2/README.md).
They test actual rank1/2/4, non-square and empty arrays, exact bits, complete outer vectors, frozen
cutoffs, parent ancestry and crash barriers without transport or completed-map work. Native5
research projections remain a required Results follow-up; absence during reader migration is an
explicit temporary capability boundary, not permanent removal of those views.
