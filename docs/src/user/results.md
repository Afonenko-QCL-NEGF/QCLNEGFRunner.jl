# [Results and restart](@id native-result-formats)

The result contract set is `qcl-negf.results.v1`; native HDF5 layout is version `4.0`.
A commit manifest binds artifacts to SHA-256 checksums. Native physics, analysis
frames and recovery state serve different purposes. An analysis result does not
necessarily contain enough state to continue a nonlinear iteration exactly.

HDF5 is a required Runner dependency.
A full checkpoint contains the compatible numerical state, algorithm history and
consumed iteration budget. Exact restart checks model, grids, algorithms and stored
identity before accepting that state. Corrupt or incompatible state is an error;
it must not silently become a fresh calculation.
The exact numerical contract requires all current algorithm and solver fields,
including the explicit `algorithms.elastic_retarded` selection.

## [Quality and continuation](@id solver-quality-contract)

Process completion, iterative convergence, physical gates, discretization evidence
and experimental validation are separate claims. Check the point's status, quality,
residuals and reasons for missing metrics. An explicitly permitted approximate inner
solution must remain marked approximate. Restart preserves consumed work and
logical iteration counters rather than resetting a budget.

Periodic checkpoints require explicit checkpoint/output settings. A process killed
before a verified checkpoint is committed cannot promise exact recovery. Use a
separate output directory for each independent execution.

Configured and scientific runs save recovery at accepted SCBA or outer boundaries.
Checkpoint cadence, recovery deadlines and cooperative pause requests preserve
the solver's native physical-marker cadence. Native results encode an unmeasured
optional marker with `physical_markers/available = 0`, and the restart reader
restores it as `nothing`.

A stationary point's first generation in an artifact directory always writes
`analysis.h5`. Scientific plan resumes use a new attempt directory, so its first
checkpoint also writes analysis. Later recovery-only generations reference the
latest analysis-producing commit in that directory by relative path and SHA-256.
The `restart_coordinates` describe the newly saved state. The `analysis_coordinates`
in the analysis-producing commit describe its frame. An analysis frame can contain
unmeasured optional markers.

## Postprocessing

`qcl-negf analyze RESULT_DIRECTORY ANALYSIS_DIRECTORY` reads saved results without
rerunning transport. Reports preserve the input identity and scientific statuses.
The separate [qcl-negf-results](https://github.com/Afonenko-QCL-NEGF/qcl-negf-results) project
provides Python readers and exports. Schema changes are coordinated with
[qcl-negf-contracts](https://github.com/Afonenko-QCL-NEGF/qcl-negf-contracts).
