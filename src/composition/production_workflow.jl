function _validate_production_checkpoint_prefix(checkpoint_prefix::AbstractString)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", checkpoint_prefix) ||
        throw(ArgumentError("checkpoint_prefix is not a portable filename stem"))
    return checkpoint_prefix
end

function _production_checkpoint_name(
    output_directory::AbstractString,
    checkpoint_prefix::AbstractString,
    temperature_index::Integer,
    voltage_index::Integer,
)
    _validate_production_checkpoint_prefix(checkpoint_prefix)
    return joinpath(
        output_directory,
        "$(checkpoint_prefix)_T$(temperature_index)_V$(voltage_index).h5",
    )
end

function _configured_optical_response!(
    metrics::Dict{Symbol,Float64},
    solution::NEGFSolution,
    photon_energies,
    path::Union{Nothing,AbstractString};
    edge_tolerance::Real = 1e-4,
    threaded::Bool = true,
)
    response =
        bare_bubble_optical_response(solution, photon_energies; edge_tolerance, threaded)
    path === nothing || save_optical_response(path, response)
    metrics[:optical_trusted_fraction] = count(response.trusted) / length(response.trusted)
    metrics[:optical_max_edge_loss] = maximum(response.edge_loss)
    eligible = findall(response.trusted)
    if isempty(eligible)
        metrics[:gain_peak_per_cm] = NaN
        metrics[:gain_peak_energy_eV] = NaN
        metrics[:gain_peak_frequency_Hz] = NaN
    else
        peak = peak_gain(response)
        metrics[:gain_peak_per_cm] = Float64(ustrip(u"cm^-1", peak.gain))
        metrics[:gain_peak_energy_eV] = _electronvolts(peak.photon_energy)
        metrics[:gain_peak_frequency_Hz] = Float64(ustrip(u"Hz", peak.frequency))
    end
    return response
end

