module Suite_T062
include("../support/common.jl")
using HDF5
include("../support/numerical_convergence.jl")

@testset "Bounded approximate acceptance and warning provenance" begin
    q = DiagnosticQualityPolicy(
        enabled = true,
        required_consecutive_passes = 3,
        target_fixed_point_threshold = 1e-4,
        strict_attempt_iterations = 2,
        coarse_wait_iterations = 6,
    )
    policy = ConvergencePolicy(
        mode = :adaptive_working,
        minimum_scba_iterations = 1,
        stagnation_window = 0,
        stagnation_relative_improvement = 0.0,
        diagnostic_quality = q,
    )
    options = SolverOptions(max_scba = 80, convergence = policy)
    target = [_scba_iteration(i; r_K = 9e-5, r_Σ = 8e-5, r_λ = 9e-6) for i = 1:5]
    @test !QCLNEGFRunner.scba_approximate_acceptance(target[1:3], options)
    @test QCLNEGFRunner.scba_approximate_acceptance(target, options)
    coarse = [_scba_iteration(i; r_K = 8e-4, r_Σ = 7e-4, r_λ = 9e-5) for i = 1:9]
    @test !QCLNEGFRunner.scba_approximate_acceptance(coarse[1:8], options)
    @test QCLNEGFRunner.scba_approximate_acceptance(coarse, options)
    unstable = copy(coarse)
    unstable[end] = _scba_iteration(9; r_K = 8e-4, r_Σ = 7e-4, r_PSD = 1e-2)
    @test !QCLNEGFRunner.scba_approximate_acceptance(unstable, options)
    invalid = copy(coarse)
    invalid[end] = _scba_iteration(9; r_K = NaN)
    @test !QCLNEGFRunner.scba_approximate_acceptance(invalid, options)
    # Reducing alpha changes neither raw gate values nor acceptance.
    damped = SolverOptions(max_scba = 80, convergence = policy, α_Σ = 0.001)
    @test QCLNEGFRunner.scba_approximate_acceptance(coarse, damped)
    @test !scba_convergence_assessment(last(coarse), options.tolerances, policy).passed
    finite_budget = SolverOptions(max_scba = 3, convergence = policy)
    @test QCLNEGFRunner.scba_approximate_acceptance(coarse[1:3], finite_budget)
    shape=(1, 1, 1, 1)
    family=SelfEnergyFamily(
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
    )
    green=GreenState(
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        zeros(ComplexF64, shape),
        ones(1, 1),
        ones(1, 1),
    )
    approximate=SCBAResult(
        green,
        Dict{Symbol,SelfEnergyFamily}(),
        family,
        family,
        family,
        coarse,
        false,
        :approximate,
        :approximate_fixed_point,
    )
    @test QCLNEGFRunner.scba_accepted(approximate)
    @test !approximate.converged
    warning=QCLNEGFRunner._approximate_warning(approximate, options, 2)
    @test warning["code"] == "SCBA_APPROXIMATE_ACCEPTED"
    @test warning["outer_iteration"] == 2
    @test warning["metrics"]["lambda_minus_one"] ≈ last(coarse).λ-1
    @test warning["thresholds"]["keldysh"] == 1e-3
end

end # independent suite
