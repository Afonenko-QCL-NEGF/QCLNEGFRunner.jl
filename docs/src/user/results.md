# [Results and restart](@id native-result-formats)

The result contract set is `qcl-negf.results.v1`; native HDF5 layout is version `4.0`. A commit
manifest binds artifacts to SHA-256 checksums. Native physics, analysis frames and recovery state
serve different purposes. An analysis result does not necessarily contain enough state to continue a
nonlinear iteration exactly.

HDF5 is a required Runner dependency. A full checkpoint contains the compatible numerical state,
algorithm history and consumed iteration budget. Exact restart checks model, grids, algorithms and
stored identity before accepting that state. Corrupt or incompatible state is an error; it must not
silently become a fresh calculation.

## [Quality and continuation](@id solver-quality-contract)

Process completion, iterative convergence, physical gates, discretization evidence and experimental
validation are separate claims. Check the point's status, quality, residuals and reasons for missing
metrics. An explicitly permitted approximate inner solution must remain marked approximate. Restart
preserves consumed work and logical iteration counters rather than resetting a budget.

Periodic checkpoints require explicit checkpoint/output settings. A process killed before a verified
checkpoint is committed cannot promise exact recovery. Use a separate output directory for each
independent execution.

## Postprocessing

`qcl-negf analyze RESULT_DIRECTORY ANALYSIS_DIRECTORY` reads saved results without rerunning
transport. Its default operations are `iv`, `populations`, `density_map`,
`potential_map`, and `energy_density_map`; spectral transport maps remain included.
Default analysis does not request saved optical spectra or peak gain. This changes
the previous default, which also requested `gain_voltage` and `optical_map`.
Expert API callers can still select those operations explicitly with
`postprocess_series(...; operations=[...])`; `optical_recompute` retains its explicit
Unitful photon-energy and saved-full-state requirements. Missing optical data is
still reported as `insufficient_data` for an explicitly selected operation.
These expert optical projections do not establish quantitative gain validation.
Reports preserve the input identity and scientific statuses. The separate
[qcl-negf-results](https://github.com/Afonenko-QCL-NEGF/qcl-negf-results) project provides Python
readers and exports. Schema changes are coordinated with
[qcl-negf-contracts](https://github.com/Afonenko-QCL-NEGF/qcl-negf-contracts).

## Scientific archive, portable recovery, and telemetry

Scientific definitions and frozen plans have one canonical policy source:

```yaml
output:
  archive:
    full_final: true
    optical: false
    projections: true
    intermediate_history: 16
  recovery:
    enabled: true
    interval_seconds: 1800.0
    retain_generations: 2
    byte_budget: 8589934592
    reserve_bytes: 67108864
  telemetry:
    enabled: true
    buffer_events: 256
```

Every stationary solve which returns a state writes one immutable full final, including nonconverged
states, under `archive/EXECUTION/POINT/final/`. Pause and crash publish recovery, without inventing
a final. Skipped or pre-state failures record `full_state: null` and `state_absence_reason`.
`scientific_accepted` comes from the core assessment; successful publication and numerical
convergence do not establish discretization or experimental validation.

Legacy `outputs` fields are deterministically migrated with a warning. A legacy `full_state: false`
becomes mandatory `archive.full_final: true`. Defining both `output` and `outputs`, disabling
`full_final`, or supplying a conflicting scientific `output.save_full_state` override is an error.
The resolved run configuration contains a normalized execution alias; it is not an independent
scientific policy source.

`recovery/EXECUTION/POINT/` contains `current.json`, `previous.json`, and bounded immutable
generations. Each generation owns `physics.h5`, a hash-bound `recovery.json`, resolved
configuration, consolidated typed history when present, `commit.json`, and `receipt.json`. No
recovery generation depends on an earlier analysis generation. Copy the entire generation directory
for portable resume. Readers verify receipts and every declared artifact; corrupt latest falls back
to previous, and loss of both is an explicit error.

Publication closes and synchronizes files, atomically renames a generation, verifies the published
bundle, writes its receipt, advances pointers, and only then removes surplus generations.
Operational budget checks count retained recovery, pending publication, local attempt files, and the
reserve. Final archives have a separate free-space admission check and are never pruned to make
recovery fit. Filesystem quotas should enforce the configured limit on the installation; these
publication checks do not replace quotas for writes by external tools. Interrupted `pending-*`
directories are never resumable.

Before recovery publication and again before acknowledgement, the logical budget also reserves
the new receipt and atomic `current.json`/`previous.json` temporary files while counting their old
versions. Pointer bytes are serialized in advance. The receipt's `verified_unix` remains the actual
time after published readback: its fixed fields are serialized beforehand with a conservative
32-byte allowance for a finite Float64 timestamp token, and actual receipt serialization must fit
that allowance before writing. A metadata-budget refusal leaves the prior acknowledgement and
fallback pointer intact; a generation published before refusal is not selected by those pointers.
These publication-boundary checks do not limit every intermediate HDF5 write or concurrent
external growth. They establish logical accounting, not a filesystem quota or complete AC2.

`qcl-negf pause OUTPUT --execution-id ID --attempt N` writes an attempt-scoped request.
`verify-pause` with the same arguments verifies the resulting `pause-receipt.json`; `verify-stop`
also accepts a verified terminal execution with its final archives. A request from an older attempt
does not pause a newer one. The receipt declares `publication_scope: local_filesystem`: validation
from a different node and LAN rename/fsync durability still require infrastructure acceptance.

Pause and terminal proofs also verify the declared archives of earlier completed points without
copying them. Both verification commands accept `--archive-byte-budget BYTES` (default 64 GiB) for
this dependency check. The platform limit must match the configured job prefix limit; a larger
prefix is refused safely. `run-plan` uses its configured archive byte budget when acknowledging
pause or completion. The checker bounds manifest metadata at 16 MiB, verifies the complete declared
file set, and charges actual file sizes before opening or hashing numerical artifacts. This
verification bound does not replace final-archive capacity planning. Native HDF5 bundles reject
external or soft links, external raw storage, and virtual datasets so their declared file hashes own
the numerical payload.

Terminal verification checks every point in the frozen execution, each archive receipt, and its full
physical/history/model closure. The optional occupied spectral quantile estimator is unavailable in
this release; its reported status is `not_measured`, and its absence does not discard a returned
full state.

`qcl-negf run-plan PLAN OUTPUT --execution-id ID --attempt N --recovery-bundle DIRECTORY` imports
one self-contained bundle into a fresh attempt. `N` must exceed its source attempt; solver/mixer
state and used cumulative iteration coordinates are restored through the existing native restart
reader. The runtime and dependency contracts remain pinned. With recovery enabled, execution writes
directly to `OUTPUT`; end-only scratch staging is bypassed so pause can acknowledge durable storage
during execution.

Optics is a separate `optical.h5` beside the final. Its metadata embeds `source_state_receipt_json`
and `stationary_quality_json`; it does not rewrite Green/self-energy arrays. Bare-bubble output
remains a diagnostic and does not establish gauge invariance, lasing, or positive gain.

External telemetry uses the existing `qcl-runtime-event-v1` envelope. Set `QCL_TELEMETRY_ENDPOINT`
for opt-in HTTP JSON delivery, or pass `telemetry_sink` to the standalone API. The sender owns
independent scalar dictionaries, caps messages at 16 KiB, uses the configured event capacity, drops
events on overflow, and isolates collector failures. The observer neither waits for network I/O nor
creates a telemetry WAL; durable scientific histories and receipts remain separate. Existing local
progress/report outputs retain their own persistence behavior. HTTP delivery has a finite
five-second worker timeout; production collector/load/resource measurements require the target
infrastructure.

For multi-point recovery, a generation also contains hash-bound `execution_progress.json`. Its
completed-point entries bind prior final receipts and the exact required file closure. Supply
`--archive-bundle DIRECTORY` with `DIRECTORY/archive/EXECUTION/POINT/final/` for these prior finals;
the runner verifies them before solving and preserves their source attempts. Missing or corrupt
dependencies cause an explicit refusal, rather than re-running completed points.
`--archive-byte-budget BYTES` bounds this transfer separately (default 64 GiB), including the
publication reserve. Only declared required files are copied. The active recovery still has its own
8 GiB default operational budget.

`qcl-negf self-check` performs a three-node analytic principal-value kernel check and a tiny
temporary HDF5 round-trip. It verifies that the selected Julia release and storage runtime execute
on a node; its JSON explicitly leaves nonlinear, discretization, and experimental acceptance
unevaluated. It does not run SCBA or Poisson. `--directory DIRECTORY` selects the existing
temporary-file parent.

## Branch failure metadata

New branch warnings contain exactly `code`, `scope`, `reason_kind`,
`source_execution_id`, `source_point_id`, `source_attempt`, and `message`.
`BRANCH_STOPPED` records an observed cause on the terminal source;
`DEPENDENCY_UNAVAILABLE` preserves that exact causal attempt on an unrun
descendant, whose initialization still names its immediate predecessor.
Strict continuation admits only the existing Core final certificate. The default
stops the branch; explicit `cold_start` permits a cold suffix but does not erase
its earlier failure. Other independent executions follow the campaign policy.

Skipped rows have `quality: not_evaluated`, `full_state: null`, and
`state_absence_reason: solver_not_run`. Their required Boolean `converged: false`
is not a measured convergence result. An absent row after a hard kill remains
absent. Row counts include skipped metadata, not just scientific payloads.
Verified recovery into an explicitly authorized new attempt preserves the prefix
and cumulative budget. A completed immutable final is reused, including a
nonaccepted final; scientific retry needs a separate authorized identity.
Legacy warnings and historical attempts remain unchanged; an unknown legacy
reason is not inferred from prose. Raw conflicting or incomplete provenance is
refused before normalization or result replacement. These metadata checks do not
establish native recovery, discretization or experimental validation.
