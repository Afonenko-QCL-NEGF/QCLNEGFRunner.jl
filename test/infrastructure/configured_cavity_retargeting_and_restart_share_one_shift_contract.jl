module Suite_T043
include("../support/common.jl")
using HDF5

@testset "Configured cavity, retargeting and restart share one shift contract" begin
    BN = QCLNEGFRunner
    configuration = load_run_configuration(
        joinpath(TEST_ROOT, "fixtures", "configurations", "diagnostics-cavity_p2.yaml"),
    )
    configured = build_configured_problem(configuration)
    problem = configured.problem
    @test configuration.algorithms.embedding === :finite_chain
    @test problem.energy_shift_discretization === :finite_volume_piecewise_constant
    @test validate_problem(problem).passed

    target = retarget_problem(problem; V_period = 54.0u"mV")
    @test target.energy_shift_discretization === problem.energy_shift_discretization
    @test target.W₊ᴸᴼ === problem.W₊ᴸᴼ
    @test target.W₋ᴸᴼ === problem.W₋ᴸᴼ
    @test validate_problem(target).passed
    @test target.W₊ᴱᵖ != problem.W₊ᴱᵖ
    explicit_target =
        retarget_problem(problem; V_period = 54.0u"mV", energy_shift = :conservative_pair)
    @test explicit_target.W₊ᴱᵖ == target.W₊ᴱᵖ
    @test explicit_target.W₋ᴱᵖ == target.W₋ᴱᵖ

    nodal = retarget_problem(problem; energy_shift = :dense)
    @test nodal.energy_shift_discretization === :nodal_linear
    @test validate_problem(nodal).passed
    @test nodal.W₊ᴸᴼ !== problem.W₊ᴸᴼ
    @test nodal.W₋ᴸᴼ !== problem.W₋ᴸᴼ
    restored = retarget_problem(nodal; energy_shift = :conservative_pair)
    @test restored.energy_shift_discretization === :finite_volume_piecewise_constant
    @test restored.W₊ᴸᴼ == problem.W₊ᴸᴼ
    @test restored.W₋ᴸᴼ == problem.W₋ᴸᴼ
    @test validate_problem(restored).passed
    @test_throws ArgumentError retarget_problem(problem; energy_shift = :unknown)

    for operator in (:W₊ᴱᵖ, :W₋ᴱᵖ, :W₊ᴸᴼ, :W₋ᴸᴼ)
        malformed = deepcopy(problem)
        matrix = getfield(malformed, operator)
        if operator in (:W₊ᴱᵖ, :W₊ᴸᴼ)
            matrix[end, 1] = 0.25
        else
            matrix[1, end] = 0.25
        end
        report = validate_problem(malformed)
        @test !report.passed
        @test report.metrics[:shift_wrap] == 0.25
    end

    # Run one real cavity iteration on a reduced grid; the test checks the
    # complete construction/retarget/solve/restart path, not convergence.
    fields = Dict(
        name => getfield(configuration.numerical, name) for
        name in fieldnames(NumericalParameters)
    )
    fields[:N_E] = 41
    fields[:M_E] = 80.0u"meV"
    fields[:N_φ] = 4
    fields[:N_qz] = 5
    numerical = NumericalParameters(; fields...)
    empty_scattering = ScatteringOptions(
        LO = false,
        acoustic = false,
        impurity = false,
        IFR = false,
        alloy = false,
    )
    direct = build_problem(
        physical = configuration.physical,
        numerical = numerical,
        scales = configuration.scales,
        scattering = empty_scattering,
        localization = :real_space,
    )
    production_built = build_problem_production(
        physical = configuration.physical,
        numerical = numerical,
        scales = configuration.scales,
        scattering = empty_scattering,
        localization = :real_space,
    ).problem
    for constructed in (direct, production_built)
        @test constructed.energy_shift_discretization === :nodal_linear
        @test validate_problem(constructed).passed
    end
    small = BN.build_configured_scattering_problem(
        physical = configuration.physical,
        numerical = numerical,
        scales = configuration.scales,
        # The open finite chain needs a nonzero scattering injection to test
        # a normalized SCBA state. A collisionless isolated chain has none.
        scattering = ScatteringOptions(
            LO = true,
            acoustic = false,
            impurity = false,
            IFR = false,
            alloy = false,
        ),
        algorithms = configuration.algorithms,
        kernel_options = configuration.kernels,
    ).problem
    options = SolverOptions(
        max_scba = 1,
        max_poisson = 1,
        tolerances = tutorial_options().tolerances,
    )
    production = ProductionOptions(
        algorithms = configuration.algorithms,
        progress_every_scba = 0,
        progress_every_outer = 0,
        verify_fft_roundoff = false,
    )
    @test_throws ArgumentError solve_scba_production(
        small,
        zeros(numerical.N_z);
        options = options,
        production_options = ProductionOptions(
            progress_every_scba = 0,
            verify_fft_roundoff = false,
        ),
    )
    @test_throws ArgumentError solve_scba_production(
        direct,
        zeros(numerical.N_z);
        options = options,
        production_options = production,
    )
    mktempdir() do directory
        sweep = run_production_sweep(
            small,
            [60.0u"mV"],
            [250.0u"K"];
            output_directory = directory,
            options = options,
            production_options = production,
            resume_from_checkpoints = false,
            save_full_state = true,
            fail_fast = false,
        )
        record = only(sweep.records)
        @test record.status === :scba_max_iterations
        @test record.final_scba_iterations == 1
        @test isfile(record.checkpoint)
        restarted_problem =
            retarget_problem(small; V_period = 60.0u"mV", Tᴸ = 250.0u"K", Tᴸᴼ = 250.0u"K")
        @test validate_problem(restarted_problem).passed
        @test load_production_restart(
            record.checkpoint,
            restarted_problem;
            algorithms = configuration.algorithms,
            solver_options = options,
        ) !== nothing
        wrong_discretization = retarget_problem(restarted_problem; energy_shift = :dense)
        # Omitting optional algorithm options must not permit a physically
        # different remap to consume the saved cavity state.
        @test_throws ArgumentError load_production_restart(
            record.checkpoint,
            wrong_discretization,
        )
        HDF5.h5open(record.checkpoint, "r+") do file
            HDF5.delete_attribute(file["numerical_inputs"], "energy_shift_discretization")
        end
        @test_throws ArgumentError load_production_restart(
            record.checkpoint,
            restarted_problem,
        )
    end
end

end # independent suite
