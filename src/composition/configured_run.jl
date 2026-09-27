const _OUTPUT_REPORT_SCHEMA = "qcl-negf-report-v1"

"""Static problem, diagnostics, and the resolved
[YAML input](@ref yaml-run-configurations)."""
struct ConfiguredProblem
    configuration::ResolvedRunConfiguration
    problem::NEGFProblem
    kernel_diagnostics::Union{Nothing,ProductionKernelDiagnostics}
    memory_estimate::ProductionMemoryEstimate
end

"""Result and artifact paths of the
[YAML run workflow](@ref yaml-run-configurations)."""
struct ConfiguredRunResult
    configured_problem::ConfiguredProblem
    sweep::ProductionSweepResult
    output_directory::String
    progress_csv::String
    live_dashboard::String
end

function _application_progress_stage(reporter::ProgressReporter)
    isempty(reporter.stack) && return nothing
    return reporter.stack[end].stage
end

_application_progress_metrics(metrics::Vector{SolverMetric}) = ProgressMetric[
    ProgressMetric(metric.name, metric.value, metric.unit) for metric in metrics
]

function _progress_event_sink(
    reporter::ProgressReporter;
    solver_event_observer::Function = identity,
)
    return function (event::SolverEvent)
        # SolverEvent is the canonical in-process observability contract.
        # External application adapters consume it before this presentation
        # adapter renders terminal/CSV/dashboard snapshots.
        current = _application_progress_stage(reporter)
        if event.action in (:phase_begin, :phase_end)
            _record_native_phase!(reporter.machine_directory, event)
            solver_event_observer(event)
            return true
        elseif event.action === :begin
            expected_parent =
                event.stage === :sweep ? :study :
                event.stage === :point ? :sweep :
                event.stage === :poisson ? :point :
                event.stage === :scba ? :poisson : nothing
            reporter.strict_hierarchy && current !== expected_parent && return false
            solver_event_observer(event)
            begin_progress_stage!(
                reporter,
                event.stage;
                label = event.label,
                iteration = event.iteration,
                total = event.total,
                metrics = _application_progress_metrics(event.metrics),
            )
            return true
        elseif event.action === :progress
            current === event.stage || return false
            solver_event_observer(event)
            update_progress!(
                reporter;
                iteration = event.iteration,
                total = event.total,
                metrics = _application_progress_metrics(event.metrics),
                message = event.message,
            )
            return true
        elseif event.action === :end
            if current !== event.stage &&
               event.status === :failed &&
               any(frame -> frame.stage === event.stage, reporter.stack)
                # An exception can escape an inner solver before it emits its
                # end event. Close the failed descendants in LIFO order so
                # runtime spans and the visible tree admit the next point.
                while _application_progress_stage(reporter) !== event.stage
                    frame = last(reporter.stack)
                    message = "$(event.stage) failed before $(frame.stage) ended"
                    child_event = SolverEvent(
                        :end,
                        frame.stage,
                        frame.label,
                        :failed,
                        frame.iteration,
                        frame.total,
                        SolverMetric[],
                        message,
                    )
                    solver_event_observer(child_event)
                    end_progress_stage!(
                        reporter,
                        frame.stage;
                        status = :failed,
                        iteration = frame.iteration,
                        total = frame.total,
                        message,
                    )
                end
                current = _application_progress_stage(reporter)
            end
            current === event.stage || return false
            solver_event_observer(event)
            end_progress_stage!(
                reporter,
                event.stage;
                status = event.status,
                iteration = event.iteration,
                total = event.total,
                metrics = _application_progress_metrics(event.metrics),
                message = event.message,
            )
            return true
        end
        throw(ArgumentError("unknown solver event action: $(event.action)"))
    end
end

function _production_options_with_reporter(
    options::ProductionOptions,
    reporter::ProgressReporter;
    solver_event_observer::Function = identity,
)
    return with_production_options(
        options;
        event_sink = _progress_event_sink(reporter; solver_event_observer),
        phase_request = _native_phase_request(reporter.machine_directory),
    )
end

"""
    configuration_output_directory(configuration)

Resolve a relative YAML output directory against the caller working directory.
A read-only installed package never receives generated artifacts.

See [YAML run configurations](@ref yaml-run-configurations).
"""
function configuration_output_directory(configuration::ResolvedRunConfiguration)
    requested = configuration.output.directory
    return abspath(requested)
end

