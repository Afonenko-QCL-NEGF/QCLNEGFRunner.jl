"""Port supplying machine resources at the composition boundary."""
function default_hardware_profile end

"""Immutable description of the resources visible to one Julia process."""
struct HardwareProfile
    julia_threads::Int
    logical_cpus::Int
    total_memory_bytes::Int
    available_memory_bytes::Int
    blas_vendor::String
    physical_memory_bytes::Int
    cgroup_memory_max_bytes::Int
    cgroup_memory_high_bytes::Int
    cgroup_memory_current_bytes::Int
    cpu_affinity_count::Int
    cpu_quota_cores::Float64
    cgroup_path::String
    cpu_source::String
    memory_source::String
end

"""Resolved E1-only execution decision recorded beside every configured run."""
struct ExecutionPlan
    requested_strategy::Symbol
    parallel_backend::Symbol
    worker_count::Int
    blas_threads::Int
    energy_chunk::Int
    hilbert_columns::Int
    residual_chunk::Int
    memory_budget_bytes::Int
    estimated_peak_bytes::Int
    contraction_jobs::Int
    active_contraction_workers::Int
    hardware::HardwareProfile
    reasons::Vector{String}
end

_auto_strategy_source() = "application:auto_exact"

function _execution_plan_provenance(
    configuration::ResolvedRunConfiguration,
    plan::ExecutionPlan,
)
    (
        plan.requested_strategy === :auto_exact &&
        configuration.execution.solver_backend === :production
    ) || return configuration.provenance
    sources = deepcopy(configuration.provenance.sources)
    source = _auto_strategy_source()
    for path in (
        "execution.blas_threads",
        "production.energy_chunk",
        "production.hilbert_columns",
        "production.parallel_backend",
        "production.worker_count",
        "production.residual_chunk",
    )
        history = get!(sources, path, String[])
        (isempty(history) || last(history) != source) && push!(history, source)
    end
    return ConfigurationProvenance(
        copy(configuration.provenance.manifests),
        copy(configuration.provenance.files),
        sources,
    )
end

function _automatic_energy_chunk(
    n::NumericalParameters,
    workers::Int,
    memory_budget_bytes::Int,
    configured_chunk::Int,
    policy::AutomaticExecutionConfiguration,
)
    memory_budget_bytes > 0 || throw(
        ArgumentError("automatic execution requires a positive post-reserve memory budget"),
    )
    workers > 0 || throw(ArgumentError("automatic execution requires at least one worker"))
    # Use arbitrary-width arithmetic for the planner itself: an overflowing
    # size estimate must never wrap into a deceptively small, "safe" chunk.
    bytes_per_energy =
        big(n.N_k) *
        big(n.N_b)^2 *
        sizeof(ComplexF64) *
        policy.workspace_complex_arrays_per_energy_block
    bytes_per_energy > 0 ||
        throw(ArgumentError("automatic execution produced an invalid workspace estimate"))
    workspace_budget = floor(
        BigInt,
        BigFloat(memory_budget_bytes) * BigFloat(policy.workspace_budget_fraction),
    )
    safe_capacity = workspace_budget ÷ (big(workers) * bytes_per_energy)
    safe_capacity >= 1 || throw(
        ArgumentError(
            "insufficient memory for one automatic energy-chunk element: " *
            "workspace budget=$(workspace_budget) bytes, " *
            "required=$(big(workers) * bytes_per_energy) bytes",
        ),
    )

    # Memory is a hard upper bound, not an optimization target. A second bound
    # keeps enough independent jobs to occupy every outer worker; the previous
    # memory-maximizing rule could create only nine jobs for 32 workers.
    target_jobs = min(n.N_E, workers * policy.energy_jobs_per_worker)
    occupancy_capacity = target_jobs <= 1 ? n.N_E : fld(n.N_E - 1, target_jobs - 1)
    candidate =
        Int(min(big(n.N_E), safe_capacity, big(configured_chunk), big(occupancy_capacity)))
    alignment = policy.energy_chunk_alignment
    if candidate < n.N_E && candidate >= alignment
        candidate = max(1, alignment * (candidate ÷ alignment))
    end
    candidate <= safe_capacity ||
        throw(AssertionError("automatic energy chunk exceeded its memory-derived capacity"))
    return candidate
end