"""
    run_production_sweep(base_problem, voltages, temperatures; ...)

reference design-oriented overload that reuses one expensive static problem and one set
of flattened kernels across a sequential bias/temperature sweep.  `voltages`
must contain Unitful voltage drops per period and `temperatures` Unitful
temperatures.  Full states are checkpointed one at a time; only scalar
[`ProductionSweepRecord`](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/api/public.md)s are retained in the result.
`checkpoint_prefix` names point HDF5 files, `save_full_state=false` passes no
checkpoint path into the solver, and `save_csv=false` keeps the summary and
optical diagnostics in memory without creating CSV files.

When `resume_from_checkpoints=true`, an existing, metadata-compatible point
checkpoint has priority over the preceding-bias warm start.  A completed
checkpoint is deliberately re-evaluated from its fixed point so convergence
and validation are certified by the current package version.
An incompatible or corrupt checkpoint fails its operating point by default;
it is never silently loaded or replaced. With `fail_fast=false`, that failure
is recorded as `:execution_failed` and independent points continue without
inheriting its state. With `fail_fast=true`, the original exception propagates
and no subsequent point is started. Configuration errors detected before the
sweep and user interrupts always propagate. The optional
`incompatible_checkpoint` policy belongs only to the direct Julia API; the
configured runtimes always reject incompatible checkpoints.

See [Production sweep, warm start, and recovery](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md) and
the [HDF5 checkpoint schema](@ref native-result-formats).
"""
function run_production_sweep(
    base_problem::NEGFProblem,
    voltages,
    temperatures;
    output_directory::AbstractString = "production_results",
    options::SolverOptions = baseline_options(),
    production_options::ProductionOptions = ProductionOptions(),
    resume_from_checkpoints::Bool = true,
    checkpoint_prefix::AbstractString = "state",
    save_full_state::Bool = true,
    save_csv::Bool = true,
    Tᴸᴼ_of_Tᴸ::Function = identity,
    fail_fast::Bool = false,
    photon_energies = nothing,
    optical_edge_tolerance::Real = 1e-4,
    incompatible_checkpoint::Symbol = :error,
    solution_observer::Union{Nothing,Function} = nothing,
    checkpoint_observer::Union{Nothing,Function} = nothing,
    checkpoint_request::Union{Nothing,Function} = nothing,
    history_observer::Union{Nothing,Function} = nothing,
    domain_adaptation::DomainAdaptationPolicy = DomainAdaptationPolicy(),
    kernel_options::ProductionKernelOptions = ProductionKernelOptions(),
)
    voltage_values = collect(voltages)
    temperature_values = collect(temperatures)
    isempty(voltage_values) && throw(ArgumentError("voltage sweep is empty"))
    isempty(temperature_values) && throw(ArgumentError("temperature sweep is empty"))
    _validate_production_checkpoint_prefix(checkpoint_prefix)
    resume_from_checkpoints &&
        !save_full_state &&
        throw(ArgumentError("resume_from_checkpoints requires save_full_state=true"))
    incompatible_checkpoint in (:error, :ignore, :quarantine) || throw(
        ArgumentError("incompatible_checkpoint must be :error, :ignore, or :quarantine"),
    )
    mkpath(output_directory)

    base_cache = build_production_cache(base_problem; options = production_options)
    records = ProductionSweepRecord[]
    summary_path = save_csv ? joinpath(output_directory, "sweep_summary.csv") : ""
    total_points = length(temperature_values) * length(voltage_values)
    owns_sweep_stage = _begin_solver_stage(
        production_options,
        :sweep;
        label = "reference design operating points",
        total = total_points,
    )
    point_index = 0
    for (it, temperature) in pairs(temperature_values)
        previous = nothing
        for (iv, voltage) in pairs(voltage_values)
            point_index += 1
            voltage_mV = Float64(ustrip(u"mV", uconvert(u"mV", voltage)))
            point_label =
                "T=$(compact_number(_kelvin(temperature))) K, " *
                "Vₚ=$(compact_number(voltage_mV)) mV"
            owns_point_stage = _begin_solver_stage(
                production_options,
                :point;
                label = point_label,
                iteration = point_index,
                total = total_points,
            )
            point_started = time_ns()
            try
                problem = retarget_problem(
                    base_problem;
                    V_period = voltage,
                    Tᴸ = temperature,
                    Tᴸᴼ = Tᴸᴼ_of_Tᴸ(temperature),
                    energy_shift = production_options.algorithms.energy_shift,
                )
                cache = retarget_production_cache(base_cache, problem)
                checkpoint =
                    save_full_state ?
                    _production_checkpoint_name(
                        output_directory,
                        checkpoint_prefix,
                        it,
                        iv,
                    ) : ""
                restart = nothing
                initial_outer_history = OuterIteration[]
                resume_scba = false
                initial_Uᴴ = previous === nothing ? nothing : previous.Uᴴ
                initial_scba = previous === nothing ? nothing : previous.scba
                if resume_from_checkpoints && isfile(checkpoint)
                    restart = load_production_restart(
                        checkpoint,
                        problem;
                        incompatible = incompatible_checkpoint,
                        algorithms = production_options.algorithms,
                        solver_options = options,
                    )
                    if restart !== nothing
                        initial_Uᴴ = restart.Uᴴ
                        initial_scba = restart.scba
                        initial_outer_history = restart.outer_history
                        resume_scba = restart.resume_scba
                        if restart.status === :running
                            # Outer checkpoint stores the accepted pre-update U with completed μ.
                            candidate, _, _, _ = solve_periodic_poisson(
                                problem,
                                _electron_density_bar(problem, restart.scba.green.Gˡ),
                            )
                            initial_Uᴴ =
                                (1-options.α_P) .* initial_Uᴴ .+ options.α_P .* candidate
                        end
                        production_options.event_sink === nothing &&
                            @info("Resuming $point_label from $(basename(checkpoint))")
                    end
                end
                production_options.event_sink === nothing && @info(
                    "Solving $point_label | peak≤$(compact_number(cache.estimate.peak_bytes / 1024.0^3)) GiB"
                )
                solve_started = time_ns()
                point_checkpoint =
                    checkpoint_observer===nothing ?
                    (
                        save_full_state ? (state->_atomic_checkpoint(checkpoint, state)) :
                        nothing
                    ) :
                    (
                        state->begin
                            checkpoint_observer(state, it, iv)
                            save_full_state &&
                                !(state.status in (:running, :running_scba, :snapshot)) &&
                                _atomic_checkpoint(checkpoint, state)
                            nothing
                        end
                    )
                point_options =
                    checkpoint_request === nothing ? production_options :
                    with_production_options(
                        production_options;
                        checkpoint_request = context -> checkpoint_request(context, it, iv),
                    )
                solution = if restart !== nothing && restart.completed
                    _completed_restart_solution(problem, options, restart)
                elseif domain_adaptation.mode !== :none
                    restart===nothing || throw(
                        ArgumentError(
                            "domain adaptation starts from a newly declared domain; resume this point through its saved adapted-domain plan",
                        ),
                    )
                    solve_adaptive_production(
                        problem;
                        domain_adaptation,
                        kernel_options,
                        options,
                        production_options = point_options,
                        cache,
                        initial_Uᴴ,
                        initial_scba,
                        checkpoint_sink = point_checkpoint,
                        state_observer = solution_observer===nothing ? nothing :
                                         (state->solution_observer(state, it, iv)),
                        history_observer = history_observer===nothing ? nothing :
                                           (
                            (kind, outer, row, source)->history_observer(
                                kind,
                                outer,
                                row,
                                source,
                                it,
                                iv,
                            )
                        ),
                    )
                else
                    solve_production(
                        problem;
                        options,
                        production_options = point_options,
                        cache,
                        initial_Uᴴ,
                        initial_scba,
                        checkpoint_sink = point_checkpoint,
                        initial_outer_history,
                        initial_warnings = restart === nothing ? Dict{String,Any}[] :
                                           get(restart, :warnings, Dict{String,Any}[]),
                        resume_scba,
                        history_observer = history_observer===nothing ? nothing :
                                           (
                            (kind, outer, row, source)->history_observer(
                                kind,
                                outer,
                                row,
                                source,
                                it,
                                iv,
                            )
                        ),
                        state_observer = solution_observer === nothing ? nothing :
                                         (state -> solution_observer(state, it, iv)),
                    )
                end
                if restart !== nothing && restart.completed && solution_observer !== nothing
                    solution_observer(solution, it, iv)
                end
                wall_seconds = (time_ns() - solve_started) * 1e-9
                current =
                    Float64(ustrip(u"A/m^2", solution.observables[:electron_flow_current]))
                metrics = _solution_report_metrics(solution)
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
                        cache.estimate.peak_bytes,
                        wall_seconds,
                        metrics,
                        checkpoint,
                        get(solution.observables, :warnings, Dict{String,Any}[]),
                    ),
                )
                save_csv && save_production_summary(
                    summary_path,
                    ProductionSweepResult(copy(records), summary_path),
                )
                # The stationary record is committed before optional optical analysis.
                # An optical failure cannot replace a completed current with NaN.
                if photon_energies !== nothing && solution.converged
                    try
                        optical_path =
                            save_csv ?
                            joinpath(output_directory, "optical_T$(it)_V$(iv).csv") :
                            nothing
                        _configured_optical_response!(
                            metrics,
                            solution,
                            photon_energies,
                            optical_path;
                            edge_tolerance = optical_edge_tolerance,
                            threaded = production_options.parallel_backend === :threads,
                        )
                    catch optical_error
                        optical_error isa InterruptException && rethrow()
                        push!(
                            records[end].warnings,
                            Dict{String,Any}(
                                "code"=>"OPTIONAL_OPTICS_FAILED",
                                "scope"=>"postprocessing",
                                "message"=>sprint(showerror, optical_error),
                            ),
                        )
                    end
                    save_csv && save_production_summary(
                        summary_path,
                        ProductionSweepResult(copy(records), summary_path),
                    )
                end
                if owns_point_stage
                    _end_solver_stage(
                        production_options,
                        :point,
                        true;
                        status = (solution.converged || solution.status === :approximate) ?
                                 :completed : :incomplete,
                        iteration = point_index,
                        total = total_points,
                        metrics = SolverMetric(
                            :J,
                            _solver_current_density(current),
                            "A/cm^2",
                        ),
                        message = String(solution.status),
                    )
                end
                if owns_sweep_stage
                    _update_solver_stage(
                        production_options,
                        :sweep;
                        iteration = point_index,
                        total = total_points,
                        metrics = SolverMetric(:completed_points, point_index),
                    )
                end
                if fail_fast && !(solution.converged || solution.status === :approximate)
                    error(
                        "production point T=$(temperature), Vp=$(voltage) " *
                        "failed with status $(solution.status)",
                    )
                end
                # Cross-point reuse is deliberately stricter than same-point
                # checkpoint recovery: diagnostic or otherwise incomplete states
                # never seed a different physical operating point.
                previous =
                    solution.converged &&
                    solution.scba.converged &&
                    solution.scba.status === :converged &&
                    solution.scba.quality === :strictly_converged ? solution : nothing
            catch error
                error isa InterruptException && rethrow()
                fail_fast && rethrow()
                failure = Dict{String,Any}(
                    "code"=>"CASE_FAILED",
                    "scope"=>"point",
                    "message"=>sprint(showerror, error),
                    "temperature_K"=>_kelvin(temperature),
                    "voltage_per_period_V"=>Float64(ustrip(u"V", voltage)),
                )
                push!(
                    records,
                    ProductionSweepRecord(
                        _kelvin(temperature),
                        Float64(ustrip(u"V", voltage)),
                        NaN,
                        NaN,
                        false,
                        :execution_failed,
                        :invalid,
                        0,
                        0,
                        0,
                        (time_ns()-point_started)*1e-9,
                        Dict{Symbol,Float64}(),
                        "",
                        [failure],
                    ),
                )
                save_csv && save_production_summary(
                    summary_path,
                    ProductionSweepResult(copy(records), summary_path),
                )
                _end_solver_stage(
                    production_options,
                    :point,
                    owns_point_stage;
                    status = :failed,
                    iteration = point_index,
                    total = total_points,
                    message = sprint(showerror, error),
                )
                previous = nothing
                @warn "independent point failed; continuing sweep" exception=(
                    error,
                    catch_backtrace(),
                )
            end
        end
        previous = nothing
        GC.gc()
    end
    if owns_sweep_stage
        _end_solver_stage(
            production_options,
            :sweep,
            true;
            status = :completed,
            iteration = total_points,
            total = total_points,
            metrics = SolverMetric(:points, total_points),
        )
    end
    return ProductionSweepResult(records, summary_path)
