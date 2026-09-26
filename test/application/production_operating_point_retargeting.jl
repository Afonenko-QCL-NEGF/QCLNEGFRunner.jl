module Suite_T093
include("../support/common.jl")
using HDF5

@testset "Production operating-point retargeting" begin
    production_grid = reference_production_numerics()
    baseline_grid = baseline_numerics()
    @test uconvert(u"meV", production_grid.M_E) == 80.0u"meV"
    @test production_grid.N_E == baseline_grid.N_E
    @test production_grid.E_min == baseline_grid.E_min
    @test production_grid.E_max == baseline_grid.E_max

    # Keep the test small while exercising the same 80 meV trust-margin contract as
    # the full production preset.
    t = tutorial_numerics()
    numerical = NumericalParameters(
        N_z = t.N_z,
        N_b = t.N_b,
        P_basis = t.P_basis,
        E_min = t.E_min,
        E_max = t.E_max,
        N_E = t.N_E,
        M_E = 80.0u"meV",
        k_max = t.k_max,
        N_k = t.N_k,
        N_φ = t.N_φ,
        qz_max = t.qz_max,
        N_qz = t.N_qz,
        η_seed = t.η_seed,
    )
    scattering = ScatteringOptions(
        LO = false,
        acoustic = true,
        impurity = false,
        IFR = false,
        alloy = false,
    )
    problem = build_problem(numerical = numerical, scattering = scattering)
    target =
        retarget_problem(problem; V_period = 64.0u"mV", Tᴸ = 400.0u"K", Tᴸᴼ = 300.0u"K")

    @test target.grids === problem.grids
    @test target.profiles === problem.profiles
    @test target.basis === problem.basis
    @test target.kernels.K === problem.kernels.K
    @test target.kernels.Fᴸᴼ === problem.kernels.Fᴸᴼ
    @test target.W₊ᴸᴼ === problem.W₊ᴸᴼ
    @test target.W₋ᴸᴼ === problem.W₋ᴸᴼ
    @test target.physical.Tᴸ == 400.0u"K"
    @test target.physical.Tᴸᴼ == 300.0u"K"
    @test uconvert(
        u"mV",
        target.physical.F_bias * QCLNEGFRunner.period_length(target.physical),
    ) ≈ 64.0u"mV"
    @test target.kernels.qᴷ[:acoustic] ≈ 2 * problem.kernels.qᴷ[:acoustic]
    @test target.W₊ᴱᵖ != problem.W₊ᴱᵖ
    @test validate_problem(target).passed

    field_target = retarget_problem(problem; F_bias = 20.0u"kV/cm")
    @test field_target.physical.F_bias ≈ 20.0u"kV/cm"
    @test_throws ArgumentError retarget_problem(
        problem;
        V_period = 56.0u"mV",
        F_bias = 20.0u"kV/cm",
    )
    @test_throws ArgumentError retarget_problem(problem; F_bias = -1.0u"V/m")
    @test_throws ArgumentError retarget_problem(problem; Tᴸ = 0.0u"K")

    production_options = ProductionOptions(
        progress_every_scba = 0,
        progress_every_outer = 0,
        verify_fft_roundoff = false,
    )
    cache = build_production_cache(problem; options = production_options)
    retargeted_cache = retarget_production_cache(cache, target)
    @test retargeted_cache.kernels === cache.kernels
    @test retargeted_cache.estimate === cache.estimate

    # Same dimensions are insufficient: a cache is tied to the exact grid and
    # normalized-kernel objects from which its flattened operators were built.
    same_shape_other_problem = deepcopy(problem)
    @test size(same_shape_other_problem.kernels.K[:acoustic]) ==
          size(problem.kernels.K[:acoustic])
    @test_throws ArgumentError retarget_production_cache(cache, same_shape_other_problem)

    # Passing the old-bias cache directly must not silently use stale period
    # energy shifts.  The supported path is retarget_production_cache above.
    one_step = SolverOptions(
        max_scba = 1,
        max_poisson = 1,
        tolerances = tutorial_options().tolerances,
    )
    @test_throws ArgumentError solve_scba_production(
        target,
        zeros(target.numerical.N_z);
        options = one_step,
        production_options = production_options,
        cache = cache,
    )

    # Runtime options are re-evaluated even for an already built cache.  A
    # stricter RAM limit must trigger the current guard rather than inheriting
    # the estimate/limit captured during cache construction.
    tiny_memory = ProductionOptions(
        memory_budget_bytes = 1,
        energy_chunk = 1,
        hilbert_columns = 1,
        verify_fft_roundoff = false,
        progress_every_scba = 0,
        progress_every_outer = 0,
    )
    @test cache.estimate.memory_budget_bytes != tiny_memory.memory_budget_bytes
    @test_throws ArgumentError solve_scba_production(
        problem,
        zeros(problem.numerical.N_z);
        options = one_step,
        production_options = tiny_memory,
        cache = cache,
    )

    # A production warm start is accepted only when every retained array,
    # including embedding families and Green diagnostics, matches the target
    # discretization.  This mirrors the educational backend's contract.
    shape = (
        problem.numerical.N_E,
        problem.numerical.N_k,
        problem.numerical.N_b,
        problem.numerical.N_b,
    )
    diagnostics_shape = (problem.numerical.N_E, problem.numerical.N_k)
    family() = SelfEnergyFamily(
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
    )
    green = GreenState(
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(Float64, diagnostics_shape),
        ones(Float64, diagnostics_shape),
    )
    valid_scattering = Dict(:acoustic => family())
    wrong_family = SelfEnergyFamily(
        zeros(ComplexF64, 1, 1, 1, 1),
        zeros(ComplexF64, 1, 1, 1, 1),
        zeros(ComplexF64, 1, 1, 1, 1),
    )
    bad_embedding = SCBAResult(
        green,
        valid_scattering,
        wrong_family,
        family(),
        family(),
        SCBAIteration[],
        false,
        :running,
        :unresolved,
    )
    @test_throws DimensionMismatch solve_scba_production(
        problem,
        zeros(problem.numerical.N_z);
        options = one_step,
        production_options = production_options,
        cache = cache,
        initial = bad_embedding,
    )

    wrong_green = GreenState(
        zeros(ComplexF64, 1, 1, 1, 1),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(Float64, diagnostics_shape),
        ones(Float64, diagnostics_shape),
    )
    bad_green = SCBAResult(
        wrong_green,
        valid_scattering,
        family(),
        family(),
        family(),
        SCBAIteration[],
        false,
        :running,
        :unresolved,
    )
    @test_throws DimensionMismatch solve_scba_production(
        problem,
        zeros(problem.numerical.N_z);
        options = one_step,
        production_options = production_options,
        cache = cache,
        initial = bad_green,
    )

    wrong_diagnostics = GreenState(
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(Float64, 1, 1),
        ones(Float64, diagnostics_shape),
    )
    bad_diagnostics = SCBAResult(
        wrong_diagnostics,
        valid_scattering,
        family(),
        family(),
        family(),
        SCBAIteration[],
        false,
        :running,
        :unresolved,
    )
    @test_throws DimensionMismatch solve_scba_production(
        problem,
        zeros(problem.numerical.N_z);
        options = one_step,
        production_options = production_options,
        cache = cache,
        initial = bad_diagnostics,
    )

    X = reshape(ComplexF64.(1:problem.numerical.N_E), problem.numerical.N_E, 1, 1, 1)
    @test apply_energy_shift(retargeted_cache.W̃₊ᴱᵖ, X) ≈ apply_energy_shift(target.W₊ᴱᵖ, X)
    @test apply_energy_shift(retargeted_cache.W̃₋ᴱᵖ, X) ≈ apply_energy_shift(target.W₋ᴱᵖ, X)
    @test apply_energy_shift(retargeted_cache.W̃₊ᴸᴼ, X) ≈ apply_energy_shift(target.W₊ᴸᴼ, X)
    @test apply_energy_shift(retargeted_cache.W̃₋ᴸᴼ, X) ≈ apply_energy_shift(target.W₋ᴸᴼ, X)

    # Exercise the memory-safe sweep overload and its atomic summary/final
    # checkpoint path without pretending that a one-step fixture converges.
    mktempdir() do directory
        sweep = run_production_sweep(
            problem,
            [60.0u"mV"],
            [250.0u"K"];
            output_directory = directory,
            options = one_step,
            production_options = production_options,
            resume_from_checkpoints = false,
            checkpoint_prefix = "reference2019_state",
            fail_fast = false,
        )
        @test length(sweep.records) == 1
        if only(sweep.records).status === :execution_failed
            @error "Unexpected sweep execution failure" warnings=only(sweep.records).warnings
        end
        @test sweep.records[1].temperature_K == 250.0
        @test sweep.records[1].voltage_per_period_V ≈ 0.060
        @test isfile(sweep.summary_path)
        @test length(readlines(sweep.summary_path)) == 2
        @test isfile(sweep.records[1].checkpoint)
        @test basename(sweep.records[1].checkpoint) == "reference2019_state_T1_V1.h5"
        @test !sweep.records[1].converged
        @test sweep.records[1].status !== :execution_failed
        @test sweep.records[1].final_scba_iterations == 1

        # A rejected restart fails this point, preserves the evidence, and
        # leaves an independent point able to execute real solver iterations.
        # Continuing the study must not turn the rejected state into a warm
        # start or report it as a numerically accepted solution.
        checkpoint = sweep.records[1].checkpoint
        HDF5.h5open(checkpoint, "r+") do file
            dataset = file["numerical_inputs/Nz"]
            HDF5.write(dataset, problem.numerical.N_z - 1)
        end
        incompatible_bytes = read(checkpoint)
        observed_points = Tuple{Int,Int}[]
        continued = run_production_sweep(
            problem,
            [60.0u"mV", 64.0u"mV"],
            [250.0u"K"];
            output_directory = directory,
            options = one_step,
            production_options = production_options,
            resume_from_checkpoints = true,
            checkpoint_prefix = "reference2019_state",
            fail_fast = false,
            solution_observer = (_, it, iv) -> push!(observed_points, (it, iv)),
        )
        @test length(continued.records) == 2
        failed, subsequent = continued.records
        @test failed.status === :execution_failed
        @test failed.scba_quality === :invalid
        @test !failed.converged
        @test isnan(failed.current_A_per_m2)
        @test failed.outer_iterations == 0
        @test failed.final_scba_iterations == 0
        @test only(failed.warnings)["code"] == "CASE_FAILED"
        @test occursin("restart N_z mismatch", only(failed.warnings)["message"])
        @test subsequent.voltage_per_period_V ≈ 0.064
        @test subsequent.status !== :execution_failed
        @test subsequent.final_scba_iterations == 1
        @test isfile(subsequent.checkpoint)
        @test basename(subsequent.checkpoint) == "reference2019_state_T1_V2.h5"
        @test !isempty(observed_points)
        @test all(==((1, 2)), observed_points)
        @test length(readlines(continued.summary_path)) == 3
        @test occursin("execution_failed", readlines(continued.summary_path)[2])
        @test isfile(checkpoint)
        @test read(checkpoint) == incompatible_bytes

        # The same mismatch remains an exception in fail-fast mode. Use a
        # separate output directory so absence of the second checkpoint proves
        # that no later operating point was run.
        strict_directory = joinpath(directory, "fail_fast")
        mkpath(strict_directory)
        strict_checkpoint = joinpath(strict_directory, basename(checkpoint))
        write(strict_checkpoint, incompatible_bytes)
        empty!(observed_points)
        @test_throws ArgumentError run_production_sweep(
            problem,
            [60.0u"mV", 64.0u"mV"],
            [250.0u"K"];
            output_directory = strict_directory,
            options = one_step,
            production_options = production_options,
            resume_from_checkpoints = true,
            checkpoint_prefix = "reference2019_state",
            fail_fast = true,
            solution_observer = (_, it, iv) -> push!(observed_points, (it, iv)),
        )
        @test read(strict_checkpoint) == incompatible_bytes
        @test !isfile(joinpath(strict_directory, "reference2019_state_T1_V2.h5"))
        @test isempty(observed_points)

        # Cancellation is not an independent-case failure and must reach the
        # caller even when ordinary point failures are configured to continue.
        @test_throws InterruptException run_production_sweep(
            problem,
            [60.0u"mV", 64.0u"mV"],
            [250.0u"K"];
            output_directory = joinpath(directory, "interrupted"),
            options = one_step,
            production_options = production_options,
            resume_from_checkpoints = false,
            save_full_state = false,
            save_csv = false,
            Tᴸᴼ_of_Tᴸ = _ -> throw(InterruptException()),
            fail_fast = false,
            solution_observer = (_, it, iv) -> push!(observed_points, (it, iv)),
        )
        @test isempty(observed_points)

        silent_directory = joinpath(directory, "no_artifacts")
        silent = run_production_sweep(
            problem,
            [60.0u"mV"],
            [250.0u"K"];
            output_directory = silent_directory,
            options = one_step,
            production_options = production_options,
            resume_from_checkpoints = false,
            save_full_state = false,
            save_csv = false,
            fail_fast = false,
        )
        @test silent.summary_path == ""
        @test only(silent.records).checkpoint == ""
        @test isempty(readdir(silent_directory))
        @test_throws ArgumentError run_production_sweep(
            problem,
            [60.0u"mV"],
            [250.0u"K"];
            output_directory = joinpath(directory, "invalid_resume"),
            options = one_step,
            production_options = production_options,
            resume_from_checkpoints = true,
            save_full_state = false,
            save_csv = false,
            fail_fast = false,
        )
        @test_throws MethodError run_production_sweep(
            (voltage, temperature) -> problem,
            [60.0u"mV"],
            [250.0u"K"],
        )
    end
end

end # independent suite
