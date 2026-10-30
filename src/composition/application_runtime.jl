"""
Composition root for the solver-independent, content-addressed sweep runtime.

Application ports and coordination live under `application/`.  This outer
module is deliberately the only place that wires those ports to the default
YAML/filesystem persistence adapters.
"""
module QCLApplicationRuntime

using SHA
using YAML

include("../application/contracts.jl")
include("../presentation/downsampling.jl")
include("../application/events.jl")
include("../application/coordinator.jl")
include("../infrastructure/persistence/atomic_files.jl")
include("../infrastructure/runtime/filesystem_repository.jl")

export SweepAxis,
    AbstractSweepSpec,
    SweepLeaf,
    SweepLevel,
    NestedSweepPlan,
    SweepPoint,
    point_count,
    planned_points,
    foreach_sweep_point,
    RunIdentity,
    RunDefinition,
    derive_run_identity,
    canonical_bytes,
    content_id,
    file_sha256,
    fingerprint_sources,
    run_definition_dict

export IterationRetentionPolicy,
    should_retain_snapshot,
    retained_snapshot_count,
    DisplayDownsamplingPolicy,
    downsample_series,
    DiskBudgetModel,
    DiskEstimate,
    estimate_disk,
    disk_estimate_dict

export AbstractRunRepository,
    FilesystemRunRepository,
    run_directory,
    initialize_run!,
    read_point_status,
    write_point_status!,
    default_run_repository,
    run_workspace_directory,
    point_workspace_directory,
    write_point_result!,
    read_point_result,
    append_event!,
    read_events,
    write_provenance!,
    write_disk_estimate!,
    read_run_result,
    write_run_status!,
    point_result_sha256,
    write_run_result!,
    write_timing_session!,
    aggregate_timing_sessions!

export AbstractCheckpointCodec,
    YamlCheckpointCodec,
    CallbackCheckpointCodec,
    CheckpointReference,
    LoadedCheckpoint,
    CheckpointIntegrityError,
    save_runtime_checkpoint!,
    ArtifactIntegrityError,
    load_latest_checkpoint,
    default_checkpoint_codec,
    verify_result_artifacts!

export RuntimeTracer,
    SpanToken,
    start_span!,
    end_span!,
    with_span,
    emit_runtime_event!,
    core_timing_summary,
    flush_timing_summary!

export AbstractPointRunner,
    FunctionPointRunner,
    PointExecutionContext,
    PointExecutionResult,
    execute_point!,
    checkpoint!,
    record_iteration!,
    SweepInterrupted,
    SweepRunSummary,
    run_sweep!

end # module QCLApplicationRuntime
