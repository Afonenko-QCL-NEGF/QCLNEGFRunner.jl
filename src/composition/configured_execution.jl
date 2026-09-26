"""Result of the single application-level computation entry point."""
struct ConfiguredExecutionResult{T,R}
    mode::Symbol
    computation::T
    report::R
    output_directory::String
end

"""Default safety ceiling for solver invocations in one configured study."""
const DEFAULT_MAXIMUM_SOLVER_RUNS = 16

"""
    planned_solver_runs(configuration)

Return the number of independent solver invocations implied by a resolved
configuration.  The count is deliberately computed before any grid, basis,
kernel, checkpoint, or output directory is created.  A comparison includes
its method repetitions and every physically unique convergence grid; one base
grid requested as the reference for several axes is solved only once.
"""
function planned_solver_runs(configuration::ResolvedRunConfiguration)
    study = configuration.study
    points = Base.checked_mul(length(study.temperatures), length(study.voltages_per_period))
    study.mode === :comparison || return points
    method_runs = Base.checked_mul(length(study.methods), study.repetitions)
    convergence_runs = _unique_convergence_grid_count(configuration)
    return Base.checked_mul(points, Base.checked_add(method_runs, convergence_runs))
end

function _check_solver_run_budget(
    configuration::ResolvedRunConfiguration,
    maximum_solver_runs::Integer,
)
    maximum_solver_runs > 0 ||
        throw(ArgumentError("maximum_solver_runs must be a positive integer"))
    planned = planned_solver_runs(configuration)
    planned <= maximum_solver_runs || throw(
        ArgumentError(
            "configuration plans $planned solver runs, exceeding the explicit " *
            "limit $maximum_solver_runs",
        ),
    )
    return planned
end

function _configuration_with_output_directory(
    configuration::ResolvedRunConfiguration,
    directory::AbstractString,
)
    output_directory = abspath(directory)
    raw = deepcopy(configuration.raw)
    raw["output"]["directory"] = output_directory
    sources = deepcopy(configuration.provenance.sources)
    history = get!(sources, "output.directory", String[])
    push!(history, _package_path("src", "composition", "configured_execution.jl"))
    provenance = ConfigurationProvenance(
        copy(configuration.provenance.manifests),
        copy(configuration.provenance.files),
        sources,
    )
    return ResolvedRunConfiguration(
        configuration.name,
        configuration.description,
        configuration.classification,
        configuration.physical,
        configuration.numerical,
        configuration.scales,
        configuration.scattering,
        configuration.solver,
        configuration.production,
        configuration.kernels,
        configuration.algorithms,
        configuration.execution,
        _output_with_directory(configuration.output, output_directory),
        configuration.study,
        provenance,
        raw,
        configuration.physical_models,
        configuration.domain_adaptation,
    )
end

function _configured_run_identifier(
    configuration::ResolvedRunConfiguration,
    requested::Union{Nothing,AbstractString},
)
    value = requested === nothing ? configuration.name : String(requested)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", value) ||
        throw(ArgumentError("run id must be a portable 1--128 character name"))
    return value
end

"""
    execute_configured_run(source; output_root, run_id, report_template)

The sole application orchestration port used by CLI, queue jobs, systemd and
acceptance. It resolves the scientific configuration once and dispatches only
on `study.mode`. Display and deployment layers may select an output root, but
no such concern enters the physical or numerical solver.
"""
function execute_configured_run(
    source;
    output_root::Union{Nothing,AbstractString} = nothing,
    run_id::Union{Nothing,AbstractString} = nothing,
    report_template::Union{Nothing,AbstractString} = nothing,
    maximum_solver_runs::Integer = DEFAULT_MAXIMUM_SOLVER_RUNS,
)
    sources = source isa AbstractVector ? String.(source) : String[source]
    isempty(sources) &&
        throw(ArgumentError("at least one configuration source is required"))
    if length(sources)==1 && is_scientific_definition(first(sources))
        plan=resolve_scientific_plan(
            first(sources);
            maximum_solver_runs = Int(maximum_solver_runs),
        )
        root=output_root===nothing ? "results" : String(output_root)
        identifier=run_id===nothing ?
                   plan.root_definition_id*"-"*string(time_ns(); base = 36) : String(run_id)
        occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", identifier) ||
            throw(ArgumentError("invalid run id"))
        directory=joinpath(abspath(root), identifier)
        computation=execute_scientific_plan(plan, directory)
        report=report_template===nothing ? nothing : postprocess_series(directory)
        return ConfiguredExecutionResult(plan.root_kind, computation, report, directory)
    end
    configuration = load_run_configuration(sources)
    _check_solver_run_budget(configuration, maximum_solver_runs)
    profile_root = _find_profile_root(first(sources))
    if output_root !== nothing
        root = abspath(String(output_root))
        identifier = _configured_run_identifier(configuration, run_id)
        configuration =
            _configuration_with_output_directory(configuration, joinpath(root, identifier))
    elseif run_id !== nothing
        throw(ArgumentError("run_id requires output_root"))
    end

    mode = configuration.study.mode
    computation = if mode === :single
        run_from_configuration(configuration)
    elseif mode === :sweep
        run_configured_nested_sweep(configuration)
    elseif mode === :comparison
        run_production_study(configuration, profile_root)
    else
        throw(ArgumentError("unsupported study mode: $mode"))
    end
    report =
        report_template === nothing ? nothing :
        render_configured_report(String(report_template), computation)
    return ConfiguredExecutionResult(
        mode,
        computation,
        report,
        configuration_output_directory(configuration),
    )
