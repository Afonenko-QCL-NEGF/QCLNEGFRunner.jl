using Test, QCLNEGFRunner
const W=QCLNEGFRunner.QCLScientificWorkflow
@testset "LO manufactured operator uses public entry points" begin
    src=read(joinpath(dirname(dirname(pathof(QCLNEGFRunner))),"src/composition/operator_physical_anchors.jl"),String)
    @test !occursin("._production_lo_contraction",src)
    @test !occursin("._fermi(",src)
    result=W._diagnostic_lo_equilibrium(65,4.0,:sparse_plan;qz_nodes=5,angular_nodes=4)
    @test isfinite(result.kms) && result.kms < 1e-12
    @test isfinite(result.number) && result.number < 1e-12
    @test isfinite(result.energy) && result.energy < 1e-12
end
