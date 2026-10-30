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

For a new AiiDA native invocation, `run-plan` accepts the paired options
`--native-execution native-execution.json --native-calcjob-uuid UUID`, together with exactly
`--execution-id ID --source-graph source-graph.json`. This path checks bounded original plan,
graph and native input bytes, whole input references, execution and output suffix independently
of optional capture. Native scratch, explicit scientific attempt and recovery options are not
enabled by these options. The original plan is limited to 1 MiB, matching the existing capture
plan allowance; the original source graph and native execution description each retain a
64 KiB limit. The native origin reader counts all original whitespace and retains the same
open-file, path, alias, byte-count, hash and frozen-plan checks. The private description
carries only the CalcJob UUID and original native-execution input UUID to a newly created recorder.

Its existing `invocation.source_epoch` is
`c1-<CalcJob lower hex32>-<native input lower hex32>-<UInt64 time_ns decimal>`: at most 89 bytes,
or 116 with the existing `-state-<UInt64 generation>` suffix, within the unchanged Id128 schema.
The nonce is independent of scientific and transport attempts. Ordinary standalone invocations
keep their `epoch-<time_ns>` convention. Inherited StateRefs, parent epochs, raw files and hashes
are never relabelled or rewritten; an old epoch does not acquire an AiiDA creator by inference.

These CLI values and input declarations are assertions. Actual original INPUT/CALL/CREATE and
submit-script joins, the protected literal launch/job chain, qualified immutable producer and
native writer/no-reuse/retention/RO lifetime remain AiiDA, Platform and Root obligations.
The epoch alone is not creator or scientific acceptance evidence. Selected-source and technical
capture consumers require their separate owning integration; these options do not activate
the existing stationary/configured execution fences or enable recovery.

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
# Select the source attempt and its full expected Identity explicitly.
checkpoint = open_exact_checkpoint(artifact_root, "attempt-4/recovery/current.json";
    expected_identity=source_identity, maximum_metadata_bytes)
state_ref = checkpoint_reference(checkpoint)
# A previously captured immutable StateRef can also be opened directly:
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

The pointer reader accepts one root-relative file, checks its Identity and generation against its
hash-pinned manifest, and uses the same verification pipeline as the StateRef reader. Expected
Identity refers to the selected source attempt, including its branch, model and frozen-plan hashes;
it is not inferred from directory names or replaced with the new continuation attempt's Identity.
There is no current/previous search or automatic switch from live to recovery. A live manifest with
`checkpoint=null` is valid history with no exact recovery capability. A pointer replaced during the
call is refused; advancing it after a successful return does not enlarge the frozen handle's cutoff.

The required metadata allowance counts every JSON input read in the call, including pointer and both
bootstrap/verified manifest reads, ancestor documents, native identity/invocation JSON and selected
original-record JSON. The bounded Runner reader supports the fixed-length scalar HDF5 string
metadata produced by its writer; the declared byte width, including padding, is checked before
reading and debited. Variable-length, non-string or non-scalar metadata is explicitly unsupported by
this reader. This reader capability does not tighten the Contracts native5 format. Streamed hashes
of selected native files remain separate byte reads; they do not materialize numeric arrays. The
allowance does not bound HDF5 internal memory, full-state loading, total artifact size or the
lifetime of an execution.

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

## [Final observations and one commit](@id final-native-observations)

`commit_final!` is the final persistence port. Pass the actual returned `NEGFSolution`, its owning
public global-final `ExactSolverState`, and the exact options/execution/adaptation/kernel binding.
Its problem is `solution.problem`, including the final adaptive coordinates. The writer calls
Core's `final_observation_snapshot` once; Core owns exact-state admission and the integrated PSD
scan. The writer does not restore a state, run a selected map, or repeat the final analysis.

Publish the inputs first with `publish_final_point_request!`. Its `model_preimage` must come from
the actual P03 point configuration after applying the operating axes. It is the canonical
`stationary_transport_inputs_v1` preimage, not a renamed legacy configuration snapshot. The helper
checks the closed model envelope and canonical digest, detaches bounded metadata, and writes the
original frozen plan bytes without reserializing them. Existing nested YAML is checked before
construction for aliases, anchors, custom tags, duplicate/merge/non-string keys, multiple documents,
nonfinite values and excessive depth. Quoted characters remain data. Original comments, line
endings and whitespace participate in the plan FileRef hash. Scientific JSON retains its existing
closed nested profile. These checks do not prove that the caller resolved the scientific model
correctly; the composition owns that source binding.

```julia
request = publish_final_point_request!(recorder;
    plan_bytes=frozen_plan_bytes, model_preimage=actual_point_model_preimage,
    temperature_K, voltage_per_period_V, scattering_requested,
    kind=:nested_sweep, maximum_metadata_bytes)

presentation = Ref{NamedTuple}()
# Final-only input: exactly these three caller-owned fields. Any recorded
# discretization/experimental evidence must already exist as a verified FileRef.
status = Dict("process" => terminal_process_status,
    "discretization" => actual_discretization_status,
    "experimental" => actual_experimental_status)
final = commit_final!(recorder, solution, terminal;
    options, production_options, execution, domain_adaptation, kernel_options,
    status, request, source_mode=:produced,
    maximum_observation_bytes, maximum_metadata_bytes,
    presentation_sink=bundle -> (presentation[] = bundle))
# Only after this return may the composition publish its terminal point/light result.
# final has exactly: checkpoint, diagnostics, observations.
```

