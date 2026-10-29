```@meta
CurrentModule = QCLNEGFRunner
```

# Public API

## [Choose an entry point by task](@id reader-api-routes)

| Reader goal                                 | Start here                                                                                                                                                                                                      | Expected boundary                                                                                                                  |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Explain a resolved field and its assignment | [Configuration route](@ref developer-configuration-route), [`load_run_configuration`](@ref), [`configuration_source`](@ref), [`resolve_execution_strategy`](@ref)                                               | Loading and provenance lookup do not run transport; assignment history and an effective execution plan remain distinct.            |
| Interpret a saved point                     | [Quality contract](@ref solver-quality-contract) and [Core criterion reference](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/f5b73369a96d1225bd96fb34f5262c8dcf965f86/docs/src/theory/12_validation.md) | Read status, applicability, measured/missing metrics and exact attempt identity; saved analysis cannot create scientific evidence. |
| Continue an interrupted execution           | [Recovery route](@ref operator-recovery-route), `open_exact_checkpoint`, `load_exact_solver_state`                                                                                                              | The typed reader verifies result-v2/native5 state; Core admits the reconstructed state. Solver/CLI migration belongs to P05.       |

The tables below retain the full expert API, including explicit optical operators. Their presence
does not promise quantitative gain/absorption validation in this release. Schema ownership stays in
Contracts, numerical criteria in Core, and file/recovery orchestration in Runner.

## Types and operations

```@docs
ExecutionConfiguration
ProgressOutputConfiguration
DeviceGeometryConfiguration
OutputConfiguration
ConvergenceStudyConfiguration
StudyMethodConfiguration
StudyConfiguration
ResolvedRunConfiguration
ConfigurationProvenance
ConfigurationError
ConfiguredProblem
ConfiguredRunResult
ConfiguredExecutionResult
ProductionStudyResult
ProgressMetric
ProgressSnapshot
ProgressReporter
ScientificHistoryRecorder
open_exact_checkpoint
load_exact_solver_state
commit_exact_checkpoint!
MethodDescriptor
MethodPoint
MethodRun
MethodComparisonRow
ExpertComparison
run_production_sweep
load_run_configuration
configuration_source
resolved_configuration_dict
physical_parameters
numerical_parameters
solver_options
production_options
algorithm_options
configuration_output_directory
configure_execution!
build_configured_problem
run_from_configuration
run_comparison_study
run_convergence_study
run_production_study
save_checkpoint
load_checkpoint
load_production_restart
save_production_summary
save_optical_response
save_kernel_diagnostics
plot_band_profile
plot_spectral_map
plot_convergence
plot_current_spectrum
plot_conditioning
plot_reference_figure3a
plot_reference_iv
plot_reference_gain
compact_number
latest_progress
begin_progress_stage!
update_progress!
end_progress_stage!
save_progress_snapshot
save_progress_dashboard
load_method_run
load_method_catalog
compare_method_runs
save_expert_report
generate_expert_report
plot_method_comparison
save_production_study_plots
```

## Extension contracts