function _effective_memory_budget(
    hardware::HardwareProfile,
    policy::AutomaticExecutionConfiguration,
    envelope::Union{Nothing,ExecutionEnvelope} = nothing,
)
    envelope === nothing || return execution_budget(hardware, envelope)
    hardware.total_memory_bytes > 0 || throw(
        ArgumentError(
            "automatic execution cannot determine a safe memory budget; " *
            "use strategy=manual or provide a valid HardwareProfile",
        ),
    )
    hardware.available_memory_bytes > 0 || throw(
        ArgumentError("automatic execution found no memory available to this process"),
    )
    reserve = max(
        policy.minimum_memory_reserve_bytes,
        ceil(Int, hardware.total_memory_bytes * policy.memory_reserve_fraction),
    )
    ceiling_budget = hardware.total_memory_bytes - reserve
    available_budget = hardware.available_memory_bytes - reserve
    budget = min(ceiling_budget, available_budget)
    budget > 0 || throw(
        ArgumentError(
            "automatic execution reserve ($(reserve) bytes) leaves no safe " *
            "memory budget in the detected resource envelope",
        ),
    )
    return budget, reserve
end

function _configured_production_estimate(
    configuration::ResolvedRunConfiguration,
    options::ProductionOptions,
)
    scattering = configuration.scattering
    mechanism_count = count(
        identity,
        (
            scattering.LO,
            scattering.acoustic,
            scattering.impurity,
            scattering.IFR,
            scattering.alloy,
        ),
    )
    dense_mechanism_count =
        count(identity, (scattering.LO, scattering.impurity, scattering.IFR))
    lo_kernel = scattering.LO ? :dense : :absent
    return estimate_production_memory(
        configuration.numerical,
        mechanism_count;
        dense_mechanism_count,
        lo_kernel,
        options,
    )
end

function _candidate_execution_plan(
    configuration::ResolvedRunConfiguration,
    hardware::HardwareProfile,
    backend::Symbol,
    worker_cap::Int,
    blas_threads::Int,
    memory_budget::Int,
    reserve::Int,
)
    backend in (:threads, :blas) ||
        throw(ArgumentError("execution candidate backend must be threads or blas"))
    production = configuration.production
    policy = configuration.execution.automatic
    numerical = configuration.numerical
    worker_cap > 0 ||
        throw(ArgumentError("execution candidate requires a positive worker cap"))
    contraction_workers = backend === :threads ? worker_cap : 1
    energy_chunk = _automatic_energy_chunk(
        numerical,
        contraction_workers,
        memory_budget,
        production.energy_chunk,
        policy,
    )
    hilbert_blocks = numerical.N_k * numerical.N_b^2
    hilbert_columns = min(
        max(1, cld(hilbert_blocks, worker_cap)),
        max(production.hilbert_columns, policy.hilbert_columns_per_worker),
    )
    residual_workers = backend === :threads ? worker_cap : 1
    residual_chunk = min(
        production.residual_chunk,
        max(
            1,
            cld(
                numerical.N_E * numerical.N_k,
                max(1, policy.blocks_per_worker * residual_workers),
            ),
        ),
    )

    function candidate_options(chunk, columns)
        return with_production_options(
            production;
            memory_budget_bytes = memory_budget,
            energy_chunk = chunk,
            hilbert_columns = columns,
            parallel_backend = backend,
            worker_count = worker_cap,
            residual_chunk = residual_chunk,
        )
    end

    estimate = _configured_production_estimate(
        configuration,
        candidate_options(energy_chunk, hilbert_columns),
    )
    # The full estimator, rather than the lightweight chunk heuristic, is the
    # final admission gate. Reduce temporary buffers before rejecting a model
    # whose resident scientific arrays still fit.
    while estimate.peak_bytes > memory_budget && (energy_chunk > 1 || hilbert_columns > 1)
        if hilbert_columns > 1
            hilbert_columns = max(1, fld(hilbert_columns, 2))
        elseif energy_chunk > 1
            energy_chunk = max(1, fld(energy_chunk, 2))
        end
        estimate = _configured_production_estimate(
            configuration,
            candidate_options(energy_chunk, hilbert_columns),
        )
    end
    estimate.peak_bytes <= memory_budget || throw(
        ArgumentError(
            "estimated production peak $(estimate.peak_bytes) bytes exceeds " *
            "the detected safe budget $(memory_budget) bytes even with minimum " *
            "temporary buffers",
        ),
    )

    jobs = cld(numerical.N_E, energy_chunk)
    active = backend === :threads ? min(worker_cap, jobs) : 1
    required_jobs = min(numerical.N_E, active * policy.energy_jobs_per_worker)
    jobs >= required_jobs || throw(
        AssertionError(
            "automatic energy chunk does not provide the required worker occupancy",
        ),
    )
    reasons = String[
        backend === :threads ?
        "independent energy blocks use Julia workers and single-threaded BLAS" :
        "dense matrix products use threaded BLAS; independent Julia phases retain the worker cap",
        "resource reserve is $(reserve) bytes from the detected process envelope",
        "keep at least $(policy.energy_jobs_per_worker) energy jobs per contraction worker",
        "full production peak estimate fits the detected dynamic budget",
        "automatic policy is restricted to physics-preserving E1 scheduling",
    ]
    energy_chunk < production.energy_chunk && push!(
        reasons,
        "reduced energy_chunk from $(production.energy_chunk) to " *
        "$energy_chunk for occupancy or memory safety",
    )
    energy_chunk < min(policy.minimum_energy_chunk, numerical.N_E) && push!(
        reasons,
        "the safe occupancy bound overrode the soft " *
        "minimum_energy_chunk throughput preference",
    )
    hilbert_columns < production.hilbert_columns && push!(
        reasons,
        "reduced hilbert_columns from $(production.hilbert_columns) to " *
        "$hilbert_columns for the per-worker column range or memory safety",
    )
    return ExecutionPlan(
        configuration.execution.strategy,
        backend,
        worker_cap,
        blas_threads,
        energy_chunk,
        hilbert_columns,
        residual_chunk,
        memory_budget,
        estimate.peak_bytes,
        jobs,
        active,
        hardware,
        reasons,
    )
