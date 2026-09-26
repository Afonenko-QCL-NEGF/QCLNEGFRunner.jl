mutable struct _CoreTimingAccumulator
    calls::Int
    total_wall_seconds::Float64
    maximum_wall_seconds::Float64
    exclusive_wall_seconds::Float64
    samples::Vector{Float64}
end

mutable struct _SpanFrame
    span_id::String
    parent_span_id::Union{Nothing,String}
    span_class::Symbol
    name::String
    core::Union{Nothing,String}
    started_ns::Int
    path::Vector{String}
    child_wall_seconds::Float64
end

"""Opaque handle enforcing properly nested physical/software spans."""
struct SpanToken
    span_id::String
end

"""
Application event tracer. `span_class=:physical` is reserved for operations
that express the model (Poisson, Dyson, scattering, observables), whereas
`:software` describes orchestration, storage, rendering, and transport.
"""
mutable struct RuntimeTracer
    repository::AbstractRunRepository
    run_id::String
    session_id::String
    monotonic_clock_ns::Function
    wall_clock_seconds::Function
    stack::Vector{_SpanFrame}
    span_counter::Int
    core_timings::Dict{String,_CoreTimingAccumulator}
    flushed::Bool
end

function RuntimeTracer(
    repository::AbstractRunRepository,
    run_id::AbstractString;
    monotonic_clock_ns::Function = () -> Int(time_ns()),
    wall_clock_seconds::Function = () -> Float64(time()),
)
    identifier = validate_content_identifier(run_id, "run id")
    started_ns = monotonic_clock_ns()
    started_wall = wall_clock_seconds()
    session_id = content_id(
        "session",
        Dict{String,Any}(
            "run_id" => identifier,
            "process_id" => getpid(),
            "thread_id" => Threads.threadid(),
            "started_monotonic_ns" => started_ns,
            "started_unix_seconds" => started_wall,
        ),
    )
    return RuntimeTracer(
        repository,
        identifier,
        session_id,
        monotonic_clock_ns,
        wall_clock_seconds,
        _SpanFrame[],
        0,
        Dict{String,_CoreTimingAccumulator}(),
        false,
    )
end

function _runtime_path(tracer::RuntimeTracer)
    return isempty(tracer.stack) ? String[] : copy(last(tracer.stack).path)
end

"""Emit one structured, append-only runtime event."""
function emit_runtime_event!(
    tracer::RuntimeTracer,
    event::Symbol;
    span_class::Symbol = :software,
    name::AbstractString = String(event),
    status::Symbol = :ok,
    attributes = Dict{String,Any}(),
    span_id = nothing,
    parent_span_id = nothing,
    path::AbstractVector{<:AbstractString} = _runtime_path(tracer),
)
    span_class in (:physical, :software) ||
        throw(ArgumentError("span_class must be physical or software"))
    mapping = Dict{String,Any}(
        "schema" => "reference2019-runtime-event-v1",
        "session_id" => tracer.session_id,
        "timestamp_unix_seconds" => tracer.wall_clock_seconds(),
        "monotonic_ns" => tracer.monotonic_clock_ns(),
        "event" => String(event),
        "span_class" => String(span_class),
        "name" => String(name),
        "status" => String(status),
        "path" => String[String(component) for component in path],
        "span_id" => span_id,
        "parent_span_id" => parent_span_id,
        "attributes" => portable_metadata(attributes),
    )
    return append_event!(tracer.repository, tracer.run_id, mapping)
end

function start_span!(
    tracer::RuntimeTracer,
    span_class::Symbol,
    name::AbstractString;
    core = nothing,
    attributes = Dict{String,Any}(),
)
    span_class in (:physical, :software) ||
        throw(ArgumentError("span_class must be physical or software"))
    tracer.flushed &&
        throw(ArgumentError("cannot start a span after timing summary was flushed"))
    core_name =
        core === nothing ? (span_class === :physical ? String(name) : nothing) :
        String(core)
    core_name === nothing || _portable_name(core_name, "physical core name")
    tracer.span_counter += 1
    parent = isempty(tracer.stack) ? nothing : last(tracer.stack).span_id
    parent_path = isempty(tracer.stack) ? String[] : last(tracer.stack).path
    path = vcat(parent_path, String(name))
    span_id = content_id(
        "span",
        Dict{String,Any}(
            "run_id" => tracer.run_id,
            "session_id" => tracer.session_id,
            "counter" => tracer.span_counter,
            "class" => String(span_class),
            "path" => path,
        ),
    )
    frame = _SpanFrame(
        span_id,
        parent,
        span_class,
        String(name),
        core_name,
        tracer.monotonic_clock_ns(),
        path,
        0.0,
    )
    push!(tracer.stack, frame)
    emit_runtime_event!(
        tracer,
        :span_start;
        span_class,
        name,
        status = :running,
        attributes,
        span_id,
        parent_span_id = parent,
        path = path,
    )
    return SpanToken(span_id)
end