end

"""
    save_optical_response(path, response)

Atomically save one optical-response curve as CSV with explicit SI/eV column
names.  The file records `trusted` and `edge_loss` so plotting software cannot
silently treat an energy-window-contaminated point as final data.

See [Optical response](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/18_optical_response.md) and
[production plots and saved data](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md).
"""
function save_optical_response(path::AbstractString, response::OpticalResponse)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary, stream = mktemp(directory)
    try
        println(
            stream,
            join(
                (
                    "photon_energy_eV",
                    "frequency_Hz",
                    "susceptibility_real",
                    "susceptibility_imag",
                    "gain_per_m",
                    "gain_per_cm",
                    "trusted",
                    "edge_loss",
                ),
                ',',
            ),
        )
        for q in eachindex(response.photon_energy)
            values = (
                _electronvolts(response.photon_energy[q]),
                Float64(ustrip(u"Hz", response.frequency[q])),
                real(response.susceptibility[q]),
                imag(response.susceptibility[q]),
                Float64(ustrip(u"m^-1", response.gain[q])),
                Float64(ustrip(u"cm^-1", response.gain[q])),
                response.trusted[q],
                response.edge_loss[q],
            )
            println(stream, join(_csv_field.(values), ','))
        end
        close(stream)
        _atomic_replace_file(temporary, path)
    catch
        isopen(stream) && close(stream)
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return path
end

