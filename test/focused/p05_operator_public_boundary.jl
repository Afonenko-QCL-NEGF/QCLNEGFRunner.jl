using Test, QCLNEGF, QCLNEGFRunner
@testset "operator anchors use public Core entry points" begin
    src=read(joinpath(dirname(dirname(pathof(QCLNEGFRunner))),"src/composition/operator_physical_anchors.jl"),String)
    @test !occursin("_DIAGNOSTIC_CORE",src)
    @test !occursin("._retarded_green_production",src)
    @test !occursin("._selfenergy_residual",src)
    @test !occursin("._mix_family_production!",src)
    shape=(1,1,1,1); family(z)=QCLNEGF.SelfEnergyFamily(fill(ComplexF64(z),shape),fill(ComplexF64(z),shape),fill(ComplexF64(z),shape))
    options=QCLNEGF.ProductionOptions(worker_count=1)
    target=family(1); candidate=family(3)
    @test QCLNEGF.production_selfenergy_residual(target,candidate;worker_count=1) ≈ 2/(3+1e-14)
    @test QCLNEGF.production_mix_selfenergy!(target,candidate,0.25;options) === target
    @test only(target.Σᴿ)==1.5
    g=QCLNEGF.production_retarded_green([1.],zeros(ComplexF64,1,1,1),fill(-0.5im,shape);options)
    @test only(g.G_R) ≈ inv(1+0.5im)
end