The final-only `status` keyword accepts exactly `process`, `discretization` and
`experimental`. It rejects caller-supplied `convergence` or `physics`, unknown fields
and missing fields. Caller metadata is detached before capture/publication callbacks.
Existing recorded external evidence is hash-checked before capture;
unmeasured external facts retain a null evidence ref and their actual reason. A successful
process does not imply convergence or scientific acceptance.

After the mandatory capture and immutable observations write, the writer creates the
complete manifest status. Its `convergence` and `physics` entries are `recorded`, each
with the exact observations FileRef. Here `recorded` means that evidence was stored,
including negative classifications and unavailable diagnostic issues; it does not mean
pass. Current classification is in `observations.summary`, raw metrics/positivity in
the linked diagnostics, original report in checkpoint `final_evidence`, and completed
restoration receipts in `observations.restoration`. The same complete status is retained
by the recorder, verified handle and pointer reconciliation. Intermediate checkpoint
and recorder-initial status inputs still require the existing complete five-field status.

The mandatory `presentation_sink` transfers the captured stationary assessment and bounded old
validation/positivity display in exactly three fields: `stationary_assessment`, `validation`,
`positivity`. It must only retain local memory. It must not perform solver work, I/O or terminal
publication. The old display may replace nonfinite numbers with null; it is not the raw scientific
record. The assessment remains a non-wire Core display template, including its existing descriptive
paths; no legacy audit identity or equivalence with a reconstructed display is invented.

The exact checkpoint retains its original numerical graph. Separate native5 analysis HDF files
store `final_diagnostics` (complete raw metrics, witnesses and four integral arrays) and
`final_observations` (actual coordinates/quadratures/scales/models, 26 stored arrays, two scalar
views, summary, issues and current restoration receipts). Complex coherences and IEEE bits are
preserved. Green/self-energy descriptors refer to the checkpoint; those arrays and kernels are not
copied into the observations file. Requested scattering flags remain separate from enabled
families and the electron-electron model. Missing views require explicit issues. A voltage
roundtrip difference keeps both samples with `not_verified`; it is not a numerical tolerance.

One manifest binds full FileRefs in the selected dependency DAG, including the original plan and
actual point model. Immutable files are closed, checked and hashed before the sink and the existing
recovery/live pointer updates. A sink or analysis failure before the first pointer keeps the old
heads and may leave immutable orphan files. After the first pointer, the two heads can identify
different valid generations; use the existing explicit reconciliation rules. Do not recapture or
replay a sink to repair an uncertain publication.

For `source_mode=:completed_restore`, pass the original loaded terminal and already obtained
current Core receipts; the recorder must hold the explicit immediate verified parent. Original
Core identity, integrity and final evidence remain distinct from the child envelope and current
revalidation. The writer does not perform that numerical revalidation. A produced state after an
ordinary interrupted resume may also have parent lineage without completed receipts.

`verify_final_artifacts(checkpoint; diagnostics_ref, observations_ref, maximum_metadata_bytes,
parent=nothing)` verifies explicit selected references, native storage and declarations without
loading numeric state, getters, restore or a map. Supply the immediate verified `parent` for a
completed-restored carrier. The metadata allowance is shared across selected inputs and native
strings. Hash verification still reads the selected immutable files. Successful verification is a
frozen selection, not protection against later external file changes or scientific acceptance.

`maximum_observation_bytes` bounds Core's additional observation estimate. It is not a total memory
cap. The writer also checks the actual production memory grant against the jointly resident caller
and recorder graph, Core's additional estimate, bounded metadata and serialization buffers. The
composition must account for other retained residents in that grant. These allowances exclude a
claim about compiler/allocator RSS. This API alone does not complete the remaining solver/CLI
composition migration or the independent Results interoperability and scientific qualification.

## Native caller composition and explicit checkpoint inputs

The native stationary caller passes the same original `FinalPointRequest` into
intermediate `commit_exact_checkpoint!` calls with an admitted `maximum_metadata_bytes`.
Those manifests inventory the exact original plan and canonical P03 model FileRefs.
The checkpoint declaration, numerical layout and return type remain unchanged.
`verify_checkpoint_inputs` takes explicitly selected plan/model refs; it checks their
manifest membership, roles, immutable bytes, original plan digest and canonical model
preimage digest. It establishes byte/source binding. It does not establish resolver
provenance or physical acceptance. A4 checkpoint contexts still have null model/plan;
Runner/Q1/actor verification of the selected pair occurs separately before A4.

```@docs
verify_checkpoint_inputs
```