```@docs
AutomaticExecutionConfiguration
DEFAULT_CONFIGURATION_SCHEMA
default_configuration_schema
ValidatedConfigurationDocument
HardwareProfile
ExecutionPlan
ExecutionCalibrationSample
ExecutionCalibrationReport
validate_configuration_schema
validate_configuration_source
load_configuration_source
probe_hardware
execution_plan_candidates
select_execution_plan
calibrate_execution_plan
resolve_execution_strategy
hardware_profile_dict
execution_plan_dict
execution_calibration_dict
save_execution_plan
save_hardware_profile
save_execution_calibration
save_resource_diagnostics
DEFAULT_MAXIMUM_SOLVER_RUNS
planned_solver_runs
execute_configured_run
QCLApplicationRuntime
SweepAxis
AbstractSweepSpec
SweepLeaf
SweepLevel
NestedSweepPlan
SweepPoint
point_count
planned_points
foreach_sweep_point
RunIdentity
RunDefinition
derive_run_identity
IterationRetentionPolicy
DisplayDownsamplingPolicy
DiskBudgetModel
DiskEstimate
estimate_disk
AbstractRunRepository
FilesystemRunRepository
AbstractCheckpointCodec
YamlCheckpointCodec
CallbackCheckpointCodec
CheckpointIntegrityError
ArtifactIntegrityError
verify_result_artifacts!
RuntimeTracer
AbstractPointRunner
FunctionPointRunner
PointExecutionContext
PointExecutionResult
SweepRunSummary
checkpoint!
record_iteration!
run_sweep!
QCLProductionPointRunner
configured_nested_sweep_plan
configured_nested_run_definition
run_configured_nested_sweep
QCLApplicationRuntime.CheckpointReference
QCLApplicationRuntime.LoadedCheckpoint
QCLApplicationRuntime.SpanToken
QCLApplicationRuntime.SweepInterrupted
QCLApplicationRuntime.append_event!
QCLApplicationRuntime.canonical_bytes
QCLApplicationRuntime.content_id
QCLApplicationRuntime.emit_runtime_event!
QCLApplicationRuntime.file_sha256
QCLApplicationRuntime.fingerprint_sources
QCLApplicationRuntime.flush_timing_summary!
QCLApplicationRuntime.initialize_run!
QCLApplicationRuntime.load_latest_checkpoint
QCLApplicationRuntime.save_runtime_checkpoint!
ConfiguredReportTemplate
ConfiguredReportArtifact
ConfiguredReportSection
ConfiguredReportContext
AbstractConfiguredReportRenderer
MarkdownConfiguredReportRenderer
CONFIGURED_REPORT_SECTIONS
configured_report_arguments
load_configured_report_template
configured_report_context
render_configured_report
QCLNEGFRunner.QCLExecutionPolicy.ExecutionEnvelope
QCLNEGFRunner.QCLExecutionPolicy.default_execution_envelope
QCLNEGFRunner.QCLExecutionPolicy.default_hardware_profile
```

## Models and scientific workflows

```@docs
QCLNEGFRunner.QCLScientificWorkflow.ScientificPointResult
QCLNEGFRunner.QCLScientificWorkflow.postprocess_series
QCLNEGFRunner.QCLScientificWorkflow.render_saved_snapshot
QCLNEGFRunner.QCLScientificWorkflow
QCLNEGFRunner.QCLScientificWorkflow.load_scientific_plan
QCLNEGFRunner.QCLScientificWorkflow.resolve_scientific_plan
QCLNEGFRunner.QCLScientificWorkflow.VoltageContinuation
QCLNEGFRunner.QCLScientificWorkflow.ScientificPoint
QCLNEGFRunner.QCLScientificWorkflow.ScientificOutputs
QCLNEGFRunner.QCLScientificWorkflow.execute_scientific_plan
QCLNEGFRunner.QCLScientificWorkflow.write_scientific_plan
QCLNEGFRunner.QCLScientificWorkflow.differential_conductance
QCLNEGFRunner.QCLScientificWorkflow.write_scientific_result
QCLNEGFRunner.QCLScientificWorkflow.is_scientific_definition
QCLNEGFRunner.configured_resource_plan
```

## Numerical solve adapter

`QCLNEGF.solve_production` accepts an in-memory checkpoint callback. Runner adds durable checkpoint
paths and compatible restart handling.

```@docs
QCLNEGFRunner.solve_production
```

## Command-line execution and scratch staging

```@docs
QCLNEGFRunner.main
QCLNEGFRunner.execute_scientific_plan_staged
QCLNEGFRunner.stage_result_tree
scattering_options(::ResolvedRunConfiguration)
```

## Saved comparison

```@docs
QCLNEGFRunner.compare_saved_results
```

This API reads bounded legacy report snapshots and returns descriptive differences, coverage, hashes
and analysis status. It cannot supply native full identity or scientific acceptance.
`run_comparison_study`, `run_convergence_study` and `run_production_study` execute computations;
`plan`/`run-plan` are the explicit plan creation/execution CLI route. CLI `compare` performs saved
analysis only.

## Resolved configuration snapshot

