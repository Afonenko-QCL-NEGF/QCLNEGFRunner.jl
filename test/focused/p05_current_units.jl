using Test, QCLNEGFRunner
const R=QCLNEGFRunner
@testset "current conversion keeps unavailable IEEE diagnostics" begin
    src=read(joinpath(dirname(dirname(pathof(R))),"src/composition/production_workflow.jl"),String)
    @test !occursin("_solver_current_density",src)
    @test R._runner_current_A_per_cm2(12500.) == 1.25
    @test isnan(R._runner_current_A_per_cm2(NaN))
    @test R._runner_current_A_per_cm2(Inf) === Inf
    @test R._runner_current_A_per_cm2(-Inf) === -Inf
end