"""
    save_kernel_diagnostics(path, diagnostics)

Atomically save the measured construction diagnostics returned by
[`build_kernels_production`](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/api/public.md).  One CSV row is written per enabled
mechanism.  Refinement histories are semicolon-separated inside their CSV
fields; residuals are dimensionless and `direct_q_evaluations` is an exact
counter for the adaptive construction and validation work.

See [Microscopic kernels](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/08_kernels.md) and
[production kernel diagnostics](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md).
"""
function save_kernel_diagnostics(
    path::AbstractString,
    diagnostics::ProductionKernelDiagnostics,
)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary, stream = mktemp(directory)
    try
        println(
            stream,
            join(
                (
                    "mechanism",
                    "construction",
                    "lookup_nodes",
                    "direct_q_evaluations",
                    "sampled_global_relative_residual",
                    "sampled_pointwise_relative_residual",
                    "sampled_angular_relative_residual",
                    "angular_quadrature_checked",
                    "angular_quadrature_relative_error",
                    "accepted",
                    "node_history",
                    "residual_history",
                ),
                ',',
            ),
        )
        for mechanism in sort!(collect(keys(diagnostics.mechanisms)); by = string)
            diagnostic = diagnostics.mechanisms[mechanism]
            values = (
                diagnostic.mechanism,
                diagnostic.construction,
                diagnostic.lookup_nodes,
                diagnostic.direct_q_evaluations,
                diagnostic.sampled_global_relative_residual,
                diagnostic.sampled_pointwise_relative_residual,
                diagnostic.sampled_angular_relative_residual,
                diagnostic.angular_quadrature_checked,
                something(diagnostic.angular_quadrature_relative_error, ""),
                diagnostic.accepted,
                join(diagnostic.node_history, ';'),
                join(diagnostic.residual_history, ';'),
            )
            println(stream, join(_csv_field.(values), ','))
        end
        close(stream)
        _atomic_replace_file(temporary, path)
    catch
        isopen(stream) && close(stream)
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return path
end


