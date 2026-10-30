const _NATIVE_PHASE_ADMISSIONS = Dict{String,Dict{String,Any}}()

struct _NativePhasePressure <: Exception
    evidence::Dict{String,Any}
end
Base.showerror(io::IO, error::_NativePhasePressure) =
    print(io, "phase memory envelope denied before allocation: ", error.evidence["phase"])

"""Bound task width by Julia's fixed pool; strict policy also checks memory headroom.

Slurm owns allocations. This callback neither reallocates CPUs nor exchanges
resource leases with another process. Ordinary phases rely on external memory
controls without predicting fit. A strict denial uses the normal exception
boundary and the most recent verified checkpoint remains the recovery authority.
"""
function _native_phase_request(
    directory::Union{Nothing,String};
    proc_root::String = "/proc",
    cgroup_root::String = "/sys/fs/cgroup",
    resource_policy::Symbol = :standalone,
)
    _resource_policy(resource_policy)
    groups = resource_policy===:campaign_strict ?
        _strict_cgroup_ancestors(proc_root,cgroup_root) :
        String[]
    return function (request)
        maximum = _checked_resource_integer(request.task_width,"phase task width";minimum=1)
        _native_phase_memory_permit!(directory, groups, request;resource_policy)
        return min(maximum, Threads.nthreads(:default))
    end
end

function _native_phase_memory_permit!(directory, groups::Vector{String}, request;
    resource_policy::Symbol=:standalone)
    _resource_policy(resource_policy)
    if resource_policy===:standalone
        directory===nothing && return nothing
        burst = get(request, :memory_burst_bytes, nothing)
        burst===nothing || _checked_resource_integer(burst,"incremental phase memory estimate")
        _NATIVE_PHASE_ADMISSIONS[directory]=Dict{String,Any}(
            "memory_admission_mode"=>"external_controls_not_predicted_fit",
        )
        return nothing
    end
    strict=resource_policy===:campaign_strict
    if directory===nothing
        strict && throw(ArgumentError("strict phase admission requires a telemetry directory"))
        return nothing
    end
    burst = get(request, :memory_burst_bytes, nothing)
    if burst===nothing
        strict && throw(ArgumentError("strict phase admission requires a known memory burst"))
        _NATIVE_PHASE_ADMISSIONS[directory]=Dict{String,Any}("memory_admission_mode"=>"unavailable")
        return nothing
    end
    burst=_checked_resource_integer(burst,"incremental phase memory estimate")
    limits = strict ? _strict_memory_bounds(groups) :
        [(group, _resource_integer(_resource_read(joinpath(group, "memory.max"))))
         for group in groups]
    strict || filter!(entry -> last(entry) != typemax(Int), limits)
    if isempty(limits)
        _NATIVE_PHASE_ADMISSIONS[directory]=Dict{String,Any}("memory_admission_mode"=>"unavailable")
        return nothing
    end
    function available()
        snapshots = [(group, limit, strict ?
            _strict_finite(_resource_read(joinpath(group,"memory.current")),"memory.current") :
            _resource_integer(_resource_read(joinpath(group,"memory.current"))))
            for (group,limit) in limits]
        strict || all(last(item) != typemax(Int) for item in snapshots) ||
            throw(ArgumentError("finite cgroup limit has unreadable memory.current"))
        # Check every applicable sum before choosing the tightest ancestor.
        for (_,_,current) in snapshots
            Base.checked_add(current,burst)
        end
        return snapshots[argmin([limit - current for (_, limit, current) in snapshots])]
    end
    _, limit, before = available()
    current = before
    gc_seconds = 0.0
    if Base.checked_add(current,burst) > limit
        started = time_ns()
        GC.gc(true)
        gc_seconds = (time_ns() - started) * 1e-9
        _, limit, current = available()
    end
    required=Base.checked_add(current,burst)
    permitted = required <= limit
    decision = Dict{String,Any}()
    _NATIVE_PHASE_ADMISSIONS[directory] = decision
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
        "required_memory_bytes" => required,
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

function _scientific_resource_preflight(resource_policy,envelope)
    _resource_policy(resource_policy)
    envelope===nothing || envelope isa ExecutionEnvelope ||
        throw(ArgumentError("invalid execution envelope"))
    if resource_policy===:campaign_strict
        envelope===nothing && throw(ArgumentError("campaign_strict needs_admission: explicit envelope required"))
        throw(ArgumentError("campaign_strict needs_guard/needs_admission: R2/R3/P1/P2/A1/C1 bindings pending"))
    end
    return nothing
end
