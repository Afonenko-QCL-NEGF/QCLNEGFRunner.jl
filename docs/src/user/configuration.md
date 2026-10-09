# [Run configurations](@id yaml-run-configurations)

A run configuration is a YAML file with dimensional physical quantities, numerical
grids, scattering models, convergence policy and output settings. Load one or more
ordered files with `load_run_configuration`; later files override explicit fields.
The schema is `schema/run.schema.json`. The checked example is
`examples/config/reference-2019-70k.yaml`.

## [Scientific plans](@id scientific-plans)

A `qcl-negf-study-v2` definition names configuration sources, variants and operating
points. Temperature and voltage axes must be explicit; no device-specific operating point is assumed. `qcl-negf plan examples/config/operator-algebra.yaml` emits an immutable
`qcl-negf-scientific-plan-v2` JSON plan. Store this plan as an AiiDA input.
`qcl-negf run-plan plan.json result --execution-id ID` runs one declared execution;
ID must be an entry from `plan.executions`, never an unrelated process identifier.
Continuation points within that execution remain sequential.

Voltage policy accepts `independent` (the default, no predecessor reuse) and `strict`.
Strict reuse requires consistent final whole/inner convergence and quality plus
ready Core stationary assessment with its known registry version and all four
stationary certificate flags true. Live reuse also requires the actual final
report to pass; completed restore reads the retained assessment from a verified
native commit and checks original final flags against commit and series metadata.
Operational `restart` is not a final convergence verdict. This gate is separate
from inner SCBA→Poisson permission and from campaign discretization or experimental
validation; `not_measured` is not promoted to pass.

Legacy voltage `research` finite-predecessor policy is retired with an explicit
error. This is a breaking boundary for typed frozen-plan load, re-execution,
resume, and Runner helpers that load such plans. Choose a new explicit strict or
independent plan with a new identity; existing fingerprints, statuses, qualities
and warnings are not rewritten or automatically migrated. Independent Results
readers and raw archive inspection remain separate from executable typed loading.
Compatibility with every historical archive schema has not been established.
Existing invalid-predecessor `cold_start`/`skip` behavior and complete S06 branch
failure acceptance remain separate work; retirement does not establish that gate.

The CLI writes scientific result JSON to stdout and artifacts below the output
directory. Exit code 0 means successful process completion. Inspect scientific
status and point quality before treating a result as accepted. Invalid arguments
and configuration errors produce exit code 2.


Resource discovery and admission are described in [resource limits](@ref resource-planning).
Numerical meaning, units and convergence criteria are documented by
[QCLNEGF.jl](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/tree/main/docs/src).

## Node-local scratch

`qcl-negf run-plan PLAN OUTPUT --scratch-root /absolute/local/scratch` runs in
a unique local directory and copies a closed result tree to a fresh destination.
Runner verifies copied bytes and native commit manifests, then publishes the
destination directory. The destination must not already exist.

Staging uses the selected execution's existing `output.recovery.byte_budget` and
`reserve_bytes` as its operational policy even when periodic recovery is disabled.
For several selected executions it uses the smallest budget and largest reserve;
an incompatible combination is rejected before computing. Recovery-enabled plans
publish directly to output storage and bypass end-only scratch staging.

`stage_result_tree(SOURCE, DEST; byte_budget=8*1024^3, reserve_bytes=64*1024^2)`
counts the simultaneous logical bytes of the closed source and pending destination
copy, plus the reserve. Each controlled copy write checks projected growth and
observed destination free space. Refusal does not replace an existing destination
or alter the source, and removes only its own incomplete staging directory.
This is a logical copy guard, not a filesystem quota or an aggregate limit on
unrelated scratch directories, logs, AiiDA retrieval or concurrent writers.

On computation or transfer failure, the local workspace is retained and its path is
reported on stderr. This option starts a fresh execution; explicit restart uses the
normal execution path and compatible checkpoint state. It does not merge results
or turn an incomplete calculation into an accepted one.