"""
    configure_execution!(configuration)

Apply the explicitly configured BLAS thread count and verify the immutable
Julia thread count.  `julia_threads: 0` accepts the thread count used to start
Julia; a positive value is a fail-closed expectation when
`fail_on_thread_mismatch: true`.

See [YAML run configurations](@ref yaml-run-configurations).
"""
function configure_execution!(configuration::ResolvedRunConfiguration)
    expected = configuration.execution.julia_threads
    actual = Base.Threads.nthreads(:default)
    if expected > 0 && expected != actual
        message =
            "configuration requests $expected Julia threads, but the " *
            "process has $actual; restart Julia with --threads=$expected"
        configuration.execution.fail_on_thread_mismatch ? throw(ArgumentError(message)) :
        @warn(message)
    end
    BLAS.set_num_threads(configuration.execution.blas_threads)
    return (julia_threads = actual, blas_threads = BLAS.get_num_threads())
end

"""
    build_configured_problem(configuration)

Build the reference design problem selected by YAML.  `kernel_build: direct` calls the
literal microscopic tensor construction; `tabulated` calls the measured-error
production construction.  The later SCBA backend choice is independent.

See [Optimization decision tree](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/20_optimization_decision_tree.md) and
[Microscopic kernels](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/08_kernels.md).
"""
function build_configured_problem(configuration::ResolvedRunConfiguration)
    algorithms = configuration.algorithms
    # Fail before grid/basis/kernel allocation for every backend. The common
    # typed scattering port below owns direct/tabulated dispatch and format
    # validation; orchestration does not branch on concrete implementations.
    _preflight_production_memory(
        configuration.numerical,
        configuration.scattering,
        configuration.production,
    )
    built = build_configured_scattering_problem(
        physical = configuration.physical,
        numerical = configuration.numerical,
        scattering = configuration.scattering,
        scales = configuration.scales,
        algorithms = algorithms,
        kernel_options = configuration.kernels,
        solver_backend = configuration.execution.solver_backend,
        physical_models = configuration.physical_models,
    )
    estimate = estimate_production_memory(built.problem; options = configuration.production)
    return ConfiguredProblem(
        configuration,
        built.problem,
        built.kernel_diagnostics,
        estimate,
    )
end

function _save_configuration_provenance(
    output_directory::AbstractString,
    configuration::ResolvedRunConfiguration,
)
    mkpath(output_directory)
    YAML.write_file(
        joinpath(output_directory, "resolved_configuration.yaml"),
        resolved_configuration_dict(configuration),
    )
    _save_output_policy(output_directory, configuration)
    values = algorithm_manifest(configuration.algorithms)
    YAML.write_file(
        joinpath(output_directory, "algorithm_manifest.yaml"),
        Dict{String,Any}(
            "package" => "QCLNEGFRunner",
            "package_version" => _software_version(),
            "run_name" => configuration.name,
            "declared_classification" => String(configuration.classification),
            "runtime" => Dict{String,Any}(
                "julia_threads" => Base.Threads.nthreads(:default),
                "blas_threads" => BLAS.get_num_threads(),
            ),
            "algorithms" => values,
        ),
    )
    catalog = Dict{String,Any}[]
    for descriptor in optimization_catalog()
        push!(
            catalog,
            Dict{String,Any}(
                "id" => String(descriptor.id),
                "label" => descriptor.label,
                "impact" => String(descriptor.impact),
                "status" => String(descriptor.status),
                "summary" => descriptor.summary,
                "reference" => descriptor.reference,
            ),
        )
    end
    YAML.write_file(
        joinpath(output_directory, "optimization_catalog.yaml"),
        Dict{String,Any}("optimizations" => catalog),
    )
    fields = Dict{String,Any}()
    for path in sort!(collect(keys(configuration.provenance.sources)))
        sources = String.(configuration.provenance.sources[path])
        fields[path] = Dict{String,Any}(
            "winning_source" => last(sources),
            "source_chain" => sources,
            "overridden" => length(sources) > 1,
        )
    end
    YAML.write_file(
        joinpath(output_directory, "configuration_provenance.yaml"),
        Dict{String,Any}(
            "manifests" => String.(configuration.provenance.manifests),
            "files" => String.(configuration.provenance.files),
            "fields" => fields,
        ),
    )
    return nothing
end

