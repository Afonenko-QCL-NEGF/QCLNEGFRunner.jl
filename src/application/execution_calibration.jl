"""One bounded E1 scheduling measurement on a synthetic production kernel."""
struct ExecutionCalibrationSample
    parallel_backend::Symbol
    worker_count::Int
    blas_threads::Int
    energy_chunk::Int
    sample_energy_nodes::Int
    sample_momentum_nodes::Int
    sample_basis_states::Int
    repetitions::Int
    median_seconds::Float64
    minimum_seconds::Float64
    maximum_seconds::Float64
    relative_spread::Float64
    output_norm::Float64
    accepted::Bool
    note::String
end

"""Auditable outcome of analytical or bounded execution-plan calibration."""
struct ExecutionCalibrationReport
    mode::Symbol
    maximum_seconds::Float64
    elapsed_seconds::Float64
    samples::Vector{ExecutionCalibrationSample}
    selected_backend::Symbol
    selected_worker_count::Int
    selected_blas_threads::Int
    reasons::Vector{String}
end

function _calibration_median(values::Vector{Float64})
    isempty(values) && return Inf
    ordered = sort(values)
    middle = cld(length(ordered), 2)
    isodd(length(ordered)) && return ordered[middle]
    return (ordered[middle] + ordered[middle+1]) / 2
end

function _calibration_problem_shape(
    configuration::ResolvedRunConfiguration,
    plan::ExecutionPlan,
)
    Nb = min(configuration.numerical.N_b, 6)
    Nk = min(configuration.numerical.N_k, 16)
    chunk = max(1, min(plan.energy_chunk, 16))
    target_workers = plan.parallel_backend === :threads ? max(1, plan.worker_count) : 1
    NE = min(configuration.numerical.N_E, max(64, min(512, 2 * target_workers * chunk)))
    return NE, Nk, Nb, chunk
end

function _calibration_arrays(NE::Int, Nk::Int, Nb::Int)
    compound = Nk * Nb^2
    matrix = Matrix{ComplexF64}(undef, compound, compound)
    @inbounds for column = 1:compound, row = 1:compound
        matrix[row, column] =
            ComplexF64(((row + 3column) % 29 - 14) / 29, ((2row + column) % 31 - 15) / 31)
    end
    green = Array{ComplexF64}(undef, NE, Nk, Nb, Nb)
    @inbounds for index in eachindex(green)
        green[index] = ComplexF64((index % 23 - 11) / 23, (index % 19 - 9) / 19)
    end
    weights = fill(inv(Float64(Nk)), Nk)
    return DenseProductionKernel(matrix, Nk, Nb), green, weights
end

function _benchmark_execution_candidate(
    configuration::ResolvedRunConfiguration,
    plan::ExecutionPlan;
    deadline::Float64,
    repetitions::Int,
)
    NE, Nk, Nb, chunk = _calibration_problem_shape(configuration, plan)
    operator, green, weights = _calibration_arrays(NE, Nk, Nb)
    times = Float64[]
    output_norm = NaN
    note = "bounded synthetic dense contraction; E1 scheduling only"
    BLAS.set_num_threads(plan.blas_threads)
    if time() < deadline
        warm_output = production_static_contraction(
            operator,
            green,
            weights,
            1.0;
            energy_chunk = chunk,
            parallel_backend = plan.parallel_backend,
            worker_count = plan.worker_count,
        )
        output_norm = sqrt(sum(abs2, warm_output))
    end
    for _ = 1:repetitions
        time() >= deadline && break
        GC.gc(false)
        started = time_ns()
        output = production_static_contraction(
            operator,
            green,
            weights,
            1.0;
            energy_chunk = chunk,
            parallel_backend = plan.parallel_backend,
            worker_count = plan.worker_count,
        )
        elapsed = (time_ns() - started) * 1e-9
        push!(times, elapsed)
        output_norm = sqrt(sum(abs2, output))
        isfinite(output_norm) || break
    end
    measured = length(times)
    median_seconds = _calibration_median(times)
    minimum_seconds = isempty(times) ? Inf : minimum(times)
    maximum_seconds = isempty(times) ? Inf : maximum(times)
    relative_spread =
        measured < 2 || !isfinite(median_seconds) ? Inf :
        (maximum_seconds - minimum_seconds) / max(median_seconds, eps())
    accepted =
        measured >= 2 &&
        isfinite(output_norm) &&
        isfinite(relative_spread) &&
        relative_spread <= 0.50
    measured < 2 && (note *= "; insufficient repetitions before deadline")
    relative_spread > 0.50 &&
        isfinite(relative_spread) &&
        (note *= "; timing spread exceeds 50%")
    return ExecutionCalibrationSample(
        plan.parallel_backend,
        plan.worker_count,
        plan.blas_threads,
        chunk,
        NE,
        Nk,
        Nb,
        measured,
        median_seconds,
        minimum_seconds,
        maximum_seconds,
        relative_spread,
        output_norm,
        accepted,
        note,
    )