Direct native file output requires `source_configuration`, the original or first
emitted `frozen_plan_bytes`, and the actual `source_graph`. A manually constructed
`NEGFProblem` alone cannot supply a P03 provenance claim. Configured composition
captures the original nested plan before operational YAML rewrites and carries the
exact prepared execution pair. It neither selects execution twice nor changes the
selected production memory allowance. Deferred final publication retains only the
owned terminal state; Core validates against the actual returned `solution.problem`.

Native direct `history_observer(snapshot, it, iv)` receives a public
`ScientificHistorySnapshot`. The former six-argument private-Core observer signature
is retired; no synthetic source or arity fallback is supplied. Canonical history is
owned or sealed before the synchronous external callback. `checkpoint_observer(state,
it, iv)` remains a state observer: intermediate after native persistence, global final
after final commit. `native_publication_sink(triple, it, iv)` and
`final_presentation_sink(bundle, it, iv)` are separate optional composition ports after
successful final commit. The triple contains exactly checkpoint/diagnostics/observations;
the display bundle contains exactly stationary_assessment/validation/positivity.
Their synchronous failures propagate. The configured result uses that same detached
display; it does not recompute an assessment from stored metrics.

The outward records use series-v4/current-v2/configured result+status-v2. They carry
full native refs, with a separate phase locator and optional optical attachment;
legacy string receipts are never aliases. Scratch receives the exact returned v4
document and a separate metadata allowance, verifies selected native graphs at the
copied root, then renames and deletes scratch only on success. Disk budget is not RAM
authority. Metadata admission uses fresh hardware headroom or the explicit execution
envelope, current seven-root residents and existing buffer reservations. It is a
source allocation bound, not measured RSS.

The stationary entry gates remain pending same-DTO Results/export, AiiDA actor and
Q1 typed transport-close qualification. The native caller does not issue a legacy
stop receipt for v4, and missing transport evidence cannot mean success. Requested
optical processing still needs its native codec/provenance rollout; the strict legacy
optical-v4 verifier remains intact. Independent Core oracles, Results obligations and
native 26+4 interoperability remain release requirements.

For cold direct native calls, the captured configured run definition and public
coordinate traversal provide deterministic point identities, including an original
plan with reordered axes. An explicit `run_id` is an opaque caller override;
it supplies no model-origin proof. A selected parent keeps its original run,
execution and point scope. Supplied `native_context` identity remains unchanged.
Intermediate state-observer exceptions propagate after the canonical checkpoint;
cleanup seals only open healthy history and never replays a failed publication.

Native series output is exactly `qcl-negf-series-result-v4` with
`qcl-negf.results.v2` from producer through public writer/readback and staging.
Legacy `qcl-negf-series-result-v3`/`qcl-negf.results.v1` remains a separate
reader/writer dispatch; cross-pairs are refused and payloads are never relabeled.
Optional outward `evidence` is an array of unique strings, including empty strings;
objects, duplicate items and non-string items are rejected before staging effects.

Direct native metadata admission always uses the minimum of unchanged selected P,
fresh total memory and fresh available memory. Optional `execution_plan` supplies
only an additional restrictive memory ceiling; configured composition forwards its
already validated selected object. Identity-only `native_context` does not change G.
The plan is retained in existing resource roots and checked before observer traversal.
Because its type is loaded later in the module, the keyword declaration is untyped;
runtime accepts only `nothing` or `ExecutionPlan`. No plan or P is reconstructed.


### Explicit native input selection

`publish_native_selection!(artifact_root, result; selected_inputs,
maximum_metadata_bytes)` publishes the original terminal series-v4 bytes and
`native-selection.json`. The control is exactly `{version: 1, selected_inputs: [...]}`;
each row has `artifact_root`, the full `selected_state` StateRef, and the original
`plan` and `model` FileRefs. Supply exactly one row for each distinct nonabsent
(root, full StateRef), including attempt history. Publication orders rows by first
occurrence in points and then attempt history; sequence numbers alone never select
a state. Final input refs must match the original observations request.

The execution owner retains bounded input refs from its actual request and verified
checkpoint/final handle before releasing point state. The public publisher reopens
exact selected checkpoints, verifies original inputs and final artifacts through
the public native verifiers, and uses one aggregate metadata allowance. It retains
no numerical state and selects no input by role, filename or directory scan.
Missing retained-source input pairs are an error; no current creator is inferred.

The return has exactly `result` and `selection` operational claims, each containing
`path`, an integer `bytes` count and `sha256`. Successful return follows file sync,
exclusive publication and exact same-open readback. An identical retry reconciles;
a conflicting existing file is preserved and refused. Errors may leave partial
files or a completed first control without the second; this is not an atomic pair
transaction. Preserve the original failure and reconcile actual bytes before using
a subsequent acknowledgement.

These controls establish selected bytes only. They do not authorize native close,
a producer, retrieval or scientific acceptance. The stationary/configured entry
qualification fences remain. This increment adds neither scratch/recovery import
nor capture ingress. The later transport packet remains five files total: result,
selection, owner-close projection and the two stock scheduler logs.