function _save_output_policy(
    output_directory::AbstractString,
    configuration::ResolvedRunConfiguration,
)
    output = configuration.output
    comparison = configuration.study.mode === :comparison
    backend = configuration.execution.solver_backend
    policy = Dict{String,Any}(
        "schema" => _OUTPUT_REPORT_SCHEMA,
        "schema_version" => 1,
        "package" => "QCLNEGFRunner",
        "package_version" => _software_version(),
        "run_name" => configuration.name,
        "output_directory" => abspath(output_directory),
        "fields" => Dict{String,Any}(
            "checkpoint_prefix" => Dict(
                "value" => output.checkpoint_prefix,
                "status" => "applied_to_point_hdf5_filenames",
            ),
            "resume" => Dict(
                "value" => output.resume,
                "status" =>
                    backend === :production ? "production_checkpoint_restart" :
                    "educational_backend_does_not_restore_checkpoints",
            ),
            "warm_start_policy" => Dict(
                "value" => "strictly_converged_only",
                "status" =>
                    backend === :production ? "fixed_between_bias_points" :
                    "not_applicable_independent_educational_points",
            ),
            "fail_fast" => Dict(
                "value" => output.fail_fast,
                "status" => "applied_to_each_sweep_point",
            ),
            "save_full_state" => Dict(
                "value" => output.save_full_state,
                "status" => "controls_optional_restart_checkpoint_files",
            ),
            "debug_hdf5" => Dict(
                "value" => output.debug_hdf5,
                "status" => "independent_opt_in_final_debug_dump",
            ),
            "light_outputs" =>
                Dict("value"=>true, "status"=>"always_emitted_without_hdf5"),
            "save_csv" => Dict(
                "value" => output.save_csv,
                "status" => "controls_scientific_summary_optical_and_diagnostic_csv",
            ),
            "save_plots" => Dict(
                "value" => output.save_plots,
                "status" => "request_for_optional_plotting_frontend_not_core_solver",
            ),
            "live_visualization" => Dict(
                "value" => output.live_visualization,
                "status" => "controls_live_html_dashboard",
            ),
            "snapshot_every_scba" => Dict(
                "value" => output.snapshot_every_scba,
                "status" => "disk_and_dashboard_snapshot_cadence",
            ),
            "snapshot_every_outer" => Dict(
                "value" => output.snapshot_every_outer,
                "status" => "disk_and_dashboard_snapshot_cadence",
            ),
            "progress" => Dict(
                "enabled" => output.progress.enabled,
                "terminal" => output.progress.terminal,
                "significant_digits" => output.progress.significant_digits,
                "human_every" => output.progress.human_every,
                "event_log_file" => output.progress.event_log_file,
                "latest_snapshot_file" => output.progress.latest_snapshot_file,
                "dashboard_file" => output.progress.dashboard_file,
                "status" => "independent_machine_event_log_and_terminal_stream",
            ),
            "report_directory" => Dict(
                "value" => output.report_directory,
                "status" =>
                    comparison ? "comparison_report_destination" :
                    "not_applicable_outside_comparison_study",
            ),
            "save_expert_markdown" => Dict(
                "value" => output.save_expert_markdown,
                "status" =>
                    comparison ? "required_and_generated" :
                    "not_applicable_outside_comparison_study",
            ),
            "save_comparison_csv" => Dict(
                "value" => output.save_comparison_csv,
                "status" =>
                    comparison ? "required_and_generated" :
                    "not_applicable_outside_comparison_study",
            ),
            "save_comparison_plots" => Dict(
                "value" => output.save_comparison_plots,
                "status" =>
                    comparison ? "optional_plotting_frontend" :
                    "not_applicable_outside_comparison_study",
            ),
            "device_geometry" => Dict(
                "periods" => output.device_geometry.periods,
                "ridge_width" => string(output.device_geometry.ridge_width),
                "cavity_length" => string(output.device_geometry.cavity_length),
                "status" => "report_only_never_enters_poisson_or_scba",
            ),
        ),
    )
    path = joinpath(output_directory, "output_policy.yaml")
    YAML.write_file(path, policy)
    return path
end

function _unwind_progress!(
    reporter::ProgressReporter;
    status = :failed,
    message = "run aborted",
)
    while !isempty(reporter.stack)
        stage = reporter.stack[end].stage
        try
            end_progress_stage!(reporter, stage; status, message)
        catch
            pop!(reporter.stack)
        end
    end
    return nothing
end


