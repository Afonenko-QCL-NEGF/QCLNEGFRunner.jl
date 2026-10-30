const _NATIVE_PHASE_ADMISSIONS = Dict{String,Dict{String,Any}}()

"""Bound task width by Julia's fixed pool; external controls own phase memory.

The ordinary callback records estimates without predicting fit from current
memory. Slurm/systemd/cgroup enforce their actual allocation independently.
"""
function _native_phase_request(
    directory::Union{Nothing,String};
    proc_root::String = "/proc",
    cgroup_root::String = "/sys/fs/cgroup",
    resource_policy::Symbol = :standalone,
)
    _resource_policy(resource_policy)
    return function (request)
        maximum = _checked_resource_integer(request.task_width,"phase task width";minimum=1)
        _native_phase_memory_permit!(directory, String[], request;resource_policy)
        return min(maximum, Threads.nthreads(:default))
    end
end

function _native_phase_memory_permit!(directory, groups::Vector{String}, request;
    resource_policy::Symbol=:standalone)
    _resource_policy(resource_policy)
    directory===nothing && return nothing
    burst = get(request, :memory_burst_bytes, nothing)
    burst===nothing || _checked_resource_integer(burst,"incremental phase memory estimate")
    _NATIVE_PHASE_ADMISSIONS[directory]=Dict{String,Any}(
        "memory_admission_mode"=>"external_controls_not_predicted_fit",
    )
    return nothing
end

function _scientific_resource_preflight(resource_policy,envelope)
    _resource_policy(resource_policy)
    envelope===nothing || envelope isa ExecutionEnvelope ||
        throw(ArgumentError("invalid execution envelope"))
    return nothing
end