function _completed_restart_solution(problem::NEGFProblem, options::SolverOptions, restart)
    q = restart.status === :converged ? :strictly_converged : :approximate_fixed_point
    old = restart.scba
    scba = SCBAResult(
        old.green,
        old.scattering,
        old.embedding,
        old.embedding_plus,
        old.embedding_minus,
        old.history,
        q === :strictly_converged,
        q === :strictly_converged ? :converged : :approximate,
        q,
        old.restart_contract,
        old.mixer_state,
    )
    observables = _collect_observables(problem, scba, restart.Uᴴ)
    observables[:warnings] = deepcopy(get(restart, :warnings, Dict{String,Any}[]))
    push!(
        observables[:warnings],
        Dict{String,Any}(
            "code"=>"COMPLETED_CHECKPOINT_REUSED",
            "scope"=>"point",
            "message"=>"Completed compatible case reused without solver iterations.",
        ),
    )
    n = _electron_density_bar(problem, scba.green.Gˡ)
    provisional = NEGFSolution(
        problem,
        options,
        restart.Uᴴ,
        n,
        scba,
        restart.outer_history,
        observables,
        ConvergenceReport(false, Dict{Symbol,Float64}(), String[]),
        false,
        restart.status,
    )
    assessment = _final_quality_report(provisional, true)
    status =
        assessment.converged ? :converged :
        assessment.approximate ? :approximate : :validation_failed
    result = NEGFSolution(
        problem,
        options,
        restart.Uᴴ,
        n,
        scba,
        restart.outer_history,
        observables,
        assessment.report,
        assessment.converged,
        status,
    )
    observables[:quality] = solution_quality(result)
    observables[:termination_reason] = String(status)
    return result
end
