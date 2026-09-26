module Suite_T080
include("../support/common.jl")
using HDF5
include("../support/production_backend.jl")

@testset "Production restart validates metadata and restores state" begin
    scattering = ScatteringOptions(
        LO = false,
        acoustic = false,
        impurity = false,
        IFR = false,
        alloy = false,
    )
    problem = build_problem(numerical = tutorial_numerics(), scattering = scattering)
    h = project_hamiltonians(problem, zeros(problem.numerical.N_z))
    green, _ = QCLNEGFRunner._seed_green(problem, h)
    cache = build_production_cache(
        problem;
        options = ProductionOptions(progress_every_scba = 0, progress_every_outer = 0),
    )
    embedding, plus, minus =
        QCLNEGFRunner._embedding_self_energy_production(problem, green, cache)
    scba = SCBAResult(
        green,
        Dict{Symbol,SelfEnergyFamily}(),
        embedding,
        plus,
        minus,
        SCBAIteration[],
        false,
        :fixture,
        :unresolved,
    )
    n̄ = QCLNEGFRunner._electron_density_bar(problem, green.Gˡ)
    solver_options = tutorial_options()
    report = ConvergenceReport(false, Dict{Symbol,Float64}(), String[])
    solution = NEGFSolution(
        problem,
        solver_options,
        zeros(problem.numerical.N_z),
        n̄,
        scba,
        OuterIteration[],
        Dict{Symbol,Any}(),
        report,
        false,
        :fixture,
    )
    mktempdir() do directory
        reference_path = joinpath(directory, "reference.h5")
        save_checkpoint(
            reference_path,
            solution;
            include_kernels = false,
            algorithms = AlgorithmOptions(),
        )
        h5open(reference_path, "r") do file
            @test haskey(file["metadata"], "toolchain_json")
            provenance = QCLNEGFRunner.YAML.load(String(read(file["metadata/toolchain_json"])))
            @test provenance["julia_version"] == string(VERSION)
            @test HDF5.read_attribute(file["metadata"], "package") == "QCLNEGF"
            @test HDF5.read_attribute(file["metadata"], "producer_package") == "QCLNEGFRunner"
            @test provenance["core_project_sha256"] == bytes2hex(QCLNEGFRunner.SHA.sha256(read(joinpath(pkgdir(QCLNEGFRunner.QCLNEGF), "Project.toml"))))
            @test provenance["manifest_sha256"] == bytes2hex(
                QCLNEGFRunner.SHA.sha256(read(joinpath(dirname(Base.active_project()), "Manifest.toml"))),
            )
            @test provenance["runtime_binary_sha256"] ==
                  bytes2hex(QCLNEGFRunner.SHA.sha256(read(joinpath(Sys.BINDIR, "julia"))))
            @test provenance["julia_threads"] == Threads.nthreads(:default)
            @test provenance["blas_threads"] == BLAS.get_num_threads()
            @test !isempty(provenance["fftw_provider"])
            @test !isempty(provenance["blas_backend"])
            @test provenance["preferences"] isa Vector
        end
        restart = load_production_restart(reference_path, problem)
        @test restart.Uᴴ == solution.Uᴴ
        @test restart.scba.green.Gᴿ == green.Gᴿ
        @test restart.scba.embedding_plus.Σˡ == plus.Σˡ

        # Compact production operators and the educational dense oracle carry
        # the same discretization identity; checkpoint bytes need no migration.
        compact_problem = retarget_problem(problem; energy_shift = :sparse_plan)
        compact_restart = load_production_restart(reference_path, compact_problem)
        @test compact_problem.W₊ᴱᵖ isa EnergyShiftPlan
        @test compact_restart.scba.green.Gᴿ == green.Gᴿ
        @test compact_restart.scba.embedding_plus.Σˡ == plus.Σˡ

        # Restoring a same-stage checkpoint preserves its logical budget.
        history = SCBAIteration[
            SCBAIteration(
                i,
                1e-12,
                1e-10,
                1e-3,
                1e-3,
                1e-4,
                1.0001,
                0.0,
                0.0,
                0.0,
                1e-5,
                1e-5,
                1.0,
                NaN,
                NaN,
                NaN,
                NaN,
                nothing,
                nothing,
            ) for i = 1:20
        ]
        resumed_state = SCBAResult(
            green,
            Dict{Symbol,SelfEnergyFamily}(),
            embedding,
            plus,
            minus,
            history,
            false,
            :running,
            :unresolved,
        )
        prior_warnings =
            [Dict{String,Any}("code"=>"SCBA_APPROXIMATE_ACCEPTED", "outer_iteration"=>1)]
        resumed_solution = NEGFSolution(
            problem,
            solver_options,
            solution.Uᴴ,
            n̄,
            resumed_state,
            OuterIteration[],
            Dict{Symbol,Any}(:warnings=>prior_warnings),
            report,
            false,
            :running_scba,
        )
        progress_path = joinpath(directory, "progress20.h5")
        save_checkpoint(
            progress_path,
            resumed_solution;
            include_kernels = false,
            algorithms = AlgorithmOptions(),
        )
        progress = load_production_restart(progress_path, problem)
        @test last(progress.scba.history).ν == 20
        @test progress.resume_scba
        @test !progress.completed
        @test progress.warnings == prior_warnings
        @test 80-last(progress.scba.history).ν == 60
        exhausted = solve_scba_production(
            problem,
            progress.Uᴴ;
            options = SolverOptions(;
                (
                    name => (name===:max_scba ? 20 : getfield(solver_options, name)) for
                    name in fieldnames(SolverOptions)
                )...,
            ),
            cache,
            initial = progress.scba,
            resume_iterations = true,
            production_options = ProductionOptions(
                progress_every_scba = 0,
                progress_every_outer = 0,
            ),
        )
        @test last(exhausted.history).ν == 20
        @test exhausted.status == :max_iterations
        @test length(exhausted.history) == 20

        # The checkpoint callback precedes the termination decision: a strict
        # state on the last permitted iteration must remain accepted on resume.
        terminal_history = SCBAIteration[
            SCBAIteration(
                i,
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
                1.0,
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
                1.0,
                NaN,
                NaN,
                NaN,
                NaN,
                nothing,
                nothing,
            ) for i = 1:3
        ]
        terminal_options = SolverOptions(;
            (
                name => (name===:max_scba ? 3 : getfield(solver_options, name)) for
                name in fieldnames(SolverOptions)
            )...,
        )
        terminal_state = SCBAResult(
            green,
            Dict{Symbol,SelfEnergyFamily}(),
            embedding,
            plus,
            minus,
            terminal_history,
            false,
            :restart,
            :unresolved,
            QCLNEGFRunner._solver_restart_contract(terminal_options, AlgorithmOptions()),
        )
        terminal = solve_scba_production(
            problem,
            solution.Uᴴ;
            options = terminal_options,
            cache,
            initial = terminal_state,
            resume_iterations = true,
            production_options = ProductionOptions(
                progress_every_scba = 0,
                progress_every_outer = 0,
            ),
        )
        @test terminal.converged
        @test terminal.status === :converged
        @test last(terminal.history).ν == 3
        @test QCLNEGFRunner._trailing_pass_count([true, true, false, true, true], identity) == 2
        @test QCLNEGFRunner._trailing_pass_count(Bool[], identity) == 0

        # A completed/partial state cannot be relabelled as another embedding model.
        @test_throws ArgumentError load_production_restart(
            progress_path,
            problem;
            algorithms = AlgorithmOptions(embedding = :finite_chain),
            solver_options,
        )
        @test_throws ArgumentError load_production_restart(
            progress_path,
            problem;
            algorithms = AlgorithmOptions(hilbert = :product_integration),
            solver_options,
        )
        changed_mixing = SolverOptions(;
            (
                name => (
                    name===:α_Σ ? solver_options.α_Σ/2 : getfield(solver_options, name)
                ) for name in fieldnames(SolverOptions)
            )...,
        )
        @test_throws ArgumentError load_production_restart(
            progress_path,
            problem;
            algorithms = AlgorithmOptions(),
            solver_options = changed_mixing,
        )
        changed_poisson_mixing = SolverOptions(;
            (
                name => (
                    name===:α_P ? solver_options.α_P/2 : getfield(solver_options, name)
                ) for name in fieldnames(SolverOptions)
            )...,
        )
        @test_throws ArgumentError load_production_restart(
            progress_path,
            problem;
            algorithms = AlgorithmOptions(),
            solver_options = changed_poisson_mixing,
        )
        old_contract_path=joinpath(directory, "old_without_contract.h5")
        save_checkpoint(old_contract_path, solution; include_kernels = false)
        @test_throws ArgumentError load_production_restart(old_contract_path, problem)
        @test load_production_restart(
            old_contract_path,
            problem;
            incompatible = :ignore,
        ) === nothing

        kernel_problem = build_problem(
            numerical = tutorial_numerics(),
            scattering = ScatteringOptions(
                LO = false,
                acoustic = false,
                impurity = true,
                IFR = false,
                alloy = false,
            ),
        )
        zero_family = SelfEnergyFamily(
            zeros(ComplexF64, size(green.Gᴿ)),
            zeros(ComplexF64, size(green.Gᴿ)),
            zeros(ComplexF64, size(green.Gᴿ)),
        )
        kernel_state = SCBAResult(
            green,
            Dict(:impurity=>zero_family),
            embedding,
            plus,
            minus,
            SCBAIteration[],
            false,
            :fixture,
            :unresolved,
        )
        kernel_solution = NEGFSolution(
            kernel_problem,
            solver_options,
            solution.Uᴴ,
            n̄,
            kernel_state,
            OuterIteration[],
            Dict{Symbol,Any}(),
            report,
            false,
            :fixture,
        )
        kernel_path=joinpath(directory, "kernel_identity.h5")
        save_checkpoint(
            kernel_path,
            kernel_solution;
            include_kernels = false,
            algorithms = AlgorithmOptions(),
        )
        @test load_production_restart(kernel_path, kernel_problem) !== nothing
        original_qK=kernel_problem.kernels.qᴷ[:impurity]
        kernel_problem.kernels.K[:impurity][1] += 1e-8
        @test kernel_problem.kernels.qᴷ[:impurity] == original_qK
        mismatch = try
            load_production_restart(kernel_path, kernel_problem)
            nothing
        catch error
            error
        end
        @test mismatch isa ArgumentError
        @test occursin("scattering operators differ", sprint(showerror, mismatch))

        # Strict loading remains the default, whereas orchestration can
        # quarantine a checkpoint created by a different discretization.  A
        # Unicode directory mirrors the Windows path from the reported fault.
        unicode_directory = joinpath(directory, "Результаты reference design")
        mkpath(unicode_directory)
        mismatch_path = joinpath(unicode_directory, "restart.h5")
        cp(reference_path, mismatch_path)
        HDF5.h5open(mismatch_path, "r+") do file
            dataset = file["numerical_inputs/Nz"]
            HDF5.write(dataset, problem.numerical.N_z - 1)
        end
        mismatch_bytes = read(mismatch_path)
        @test_throws ArgumentError load_production_restart(mismatch_path, problem)
        @test isfile(mismatch_path)
        @test isnothing(
            load_production_restart(mismatch_path, problem; incompatible = :ignore),
        )
        @test isfile(mismatch_path)
        @test isnothing(
            load_production_restart(mismatch_path, problem; incompatible = :quarantine),
        )
        @test !isfile(mismatch_path)
        quarantined = filter(readdir(unicode_directory; join = true)) do path
            name = basename(path)
            startswith(name, "restart.incompatible.") && endswith(name, ".h5")
        end
        @test length(quarantined) == 1
        @test read(only(quarantined)) == mismatch_bytes

        # Reusing the original basename must preserve both incompatible files
        # under distinct names rather than overwriting the first quarantine.
        cp(only(quarantined), mismatch_path)
        @test isnothing(
            load_production_restart(mismatch_path, problem; incompatible = :quarantine),
        )
        quarantined = filter(readdir(unicode_directory; join = true)) do path
            name = basename(path)
            startswith(name, "restart.incompatible.") && endswith(name, ".h5")
        end
        @test length(quarantined) == 2
        @test all(path -> read(path) == mismatch_bytes, quarantined)
        @test_throws ArgumentError load_production_restart(
            reference_path,
            problem;
            incompatible = :invalid,
        )

        # A self-identifying foreign package is an incompatible restart, not
        # an old-format payload to be guessed or translated.
        foreign_path = joinpath(directory, "foreign-package.h5")
        HDF5.h5open(foreign_path, "w") do file
            metadata = HDF5.create_group(file, "metadata")
            HDF5.attributes(metadata)["package"] = "ForeignNEGF"
            HDF5.attributes(metadata)["schema_version"] = "1.3"
        end
        @test_throws ArgumentError load_production_restart(foreign_path, problem)
        @test isnothing(
            load_production_restart(foreign_path, problem; incompatible = :ignore),
        )
        @test isfile(foreign_path)

        # A malformed HDF5 file is corruption, not a compatibility mismatch:
        # even quarantine mode must propagate the reader error and preserve it.
        corrupt_path = joinpath(unicode_directory, "corrupt.h5")
        write(corrupt_path, UInt8[0x42, 0x4f, 0x53, 0x43, 0x4f])
        @test_throws Exception load_production_restart(
            corrupt_path,
            problem;
            incompatible = :quarantine,
        )
        @test isfile(corrupt_path)
        @test isempty(
            filter(
                name -> startswith(name, "corrupt.incompatible."),
                readdir(unicode_directory),
            ),
        )

        physical_path = joinpath(directory, "changed_physical.h5")
        cp(reference_path, physical_path)
        HDF5.h5open(physical_path, "r+") do file
            dataset = file["inputs/T_L_K"]
            HDF5.write(dataset, read(dataset) + 1.0)
        end
        @test_throws ArgumentError load_production_restart(physical_path, problem)

        numerical_path = joinpath(directory, "changed_numerical.h5")
        cp(reference_path, numerical_path)
        HDF5.h5open(numerical_path, "r+") do file
            dataset = file["numerical_inputs/M_E_eV"]
            HDF5.write(dataset, read(dataset) * (1 + 1e-6))
        end
        @test_throws ArgumentError load_production_restart(numerical_path, problem)

        missing_window_path = joinpath(directory, "missing_window.h5")
        cp(reference_path, missing_window_path)
        HDF5.h5open(missing_window_path, "r+") do file
            HDF5.delete_object(file["numerical_inputs"], "energy_tail_window_fraction")
        end
        missing_window_error = try
            load_production_restart(missing_window_path, problem)
            nothing
        catch error
            error
        end
        @test missing_window_error isa ArgumentError
        @test occursin(
            "energy_tail_window_fraction",
            sprint(showerror, missing_window_error),
        )
        @test_throws ArgumentError load_production_restart(
            missing_window_path,
            problem;
            incompatible = :quarantine,
        )
        @test isfile(missing_window_path)

        invalid_window_path = joinpath(directory, "invalid_window.h5")
        cp(reference_path, invalid_window_path)
        HDF5.h5open(invalid_window_path, "r+") do file
            dataset = file["numerical_inputs/energy_tail_window_fraction"]
            HDF5.write(dataset, 1.0)
        end
        invalid_window_error = try
            load_production_restart(invalid_window_path, problem)
            nothing
        catch error
            error
        end
        @test invalid_window_error isa ArgumentError
        @test occursin("must lie in (0,1)", sprint(showerror, invalid_window_error))

        nonfinite_window_path = joinpath(directory, "nan_window.h5")
        cp(reference_path, nonfinite_window_path)
        HDF5.h5open(nonfinite_window_path, "r+") do file
            dataset = file["numerical_inputs/momentum_tail_window_fraction"]
            HDF5.write(dataset, NaN)
        end
        nonfinite_window_error = try
            load_production_restart(nonfinite_window_path, problem)
            nothing
        catch error
            error
        end
        @test nonfinite_window_error isa ArgumentError
        @test occursin(
            "contains a non-finite value",
            sprint(showerror, nonfinite_window_error),
        )

        nonfinite_path = joinpath(directory, "nan_state.h5")
        cp(reference_path, nonfinite_path)
        HDF5.h5open(nonfinite_path, "r+") do file
            dataset = file["state_dimensionless/UH"]
            values = read(dataset)
            values[1] = NaN
            HDF5.write(dataset, values)
        end
        @test_throws ArgumentError load_production_restart(nonfinite_path, problem)
        @test_throws ArgumentError load_production_restart(
            nonfinite_path,
            problem;
            incompatible = :quarantine,
        )
        @test isfile(nonfinite_path)
    end

    # Packaged end-to-end fixed-point fixture.  Large finite tolerances make
    # this an algorithmic path test, not a quantitative reference design acceptance
    # claim; both inner and outer loops must nevertheless execute at least two
    # iterations, followed by the independent final SCBA alignment solve.
    permissive = SolverTolerances(
        r_D = 1e100,
        r_A = 1e100,
        r_K = 1e100,
        r_Σ = 1e100,
        r_λ = 1e100,
        r_P = 1e100,
        r_U = 1e100,
        r_n = 1e100,
        r_neutral = 1e100,
        r_J = 1e100,
        r_C = 1e100,
        r_power = 1e100,
        r_PSD = 1e100,
        r_caus = 1e100,
        r_sum = 1e100,
        r_obs = 1e100,
        r_ζ = 1e100,
        r_imag = 1e100,
        r_tail = 1e100,
        r_edge = 1e100,
        r_roundoff = 1e100,
    )
    fixed_point_options = SolverOptions(
        α_Σ = 1.0,
        α_P = 1.0,
        max_scba = 3,
        max_poisson = 3,
        tolerances = permissive,
        convergence = ConvergencePolicy(
            required_consecutive_scba_passes = 1,
            required_consecutive_poisson_passes = 1,
            stagnation_window = 0,
            stagnation_relative_improvement = 0.0,
        ),
    )
    production_options = ProductionOptions(
        checkpoint_every_outer = 1,
        checkpoint_every_scba = 1,
        progress_every_scba = 0,
        progress_every_outer = 0,
        verify_fft_roundoff = true,
    )
    mktempdir() do directory
        checkpoint = joinpath(directory, "converged.h5")
        final = solve_production(
            problem;
            options = fixed_point_options,
            production_options,
            cache,
            checkpoint_path = checkpoint,
        )
        @test final.converged
        @test final.status == :converged
        @test final.scba.converged
        @test length(final.outer_history) ≥ 2
        @test length(final.scba.history) ≥ 2
        @test final.report.passed
        @test final.n ≈ QCLNEGFRunner._electron_density_bar(problem, final.scba.green.Gˡ) rtol=8eps(
            Float64,
        )

        # Recompute the Dyson residual with the stored final Hartree field.
        # This would expose a one-outer-step lag even if the checkpoint arrays
        # were individually well formed.
        shape = size(final.scba.green.Gᴿ)
        scattering_total = QCLNEGFRunner._sum_selfenergies(final.scba.scattering, shape)
        total = SelfEnergyFamily(
            scattering_total.Σᴿ + final.scba.embedding.Σᴿ,
            scattering_total.Σˡ + final.scba.embedding.Σˡ,
            scattering_total.Σᵍ + final.scba.embedding.Σᵍ,
        )
        aligned_residual = QCLNEGFRunner._dyson_residual(
            problem.grids.ε,
            project_hamiltonians(problem, final.Uᴴ),
            total.Σᴿ,
            final.scba.green.Gᴿ,
        )
        @test aligned_residual < 1e-10

        @test isfile(checkpoint)
        stored = load_production_restart(checkpoint, problem)
        @test stored.Uᴴ == final.Uᴴ
        @test stored.scba.green.Gᴿ == final.scba.green.Gᴿ
        @test stored.scba.embedding_plus.Σˡ == final.scba.embedding_plus.Σˡ
    end
end

end # independent suite