function _configured_photon_energies(study::StudyConfiguration)
    study.calculate_optical_response || return nothing
    count = study.photon_energy_points
    return EnergyQuantity[
        study.photon_energy_min +
        (index - 1) / (count - 1) * (study.photon_energy_max - study.photon_energy_min) for
        index = 1:count
    ]
end

function _persist_progress_snapshot(output::OutputConfiguration, snapshot::ProgressSnapshot)
    snapshot.event === :progress || return true
    isempty(snapshot.stage_path) && return true
    stage = last(snapshot.stage_path)
    cadence =
        stage === :scba ? output.snapshot_every_scba :
        stage === :poisson ? output.snapshot_every_outer : nothing
    cadence === nothing && return true
    cadence == 0 && return false
    iteration = snapshot.iteration
    iteration === nothing && return true
    return iteration == 1 || iteration == snapshot.total || iteration % cadence == 0
end

function _configured_progress_paths(
    output_directory::AbstractString,
    output::OutputConfiguration,
)
    progress = output.progress
    enabled = progress.enabled
    event_log = enabled ? joinpath(output_directory, "progress", "events.jsonl") : ""
    dashboard =
        !enabled || !output.live_visualization || progress.dashboard_file === nothing ? "" :
        joinpath(output_directory, progress.dashboard_file)
    latest = enabled ? joinpath(output_directory, "progress", "progress.yaml") : ""
    return (event_log = event_log, dashboard = dashboard, latest = latest)
end

function _run_educational_sweep(
    configured::ConfiguredProblem,
    output_directory::AbstractString,
    reporter::ProgressReporter,
)
    configuration = configured.configuration
    storage=_configured_storage_observers(configuration, output_directory)
    records = ProductionSweepRecord[]
    summary_path =
        configuration.output.save_csv ? joinpath(output_directory, "sweep_summary.csv") : ""
    total =
        length(configuration.study.voltages_per_period) *
        length(configuration.study.temperatures)
    begin_progress_stage!(
        reporter,
        :sweep;
        label = "educational oracle",
        iteration = 0,
        total,
    )
    index = 0
    for (temperature_index, temperature) in pairs(configuration.study.temperatures)
        for (voltage_index, voltage) in pairs(configuration.study.voltages_per_period)
            index += 1
            voltage_mV = Float64(ustrip(u"mV", uconvert(u"mV", voltage)))
            label =
                "T=$(compact_number(_kelvin(temperature))) K, " *
                "Vₚ=$(compact_number(voltage_mV)) mV"
            begin_progress_stage!(reporter, :point; label, iteration = index, total)
            problem = retarget_problem(
                configured.problem;
                V_period = voltage,
                Tᴸ = temperature,
                Tᴸᴼ = temperature,
                energy_shift = configuration.algorithms.energy_shift,
            )
            started = time_ns()
            solution = try
                solve(
                    problem;
                    options = configuration.solver,
                    history_observer = (kind, outer, row, source)->storage.history(
                        kind,
                        outer,
                        row,
                        source,
                        temperature_index,
                        voltage_index,
                    ),
                )
            catch error
                error isa InterruptException && rethrow()
                configuration.output.fail_fast && rethrow()
                warning = Dict{String,Any}(
                    "code"=>"POINT_FAILED",
                    "scope"=>"point",
                    "message"=>sprint(showerror, error),
                    "thresholds"=>Dict{String,Any}(),
                    "metrics"=>Dict{String,Any}(),
                )
                push!(
                    records,
                    ProductionSweepRecord(
                        _kelvin(temperature),
                        Float64(ustrip(u"V", uconvert(u"V", voltage))),
                        _volts_per_metre(problem.physical.F_bias),
                        NaN,
                        false,
                        :failed,
                        :invalid,
                        0,
                        0,
                        configured.memory_estimate.peak_bytes,
                        (time_ns()-started)*1e-9,
                        Dict{Symbol,Float64}(),
                        "",
                        [warning],
                    ),
                )
                configuration.output.save_csv && save_production_summary(
                    summary_path,
                    ProductionSweepResult(copy(records), summary_path),
                )
                end_progress_stage!(
                    reporter,
                    :point;
                    status = :failed,
                    iteration = index,
                    total,
                    message = sprint(showerror, error),
                )
                update_progress!(
                    reporter;
                    iteration = index,
                    total,
                    metrics = ProgressMetric(:processed_points, index),
                )
                continue
            end
            storage.solution(solution, temperature_index, voltage_index)
            wall_seconds = (time_ns() - started) * 1e-9
            checkpoint =
                configuration.output.save_full_state ?
                _production_checkpoint_name(
                    output_directory,
                    configuration.output.checkpoint_prefix,
                    temperature_index,
                    voltage_index,
                ) : ""
            configuration.output.save_full_state && _atomic_checkpoint(checkpoint, solution)
            current =
                Float64(ustrip(u"A/m^2", solution.observables[:electron_flow_current]))
            metrics = _solution_report_metrics(solution)
            photon_energies = _configured_photon_energies(configuration.study)
            if photon_energies !== nothing && solution.converged
                _configured_optical_response!(
                    metrics,
                    solution,
                    photon_energies,
                    configuration.output.save_csv ?
                    joinpath(
                        output_directory,
                        "optical_T$(temperature_index)_V$(voltage_index).csv",
                    ) : nothing;
                    edge_tolerance = configuration.study.optical_edge_tolerance,
                    threaded = configuration.production.parallel_backend === :threads,
                )
            end
            push!(
                records,
                ProductionSweepRecord(
                    _kelvin(temperature),
                    Float64(ustrip(u"V", uconvert(u"V", voltage))),
                    _volts_per_metre(problem.physical.F_bias),
                    current,
                    solution.converged,
                    solution.status,
                    solution.scba.quality,
                    length(solution.outer_history),
                    length(solution.scba.history),
                    configured.memory_estimate.peak_bytes,
                    wall_seconds,
                    metrics,
                    checkpoint,
                    get(solution.observables, :warnings, Dict{String,Any}[]),
                ),
            )
            configuration.output.save_csv && save_production_summary(
                summary_path,
                ProductionSweepResult(copy(records), summary_path),
            )
            end_progress_stage!(
                reporter,
                :point;
                status = solution.converged ? :completed :
                         solution.status === :approximate ? :completed_with_warnings :
                         :incomplete,
                iteration = index,
                total,
                metrics = ProgressMetric[
                    ProgressMetric(:J, current/1e4, "A/cm^2"),
                    ProgressMetric(:wall, wall_seconds, "s"),
                ],
                message = String(solution.status),
            )
            update_progress!(
                reporter;
                iteration = index,
                total,
                metrics = ProgressMetric(:completed_points, index),
            )
            configuration.output.fail_fast &&
                !(solution.converged || solution.status === :approximate) &&
                error(
                    "educational point T=$(temperature), Vp=$(voltage) failed " *
                    "with status $(solution.status)",
                )
        end
    end
    end_progress_stage!(reporter, :sweep; iteration = total, total, status = :completed)
    result = ProductionSweepResult(records, summary_path)
    return result
