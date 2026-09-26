module Suite_T019
include("../support/common.jl")

@testset "Declarative automatic E1 execution strategy" begin
    root = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))
    configuration = load_run_configuration(joinpath(root, "exact_cpu.yaml"))
    function synthetic_hardware(memory_bytes::Integer; threads::Integer = 12)
        memory = Int(memory_bytes)
        workers = Int(threads)
        return HardwareProfile(
            workers,
            workers,
            memory,
            memory,
            "test-blas",
            memory,
            typemax(Int),
            typemax(Int),
            0,
            workers,
            Inf,
            "synthetic-test-envelope",
            "test fixture",
            "test fixture",
        )
    end
    @test_throws MethodError HardwareProfile(12, 12, 24 * 1024^3, "test-blas")
    # Synthetic roomy process envelope.  The value is deliberately unrelated
    # to any deployment profile; the test verifies the fractional reserve.
    hardware = synthetic_hardware(24 * 1024^3)
    plan = select_execution_plan(configuration; hardware)

    @test plan.requested_strategy == :auto_exact
    @test plan.parallel_backend == :threads
    @test plan.worker_count == 12
    @test plan.blas_threads == 1
    @test 1 <= plan.energy_chunk <= configuration.numerical.N_E
    @test plan.energy_chunk % configuration.execution.automatic.energy_chunk_alignment ==
          0 || plan.energy_chunk == configuration.numerical.N_E
    @test plan.memory_budget_bytes == 21 * 1024^3
    @test plan.estimated_peak_bytes <= plan.memory_budget_bytes
    @test plan.contraction_jobs >= min(
        configuration.numerical.N_E,
        plan.active_contraction_workers *
        configuration.execution.automatic.energy_jobs_per_worker,
    )

    candidates = execution_plan_candidates(configuration; hardware)
    @test any(candidate -> candidate.parallel_backend == :threads, candidates)
    @test any(candidate -> candidate.parallel_backend == :blas, candidates)
    blas_candidate =
        only(filter(candidate -> candidate.parallel_backend == :blas, candidates))
    @test blas_candidate.worker_count == 12
    @test blas_candidate.active_contraction_workers == 1
    @test blas_candidate.blas_threads == 12

    narrow_fft_raw = deepcopy(configuration.raw)
    narrow_fft_raw["production"]["hilbert_columns"] = 4
    narrow_fft = QCLNEGFRunner._resolve_configuration(narrow_fft_raw, configuration.provenance)
    narrow_fft_plan = select_execution_plan(narrow_fft; hardware)
    @test narrow_fft_plan.hilbert_columns ==
          narrow_fft.execution.automatic.hilbert_columns_per_worker
    @test narrow_fft_plan.hilbert_columns <= cld(
        narrow_fft.numerical.N_k * narrow_fft.numerical.N_b^2,
        narrow_fft_plan.worker_count,
    )

    resolved, resolved_plan = resolve_execution_strategy(configuration; hardware)
    @test resolved.algorithms === configuration.algorithms
    @test resolved.scattering === configuration.scattering
    @test resolved.physical === configuration.physical
    @test resolved.numerical === configuration.numerical
    @test resolved.solver === configuration.solver
    @test resolved.kernels === configuration.kernels
    @test all(
        field -> getfield(resolved_plan, field) == getfield(plan, field),
        fieldnames(ExecutionPlan),
    )
    @test resolved.production.parallel_backend == plan.parallel_backend
    @test resolved.production.worker_count == plan.worker_count
    @test resolved.production.memory_budget_bytes == plan.memory_budget_bytes
    @test resolved.raw["production"]["energy_chunk"] == plan.energy_chunk
    @test resolved.raw["production"]["parallel_backend"] == String(plan.parallel_backend)
    @test resolved.raw["execution"]["blas_threads"] == plan.blas_threads
    @test configuration_source(resolved, "production.energy_chunk") ==
          "application:auto_exact"
    reparsed = QCLNEGFRunner._resolve_configuration(resolved.raw, resolved.provenance)
    @test reparsed.production.energy_chunk == resolved.production.energy_chunk
    @test reparsed.production.memory_budget_bytes == typemax(Int)

    analytical_plan, analytical_report =
        calibrate_execution_plan(configuration; hardware, run_benchmark = false)
    @test analytical_report.mode == :analytical
    @test isempty(analytical_report.samples)
    @test analytical_plan.parallel_backend == plan.parallel_backend

    mktempdir() do directory
        path = save_resource_diagnostics(
            joinpath(directory, "resource-diagnostics.yaml"),
            analytical_plan;
            calibration = analytical_report,
        )
        text = read(path, String)
        @test occursin("qcl-negf-resource-diagnostics-v1", text)
        @test occursin("E1_physics_preserving_execution", text)
        @test occursin("estimated_peak_bytes", text)
        @test occursin("test-blas", text)
    end

    oracle = load_run_configuration(joinpath(root, "naive_oracle.yaml"))
    manual = select_execution_plan(oracle; hardware)
    @test manual.requested_strategy == :manual
    @test manual.worker_count == oracle.production.worker_count
    @test manual.blas_threads == oracle.execution.blas_threads
    @test manual.estimated_peak_bytes == 0
    manual_configuration, _ = resolve_execution_strategy(oracle; hardware)
    @test manual_configuration === oracle

    smoke = load_run_configuration(joinpath(root, "studies-smoke.yaml"))
    constrained_hardware = synthetic_hardware(3 * 1024^3)
    constrained = select_execution_plan(smoke; hardware = constrained_hardware)
    @test constrained.memory_budget_bytes == 1024^3
    @test constrained.estimated_peak_bytes <= constrained.memory_budget_bytes
    @test constrained.energy_chunk <= smoke.production.energy_chunk
    automatic = smoke.execution.automatic
    bytes_per_energy =
        smoke.numerical.N_k *
        smoke.numerical.N_b^2 *
        sizeof(ComplexF64) *
        automatic.workspace_complex_arrays_per_energy_block
    workspace_budget =
        floor(Int, constrained.memory_budget_bytes * automatic.workspace_budget_fraction)
    @test constrained.active_contraction_workers *
          constrained.energy_chunk *
          bytes_per_energy <= workspace_budget

    blas_threshold_raw = deepcopy(configuration.raw)
    blas_threshold_raw["execution"]["auto"]["minimum_outer_parallel_threads"] = 13
    blas_threshold =
        QCLNEGFRunner._resolve_configuration(blas_threshold_raw, configuration.provenance)
    blas_plan = select_execution_plan(blas_threshold; hardware)
    @test blas_plan.parallel_backend == :blas
    @test blas_plan.worker_count == 12
    @test blas_plan.active_contraction_workers == 1

    @test_throws ArgumentError select_execution_plan(
        configuration;
        hardware = synthetic_hardware(2 * 1024^3),
    )
    @test_throws ArgumentError select_execution_plan(
        configuration;
        hardware = synthetic_hardware(0),
    )
end

end # independent suite
