"""Producer phase boundaries; the observer's ingestion time never replaces these."""
mutable struct _NativePhaseJournal
    session::String
    sequence::Int
    clock_domain::String
    utc_anchor_ns::Int
    monotonic_anchor_ns::Int
    stack::Vector{Pair{String,String}}
    admissions::Dict{String,Dict{String,Any}}
end
const _NATIVE_PHASE_JOURNALS = Dict{String,_NativePhaseJournal}()
const _NATIVE_PHASE_ADMISSIONS = Dict{String,Dict{String,Any}}()

struct _NativePhasePressure <: Exception
    evidence::Dict{String,Any}
end
Base.showerror(io::IO, error::_NativePhasePressure) =
    print(io, "phase memory envelope denied before allocation: ", error.evidence["phase"])

function _native_phase_journal(directory::String)
    return get!(_NATIVE_PHASE_JOURNALS, directory) do
        session = string(getpid(), "-", time_ns())
        boot = try
            strip(read("/proc/sys/kernel/random/boot_id", String))
        catch
            "boot_unknown"
        end
        _NativePhaseJournal(
            session,
            0,
            boot * ":julia:" * session,
            round(Int, time() * 1e9),
            Int(time_ns()),
            Pair{String,String}[],
            Dict{String,Dict{String,Any}}(),
        )
    end
end

function _record_native_phase!(directory::Union{Nothing,String}, event::SolverEvent)
    directory === nothing && return nothing
    event.action in (:phase_begin, :phase_end) || return nothing
    mkpath(directory)
    journal = _native_phase_journal(directory)
    journal.sequence += 1
    metrics = Dict(String(metric.name) => metric.value for metric in event.metrics)
    phase = event.label
    beginning = event.action === :phase_begin
    if beginning
        parent = isempty(journal.stack) ? nothing : last(journal.stack).second
        span = journal.session * ":" * string(journal.sequence)
        push!(journal.stack, phase => span)
        journal.admissions[span]=copy(
            get(_NATIVE_PHASE_ADMISSIONS, directory, Dict{String,Any}()),
        )
    else
        isempty(journal.stack) && throw(ArgumentError("phase ended without begin: $phase"))
        last(journal.stack).first == phase ||
            throw(ArgumentError("phase nesting mismatch: $phase"))
        span = pop!(journal.stack).second
        parent = isempty(journal.stack) ? nothing : last(journal.stack).second
    end
    stamp = get(metrics, "producer_monotonic_ns", nothing)
    stamp isa Integer || throw(ArgumentError("producer phase lacks monotonic timestamp"))
    row = Dict{String,Any}(
        "schema" => "qcl-negf.producer-phase.v2",
        "contract_set" => "qcl-negf.results.v1",
        "source_session_id" => journal.session,
        "source_sequence" => journal.sequence,
        "clock_domain_id" => journal.clock_domain,
        "utc_anchor_ns" => journal.utc_anchor_ns,
        "monotonic_anchor_ns" => journal.monotonic_anchor_ns,
        "span_id" => span,
        "parent_span_id" => parent,
        "phase" => phase,
        "event_kind" => beginning ? "begin" : "end",
        "monotonic_ns" => Int(stamp),
        "begin_monotonic_ns" => get(metrics, "start_monotonic_ns", stamp),
        "end_monotonic_ns" =>
            beginning ? nothing : get(metrics, "end_monotonic_ns", stamp),
        "duration_seconds" =>
            beginning ? 0.0 : (stamp - get(metrics, "start_monotonic_ns", stamp)) / 1e9,
        "process_cpu_seconds" => get(metrics, "cpu_seconds", nothing),
        "allocated_bytes" => get(metrics, "allocated_bytes", nothing),
        "gc_seconds" => get(metrics, "gc_seconds", nothing),
        "gc_count" => get(metrics, "gc_count", nothing),
        "counter_scope" => "process_inclusive_delta_on_end",
        "process_cpu_total_seconds" => get(metrics, "cpu_seconds_total", nothing),
        "allocated_total_bytes" => get(metrics, "allocated_bytes_total", nothing),
        "gc_total_seconds" => get(metrics, "gc_seconds_total", nothing),
        "gc_total_count" => get(metrics, "gc_count_total", nothing),
        "task_width" => get(metrics, "task_width", nothing),
        "work_units" => get(metrics, "work_units", nothing),
        "workspace_bytes" => get(metrics, "workspace_bytes", nothing),
        "memory_burst_bytes" => get(metrics, "memory_burst_bytes", nothing),
        "parallel_kind" => get(metrics, "parallel_kind", nothing),
        "phase_wait_reason" => get(metrics, "phase_wait_reason", nothing),
        "capability_reasons" =>
            get(metrics, "memory_burst_bytes", nothing) === nothing ?
            "{\"memory_burst_bytes\":\"not_measured\"}" : "{}",
        "iteration" => event.iteration,
        "stage_path" => String(event.stage),
        "status" => String(event.status),
    )
    admission=beginning ? journal.admissions[span] : pop!(journal.admissions, span)
    for name in (
        "memory_admission_mode",
        "memory_current_before_bytes",
        "memory_limit_bytes",
        "memory_granted_additional_bytes",
        "memory_current_after_gc_bytes",
        "memory_effective_current_bytes",
        "memory_clean_cache_credit_bytes",
        "memory_full_gc_seconds",
        "memory_stat_before",
        "memory_stat_after_gc",
    )
        row[name]=get(admission, name, nothing)
    end
    open(joinpath(directory, "phases.jsonl"), "a") do io
        _light_json(io, row)
        println(io)
        flush(io)
    end
    _observability_atomic_text(joinpath(directory, "phase-current.json")) do io
        _light_json(io, row)
        println(io)
    end
    return nothing
