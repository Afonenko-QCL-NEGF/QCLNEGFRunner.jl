# [Scientific comparison](@id expert-comparison-workflow)

Compare material, geometry, operating point, physical mechanisms, boundary model,
algorithm and strict tolerances before comparing observables. Declare the intended
changed configuration paths in a controlled study. Preserve requested and effective
inputs, including any seed floor imposed by the energy grid.

A process that completed is not automatically a converged or accepted physical
result. Report iterative convergence, physical gates and discretization evidence
separately. Unmeasured quantities need a reason; they must not be replaced with zero.
Study-specific tolerances and comparison budgets belong in the research definition,
not in a generic package-wide claim of device accuracy.

Performance comparisons require identical scientific work and acceptance criteria,
recorded thread budgets, warm-up policy and completed calculations. Measure the
number of nonlinear iterations separately from time per iteration. More CPU usage
alone does not demonstrate less time to an accepted result.

## Compare saved report snapshots

`qcl-negf compare CATALOG.csv ANALYSIS_DIRECTORY --reference-id ID` and
`compare_saved_results(catalog, directory; reference_id)` only read saved catalog
and materialized summary CSV files. They never execute methods or derive optics.
Reference selection is explicit. The default total capture budget is 16 MiB;
`maximum_input_bytes` (CLI `--maximum-input-bytes`) adjusts this engineering limit.
The SHA256 and parser consume the same captured bytes. Use a separate analysis
directory that does not contain the input snapshots.

Finite nonnegative `temperature_atol` (K, default `1e-9`) and `voltage_atol`
(V, default `1e-12`) locate serialized points; zero means exact matching.
Invalid caller values or Float64 overflow are rejected before reading inputs.
CLI options are `--temperature-atol` and `--voltage-atol`. Both actual coordinate
pairs, signed deltas, tolerances, source paths and hashes appear in provenance.

The returned `analysis_status` is `:completed` or `:partial`; either has CLI exit 0
and means only analysis execution. Missing/nonfinite metrics and unmatched points
appear in coverage. No finite matched pair, absent files or required columns,
or a reference-only catalog yield `insufficient_data` and CLI exit 2. Ambiguous
coordinates and incomparable declared structure/signatures are rejected. Raw
failed statuses, warnings and nonfinite observations remain in the point report.
A zero reference has a missing relative difference. Missing timing remains missing;
estimated memory remains labelled estimated.

Provenance scope is `declared_saved_report`. Native execution/attempt/branch/order/
commit identity and scientific assessments are unavailable. Declared physics
signatures do not verify all resolved inputs, grids, tolerances or experimental
comparability. Failed finite points provide descriptive diagnostics only; even
converged differences are not an independent accuracy oracle. Archived optical
metrics confer no quantitative optical acceptance.

`run_comparison_study` remains a deprecated compute-and-report wrapper and warns
before executing declared methods × repetitions. `run_convergence_study` and
`run_production_study` also compute explicitly. This saved frontend does not alter
the lower-level `compare_method_runs` or `generate_expert_report` contracts.
