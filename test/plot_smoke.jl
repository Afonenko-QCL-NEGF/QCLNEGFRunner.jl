using Test
using QCLNEGFRunner
using CairoMakie
using Unitful

@testset "CairoMakie extension" begin
    extension = Base.get_extension(QCLNEGFRunner, :QCLNEGFRunnerPlotsExt)
    displayed = extension._finite_residual([0.0, -1e-4, NaN, 1e-20, 1e-4])
    @test all(isnan, displayed[1:3])
    @test displayed[4:5] == [1e-20, 1e-4]

    problem = build_problem(
        numerical = tutorial_numerics(),
        scattering = ScatteringOptions(
            LO = false,
            acoustic = false,
            impurity = false,
            IFR = false,
            alloy = false,
        ),
    )
    options = SolverOptions(
        max_scba = 2,
        max_poisson = 2,
        tolerances = tutorial_options().tolerances,
    )
    Uᴴ = zeros(problem.numerical.N_z)
    result = solve_scba(problem, Uᴴ; options)
    n̄ = QCLNEGFRunner._electron_density_bar(problem, result.green.Gˡ)
    observables = QCLNEGFRunner._collect_observables(problem, result, Uᴴ)
    report = ConvergenceReport(false, Dict{Symbol,Float64}(), String[])
    solution = NEGFSolution(
        problem,
        options,
        Uᴴ,
        n̄,
        result,
        OuterIteration[],
        observables,
        report,
        false,
        :test_fixture,
    )
    for figure in (
        plot_band_profile(solution),
        plot_spectral_map(solution),
        plot_convergence(solution),
        plot_current_spectrum(solution),
        plot_conditioning(solution),
    )
        @test figure isa CairoMakie.Figure
    end

    @test_throws ArgumentError plot_reference_figure3a(solution; require_converged = true)
    reference2019_state = plot_reference_figure3a(
        solution;
        periods = 0:0,
        energy_limits_meV = (-100.0, 300.0),
        position_limits_nm = (0.0, 30.0),
    )
    @test reference2019_state isa CairoMakie.Figure
    state_axis = content(reference2019_state[1, 1])
    @test occursin(String(solution.status), state_axis.title[])
    @test occursin(String(solution_quality(solution)), state_axis.title[])
    @test state_axis.xlabel[] == "z (nm)"
    @test state_axis.ylabel[] == "electron energy (meV)"
    band_positions = state_axis.scene.plots[2].positions[]
    z=problem.grids.x .* problem.scales.L₀_m
    potential=problem.profiles.Eᶜ .* problem.scales.E₀_eV .+
              QCLNEGFRunner._electronvolts(problem.physical.E_ref) .-
              QCLNEGFRunner._volts_per_metre(problem.physical.F_bias) .*
              (z .- QCLNEGFRunner._metres(problem.physical.z₀)) .+
              solution.Uᴴ .* problem.scales.E₀_eV
    @test first.(band_positions) ≈ z .* 1e9
    @test last.(band_positions) ≈ 1e3 .* potential rtol=2e-6
    maps=spatial_energy_density(problem, solution.scba.green.Gˡ)
    @test size(maps.n_per_eV_m3)==(problem.numerical.N_E, problem.numerical.N_z)
    @test !solution.converged && solution.status === :test_fixture

    records = ProductionSweepRecord[
        ProductionSweepRecord(
            200.0,
            0.048,
            1.62e6,
            8.0e6,
            true,
            :converged,
            :strictly_converged,
            7,
            32,
            2_000_000,
            11.0,
            Dict{Symbol,Float64}(:self_energy => 8e-9),
            "a.h5",
        ),
        ProductionSweepRecord(
            200.0,
            0.052,
            1.76e6,
            1.1e7,
            false,
            :max_poisson_iterations,
            :unresolved,
            100,
            500,
            2_000_000,
            18.0,
            Dict{Symbol,Float64}(:self_energy => 2e-7),
            "b.h5",
        ),
        ProductionSweepRecord(
            200.0,
            0.056,
            1.89e6,
            1.4e7,
            true,
            :converged,
            :strictly_converged,
            9,
            40,
            2_000_000,
            14.0,
            Dict{Symbol,Float64}(:self_energy => 7e-9),
            "e.h5",
        ),
        ProductionSweepRecord(
            220.0,
            0.048,
            1.62e6,
            7.5e6,
            true,
            :converged,
            :strictly_converged,
            8,
            35,
            2_000_000,
            12.0,
            Dict{Symbol,Float64}(:self_energy => 9e-9),
            "c.h5",
        ),
        ProductionSweepRecord(
            220.0,
            0.052,
            1.76e6,
            1.0e7,
            true,
            :converged,
            :strictly_converged,
            9,
            40,
            2_000_000,
            15.0,
            Dict{Symbol,Float64}(:self_energy => 6e-9),
            "d.h5",
        ),
    ]
    reference2019_iv = plot_reference_iv(
        ProductionSweepResult(records, "summary.csv");
        periods = 405,
        ridge_width = 150.0u"μm",
        cavity_length = 1.8u"mm",
    )
    @test reference2019_iv isa CairoMakie.Figure
    density_axis = content(reference2019_iv[1, 1])
    density_line_positions = density_axis.scene.plots[1].positions[]
    @test length(density_line_positions) == 3
    @test isfinite(density_line_positions[1][2])
    @test isnan(density_line_positions[2][2])
    @test isfinite(density_line_positions[3][2])
    marker_positions = density_axis.scene.plots[2].positions[]
    @test length(marker_positions) == 3
    @test all(isfinite, marker_positions[2]) # only the connecting line is broken
    @test marker_positions[2][2] ≈ records[2].current_A_per_m2 / 1e7
    marker_strokes = density_axis.scene.plots[2].strokecolor[]
    @test marker_strokes[2].r == 1 && marker_strokes[2].g == 0 && marker_strokes[2].b == 0
    @test_throws ArgumentError plot_reference_iv(
        ProductionSweepResult(records, "summary.csv");
        periods = 0,
        ridge_width = 150.0u"μm",
        cavity_length = 1.8u"mm",
    )

    response = OpticalResponse(
        [0.012u"eV", 0.015u"eV", 0.018u"eV"],
        [2.9e12u"Hz", 3.6e12u"Hz", 4.4e12u"Hz"],
        [1.8e13u"s^-1", 2.3e13u"s^-1", 2.8e13u"s^-1"],
        ComplexF64[0.1+0.03im, 0.1-0.04im, 0.1+0.01im],
        ComplexF64[3.6+0.01im, 3.6-0.02im, 3.6+0.01im],
        [-50.0u"m^-1", 120.0u"m^-1", -20.0u"m^-1"],
        BitVector([false, true, true]),
        [0.3, 0.0, 0.0],
        12.9,
        :bare_bubble,
        :length,
        false,
    )
    reference2019_gain = plot_reference_gain(response)
    @test reference2019_gain isa CairoMakie.Figure

    mktempdir() do directory
        for (name, figure) in
            (("state", reference2019_state), ("iv", reference2019_iv), ("gain", reference2019_gain))
            path = joinpath(directory, name * ".png")
            save(path, figure)
            @test isfile(path)
            @test filesize(path) > 1_000
        end
    end
end
