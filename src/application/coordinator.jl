"""Solver adapter port invoked once for each content-addressed sweep point."""
abstract type AbstractPointRunner end

"""Adapter that turns a callable `context -> PointExecutionResult` into a port."""
struct FunctionPointRunner <: AbstractPointRunner
    callback::Function
end

execute_point!(runner::FunctionPointRunner, context) = runner.callback(context)

function execute_point!(runner::AbstractPointRunner, context)
    throw(MethodError(execute_point!, (runner, context)))
end

"""Result returned by the point-runner port."""
struct PointExecutionResult
    status::Symbol
    metadata::Dict{String,Any}
    artifacts::Dict{String,Any}
    function PointExecutionResult(
        status::Symbol;
        metadata = Dict{String,Any}(),
        artifacts = Dict{String,Any}(),
    )
        status in (:completed, :incomplete) ||
            throw(ArgumentError("point result status must be completed or incomplete"))
        new(status, _canonical_mapping(metadata), _canonical_mapping(artifacts))
    end
end

"""Explicit cooperative interruption used by batch schedulers and tests."""
struct SweepInterrupted <: Exception
    message::String
end

SweepInterrupted() = SweepInterrupted("sweep interrupted")
Base.showerror(io::IO, error::SweepInterrupted) = print(io, error.message)

"""Capabilities and resume state supplied to one point-runner invocation."""
mutable struct PointExecutionContext
    definition::RunDefinition
    point::SweepPoint
    attempt::Int
    repository::AbstractRunRepository
    checkpoint_codec::AbstractCheckpointCodec
    tracer::RuntimeTracer
    retention::IterationRetentionPolicy
    resume_checkpoint::Union{Nothing,LoadedCheckpoint}
end

"""Commit a solver checkpoint through the application checkpoint port."""
function checkpoint!(
    context::PointExecutionContext,
    state;
    kind::AbstractString = "iteration",
    iteration = nothing,
    metadata = Dict{String,Any}(),
)
    return save_runtime_checkpoint!(
        context.repository,
        context.checkpoint_codec,
        context.definition.identity.run_id,
        context.point.point_id,
        context.attempt,
        state;
        kind,
        iteration,
        metadata,
    )
end

"""
Persist every scalar iteration event. If `state` is supplied, only the
expensive state payload follows the configured snapshot retention policy.
"""
function record_iteration!(
    context::PointExecutionContext,
    iteration::Integer,
    total::Integer,
    metrics;
    phase::AbstractString = "iteration",
    state = nothing,
    state_metadata = Dict{String,Any}(),
    terminal::Bool = false,
)
    iteration >= 1 || throw(ArgumentError("iteration must be positive"))
    total >= iteration || throw(ArgumentError("total must be at least iteration"))
    metric_mapping = _canonical_mapping(metrics)
    emit_runtime_event!(
        context.tracer,
        :iteration;
        span_class = :physical,
        name = phase,
        status = :progress,
        attributes = Dict{String,Any}(
            "point_id" => context.point.point_id,
            "attempt" => context.attempt,
            "iteration" => Int(iteration),
            "total" => Int(total),
            "fraction" => Float64(iteration / total),
            "metrics" => metric_mapping,
            "state_snapshot_retained" =>
                state !== nothing &&
                should_retain_snapshot(context.retention, iteration; total, terminal),
        ),
    )
    if state !== nothing &&
       should_retain_snapshot(context.retention, iteration; total, terminal)
        return checkpoint!(
            context,
            state;
            kind = "iteration_snapshot",
            iteration,
            metadata = state_metadata,
        )
    end
    return nothing
end

"""Terminal counts and result location of one coordinated sweep session."""
struct SweepRunSummary
    run_id::String
    status::Symbol
    point_count::Int
    completed::Int
    incomplete::Int
    failed::Int
    interrupted::Int
    skipped_completed::Int
    result_path::String
end

function _coordinate_result(point::SweepPoint)
    return Dict{String,Any}(name => deepcopy(value) for (name, value) in point.coordinates)
end

function _point_status_mapping(
    definition::RunDefinition,
    point::SweepPoint,
    status::Symbol,
    attempt::Int;
    message::AbstractString = "",
    checkpoint = nothing,
    result_sha256 = nothing,
)
    checkpoint_mapping =
        checkpoint === nothing ? nothing :
        Dict{String,Any}(
            "generation" => checkpoint.generation,
            "attempt" => checkpoint.attempt,
            "kind" => checkpoint.kind,
            "iteration" => checkpoint.iteration,
            "sha256" => checkpoint.sha256,
        )
    return Dict{String,Any}(
        "schema" => "reference2019-point-status-v1",
        "run_id" => definition.identity.run_id,
        "point_id" => point.point_id,
        "ordinal" => point.ordinal,
        "leaf" => point.leaf,
        "coordinates" => _coordinate_result(point),
        "status" => String(status),
        "attempt" => attempt,
        "message" => String(message),
        "result_sha256" => result_sha256,
        "updated_unix_seconds" => Float64(time()),
        "latest_checkpoint" => checkpoint_mapping,
    )