end

"""
    execution_plan_candidates(configuration; hardware=default_hardware_profile())

Return feasible E1 scheduling candidates. The list changes only scheduling,
temporary-buffer sizes, and BLAS/JULIA worker allocation; scientific inputs
are never modified.
"""
function execution_plan_candidates(
    configuration::ResolvedRunConfiguration;
    hardware::HardwareProfile = default_hardware_profile(),
    envelope::Union{Nothing,ExecutionEnvelope} = default_execution_envelope(),
)
    requested = configuration.execution.strategy
    requested in (:manual, :auto_exact) ||
        throw(ArgumentError("unknown execution strategy: $requested"))
    production = configuration.production
    if requested === :manual || configuration.execution.solver_backend === :educational
        reason =
            requested === :manual ? "manual configuration policy" :
            "educational oracle keeps its literal single-thread schedule"
        estimated_peak =
            configuration.execution.solver_backend === :production ?
            _configured_production_estimate(configuration, production).peak_bytes : 0
        workers =
            production.parallel_backend === :threads ?
            max(
                1,
                min(
                    hardware.julia_threads,
                    production.worker_count == 0 ? hardware.julia_threads :
                    production.worker_count,
                ),
            ) : 1
        jobs = cld(configuration.numerical.N_E, production.energy_chunk)
        budget =
            envelope === nothing ? production.memory_budget_bytes :
            min(production.memory_budget_bytes, first(execution_budget(hardware, envelope)))
        envelope === nothing ||
            estimated_peak <= budget ||
            throw(
                ArgumentError(
                    "manual execution estimate exceeds the numerical memory grant",
                ),
            )
        return [
            ExecutionPlan(
                requested,
                production.parallel_backend,
                production.worker_count,
                envelope === nothing ? configuration.execution.blas_threads : 1,
                production.energy_chunk,
                production.hilbert_columns,
                production.residual_chunk,
                budget,
                estimated_peak,
                jobs,
                min(workers, jobs),
                hardware,
                [reason],
            ),
        ]
    end

    threads =
        envelope === nothing ? max(min(hardware.julia_threads, hardware.logical_cpus), 1) :
        envelope.thread_pool_size
    budget, reserve =
        _effective_memory_budget(hardware, configuration.execution.automatic, envelope)
    candidates = ExecutionPlan[]
    failures = String[]
    function add_candidate(backend, worker_cap, blas_threads)
        try
            push!(
                candidates,
                _candidate_execution_plan(
                    configuration,
                    hardware,
                    backend,
                    worker_cap,
                    blas_threads,
                    budget,
                    reserve,
                ),
            )
        catch error
            push!(
                failures,
                "$(backend)/workers=$(worker_cap)/blas=" *
                "$(blas_threads): $(sprint(showerror, error))",
            )
        end
        return nothing
    end
    add_candidate(:threads, threads, 1)
    if threads >= 4
        half = max(1, cld(threads, 2))
        add_candidate(:threads, half, 1)
    end
    if envelope === nothing
        add_candidate(:blas, threads, threads)
    elseif threads > 1
        # Queued workers use one BLAS thread. Keep a low-memory fallback in
        # the Julia pool rather than selecting a BLAS plan that the runner
        # would subsequently force into an accidental serial execution.
        add_candidate(:threads, 1, 1)
    end
    if envelope !== nothing
        for candidate in candidates
            push!(
                candidate.reasons,
                "explicit allocation bounds numerical RAM and task width; BLAS threads=1",
            )
        end
    end
    isempty(candidates) && throw(
        ArgumentError(
            "no execution candidate fits the detected resource envelope: " *
            join(failures, " | "),
        ),
    )
    return candidates