end

# Expand the same effective configurations used by the executor without
# allocating a physical grid, basis, kernel, or result directory.
function _configured_resource_cases(configuration::ResolvedRunConfiguration, profile_root)
    study = configuration.study
    points = length(study.temperatures) * length(study.voltages_per_period)
    cases = NamedTuple[]
    if study.mode !== :comparison
        push!(
            cases,
            (id = configuration.name, runs = points, configuration = configuration),
        )
        return cases
    end
    for (index, metadata) in enumerate(study.methods)
        profile = load_run_configuration(_profile_directory(profile_root, metadata.profile))
        overrides = get(
            configuration.raw["study"]["methods"][index],
            "overrides",
            Dict{String,Any}(),
        )
        effective = _method_configuration(
            configuration,
            profile,
            configuration.output.directory;
            overrides,
        )
        push!(
            cases,
            (
                id = "method/$index/$(metadata.profile)",
                runs = points * study.repetitions,
                configuration = effective,
            ),
        )
    end
    reference =
        load_run_configuration(_profile_directory(profile_root, study.reference_profile))
    base = _method_configuration(configuration, reference, configuration.output.directory)
    for request in _convergence_grid_requests(configuration)
        request.reused && continue
        effective = _configuration_with_numerical(
            base,
            request.numerical,
            configuration.output.directory,
            request.grid_id,
        )
        push!(
            cases,
            (
                id = "convergence/$(request.grid_id)",
                runs = points,
                configuration = effective,
            ),
        )
    end
    sum(case.runs for case in cases) == planned_solver_runs(configuration) ||
        error("resource case expansion disagrees with solver-run count")
    return cases
end

function _configured_execution_resource_plan(
    configuration::ResolvedRunConfiguration,
    profile_root::AbstractString;
    hardware::HardwareProfile = probe_hardware(),
    run_benchmark::Bool = false,
)
    cases = _configured_resource_cases(configuration, profile_root)
    plans = ExecutionPlan[]
    calibrations = ExecutionCalibrationReport[]
    estimates = Int[]
    for case in cases
        plan, calibration = calibrate_execution_plan(case.configuration; hardware)
        effective = _configuration_with_execution_plan(case.configuration, plan)
        # The educational schedule reports no production scheduling estimate.
        # It still uses the common allocation guard before building the model.
        estimate =
            _configured_production_estimate(effective, effective.production).peak_bytes
        push!(plans, plan)
        push!(calibrations, calibration)
        push!(estimates, estimate)
    end
    worst = argmax(estimates)
    if run_benchmark
        # Keep the CLI's bounded microbenchmark budget: benchmark only the
        # largest analytical case, not every case in a large campaign.
        plans[worst], calibrations[worst] = calibrate_execution_plan(
            cases[worst].configuration;
            hardware,
            run_benchmark = true,
        )
        effective =
            _configuration_with_execution_plan(cases[worst].configuration, plans[worst])
        estimates[worst] =
            _configured_production_estimate(effective, effective.production).peak_bytes
        worst = argmax(estimates)
    end
    entries = Dict{String,Any}[]
    for (index, case) in enumerate(cases)
        effective = case.configuration
        push!(
            entries,
            Dict{String,Any}(
                "case_id" => case.id,
                "solver_runs" => case.runs,
                "numerical" => deepcopy(effective.raw["numerical"]),
                "scattering" => deepcopy(effective.raw["scattering"]),
                "solver_backend" => String(effective.execution.solver_backend),
                "estimated_peak_bytes" => estimates[index],
                "memory_budget_bytes" =>
                    _resource_limit_value(plans[index].memory_budget_bytes),
                "save_full_state" => effective.output.save_full_state,
                "debug_hdf5" => effective.output.debug_hdf5,
            ),
        )
    end
    campaign = Dict{String,Any}(
        "schema" => "qcl-negf-campaign-resource-plan-v1",
        "memory_model" => "julia-common-preallocation-guard",
        "execution" => "sequential_cases",
        "planned_solver_runs" => sum(case.runs for case in cases),
        "resolved_case_count" => length(cases),
        "maximum_estimated_peak_bytes" => estimates[worst],
        "maximum_memory_case_id" => cases[worst].id,
        "cases" => entries,
    )
    return (plan = plans[worst], calibration = calibrations[worst], campaign = campaign)
end

"""Public legacy resource inspection; boundary resolution remains in composition."""
function configured_resource_plan(
    configuration::ResolvedRunConfiguration,
    source::AbstractString;
    kwargs...,
)
    return _configured_execution_resource_plan(
        configuration,
        _find_profile_root(source);
        kwargs...,
    )
end