end

function _write_recovered_interruption!(
    repository::AbstractRunRepository,
    definition::RunDefinition,
    point::SweepPoint,
    prior::AbstractDict,
    checkpoint,
)
    attempt = Int(get(prior, "attempt", 0))
    status = _point_status_mapping(
        definition,
        point,
        :interrupted,
        attempt;
        message = "recovered after an unclean application exit",
        checkpoint,
    )
    write_point_status!(repository, definition.identity.run_id, point.point_id, status)
    return status
end

function _result_mapping(
    context::PointExecutionContext,
    result::PointExecutionResult,
    checkpoint,
)
    reference =
        checkpoint === nothing ? nothing :
        Dict{String,Any}(
            "generation" => checkpoint.generation,
            "attempt" => checkpoint.attempt,
            "kind" => checkpoint.kind,
            "iteration" => checkpoint.iteration,
            "sha256" => checkpoint.sha256,
        )
    return Dict{String,Any}(
        "schema" => "reference2019-point-result-v1",
        "run_id" => context.definition.identity.run_id,
        "point_id" => context.point.point_id,
        "ordinal" => context.point.ordinal,
        "leaf" => context.point.leaf,
        "coordinates" => _coordinate_result(context.point),
        "attempt" => context.attempt,
        "status" => String(result.status),
        "result" => deepcopy(result.metadata),
        "artifacts" => deepcopy(result.artifacts),
        "latest_checkpoint" => reference,
    )
end

function _provenance_mapping(definition::RunDefinition, provenance)
    caller = _canonical_mapping(provenance)
    return Dict{String,Any}(
        "schema" => "reference2019-run-provenance-v1",
        "run_id" => definition.identity.run_id,
        "identity_digest" => definition.identity.digest,
        "scientific_identity" => deepcopy(definition.scientific_identity),
        "software_identity" => deepcopy(definition.software_identity),
        "source_and_environment" => caller,
    )
end

function _status_symbol(status)
    status === nothing && return :pending
    value = Symbol(String(get(status, "status", "pending")))
    value in (:pending, :running, :completed, :incomplete, :failed, :interrupted) ||
        throw(ArgumentError("unknown stored point status $value"))
    return value
end

function _summary_counts(repository::AbstractRunRepository, definition::RunDefinition)
    counts = Dict{Symbol,Int}(
        status => 0 for
        status in (:pending, :running, :completed, :incomplete, :failed, :interrupted)
    )
    foreach_sweep_point(definition.plan, definition.identity.run_id) do point
        counts[_status_symbol(
            read_point_status(repository, definition.identity.run_id, point.point_id),
        )] += 1
    end
    return counts
end

function _run_result_mapping(
    definition::RunDefinition,
    status::Symbol,
    counts::Dict{Symbol,Int},
    skipped::Int,
)
    return Dict{String,Any}(
        "schema" => "reference2019-run-result-v1",
        "run_id" => definition.identity.run_id,
        "status" => String(status),
        "point_count" => point_count(definition.plan),
        "counts" => Dict{String,Any}(String(key) => value for (key, value) in counts),
        "skipped_completed_on_resume" => skipped,
        "updated_unix_seconds" => Float64(time()),
        "result_format" => "hierarchical_yaml",
    )
end

function _finish_run!(
    repository::AbstractRunRepository,
    definition::RunDefinition,
    skipped::Int,
    tracer::RuntimeTracer,
)
    counts = _summary_counts(repository, definition)
    status = counts[:completed] == point_count(definition.plan) ? :completed : :incomplete
    result = _run_result_mapping(definition, status, counts, skipped)
    path = write_run_result!(repository, definition.identity.run_id, result)
    write_run_status!(
        repository,
        definition.identity.run_id,
        Dict{String,Any}(
            "schema" => "reference2019-run-status-v1",
            "run_id" => definition.identity.run_id,
            "status" => String(status),
            "updated_unix_seconds" => Float64(time()),
        ),
    )
    flush_timing_summary!(tracer)
    return SweepRunSummary(
        definition.identity.run_id,
        status,
        point_count(definition.plan),
        counts[:completed],
        counts[:incomplete],
        counts[:failed],
        counts[:interrupted],
        skipped,
        path,
    )