end

"""Bound task width by Julia's fixed pool and observe cgroup v2 memory headroom.

Slurm owns allocations. This callback neither reallocates CPUs nor exchanges
resource leases with another process. A denied allocation preserves the most
recent committed scientific state through the normal exception boundary.
"""
function _native_phase_request(
    directory::Union{Nothing,String};
    proc_root::String = "/proc",
    cgroup_root::String = "/sys/fs/cgroup",
)
    groups = _cgroup_ancestors(cgroup_root, _process_cgroup_path(proc_root))
    return function (request)
        maximum = Int(request.task_width)
        maximum >= 1 || throw(ArgumentError("phase task width must be positive"))
        _native_phase_memory_permit!(directory, groups, request)
        return min(maximum, Threads.nthreads(:default))
    end
end

function _native_phase_memory_permit!(directory, groups::Vector{String}, request)
    directory === nothing && return nothing
    decision = Dict{String,Any}("memory_admission_mode" => "unavailable")
    _NATIVE_PHASE_ADMISSIONS[directory] = decision
    burst = get(request, :memory_burst_bytes, nothing)
    burst === nothing && return nothing
    burst isa Integer && !(burst isa Bool) && burst >= 0 ||
        throw(ArgumentError("invalid incremental phase memory estimate"))
    limits = [(group, _resource_integer(_resource_read(joinpath(group, "memory.max"))))
              for group in groups]
    filter!(entry -> last(entry) != typemax(Int), limits)
    isempty(limits) && return nothing
    function available()
        snapshots = [(group, limit, _resource_integer(_resource_read(joinpath(group, "memory.current"))))
                     for (group, limit) in limits]
        all(last(item) != typemax(Int) for item in snapshots) ||
            throw(ArgumentError("finite cgroup limit has unreadable memory.current"))
        return snapshots[argmin([limit - current for (_, limit, current) in snapshots])]
    end
    _, limit, before = available()
    current = before
    gc_seconds = 0.0
    if current > limit - burst
        started = time_ns()
        GC.gc(true)
        gc_seconds = (time_ns() - started) * 1e-9
        _, limit, current = available()
    end
    permitted = current <= limit - burst
    merge!(decision, Dict(
        "memory_admission_mode" => "cgroup_v2",
        "memory_current_before_bytes" => before,
        "memory_current_after_gc_bytes" => current,
        "memory_effective_current_bytes" => current,
        "memory_clean_cache_credit_bytes" => 0,
        "memory_full_gc_seconds" => gc_seconds,
        "memory_limit_bytes" => limit,
        "memory_granted_additional_bytes" => permitted ? Int(burst) : nothing,
    ))
    permitted && return nothing
    evidence = Dict{String,Any}(
        "schema" => "qcl-negf.phase-pressure.v2",
        "contract_set" => "qcl-negf.results.v1",
        "reason" => "phase_memory_bound",
        "phase" => String(get(request, :name, :unknown)),
        "iteration" => get(request, :iteration, 0),
        "current_bytes" => current,
        "incremental_estimate_bytes" => Int(burst),
        "required_memory_bytes" => current + Int(burst),
        "limit_bytes" => limit,
        "action" => "pause_before_allocation_restore_last_committed_state",
        "requested_unix" => time(),
        "producer_monotonic_ns" => Int(time_ns()),
    )
    _observability_atomic_text(joinpath(directory, "resource-pressure.json")) do io
        _light_json(io, evidence)
        println(io)
    end
    throw(_NativePhasePressure(evidence))
end
