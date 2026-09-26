module Suite_T099
include("../support/common.jl")
using HDF5

@testset "SCBA seed, explicit status and HDF5 roundtrip" begin
    scattering = ScatteringOptions(
        LO = false,
        acoustic = false,
        impurity = false,
        IFR = false,
        alloy = false,
    )
    problem = build_problem(numerical = tutorial_numerics(), scattering = scattering)
    options = SolverOptions(
        α_Σ = 0.5,
        α_P = 0.5,
        max_scba = 2,
        max_poisson = 2,
        tolerances = tutorial_options().tolerances,
    )
    Uᴴ = zeros(problem.numerical.N_z)
    result = solve_scba(problem, Uᴴ; options)
    @test result.status in (:converged, :max_iterations, :invalid_candidate)
    @test !isempty(result.history) || result.status == :invalid_candidate
    @test size(result.green.Gᴿ) == (
        problem.numerical.N_E,
        problem.numerical.N_k,
        problem.numerical.N_b,
        problem.numerical.N_b,
    )
    @test size(result.green.dyson_scale) == (problem.numerical.N_E, problem.numerical.N_k)

    @testset "SCBA results enforce their public classification" begin
        arguments = (
            result.green,
            result.scattering,
            result.embedding,
            result.embedding_plus,
            result.embedding_minus,
            result.history,
        )
        @test_throws ArgumentError SCBAResult(
            arguments...,
            true,
            :converged,
            :approximate_fixed_point,
        )
        @test_throws ArgumentError SCBAResult(
            arguments...,
            false,
            :converged,
            :strictly_converged,
        )
        @test_throws ArgumentError SCBAResult(
            arguments...,
            false,
            :max_iterations,
            :unknown,
        )
    end

    @testset "Dyson failure never returns a stale warm state" begin
        warm_h = project_hamiltonians(problem, Uᴴ)
        warm_green, _ = QCLNEGFRunner._seed_green(problem, warm_h)
        warm_scattering = Dict{Symbol,SelfEnergyFamily}()
        warm_embedding, warm_plus, warm_minus =
            QCLNEGFRunner.embedding_self_energy(problem, warm_green)

        # Manufacture one exactly singular Dyson block. Before the fail-closed
        # fix, solve_scba returned `warm_green` even though it belonged to the
        # preceding Hartree field.
        current_Uᴴ = fill(1.0e-3, problem.numerical.N_z)
        current_h = project_hamiltonians(problem, current_Uᴴ)
        e, k = first(axes(warm_embedding.Σᴿ, 1)), first(axes(warm_embedding.Σᴿ, 2))
        identity_block = Matrix{ComplexF64}(I, problem.numerical.N_b, problem.numerical.N_b)
        warm_embedding.Σᴿ[e, k, :, :] .=
            problem.grids.ε[e] .* identity_block .- current_h[k, :, :]
        stale = SCBAResult(
            warm_green,
            warm_scattering,
            warm_embedding,
            warm_plus,
            warm_minus,
            SCBAIteration[],
            false,
            :max_iterations,
            :invalid,
        )

        @test_throws SingularException solve_scba(
            problem,
            current_Uᴴ;
            options = options,
            initial = stale,
        )
    end

    n̄ = QCLNEGFRunner._electron_density_bar(problem, result.green.Gˡ)
    target = QCLNEGFRunner._scaled_physics(problem.physical, problem.scales).Nᴰ²ᴰ
    @test dot(problem.grids.wˣ, n̄) ≈ target rtol=2e-12
    density = electron_density(problem, result.green.Gˡ)
    @test ustrip.(u"m^-3", density) ≈ n̄ ./ problem.scales.L₀_m^3 rtol=2e-13

    # A trace commutator has exactly zero integrated collision rate.
    commuting_family = SelfEnergyFamily(
        zeros(ComplexF64, size(result.green.Gᴿ)),
        copy(result.green.Gˡ),
        copy(result.green.Gᵍ),
    )
    manufactured_balance = collision_balance(problem, commuting_family, result.green)
    @test manufactured_balance.residual < 1e-12

    report = ConvergenceReport(false, Dict{Symbol,Float64}(), String[])
    fixture = NEGFSolution(
        problem,
        options,
        Uᴴ,
        n̄,
        result,
        OuterIteration[],
        Dict{Symbol,Any}(),
        report,
        false,
        :test_fixture,
    )
    checked = validate_solution(fixture)
    @test !checked.passed
    @test !isempty(checked.metrics)

    # Exercise the complete nested orchestration with finite deliberately loose
    # gates.  This is a control-flow test, not a physical convergence claim.
    loose_keywords = (; (name => 1e100 for name in fieldnames(SolverTolerances))...)
    closed_options = SolverOptions(
        α_Σ = 1.0,
        α_P = 1.0,
        max_scba = 3,
        max_poisson = 2,
        tolerances = SolverTolerances(; loose_keywords...),
        convergence = ConvergencePolicy(
            required_consecutive_scba_passes = 1,
            required_consecutive_poisson_passes = 1,
            stagnation_window = 0,
            stagnation_relative_improvement = 0.0,
        ),
        energy_tail_window_fraction = 0.07,
        momentum_tail_window_fraction = 0.13,
    )
    solution = solve(problem; options = closed_options)
    @test solution.converged
    @test solution.status == :converged
    @test length(solution.outer_history) == 2
    @test solution.report.passed

    mktemp() do path, io
        close(io)
        save_checkpoint(path, solution; include_kernels = false)
        HDF5.h5open(path, "r") do file
            @test String(HDF5.read_attribute(file["metadata"], "package_version")) ==
                  string(Base.pkgversion(QCLNEGFRunner))
            @test String(HDF5.read_attribute(file["metadata"], "schema_version")) == "4.0"
            @test String(HDF5.read_attribute(file["metadata"], "scba_quality")) ==
                  "strictly_converged"
            @test String(
                HDF5.read_attribute(file["basis_dimensionless"], "localization"),
            ) == String(problem.basis.localization)
            @test read(file["numerical_inputs/energy_tail_window_fraction"]) ==
                  solution.options.energy_tail_window_fraction
            @test read(file["numerical_inputs/momentum_tail_window_fraction"]) ==
                  solution.options.momentum_tail_window_fraction
            dataset = file["state_dimensionless/GR/real"]
            space = HDF5.dataspace(dataset)
            raw_dimensions = HDF5.API.h5s_get_simple_extent_dims(space, nothing)
            close(space)
            @test Tuple(Int.(raw_dimensions)) == size(solution.scba.green.Gᴿ)
            @test read(dataset) == permutedims(real.(solution.scba.green.Gᴿ), 4:-1:1)
        end
        loaded = load_checkpoint(path)
        @test loaded.Uᴴ == solution.Uᴴ
        @test loaded.n == solution.n
        @test loaded.Gᴿ == solution.scba.green.Gᴿ
        @test loaded.h == project_hamiltonians(problem, solution.Uᴴ)
        @test length(loaded.trusted_energy) == problem.numerical.N_E
    end

    for (package, schema, expected_message) in (
        (QCLNEGFRunner._CHECKPOINT_PACKAGE, "0.4", "unsupported HDF5 checkpoint schema 0.4"),
        ("ForeignNEGF", "1.3", "HDF5 checkpoint package ForeignNEGF is not QCLNEGF"),
    )
        mktemp() do path, io
            close(io)
            HDF5.h5open(path, "w") do file
                metadata = HDF5.create_group(file, "metadata")
                HDF5.attributes(metadata)["package"] = package
                HDF5.attributes(metadata)["schema_version"] = schema
            end
            identity_error = try
                load_checkpoint(path)
                nothing
            catch error
                error
            end
            @test identity_error isa ArgumentError
            @test occursin(expected_message, sprint(showerror, identity_error))
        end
    end
end

end # independent suite
