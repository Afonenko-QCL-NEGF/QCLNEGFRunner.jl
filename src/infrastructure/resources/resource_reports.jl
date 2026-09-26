_resource_limit_value(value::Int) = value == typemax(Int) ? "unlimited" : value
_resource_measurement_value(value::Float64) = isfinite(value) ? value : "not_measured"

"""Return the serialization-safe dictionary for a hardware observation."""
function hardware_profile_dict(hardware::HardwareProfile)
    return Dict{String,Any}(
        "julia_threads" => hardware.julia_threads,
        "effective_logical_cpus" => hardware.logical_cpus,
        "cpu_affinity_count" => _resource_limit_value(hardware.cpu_affinity_count),
        "cpu_quota_cores" =>
            isfinite(hardware.cpu_quota_cores) ? hardware.cpu_quota_cores : "unlimited",
        "effective_memory_bytes" => hardware.total_memory_bytes,
        "available_memory_bytes" => hardware.available_memory_bytes,
        "physical_memory_bytes" => hardware.physical_memory_bytes,
        "cgroup_memory_current_bytes" => hardware.cgroup_memory_current_bytes,
        "cgroup_memory_high_bytes" =>
            _resource_limit_value(hardware.cgroup_memory_high_bytes),
        "cgroup_memory_max_bytes" =>
            _resource_limit_value(hardware.cgroup_memory_max_bytes),
        "cgroup_path" => hardware.cgroup_path,
        "blas_vendor" => hardware.blas_vendor,
        "cpu_source" => hardware.cpu_source,
        "memory_source" => hardware.memory_source,
    )
end

"""Return the serialization-safe dictionary for an E1 execution plan."""
function execution_plan_dict(plan::ExecutionPlan)
    return Dict{String,Any}(
        "requested_strategy" => String(plan.requested_strategy),
        "resolved" => Dict{String,Any}(
            "parallel_backend" => String(plan.parallel_backend),
            "worker_count" => plan.worker_count,
            "blas_threads" => plan.blas_threads,
            "energy_chunk" => plan.energy_chunk,
            "hilbert_columns" => plan.hilbert_columns,
            "residual_chunk" => plan.residual_chunk,
            "memory_budget_bytes" => _resource_limit_value(plan.memory_budget_bytes),
            "estimated_peak_bytes" => plan.estimated_peak_bytes,
            "contraction_jobs" => plan.contraction_jobs,
            "active_contraction_workers" => plan.active_contraction_workers,
        ),
        "hardware" => hardware_profile_dict(plan.hardware),
        "evidence_class" => "E1_physics_preserving_execution",
        "reasons" => plan.reasons,
    )
end

"""Return the serialization-safe dictionary for bounded calibration evidence."""
function execution_calibration_dict(report::ExecutionCalibrationReport)
    samples = Dict{String,Any}[]
    for sample in report.samples
        push!(
            samples,
            Dict{String,Any}(
                "parallel_backend" => String(sample.parallel_backend),
                "worker_count" => sample.worker_count,
                "blas_threads" => sample.blas_threads,
                "energy_chunk" => sample.energy_chunk,
                "sample_shape" => Dict(
                    "energy_nodes" => sample.sample_energy_nodes,
                    "momentum_nodes" => sample.sample_momentum_nodes,
                    "basis_states" => sample.sample_basis_states,
                ),
                "repetitions" => sample.repetitions,
                "median_seconds" => _resource_measurement_value(sample.median_seconds),
                "minimum_seconds" => _resource_measurement_value(sample.minimum_seconds),
                "maximum_seconds" => _resource_measurement_value(sample.maximum_seconds),
                "relative_spread" => _resource_measurement_value(sample.relative_spread),
                "output_norm" => _resource_measurement_value(sample.output_norm),
                "accepted" => sample.accepted,
                "note" => sample.note,
            ),
        )
    end
    return Dict{String,Any}(
        "mode" => String(report.mode),
        "maximum_seconds" => report.maximum_seconds,
        "elapsed_seconds" => report.elapsed_seconds,
        "selected" => Dict(
            "parallel_backend" => String(report.selected_backend),
            "worker_count" => report.selected_worker_count,
            "blas_threads" => report.selected_blas_threads,
        ),
        "samples" => samples,
        "reasons" => report.reasons,
        "evidence_class" => "E1_physics_preserving_execution",
    )
end

function _save_resource_yaml(path::AbstractString, value)
    destination = abspath(path)
    mkpath(dirname(destination))
    temporary, stream = mktemp(dirname(destination))
    close(stream)
    try
        YAML.write_file(temporary, value)
        _atomic_replace_file(temporary, destination)
    finally
        isfile(temporary) && rm(temporary; force = true)
    end
    return destination
end

"""Write the resolved hardware/execution decision as auditable YAML."""
save_execution_plan(path::AbstractString, plan::ExecutionPlan) =
    _save_resource_yaml(path, execution_plan_dict(plan))

"""Write the detected process resource envelope independently of the plan."""
save_hardware_profile(path::AbstractString, hardware::HardwareProfile) =
    _save_resource_yaml(path, hardware_profile_dict(hardware))

"""Write the bounded E1 calibration measurements as auditable YAML."""
save_execution_calibration(path::AbstractString, report::ExecutionCalibrationReport) =
    _save_resource_yaml(path, execution_calibration_dict(report))

"""Write one self-contained hardware, plan, and optional calibration report."""
function save_resource_diagnostics(
    path::AbstractString,
    plan::ExecutionPlan;
    calibration::Union{Nothing,ExecutionCalibrationReport} = nothing,
    campaign::Union{Nothing,AbstractDict} = nothing,
)
    value = Dict{String,Any}(
        "schema" => "qcl-negf-resource-diagnostics-v1",
        "plan" => execution_plan_dict(plan),
    )
    calibration === nothing ||
        (value["calibration"] = execution_calibration_dict(calibration))
    campaign === nothing || (value["campaign"] = campaign)
    return _save_resource_yaml(path, value)
end