end

"""
    run_from_configuration(configuration_directory)

One-command entry point for a canonical YAML configuration file. Physical
values, algorithms, resources, restart policy and study points come from its
resolved content. It writes the resolved YAML and `output_policy.yaml`.
Native HDF5 records retain physics, recovery and the complete scalar history;
JSONL carries lifecycle events, while scalar timing rows feed typed performance
storage. Latest progress and optional dashboards are derived views. This entry
point accepts `single` and `sweep`; public study/meta definitions use the frozen
scientific-plan workflow. Explicit CSV reporter exports remain opt-in views.

See [YAML run configurations](@ref yaml-run-configurations),
[Production observability](@ref native-result-formats), and
[Expert comparison workflow](@ref expert-comparison-workflow).
"""
function run_from_configuration(
    configuration_directory::AbstractString;
    solver_event_observer::Function = identity,
    resume_from_checkpoint::Union{Nothing,Bool} = nothing,
)
    return run_from_configuration(
        load_run_configuration(configuration_directory);
        solver_event_observer,
        resume_from_checkpoint,
    )
end

function run_from_configuration(
    configuration::ResolvedRunConfiguration;
    solver_event_observer::Function = identity,
    resume_from_checkpoint::Union{Nothing,Bool} = nothing,
)
    study = configuration.study
    study.mode in (:single, :sweep) || throw(
        ArgumentError(
            "run_from_configuration accepts only single/sweep studies; " *
            "comparison and convergence campaigns require " *
            "run_production_study",
        ),
    )
    study.mode === :single &&
        (length(study.voltages_per_period) != 1 || length(study.temperatures) != 1) &&
        throw(ArgumentError("single mode requires exactly one temperature and one voltage"))
    isempty(study.comparison_profiles) ||
        throw(ArgumentError("comparison_profiles require run_production_study"))
    study.reference_profile === nothing ||
        throw(ArgumentError("reference_profile requires run_production_study"))
    isempty(study.methods) ||
        throw(ArgumentError("study methods require run_production_study"))
    study.repetitions == 1 ||
        throw(ArgumentError("repetitions greater than one require run_production_study"))
    convergence_axes = (
        study.convergence.spatial_nodes,
        study.convergence.energy_nodes,
        study.convergence.momentum_nodes,
        study.convergence.angular_nodes,
    )
    all(isempty, convergence_axes) ||
        throw(ArgumentError("convergence axes require run_production_study"))
    if configuration.execution.solver_backend === :educational &&
       resume_from_checkpoint !== nothing
        throw(
            ArgumentError(
                "resume_from_checkpoint is only valid for the production backend",
            ),
        )
    end
    configuration, execution_plan = resolve_execution_strategy(configuration)
    configure_execution!(configuration)
    output_directory = configuration_output_directory(configuration)
    mkpath(output_directory)
    _save_configuration_provenance(output_directory, configuration)
    save_execution_plan(joinpath(output_directory, "execution_plan.yaml"), execution_plan)
    save_hardware_profile(
        joinpath(output_directory, "hardware_profile.yaml"),
        execution_plan.hardware,
    )

    progress_configuration = configuration.output.progress
    progress_paths = _configured_progress_paths(output_directory, configuration.output)
    progress_csv = progress_paths.event_log
    dashboard_path = progress_paths.dashboard
    latest_path = progress_paths.latest
    history = ProgressSnapshot[]
    function observe(snapshot)
        progress_configuration.enabled || return snapshot
        _persist_progress_snapshot(configuration.output, snapshot) || return snapshot
        push!(history, snapshot)
        length(history) > 2000 && deleteat!(history, 1:(length(history)-2000))
        # Canonical latest progress is written by the machine reporter itself.
        configuration.output.live_visualization &&
            !isempty(dashboard_path) &&
            save_progress_dashboard(dashboard_path, history)
        return snapshot
    end
    human_stream =
        progress_configuration.enabled && progress_configuration.terminal ? stdout : nothing
    reporter = if isempty(progress_csv) || !progress_configuration.enabled
        ProgressReporter(;
            human_io = human_stream,
            significant_digits = progress_configuration.significant_digits,
            human_every = progress_configuration.human_every,
            on_snapshot = observe,
        )
    else
        ProgressReporter(;
            machine_directory = dirname(progress_csv),
            append = configuration.output.resume,
            human_io = human_stream,
            significant_digits = progress_configuration.significant_digits,
            human_every = progress_configuration.human_every,
            on_snapshot = observe,
        )
    end
    configured = nothing
    sweep = nothing
    try
        begin_progress_stage!(reporter, :study; label = configuration.name)
        configured = build_configured_problem(configuration)
        save_kernel_diagnostics_path = joinpath(output_directory, "kernel_diagnostics.csv")
        !configuration.output.save_csv ||
            configured.kernel_diagnostics === nothing ||
            save_kernel_diagnostics(
                save_kernel_diagnostics_path,
                configured.kernel_diagnostics,
            )
        if configuration.execution.solver_backend === :educational
            configuration.output.resume && @warn(
                "output.resume does not restore educational checkpoints; " *
                "educational sweep points are recomputed independently"
            )
            sweep = _run_educational_sweep(configured, output_directory, reporter)
        else
            selected_resume =
                resume_from_checkpoint === nothing ? configuration.output.resume :
                resume_from_checkpoint
            runtime_options = _production_options_with_reporter(
                configuration.production,
                reporter;
                solver_event_observer,
            )
            photon_energies = _configured_photon_energies(configuration.study)
            storage=_configured_storage_observers(configuration, output_directory)
            sweep = run_production_sweep(
                configured.problem,
                configuration.study.voltages_per_period,
                configuration.study.temperatures;
                output_directory,
                options = configuration.solver,
                production_options = runtime_options,
                resume_from_checkpoints = selected_resume,
                checkpoint_prefix = configuration.output.checkpoint_prefix,
                save_full_state = configuration.output.save_full_state,
                save_csv = configuration.output.save_csv,
                solution_observer = storage.solution,
                checkpoint_observer = storage.checkpoint,
                checkpoint_request = storage.request,
                history_observer = storage.history,
                fail_fast = configuration.output.fail_fast,
                photon_energies = photon_energies,
                optical_edge_tolerance = configuration.study.optical_edge_tolerance,
                incompatible_checkpoint = :error,
                domain_adaptation = configuration.domain_adaptation,
                kernel_options = configuration.kernels,
            )
        end
        end_progress_stage!(reporter, :study; status = :completed, message = "run finished")
    catch error
        _unwind_progress!(reporter; status = :failed, message = sprint(showerror, error))
        rethrow()
    finally
        close(reporter)
    end
    return ConfiguredRunResult(
        configured,
        sweep,
        output_directory,
        progress_csv,
        dashboard_path,
    )
