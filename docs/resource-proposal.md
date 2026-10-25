# Bounded resource forecast

`qcl-negf resource-proposal --runner-source-id ID --core-source-id ID` reads a
bounded JSON request and returns a separate forecast; it never rewrites a frozen
scientific plan, solves, calibrates, discovers worker inventory or reserves CPU/RAM.
The controller binds the exact installed Runner/Core source identities. Stdin is
limited to 5MiB, the raw plan to 4MiB, response to 1MiB, candidate cap to 256,
executions to 64 and points to 256. Limits refuse, never truncate scientific inputs.

Request has exactly `plan` (the original frozen JSON string), `plan_sha256`,
`expected_runner_source_id`, `expected_core_source_id`, `target`,
`candidate_cpu_max`, `runtime_margin_policy`. The owning frozen-plan loader checks
the raw SHA, full/scientific fingerprints, resolved configurations and membership.
The six target fields are `logical_cpu_limit`, `memory_limit_bytes`,
`available_memory_bytes`, `affinity_limit`, `quota_full_cpu_limit`,
`resource_policy_id`. Numeric target capacities are finite nonnegative integers;
unknown/fractional full-core limits are unavailable and zero capacity refuses.
They mean already-admitted per-allocation net capacities. Host/foreign reserves
are never subtracted again, and this adapter does not establish their freshness.

`runtime_margin_policy` is null or exactly `{policy_id,policy_sha256}`. A selector
is not approval. Positive forecast additionally requires an installed immutable
policy loaded with the all-or-none trusted CLI suffix
`--runtime-id ID --margin-policy-file FILE --margin-policy-sha256 SHA`.
FILE is a normalized absolute regular file with no symlink ancestors, at most
64KiB. It is a trusted read-only installed asset selected by the command producer,
never a browser path. Raw file SHA is checked against trusted argv before strict
JSON decoding; no package/module is loaded from it. Missing/invalid binding stays
`memory_forecast_unavailable` with a bounded detail and no private path disclosure.

Installed policy schema `qcl-negf-runtime-margin-policy-v1` has exactly `schema`,
`policy_id`, `runner_source_id`, `core_source_id`, `runtime_id`, `plan_sha256`,
`maximum_solver_threads`, `maximum_hard_memory_bytes`, `coverage_contract`,
`runtime_upper_bytes`, `allocator_retention_upper_bytes`, `confidence`,
`approval_ref`, `calibration_ref`. SHA fields are lowercase 64hex; finite strings
are nonempty and have no controls (256-byte cap, policy ID128). Threads are 1..256;
all three byte caps are positive representable integers. Coverage must be
`disjoint_non_numerical_v1`. Confidence is `approved_conservative_uncalibrated`
with null calibration, or `calibrated_within_scope` with exact
`{artifact_sha256,locator}`. These are retained owning evidence references, not
measurements made by forecast. No production allowance is provided by this source.

Policy scope binds exact raw plan SHA, installed Runner/Core/runtime identities,
maximum requested solver threads and hard bytes, including every resolved point
and declared adaptation/output cap. Numerical workspaces already in the estimator
are excluded from the two disjoint allowances: runtime r includes all omitted
live runtime/native/HDF/audit/JIT/stack costs; allocator a covers only retained
unused capacity/fragmentation. Unsupported overlap is unavailable.

The same pure margin checker preserves the existing three memory boundaries:

- Auto without envelope: existing `(B,S)=_effective_memory_budget(...)`, require
  `r+a<=S` and numerical q<=B. Overhead is covered inside S; it is not subtracted
  again. S is based on admitted total T, and B=min(T-S,A-S). S-r-a remains reserve.
- Manual without envelope: preserve P and require checked `P+r+a<=min(T,A)`,
  q<=P. No generic reserve and no silent P reduction. In current JSON configuration
  schema P is the default `typemax(Int)`; ordinary frozen manual plans therefore
  conservatively fail this finite fit. Existing typed callers may supply a finite
  P through production options; the source does not add a new configuration leaf.
- Trusted existing envelope: require r<=runtime partition, a<=allocator partition,
  use `min(plan budget,envelope numerical)`, reserve0. No second overhead/current
  RSS subtraction and no reallocation of partition slack or unassigned hard bytes.

For each C from the safe maximum down to1, the adapter reuses existing equivalent
production strategy candidates with BLAS1 and checks every actual resolved point.
Explicit manual thread/BLAS/worker settings are preserved or refused. Scientific
estimate includes declared adaptive-domain/retained-state caps and is evaluated at
explicit target capacity; the maximum sequential point need is reported, never the
sum of per-point runtime overhead. There is no walltime/speedup prediction.

Response `qcl-negf-resource-proposal-v1` has decision kind `forecast`, immutable
plan/source bindings, selected requested threads/R, historical preview estimates,
point forecasts/strategy/margin breakdown, confidence and headroom. A positive
forecast is `status="available"` but remains `launch_allowed=false` with reason
`shared_grant_unavailable`; `allocated_cpus_upper`, allocation policy digest and
width binding remain explicitly unknown. Solver threads are not Slurm AllocCPUS.
Existing DTO integer tags retain values outside JavaScript's safe range.

Planning's default `scientific_memory_estimate` capacity remains Sys.CPU_THREADS.
Runtime uses its existing effective capacity expression or explicit envelope pool;
no thread/affinity resizing occurs. Optional internal `margin_context` consists of
the immutable installed policy and original entry bytes captured by the private
`_resource_bind_entry(raw,policy,runner_source_id,core_source_id,runtime_id)` port.
It derives SHA from those bytes, verifies the owning load, and keeps the raw String
in an immutable entry. At execution, bytes are checked/reloaded independently and
the validated load result is compared with the actual typed plan before output
setup. Typed plans with a plain metadata context refuse `actual_raw_entry_required`;
serializing a typed plan is never treated as original raw SHA. Non-null invalid
context refuses; null legacy is
unchanged and is not claimed I06-safe. Stationary preparation uses the same strategy
and margin checker against observed hardware before scientific allocations, and
records the margin in the existing reservation metadata. Non-stationary diagnostics
bypass that legacy reservation seam, so non-null context currently refuses them.
Future launch-owner propagation and fresh native admission are separate gates;
public run-plan/staged launch is not changed to synthesize this context.

Focused source controls live in `test/focused/resource_proposal.jl`; executing them
requires the coordinator's finite prepared-environment gate. No installation,
solver, HDF arrays, native inventory or calibration is needed by these controls.
