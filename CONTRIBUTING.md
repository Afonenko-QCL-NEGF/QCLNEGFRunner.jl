# Contributing

For documentation-only text or link corrections, review the diff and check the
changed links, anchors and formatting. This does not require Julia, package
installation, a full test suite or documentation generation. Record numerical and
rendering checks that were not run. Executable examples, documentation build
recipes and public API changes need the relevant checks for their behavior.

For code changes, run relevant targeted checks in the prepared environment.
`deno task check` checks the TypeScript orchestration; it does not test Runner's
runtime behavior. `deno task test` runs Julia tests, and `deno task docs` runs the
Julia documentation generator; both may instantiate dependencies when no prepared
project is selected. Environment preparation, the full suite and documentation
generation belong to their assigned stages with a finite shared budget. Missing
runtime is a reported check limitation, not permission to mark a check as passed.

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