end


"""Outer composition binds numerical snapshots to a bounded file adapter."""
function _configured_storage_observers(
    configuration::ResolvedRunConfiguration,
    output_directory::AbstractString,
)
    output=configuration.output
    recorders=Dict{Tuple{Int,Int},ScientificHistoryRecorder}()
    clocks=Dict{Tuple{Int,Int},CheckpointDeadline}()
    storage_started=time_ns()
    function recorder(it, iv)
        get!(recorders, (it, iv)) do
            point="T$(it)-V$(iv)"
            parent=joinpath(output_directory, "points", point)
            mkpath(parent)
            attempts=[
                parse(Int, match(r"^attempt-(\d+)$", name).captures[1]) for
                name in readdir(parent) if occursin(r"^attempt-\d+$", name)
            ]
            attempt=isempty(attempts) ? 1 : maximum(attempts)+1
            identity=Dict{String,Any}(
                "point_id"=>point,
                "execution_id"=>"configured",
                "attempt"=>attempt,
                "plan_fingerprint"=>bytes2hex(
                    sha256(sprint(_light_json, configuration.raw)),
                ),
            )
            previous_scba, previous_outer=scientific_history_counts(parent)
            ScientificHistoryRecorder(
                joinpath(parent, "attempt-$(attempt)"),
                identity,
                Ref(previous_scba),
                Ref(previous_outer),
            )
        end
    end
    history=(kind, outer, row, source, it, iv)->record_scientific_history!(
        recorder(it, iv),
        kind,
        outer,
        row,
        source,
    )
    function persist(solution::NEGFSolution, it::Integer, iv::Integer; analysis = true)
        solution.observables[:model_capabilities]=model_capabilities(
            solution.problem,
            configuration.algorithms,
        )
        terminal=!(solution.status in (:running, :running_scba, :snapshot))
        saved=recorder(it, iv)
        flush_scientific_history!(saved)
        clock=get!(() -> CheckpointDeadline(storage_started), clocks, (it, iv))
        directory=dirname(saved.directory)
        commit_point_artifacts(
            directory,
            solution;
            identity = saved.identity,
            algorithms = configuration.algorithms,
            configuration = configuration.raw,
            history_paths = scientific_history_sources(dirname(directory)),
            analysis,
            terminal_status = terminal ? "completed" : "running",
            checkpoint_metadata = checkpoint_policy(clock),
        )
        checkpoint_completed!(clock)
        return nothing
    end
    function solution_observer(solution::NEGFSolution, it::Integer, iv::Integer)
        outer=length(solution.outer_history)
        terminal=solution.status!==:snapshot
        cadence=output.snapshot_every_outer
        !terminal && (cadence==0 || (outer>1 && outer%cadence!=0)) && return nothing
        persist(solution, it, iv)
    end
    function checkpoint_request(context, it::Integer, iv::Integer)
        clock = get!(() -> CheckpointDeadline(storage_started), clocks, (it, iv))
        cadence =
            context.stage === :scba ? configuration.production.checkpoint_every_scba :
            configuration.production.checkpoint_every_outer
        return checkpoint_due(clock) || (cadence > 0 && context.iteration % cadence == 0)
    end
    function checkpoint_observer(solution::NEGFSolution, it::Integer, iv::Integer)
        solution.status in (:running, :running_scba) || return nothing
        persist(solution, it, iv; analysis = false)
    end
    return (
        solution = solution_observer,
        checkpoint = checkpoint_observer,
        request = checkpoint_request,
        history = history,
    )
end
_configured_light_observer(configuration, output_directory) =
    _configured_storage_observers(configuration, output_directory).solution
