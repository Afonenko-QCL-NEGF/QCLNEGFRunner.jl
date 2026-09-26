module Suite_T023
include("../support/common.jl")
using HDF5
include("../support/configuration.jl")

@testset "Strict hierarchical YAML configuration" begin
    base = load_run_configuration(joinpath(CONFIGURATION_ROOT, "base.yaml"))
    @test base isa ResolvedRunConfiguration
    @test base.name == "reference2019_base_reference"
    @test base.classification == :reference
    @test length(base.physical.layers) == 6
    @test isapprox(
        ustrip(
            u"mV",
            uconvert(
                u"mV",
                base.physical.F_bias * sum(layer.d for layer in base.physical.layers),
            ),
        ),
        56.0;
        atol = 1e-12,
    )
    @test base.numerical.N_z == 198
    @test base.numerical.N_E == 2401
    @test base.scattering.LO
    @test !base.scattering.alloy
    @test base.solver.α_Σ == 0.10
    @test base.solver.energy_tail_window_fraction == 0.05
    @test base.solver.momentum_tail_window_fraction == 0.10
    @test base.production.memory_budget_bytes == typemax(Int)
    @test base.production.algorithms == base.algorithms
    @test base.algorithms.energy_shift == :sparse_plan
    @test base.algorithms.retarded_real_part == :kramers_kronig
    @test base.execution.solver_backend == :production
    @test base.study.mode == :single
    @test base.study.reference_profile === nothing
    @test base.output.progress.significant_digits == 4
    @test base.output.progress.human_every == 5
    @test base.output.progress.event_log_file == joinpath("progress", "events.csv")
    @test base.output.progress.dashboard_file === nothing
    @test base.output.report_directory == "expert_report"
    @test base.output.device_geometry.periods == 405
    @test base.output.device_geometry.ridge_width == 150u"μm"
    @test base.output.device_geometry.cavity_length == 1.8u"mm"
    @test physical_parameters(base) === base.physical
    @test numerical_parameters(base) === base.numerical
    @test scattering_options(base) === base.scattering
    @test solver_options(base) === base.solver
    @test production_options(base) === base.production
    @test algorithm_options(base) === base.algorithms
    @test !isempty(base.provenance.files)
    @test allunique(base.provenance.files)
    @test endswith(configuration_source(base, "physical.lattice_temperature"), "base.yaml")
    @test configuration_source(base, "does.not.exist") === nothing

    preset_physical = reference_parameters(Tᴸ = 70.0u"K")
    for field in fieldnames(PhysicalParameters)
        @test getfield(base.physical, field) == getfield(preset_physical, field)
    end
    preset_numerical = reference_production_numerics()
    for field in fieldnames(NumericalParameters)
        @test getfield(base.numerical, field) == getfield(preset_numerical, field)
    end
    preset_scales = ScaleSystem()
    for field in fieldnames(ScaleSystem)
        @test getfield(base.scales, field) == getfield(preset_scales, field)
    end
    @test base.scattering == default_scattering()
    preset_solver = reference_production_solver_options()
    @test base.solver.α_Σ == preset_solver.α_Σ
    @test base.solver.α_P == preset_solver.α_P
    @test base.solver.max_scba == preset_solver.max_scba
    @test base.solver.max_poisson == preset_solver.max_poisson
    # Configured runs explicitly permit approximate acceptance with warnings;
    # direct Julia callers remain strict unless they opt into that policy.
    # Every other termination setting and every numerical threshold agrees.
    for field in fieldnames(ConvergencePolicy)
        field in (:diagnostic_quality, :mode) && continue
        @test getfield(base.solver.convergence, field) ==
              getfield(preset_solver.convergence, field)
    end
    @test base.solver.convergence.mode === :research_continue
    @test preset_solver.convergence.mode === :strict_fail_fast
    configured_quality = base.solver.convergence.diagnostic_quality
    direct_quality = preset_solver.convergence.diagnostic_quality
    @test configured_quality.enabled
    @test !direct_quality.enabled
    for field in fieldnames(DiagnosticQualityPolicy)
        field === :enabled && continue
        @test getfield(configured_quality, field) == getfield(direct_quality, field)
    end
    @test base.solver.tolerances.r_Σ == 1e-8
    @test configured_quality.target_fixed_point_threshold == 1e-4
    @test configured_quality.self_energy_threshold == 1e-3
    @test base.solver.energy_tail_window_fraction ==
          preset_solver.energy_tail_window_fraction
    @test base.solver.momentum_tail_window_fraction ==
          preset_solver.momentum_tail_window_fraction
    for field in fieldnames(SolverTolerances)
        @test getfield(base.solver.tolerances, field) ==
              getfield(preset_solver.tolerances, field)
    end
    preset_kernels = ProductionKernelOptions()
    for field in fieldnames(ProductionKernelOptions)
        @test getfield(base.kernels, field) == getfield(preset_kernels, field)
    end

    raw = resolved_configuration_dict(base)
    raw["numerical"]["energy_nodes"] = 3
    @test base.raw["numerical"]["energy_nodes"] == 2401

    naive = load_run_configuration(joinpath(CONFIGURATION_ROOT, "naive_oracle.yaml"))
    @test naive.execution.solver_backend == :educational
    @test naive.algorithms.solver_backend == :educational
    @test naive.algorithms.energy_shift == :dense
    @test naive.algorithms.contraction == :literal
    @test naive.algorithms.retarded_real_part == :kramers_kronig
    @test isempty(naive.provenance.manifests)

    exact = load_run_configuration(joinpath(CONFIGURATION_ROOT, "exact_cpu.yaml"))
    @test exact.classification == :computationally_equivalent
    @test exact.algorithms.hilbert == :fft
    @test exact.production.phase_timing
    @test length(exact.provenance.sources["algorithms.hilbert"]) == 1
    @test endswith(configuration_source(exact, "algorithms.hilbert"), "exact_cpu.yaml")

    controlled =
        load_run_configuration(joinpath(CONFIGURATION_ROOT, "controlled_numeric.yaml"))
    @test controlled.classification == :controlled_numerical
    @test controlled.algorithms.contraction == :low_rank
    @test controlled.algorithms.kernel_build == :tabulated
    @test controlled.algorithms.mixing == :anderson
    @test controlled.algorithms.low_rank_maximum_rank == 256
    @test algorithm_impact(controlled.algorithms) == :controlled_numerical

    screening =
        load_run_configuration(joinpath(CONFIGURATION_ROOT, "physics_screening.yaml"))
    @test screening.classification == :physics_changing
    @test screening.algorithms.retarded_real_part == :drop
    @test screening.algorithms.self_energy_structure == :diagonal
    @test screening.algorithms.transverse_momentum == :averaged
    @test screening.algorithms.contraction == :dense_blas
    @test screening.algorithms.kernel_build == :direct
    @test screening.algorithms.mixing == :linear
    @test algorithm_impact(screening.algorithms) == :physical_model

    smoke = load_run_configuration(joinpath(CONFIGURATION_ROOT, "studies-smoke.yaml"))
    @test smoke.classification == :study
    @test smoke.numerical.N_z == 48
    @test smoke.numerical.N_E == 49
    @test smoke.study.mode == :comparison
    @test smoke.study.comparison_profiles == ["naive_oracle.yaml", "exact_cpu.yaml"]
    @test smoke.study.reference_profile == "naive_oracle.yaml"
    @test length(smoke.study.methods) == 2
    @test smoke.study.methods[1].algorithm_family == :direct_reference
    @test smoke.study.convergence.spatial_nodes == [36, 48]
    @test !smoke.study.calculate_optical_response
    @test_throws ArgumentError run_from_configuration(smoke)

    ignored_convergence_study = StudyConfiguration(
        :single,
        copy(base.study.voltages_per_period),
        copy(base.study.temperatures),
        String[],
        nothing,
        StudyMethodConfiguration[],
        1,
        base.study.calculate_optical_response,
        base.study.photon_energy_min,
        base.study.photon_energy_max,
        base.study.photon_energy_points,
        base.study.optical_edge_tolerance,
        ConvergenceStudyConfiguration(Int[], [101], Int[], Int[]),
    )
    ignored_convergence_configuration = ResolvedRunConfiguration(
        base.name,
        base.description,
        base.classification,
        base.physical,
        base.numerical,
        base.scales,
        base.scattering,
        base.solver,
        base.production,
        base.kernels,
        base.algorithms,
        base.execution,
        base.output,
        ignored_convergence_study,
        base.provenance,
        base.raw,
    )
    @test_throws ArgumentError run_from_configuration(ignored_convergence_configuration)

    pilot_reference =
        load_run_configuration(joinpath(CONFIGURATION_ROOT, "studies-pilot_reference.yaml"))
    pilot_production = load_run_configuration(
        joinpath(CONFIGURATION_ROOT, "studies-pilot_production.yaml"),
    )
    @test planned_solver_runs(pilot_reference) == 2
    @test planned_solver_runs(pilot_production) == 3
    @test pilot_reference.study.repetitions == 1
    @test pilot_production.study.repetitions == 1
    # Both pilots diagnose transport convergence before any optical analysis;
    # one incomplete case must not terminate the comparison of methods.
    for pilot in (pilot_reference, pilot_production)
        @test !pilot.study.calculate_optical_response
        @test !pilot.output.fail_fast
        @test pilot.solver.convergence.diagnostic_quality.enabled
        # A small grid does not justify the former 160-step SCBA ceiling:
        # the measured pilot first reaches its accepted band after step 273.
        @test pilot.solver.max_scba == base.solver.max_scba == 2000
        @test pilot.solver.max_poisson < base.solver.max_poisson
    end
    @test only(
        filter(
            method -> method.profile == "physics_screening.yaml",
            pilot_production.study.methods,
        ),
    ).modifies_physics
end

end # independent suite
