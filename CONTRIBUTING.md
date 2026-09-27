# Contributing

Run `deno task check`, `deno task test` and `deno task docs` before proposing a change.
Test adapters through supported public entry points. Configuration must reject
unknown fields and invalid units; persisted state must preserve scientific identity,
checksums and exact-restart requirements. Test corrupt and incompatible input as
well as successful execution.

Keep numerical equations and in-memory model types in QCLNEGF.jl. Runner may depend
on core; core must not depend on Runner. Coordinate format changes with
qcl-negf-contracts, qcl-negf-results and qcl-negf-aiida. A successful process exit
must not be promoted into scientific acceptance. Do not embed deployment hosts,
credentials, scheduler queues or organization-specific study definitions in code.

Integration CI is defined in the [qcl-negf superproject](https://github.com/Afonenko-QCL-NEGF/qcl-negf) and uses its local runner. Update the component gitlink there to check a change with the complete selected source graph.