end

function _plan_with_calibration_reason(plan::ExecutionPlan, reason::AbstractString)
    return ExecutionPlan(
        plan.requested_strategy,
        plan.parallel_backend,
        plan.worker_count,
        plan.blas_threads,
        plan.energy_chunk,
        plan.hilbert_columns,
        plan.residual_chunk,
        plan.memory_budget_bytes,
        plan.estimated_peak_bytes,
        plan.contraction_jobs,
        plan.active_contraction_workers,
        plan.hardware,
        [plan.reasons; String(reason)],
    )
end

"""
    calibrate_execution_plan(configuration; ...)

Optionally compare the feasible E1 scheduling candidates with a bounded,
deterministic dense-contraction microbenchmark. The benchmark never constructs
a physical model, changes an algorithm option, or executes the educational
solver. A noisy or incomplete measurement falls back to the analytical plan.
"""
function calibrate_execution_plan(
    configuration::ResolvedRunConfiguration;
    hardware::HardwareProfile = default_hardware_profile(),
    run_benchmark::Bool = false,
    maximum_seconds::Real = 5.0,
    repetitions::Integer = 3,
    minimum_winning_margin::Real = 0.03,
)
    0 < maximum_seconds <= 60 ||
        throw(ArgumentError("calibration maximum_seconds must lie in (0, 60]"))
    2 <= repetitions <= 7 ||
        throw(ArgumentError("calibration repetitions must lie in [2, 7]"))
    0 <= minimum_winning_margin < 1 ||
        throw(ArgumentError("minimum_winning_margin must lie in [0, 1)"))
    analytical = select_execution_plan(configuration; hardware)
    candidates = execution_plan_candidates(configuration; hardware)
    if !run_benchmark || length(candidates) == 1
        reason =
            run_benchmark ?
            "calibration is not applicable to a manual or educational plan" :
            "analytical resource plan selected; microbenchmark not requested"
        report = ExecutionCalibrationReport(
            :analytical,
            Float64(maximum_seconds),
            0.0,
            ExecutionCalibrationSample[],
            analytical.parallel_backend,
            analytical.worker_count,
            analytical.blas_threads,
            [reason],
        )
        return _plan_with_calibration_reason(analytical, reason), report
    end

    started = time()
    deadline = started + Float64(maximum_seconds)
    samples = ExecutionCalibrationSample[]
    previous_blas_threads = BLAS.get_num_threads()
    try
        for candidate in candidates
            time() >= deadline && break
            try
                push!(
                    samples,
                    _benchmark_execution_candidate(
                        configuration,
                        candidate;
                        deadline,
                        repetitions = Int(repetitions),
                    ),
                )
            catch error
                NE, Nk, Nb, chunk = _calibration_problem_shape(configuration, candidate)
                push!(
                    samples,
                    ExecutionCalibrationSample(
                        candidate.parallel_backend,
                        candidate.worker_count,
                        candidate.blas_threads,
                        chunk,
                        NE,
                        Nk,
                        Nb,
                        0,
                        Inf,
                        Inf,
                        Inf,
                        Inf,
                        NaN,
                        false,
                        "calibration candidate failed: " * sprint(showerror, error),
                    ),
                )
            end
        end
    finally
        BLAS.set_num_threads(previous_blas_threads)
    end
    accepted = [(index, sample) for (index, sample) in pairs(samples) if sample.accepted]
    reasons = String[]
    selected = analytical
    if isempty(accepted)
        push!(reasons, "no stable calibration sample completed; analytical plan retained")
    else
        sort!(accepted; by = item -> item[2].median_seconds)
        winning_index, winner = first(accepted)
        decisive =
            length(accepted) >= 2 &&
            winner.median_seconds <=
            accepted[2][2].median_seconds * (1 - Float64(minimum_winning_margin))
        if decisive
            selected = candidates[winning_index]
            push!(
                reasons,
                "bounded E1 calibration selected " *
                "$(winner.parallel_backend) with $(winner.worker_count) " *
                "Julia workers and $(winner.blas_threads) BLAS threads",
            )
        elseif length(accepted) < 2
            push!(
                reasons,
                "fewer than two stable candidates completed; " *
                "deterministic analytical plan retained",
            )
        else
            push!(
                reasons,
                "calibration candidates are within the winning " *
                "margin; deterministic analytical plan retained",
            )
        end
    end
    elapsed = time() - started
    reason = join(reasons, "; ")
    report = ExecutionCalibrationReport(
        :microbenchmark,
        Float64(maximum_seconds),
        elapsed,
        samples,
        selected.parallel_backend,
        selected.worker_count,
        selected.blas_threads,
        reasons,
    )
    return _plan_with_calibration_reason(selected, reason), report
end
