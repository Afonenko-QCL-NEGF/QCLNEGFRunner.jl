using Test, QCLNEGFRunner
const W=QCLNEGFRunner.QCLScientificWorkflow
@testset "spectral diagnostic uses public optimized operator and marker" begin
    src=read(joinpath(dirname(dirname(pathof(QCLNEGFRunner))),"src/composition/operator_spectral_resolution.jl"),String)
    @test !occursin("._retarded_green_production",src)
    @test !occursin("._sampled_linewidth_markers",src)
    row=W._spectral_resolution_sample(reshape(ComplexF64[0],1,1),reshape(ComplexF64[0.01],1,1),65,0.0)
    @test row["marker_status"] == "available"
    @test row["sampled_gamma_over_step_quantiles"] ≈ [4.,4.,4.] rtol=1e-12
    @test row["marker_bound_violation"] < 1e-12
end
