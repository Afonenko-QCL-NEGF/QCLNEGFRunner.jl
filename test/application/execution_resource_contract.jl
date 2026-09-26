module Suite_ExecutionResourceContract
include("../support/common.jl")
using YAML

const GiB = 1024^3

function managed_hardware(; hard = 10GiB, pool = 12)
    # memory.high and MemAvailable describe current pressure, not a second
    # authorization boundary for the already reserved numerical buffers.
    return HardwareProfile(
        pool,
        2,
        9GiB,
        256 * 1024^2,
        "test-blas",
        60GiB,
        hard,
        9GiB,
        9GiB,
        2,
        Inf,
        "managed-test",
        "affinity",
        "cgroup",
    )
end



@testset "Managed execution resource authority" begin
    envelope =
        QCLNEGFRunner.ExecutionEnvelope("allocation", 8GiB, GiB, GiB, 10GiB, 12, [0, 1])
    hardware = managed_hardware()
    @test QCLNEGFRunner.execution_budget(hardware, envelope) == (8GiB, 0)
    @test_throws ArgumentError QCLNEGFRunner.execution_budget(
        managed_hardware(; hard = 9GiB),
        envelope,
    )
    @test_throws ArgumentError QCLNEGFRunner.execution_budget(
        managed_hardware(; pool = 8),
        envelope,
    )
    @test parentmodule(HardwareProfile) === QCLNEGFRunner.QCLExecutionPolicy
    @test parentmodule(ResolvedRunConfiguration) === QCLNEGFRunner.QCLConfiguration

    configuration = load_run_configuration(
        joinpath(TEST_ROOT, "fixtures", "configurations", "exact_cpu.yaml"),
    )
    resolved, plan = resolve_execution_strategy(configuration; hardware, envelope)
    @test plan.memory_budget_bytes == 8GiB
    @test plan.worker_count == 12
    @test plan.hardware.logical_cpus == 2
    @test plan.hardware.available_memory_bytes == 256 * 1024^2
    @test resolved.production.memory_budget_bytes == 8GiB
    @test resolved.algorithms === configuration.algorithms
    @test resolved.scattering === configuration.scattering
    @test resolved.physical === configuration.physical
    @test resolved.numerical === configuration.numerical
    @test resolved.solver === configuration.solver
    @test_throws ArgumentError select_execution_plan(
        configuration;
        hardware,
        envelope = nothing,
    )

    # Standalone large-basis policy normally selects BLAS. Queued BLAS is
    # fixed at one thread, so that choice would accidentally serialize a
    # wide CPU grant. Managed plans retain outer Julia parallelism instead.
    blas_raw = deepcopy(configuration.raw)
    blas_raw["execution"]["auto"]["large_basis_threshold"] = configuration.numerical.N_b
    blas_preferred = QCLNEGFRunner._resolve_configuration(blas_raw, configuration.provenance)
    managed_candidates = execution_plan_candidates(blas_preferred; hardware, envelope)
    @test all(
        candidate -> candidate.parallel_backend === :threads && candidate.blas_threads == 1,
        managed_candidates,
    )
    @test select_execution_plan(blas_preferred; hardware, envelope).worker_count == 12
    @test any(candidate -> candidate.worker_count == 1, managed_candidates)

    manual_raw = deepcopy(configuration.raw)
    manual_raw["execution"]["strategy"] = "manual"
    manual_raw["execution"]["blas_threads"] = 12
    manual = QCLNEGFRunner._resolve_configuration(manual_raw, configuration.provenance)
    managed_manual, manual_plan = resolve_execution_strategy(manual; hardware, envelope)
    @test managed_manual.production.memory_budget_bytes == 8GiB
    @test managed_manual.production.energy_chunk == manual.production.energy_chunk
    @test managed_manual.numerical === manual.numerical
    @test manual_plan.requested_strategy === :manual
    @test manual_plan.blas_threads == 1
    @test managed_manual.execution.blas_threads == 1
    @test manual.execution.blas_threads == 12
    @test first(resolve_execution_strategy(manual; hardware, envelope = nothing)) === manual
    tiny_grant = QCLNEGFRunner.ExecutionEnvelope("tiny", 1, GiB, GiB, 3GiB, 12, [0])
    @test_throws ArgumentError select_execution_plan(
        manual;
        hardware,
        envelope = tiny_grant,
    )
end

@testset "Execution envelope rejects malformed grants" begin
    good = ("allocation", 8GiB, GiB, GiB, 10GiB, 12, [0, 1])
    for (index, invalid) in (
        (1, 1),
        (1, ""),
        (2, true),
        (2, 0),
        (2, -1),
        (2, 1.0),
        (2, big(typemax(Int)) + 1),
        (3, 0),
        (4, 0),
        (5, 9GiB),
        (6, 1),
        (7, true),
        (7, []),
        (7, [0, 0]),
        (7, [false]),
        (7, [-1]),
        (7, [big(typemax(Int)) + 1]),
    )
        values = Any[good...]
        values[index] = invalid
        @test_throws ArgumentError QCLNEGFRunner.ExecutionEnvelope(values...)
    end
    source = [0, 1]
    grant = QCLNEGFRunner.ExecutionEnvelope("allocation", 8GiB, GiB, GiB, 10GiB, 12, source)
    source[1] = 3
    @test grant.cpu_ids == [0, 1]

    @test QCLNEGFRunner.default_execution_envelope() === nothing
end

@testset "Phase width respects the fixed Julia pool" begin
    request = QCLNEGFRunner._native_phase_request(nothing)
    pool = Threads.nthreads(:default)
    @test request((task_width = 1, elastic = true)) == 1
    @test request((task_width = pool, elastic = false)) == pool
    @test request((task_width = pool + 1, elastic = true)) == pool
    @test_throws ArgumentError request((task_width = 0, elastic = true))
end
end