end

"""
    run_sweep!(repository, definition, runner; ...)

Execute a nested content-addressed sweep. Completed point YAML results are
certificates and are skipped on resume. A point left `running` is first marked
`interrupted`; its latest checksum-verified checkpoint is supplied to the
runner context. Result YAML is committed before the terminal point status, so
`completed` never refers to a missing result.
"""
function run_sweep!(
    repository::AbstractRunRepository,
    definition::RunDefinition,
    runner::AbstractPointRunner;
    checkpoint_codec::AbstractCheckpointCodec = default_checkpoint_codec(),
    retention::IterationRetentionPolicy = IterationRetentionPolicy(),
    provenance = Dict{String,Any}(),
    session_provenance = Dict{String,Any}(),
    resume::Bool = true,
    retry_failed::Bool = true,
    fail_fast::Bool = true,
    disk_model::Union{Nothing,DiskBudgetModel} = nothing,
    iterations_per_point::Union{Nothing,Integer} = nothing,
)
    existed = initialize_run!(repository, definition)
    existed &&
        !resume &&
        throw(
            ArgumentError(
                "content-addressed run already exists; enable resume or change an " *
                "identity-bearing input",
            ),
        )
    write_provenance!(
        repository,
        definition.identity.run_id,
        _provenance_mapping(definition, provenance),
    )
    if disk_model !== nothing
        iterations_per_point === nothing &&
            throw(ArgumentError("iterations_per_point is required with disk_model"))
        write_disk_estimate!(
            repository,
            definition.identity.run_id,
            estimate_disk(definition.plan, disk_model, retention; iterations_per_point),
        )
    end

    tracer = RuntimeTracer(repository, definition.identity.run_id)
    skipped = 0
    write_run_status!(
        repository,
        definition.identity.run_id,
        Dict{String,Any}(
            "schema" => "reference2019-run-status-v1",
            "run_id" => definition.identity.run_id,
            "status" => "running",
            "updated_unix_seconds" => Float64(time()),
        ),
    )
    emit_runtime_event!(
        tracer,
        :run_start;
        name = definition.plan.name,
        status = :running,
        attributes = Dict{String,Any}(
            "resume" => resume,
            "point_count" => point_count(definition.plan),
            "session_provenance" => _canonical_mapping(session_provenance),
        ),
    )

    try
        foreach_sweep_point(definition.plan, definition.identity.run_id) do point
            prior =
                read_point_status(repository, definition.identity.run_id, point.point_id)
            prior_status = _status_symbol(prior)
            if prior_status === :completed
                stored_result = read_point_result(
                    repository,
                    definition.identity.run_id,
                    point.point_id,
                )
                stored_result === nothing && throw(
                    ArgumentError("completed point $(point.point_id) has no result.yaml"),
                )
                expected_result_digest = validate_sha256_digest(
                    get(prior, "result_sha256", nothing),
                    "stored result digest for $(point.point_id)",
                )
                actual_result_digest = validate_sha256_digest(
                    point_result_sha256(
                        repository,
                        definition.identity.run_id,
                        point.point_id,
                    ),
                    "repository result digest for $(point.point_id)",
                )
                actual_result_digest == expected_result_digest || throw(
                    ArgumentError(
                        "completed point $(point.point_id) " * "result digest mismatch",
                    ),
                )
                verify_result_artifacts!(
                    repository,
                    definition.identity.run_id,
                    get(stored_result, "artifacts", Dict{String,Any}()),
                )
                skipped += 1
                emit_runtime_event!(
                    tracer,
                    :point_skipped;
                    name = point.leaf,
                    status = :completed,
                    attributes = Dict{String,Any}(
                        "point_id" => point.point_id,
                        "reason" => "completed_result_exists",
                    ),
                )
                return
            end
            if prior_status === :failed && !retry_failed
                emit_runtime_event!(
                    tracer,
                    :point_skipped;
                    name = point.leaf,
                    status = :failed,
                    attributes = Dict{String,Any}(
                        "point_id" => point.point_id,
                        "reason" => "retry_failed_is_false",
                    ),
                )
                return
            end

            loaded =
                resume ?
                load_latest_checkpoint(
                    repository,
                    checkpoint_codec,
                    definition.identity.run_id,
                    point.point_id,
                ) : nothing
            reference = loaded === nothing ? nothing : loaded.reference
            if prior_status === :running
                _write_recovered_interruption!(
                    repository,
                    definition,
                    point,
                    prior,
                    reference,
                )
                emit_runtime_event!(
                    tracer,
                    :point_recovered;
                    name = point.leaf,
                    status = :interrupted,
                    attributes = Dict{String,Any}(
                        "point_id" => point.point_id,
                        "prior_attempt" => Int(get(prior, "attempt", 0)),
                        "checkpoint_generation" =>
                            reference === nothing ? nothing : reference.generation,
                    ),
                )
            end
            attempt =
                prior === nothing ? 1 : Base.checked_add(Int(get(prior, "attempt", 0)), 1)
            running = _point_status_mapping(
                definition,
                point,
                :running,
                attempt;
                message = loaded === nothing ? "fresh start" :
                          "resuming checkpoint generation $(reference.generation)",
                checkpoint = reference,
            )
            write_point_status!(
                repository,
                definition.identity.run_id,
                point.point_id,
                running,
            )
            context = PointExecutionContext(
                definition,
                point,
                attempt,
                repository,
                checkpoint_codec,
                tracer,
                retention,
                loaded,
            )
            token = start_span!(
                tracer,
                :software,
                "point";
                attributes = Dict{String,Any}(
                    "point_id" => point.point_id,
                    "ordinal" => point.ordinal,
                    "coordinates" => _coordinate_result(point),
                    "attempt" => attempt,
                    "resumed" => loaded !== nothing,
                ),
            )
            try
                result = execute_point!(runner, context)
                result isa PointExecutionResult || throw(
                    ArgumentError(
                        "point runner returned $(typeof(result)); expected " *
                        "PointExecutionResult",
                    ),
                )
                latest = load_latest_checkpoint(
                    repository,
                    checkpoint_codec,
                    definition.identity.run_id,
                    point.point_id,
                )
                latest_reference = latest === nothing ? nothing : latest.reference
                write_point_result!(
                    repository,
                    definition.identity.run_id,
                    point.point_id,
                    _result_mapping(context, result, latest_reference),
                )
                verify_result_artifacts!(
                    repository,
                    definition.identity.run_id,
                    result.artifacts,
                )
                result_digest = validate_sha256_digest(
                    point_result_sha256(
                        repository,
                        definition.identity.run_id,
                        point.point_id,
                    ),
                    "repository result digest for $(point.point_id)",
                )
                terminal = _point_status_mapping(
                    definition,
                    point,
                    result.status,
                    attempt;
                    message = "runner returned",
                    checkpoint = latest_reference,
                    result_sha256 = result_digest,
                )
                write_point_status!(
                    repository,
                    definition.identity.run_id,
                    point.point_id,
                    terminal,
                )
                end_span!(tracer, token; status = result.status)
            catch error
                _fail_span_tree!(tracer, token, error)
                latest = load_latest_checkpoint(
                    repository,
                    checkpoint_codec,
                    definition.identity.run_id,
                    point.point_id,
                )
                latest_reference = latest === nothing ? nothing : latest.reference
                is_interruption = error isa Union{SweepInterrupted,InterruptException}
                status = is_interruption ? :interrupted : :failed
                failed = _point_status_mapping(
                    definition,
                    point,
                    status,
                    attempt;
                    message = sprint(showerror, error),
                    checkpoint = latest_reference,
                )
                write_point_status!(
                    repository,
                    definition.identity.run_id,
                    point.point_id,
                    failed,
                )
                if is_interruption || fail_fast
                    rethrow()
                end
            end
        end
    catch error
        emit_runtime_event!(
            tracer,
            :run_end;
            name = definition.plan.name,
            status = error isa Union{SweepInterrupted,InterruptException} ? :interrupted :
                     :failed,
            attributes = Dict{String,Any}(
                "exception_type" => string(typeof(error)),
                "message" => sprint(showerror, error),
            ),
        )
        write_run_status!(
            repository,
            definition.identity.run_id,
            Dict{String,Any}(
                "schema" => "reference2019-run-status-v1",
                "run_id" => definition.identity.run_id,
                "status" =>
                    error isa Union{SweepInterrupted,InterruptException} ? "interrupted" :
                    "failed",
                "message" => sprint(showerror, error),
                "updated_unix_seconds" => Float64(time()),
            ),
        )
        isempty(tracer.stack) && flush_timing_summary!(tracer)
        rethrow()
    end

    final_counts = _summary_counts(repository, definition)
    final_status =
        final_counts[:completed] == point_count(definition.plan) ? :completed : :incomplete
    emit_runtime_event!(
        tracer,
        :run_end;
        name = definition.plan.name,
        status = final_status,
        attributes = Dict{String,Any}("skipped_completed_on_resume" => skipped),
    )
    summary = _finish_run!(repository, definition, skipped, tracer)
    return summary
end
