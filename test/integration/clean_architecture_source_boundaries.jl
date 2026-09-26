module Suite_T018
include("../support/common.jl")

@testset "Explicit module ownership and independent numerical implementations" begin
    @test parentmodule(PhysicalParameters) === QCLNEGFRunner.QCLDomain
    @test parentmodule(ConvergencePolicy) === QCLNEGFRunner.QCLDomain
    @test parentmodule(build_grids) === QCLNEGFRunner.QCLReferenceOperators
    @test parentmodule(electron_density) === QCLNEGFRunner.QCLPhysics
    @test parentmodule(solve_scba) === QCLNEGFRunner.QCLNumerics
    @test parentmodule(production_residual_suite) === QCLNEGFRunner.QCLNumerics
    @test !isdefined(QCLNEGFRunner.QCLDomain, :validate_solution)
    @test !isdefined(QCLNEGFRunner.QCLDomain, :YAML)
    @test !isdefined(QCLNEGFRunner.QCLNumerics, :HDF5)
    @test !isdefined(QCLNEGFRunner.QCLReferenceOperators, :ProductionOptions)
    @test QCLNEGFRunner._static_contraction !== production_static_contraction
    @test solve_scba !== solve_scba_production
    # The production energy-shift method extends the same explicit operator
    # contract; independent literal and optimized implementations remain distinct.
    @test parentmodule(apply_energy_shift) === QCLNEGFRunner.QCLReferenceOperators
end

end