end

"""
    select_execution_plan(configuration; hardware=default_hardware_profile())

Resolve only computational scheduling. `:auto_exact` cannot change
`AlgorithmOptions`, scattering models, tolerances, grids, or basis. The
decision is therefore E1 even when the requested scientific run is E2/E3.
The default decision is deterministic; optional bounded calibration can choose
among the same candidates before a run starts.
"""
function select_execution_plan(
    configuration::ResolvedRunConfiguration;
    hardware::HardwareProfile = default_hardware_profile(),
    envelope::Union{Nothing,ExecutionEnvelope} = default_execution_envelope(),
)
    candidates = execution_plan_candidates(configuration; hardware, envelope)
    length(candidates) == 1 && return only(candidates)
    policy = configuration.execution.automatic
    prefer_threads =
        (envelope === nothing ? hardware.logical_cpus : envelope.thread_pool_size) >=
        policy.minimum_outer_parallel_threads &&
        configuration.numerical.N_b < policy.large_basis_threshold
    preferred_backend = prefer_threads ? :threads : :blas
    preferred = filter(plan -> plan.parallel_backend === preferred_backend, candidates)
    return isempty(preferred) ? first(candidates) : first(preferred)
end

function _configuration_with_execution_plan(
    configuration::ResolvedRunConfiguration,
    plan::ExecutionPlan;
    managed::Bool = false,
)
    !managed &&
        (
            plan.requested_strategy === :manual ||
            configuration.execution.solver_backend === :educational
        ) &&
        return configuration
    execution = ExecutionConfiguration(
        configuration.execution.strategy,
        configuration.execution.solver_backend,
        configuration.execution.julia_threads,
        plan.blas_threads,
        configuration.execution.fail_on_thread_mismatch,
        configuration.execution.automatic,
    )
    production = with_production_options(
        configuration.production;
        memory_budget_bytes = plan.memory_budget_bytes,
        energy_chunk = plan.energy_chunk,
        hilbert_columns = plan.hilbert_columns,
        parallel_backend = plan.parallel_backend,
        worker_count = plan.worker_count,
        residual_chunk = plan.residual_chunk,
    )
    raw = deepcopy(configuration.raw)
    raw["execution"]["blas_threads"] = plan.blas_threads
    raw["production"]["energy_chunk"] = plan.energy_chunk
    raw["production"]["hilbert_columns"] = plan.hilbert_columns
    raw["production"]["parallel_backend"] = String(plan.parallel_backend)
    raw["production"]["worker_count"] = plan.worker_count
    raw["production"]["residual_chunk"] = plan.residual_chunk
    provenance = _execution_plan_provenance(configuration, plan)
    return ResolvedRunConfiguration(
        configuration.name,
        configuration.description,
        configuration.classification,
        configuration.physical,
        configuration.numerical,
        configuration.scales,
        configuration.scattering,
        configuration.solver,
        production,
        configuration.kernels,
        configuration.algorithms,
        execution,
        configuration.output,
        configuration.study,
        provenance,
        raw,
        configuration.physical_models,
        configuration.domain_adaptation,
    )
end

"""Apply the selected E1 execution plan without changing scientific inputs."""
function resolve_execution_strategy(
    configuration::ResolvedRunConfiguration;
    hardware::HardwareProfile = default_hardware_profile(),
    envelope::Union{Nothing,ExecutionEnvelope} = default_execution_envelope(),
)
    plan = select_execution_plan(configuration; hardware, envelope)
    return _configuration_with_execution_plan(
        configuration,
        plan;
        managed = envelope !== nothing,
    ),
    plan
end
