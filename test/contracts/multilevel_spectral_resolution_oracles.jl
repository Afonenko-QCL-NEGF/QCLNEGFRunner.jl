module MultilevelSpectralResolutionOracles
include("../support/common.jl")
const Workflow = QCLNEGFRunner.QCLScientificWorkflow

@testset "Finite-window analytic matrix integral has an independent scalar limit" begin
    levels = [-0.021, 0.003, 0.028]
    widths = [0.00011, 0.003, 0.008]
    lower, upper = -0.08, 0.09
    result = Workflow._constant_selfenergy_spectral_integral(
        Matrix(Diagonal(levels)),
        Matrix(Diagonal(widths)),
        lower,
        upper,
    )
    truth = Diagonal([
        (atan(2*(upper-e)/g)-atan(2*(lower-e)/g))/π for (e, g) in zip(levels, widths)
    ])
    @test result ≈ truth rtol=2e-14 atol=2e-14
    phase = cis(2π/3)
    U = ComplexF64[1 1 1; 1 phase phase^2; 1 phase^2 phase]/sqrt(3)
    transformed = Workflow._constant_selfenergy_spectral_integral(
        U*Diagonal(levels)*U',
        U*Diagonal(widths)*U',
        lower,
        upper,
    )
    @test transformed ≈ U*truth*U' rtol=2e-13 atol=2e-13
end

@testset "Narrow noncommuting spectra reject coarse grids and pass true fine tolerances" begin
    rows = Workflow.run_operator_diagnostics(:operator_spectral_resolution)
    @test all(row["passed"] for row in rows)
    integrals = filter(row->startswith(row["name"], "multilevel_integral_"), rows)
    @test length(integrals)==6
    @test all(row["noncommutation_relative"]>0.05 for row in integrals)
    for row in integrals
        @test row["value"]<=1e-6
        @test all(width->width>0, row["pole_full_linewidths_eV"])
        @test all(sample->sample["marker_status"]=="available", row["samples"])
    end
    unresolved = filter(row->startswith(row["name"], "unresolved_"), rows)
    @test length(unresolved)==2
    @test all(row["value"]>=0.05 for row in unresolved)
    @test all(row["coarse_marker_underresolved_weight"]≈1 for row in unresolved)
    @test all(row["fine_marker_underresolved_weight"]≈0 for row in unresolved)
    chain = filter(row->startswith(row["name"], "multilevel_chain_"), rows)
    @test length(chain)==9
    @test all(row["value"]<=2e-11 for row in chain)
end
end
