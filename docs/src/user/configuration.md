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

The CLI writes scientific result JSON to stdout and artifacts below the output
directory. Exit code 0 means successful process completion. Inspect scientific
status and point quality before treating a result as accepted. Invalid arguments
and configuration errors produce exit code 2.


Resource discovery and admission are described in [resource limits](@ref resource-planning).
Numerical meaning, units and convergence criteria are documented by
[QCLNEGF.jl](https://github.com/AfonenkoA/QCLNEGF.jl/tree/main/docs/src).

## Node-local scratch

`qcl-negf run-plan PLAN OUTPUT --scratch-root /absolute/local/scratch` runs in
a unique local directory and copies a closed result tree to a fresh destination.
Runner verifies copied bytes and native commit manifests, then publishes the
destination directory. The destination must not already exist.

On computation or transfer failure, the local workspace is retained and its path is
reported on stderr. This option starts a fresh execution; explicit restart uses the
normal execution path and compatible checkpoint state. It does not merge results
or turn an incomplete calculation into an accepted one.
