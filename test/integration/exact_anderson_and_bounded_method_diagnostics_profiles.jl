module Suite_T054
include("../support/common.jl")
using HDF5
include("../support/method_diagnostics_configuration.jl")

@testset "Exact Anderson and bounded method diagnostics profiles" begin
    accelerated = load_run_configuration(
        joinpath(METHOD_DIAGNOSTICS_CONFIG_ROOT, "exact_anderson.yaml"),
    )
    @test accelerated.classification == :computationally_equivalent
    @test accelerated.algorithms.energy_shift == :sparse_plan
    @test accelerated.algorithms.hilbert == :fft
    @test accelerated.algorithms.contraction == :dense_blas
    @test accelerated.algorithms.kernel_build == :direct
    @test accelerated.algorithms.mixing == :anderson
    @test accelerated.algorithms.anderson_history_depth == 8
    @test accelerated.algorithms.anderson_damping == 0.8
    @test accelerated.algorithms.anderson_regularization == 1.0e-10
    @test accelerated.algorithms.retarded_real_part == :kramers_kronig
    @test accelerated.algorithms.self_energy_structure == :full
    @test accelerated.algorithms.transverse_momentum == :resolved
    @test algorithm_impact(accelerated.algorithms) == :physics_preserving

    diagnostics = load_run_configuration(
        joinpath(METHOD_DIAGNOSTICS_CONFIG_ROOT, "studies-method_diagnostics.yaml"),
    )
    @test diagnostics.classification == :study
    @test diagnostics.solver.max_scba == 2000
    @test diagnostics.solver.tolerances.r_K == 1.0e-8
    @test diagnostics.solver.tolerances.r_Σ == 1.0e-8
    @test diagnostics.solver.tolerances.r_λ == 1.0e-8
    @test diagnostics.solver.convergence.stagnation_window == 200
    @test diagnostics.solver.convergence.stagnation_relative_improvement == 0.005
    quality = diagnostics.solver.convergence.diagnostic_quality
    @test quality.enabled
    @test quality.keldysh_threshold == 1.0e-3
    @test quality.self_energy_threshold == 1.0e-3
    @test quality.normalization_threshold == 1.0e-4
    @test quality.required_consecutive_passes == 4
    @test !diagnostics.output.fail_fast
    @test !diagnostics.output.save_full_state
    @test !diagnostics.output.resume
    @test diagnostics.production.checkpoint_every_scba == 0
    @test diagnostics.production.progress_every_scba == 1
    @test first(diagnostics.study.comparison_profiles) == "diagnostics-lo_only.yaml"
    @test diagnostics.study.repetitions == 1
    @test isempty(diagnostics.study.convergence.spatial_nodes)
    @test isempty(diagnostics.study.convergence.energy_nodes)
    @test isempty(diagnostics.study.convergence.momentum_nodes)
    @test isempty(diagnostics.study.convergence.angular_nodes)
    @test planned_solver_runs(diagnostics) == 8
    # Resolved per-method overrides, not just method labels, change equations.
    method = load_run_configuration(
        joinpath(METHOD_DIAGNOSTICS_CONFIG_ROOT, "diagnostics-lo_only.yaml"),
    )
    overrides = diagnostics.raw["study"]["methods"][1]["overrides"]
    resolved = QCLNEGFRunner._method_configuration(diagnostics, method, "unused"; overrides)
    @test resolved.scattering.LO
    @test !resolved.scattering.impurity
    @test !resolved.scattering.IFR
    @test !resolved.scattering.acoustic
    @test resolved.classification === :physics_changing
    @test resolved.numerical.N_E == diagnostics.numerical.N_E

    smoke = load_run_configuration(
        joinpath(METHOD_DIAGNOSTICS_CONFIG_ROOT, "studies-smoke.yaml"),
    )
    @test smoke.solver.convergence.minimum_scba_iterations == 2
    @test smoke.solver.convergence.required_consecutive_scba_passes == 1
    @test smoke.solver.convergence.minimum_poisson_iterations == 2
    @test smoke.solver.convergence.required_consecutive_poisson_passes == 1
    @test smoke.solver.convergence.stagnation_window == 0
    @test smoke.solver.convergence.stagnation_relative_improvement == 0.0
    @test !smoke.solver.convergence.diagnostic_quality.enabled
end

end # independent suite