function end_span!(
    tracer::RuntimeTracer,
    token::SpanToken;
    status::Symbol = :completed,
    attributes = Dict{String,Any}(),
)
    isempty(tracer.stack) &&
        throw(ArgumentError("cannot end span $(token.span_id): span stack is empty"))
    frame = last(tracer.stack)
    frame.span_id == token.span_id || throw(
        ArgumentError(
            "spans must end in LIFO order; expected $(frame.span_id), " *
            "got $(token.span_id)",
        ),
    )
    elapsed = max(0.0, (tracer.monotonic_clock_ns() - frame.started_ns) * 1e-9)
    merged = _canonical_mapping(attributes)
    exclusive_elapsed = max(0.0, elapsed - frame.child_wall_seconds)
    merged["wall_seconds"] = elapsed
    merged["exclusive_wall_seconds"] = exclusive_elapsed
    merged["timing_semantics"] = "wall_seconds inclusive; exclusive subtracts synchronous child spans only"
    emit_runtime_event!(
        tracer,
        :span_end;
        span_class = frame.span_class,
        name = frame.name,
        status,
        attributes = merged,
        span_id = frame.span_id,
        parent_span_id = frame.parent_span_id,
        path = frame.path,
    )
    pop!(tracer.stack)
    isempty(tracer.stack) || (last(tracer.stack).child_wall_seconds += elapsed)
    if frame.span_class === :physical && frame.core !== nothing
        timing = get!(tracer.core_timings, frame.core) do
            _CoreTimingAccumulator(0, 0.0, 0.0, 0.0, Float64[])
        end
        timing.calls += 1
        timing.total_wall_seconds += elapsed
        timing.maximum_wall_seconds = max(timing.maximum_wall_seconds, elapsed)
        timing.exclusive_wall_seconds += exclusive_elapsed
        push!(timing.samples, elapsed)
        length(timing.samples) > 100000 && deleteat!(timing.samples, 1)
    end
    return elapsed
end

function with_span(
    callback::Function,
    tracer::RuntimeTracer,
    span_class::Symbol,
    name::AbstractString;
    core = nothing,
    attributes = Dict{String,Any}(),
)
    token = start_span!(tracer, span_class, name; core, attributes)
    try
        value = callback(token)
        end_span!(tracer, token; status = :completed)
        return value
    catch error
        _fail_span_tree!(tracer, token, error)
        rethrow()
    end
end

function _fail_span_tree!(tracer::RuntimeTracer, token::SpanToken, error)
    attributes = Dict{String,Any}(
        "exception_type" => string(typeof(error)),
        "message" => sprint(showerror, error),
    )
    while !isempty(tracer.stack)
        frame = last(tracer.stack)
        end_span!(tracer, SpanToken(frame.span_id); status = :failed, attributes)
        frame.span_id == token.span_id && return nothing
    end
    return nothing
end

function _runtime_timing_quantile(samples, probability)
    isempty(samples) && return nothing
    values = sort(samples)
    position = 1+(length(values)-1)*probability
    lower, upper = floor(Int, position), ceil(Int, position)
    return values[lower]+(position-lower)*(values[upper]-values[lower])
end

function core_timing_summary(tracer::RuntimeTracer)
    cores = Dict{String,Any}()
    for name in sort!(collect(keys(tracer.core_timings)))
        timing = tracer.core_timings[name]
        cores[name] = Dict{String,Any}(
            "calls" => timing.calls,
            "total_wall_seconds" => timing.total_wall_seconds,
            "maximum_wall_seconds" => timing.maximum_wall_seconds,
            "exclusive_wall_seconds" => timing.exclusive_wall_seconds,
            "samples_wall_seconds" => copy(timing.samples),
            "sample_window" => 100000,
            "quantile_policy" => "linear interpolation of retained inclusive wall samples",
            "q05_wall_seconds" => _runtime_timing_quantile(timing.samples, 0.05),
            "q25_wall_seconds" => _runtime_timing_quantile(timing.samples, 0.25),
            "median_wall_seconds" => _runtime_timing_quantile(timing.samples, 0.5),
            "q75_wall_seconds" => _runtime_timing_quantile(timing.samples, 0.75),
            "q95_wall_seconds" => _runtime_timing_quantile(timing.samples, 0.95),
            "mean_wall_seconds" =>
                timing.calls == 0 ? 0.0 : timing.total_wall_seconds / timing.calls,
        )
    end
    return Dict{String,Any}(
        "schema" => "reference2019-core-timing-session-v1",
        "run_id" => tracer.run_id,
        "session_id" => tracer.session_id,
        "cores" => cores,
    )
end

"""Persist an immutable per-session timing file and rebuild its aggregate."""
function flush_timing_summary!(tracer::RuntimeTracer)
    isempty(tracer.stack) ||
        throw(ArgumentError("cannot flush timing summary with open spans"))
    if !tracer.flushed
        write_timing_session!(
            tracer.repository,
            tracer.run_id,
            tracer.session_id,
            core_timing_summary(tracer),
        )
        tracer.flushed = true
    end
    return aggregate_timing_sessions!(tracer.repository, tracer.run_id)
end