The following Runner APIs perform configuration/metadata work only. They never solve or admit work.

```@docs
ResolvedConfigurationSnapshot
resolved_configuration_snapshot
resolved_snapshot_dict
resolved_configuration_diff
scientific_resource_estimate
```

## Typed scientific persistence (result v2 / native5)

These operations consume the public Core state types. They perform persistence only and do not
invoke a solve, completed-map evaluation or scientific acceptance. Schema/registry ownership remains
in Contracts; exact numerical admission remains in Core. See [Results and restart](@ref
native-result-formats) for pins, ordered catalogs and pointer semantics.

```julia
ScientificHistoryRecorder(directory; artifact_root, identity, source_epoch, provenance, status,
    maximum_scba_rows, parent_checkpoint=nothing, maximum_buffer_records=1000,
    maximum_buffer_bytes=1048576, flush_interval_seconds=30, clock_ns=time_ns,
    resource_policy=:standalone, storage_context=nothing)
record_scientific_history!(recorder, snapshot::QCLNEGF.ScientificHistorySnapshot)::Nothing
flush_scientific_history!(recorder)::Dict{String,Any} # detached canonical HistoryPin
commit_exact_checkpoint!(recorder, problem::QCLNEGF.NEGFProblem, state::QCLNEGF.ExactSolverState;
    options, production_options, execution, domain_adaptation, kernel_options, status,
    closed=false, publication_hook=stage->nothing)::VerifiedExactCheckpoint
open_exact_checkpoint(artifact_root, state_ref; maximum_metadata_bytes)::VerifiedExactCheckpoint
open_exact_checkpoint(artifact_root, pointer_relative::AbstractString;
    expected_identity, maximum_metadata_bytes)::VerifiedExactCheckpoint
checkpoint_reference(checkpoint)::Dict{String,Any} # detached canonical StateRef
load_exact_solver_state(checkpoint)::QCLNEGF.ExactSolverState
```

`VerifiedExactCheckpoint` is created by commit/open, not by a caller-supplied proof dictionary. The
artifact root must already exist. Recorder metadata is frozen at construction; each invocation owns
a fresh namespace. `maximum_scba_rows` bounds compact current-stage RowKey/locator entries; buffer
limits bound current pending rows, not the complete exact-state payload. The current normal writer
accepts standalone owning storage with no storage context. Unsupported contexts fail explicitly;
removal of the obsolete strict resource mode belongs to its owning stage.

The pointer overload requires an explicit root-relative native5 pointer file and the expected full
source-attempt Identity. It resolves every FileRef against the same artifact root and returns the
existing verified handle. It never searches for another pointer or falls back after an error. A
history-only live manifest with `checkpoint=null` has no exact recovery capability and is refused.
Use the explicitly selected recovery pointer for the last exact cutoff. A pointer that changes
during verification is refused; updates after return do not change the captured immutable StateRef.

`maximum_metadata_bytes` is one aggregate input-read allowance for the call: pointer bytes, every
referenced JSON document, the bootstrap manifest and its repeated verified read, parsed native
identity/invocation JSON, and selected original-record JSON slices, including repeated ancestor
reads. Native scalar JSON must use fixed-length HDF5 string datasets with scalar dataspace; their
declared storage width, including padding, consumes the allowance before allocation. Variable-length
or other metadata types are unsupported by this bounded exact reader and are refused before a
payload read or variable-length size query. This is a Runner reader capability, not a change to the
Contracts native5 schema or scientific numeric dtypes. The allowance is per call; streamed native
file hashing, opaque HDF5 library memory and explicit full-state loading are separate costs. It is
not a process memory or lifetime history limit.

The required `status` carries independent process, convergence, physics, discretization and
experimental evidence states. It cannot be synthesized from process exit. `closed=true` requires a
terminal public final state and terminal process status. The full exact state and its histories
remain mandatory. After opening/loading, the consumer passes the actual problem, options and runtime
identity to Core's public restore API.

The production callback migration and native4/private bridge removal are P05 work. Existing legacy
production entry points do not forward into a fallback of this typed API.
