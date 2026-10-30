using Test, LinearAlgebra, QCLNEGF, QCLNEGFRunner
const W=QCLNEGFRunner.QCLScientificWorkflow
@testset "complex projected spectrum preserves post-phase residual" begin
    h=ComplexF64[1 0.3im; -0.3im 2]
    chi=ComplexF64[1 im; 1+im 2; -im 1-im]
    old=eigen(Hermitian(h)); oldv=copy(old.vectors); oldspatial=chi*oldv
    for state in axes(oldspatial,2)
        pivot=argmax(abs.(view(oldspatial,:,state))); amplitude=oldspatial[pivot,state]
        if abs(amplitude)>0
            phase=conj(amplitude)/abs(amplitude)
            oldspatial[:,state].*=phase; oldv[:,state].*=phase
        end
    end
    expected=norm(h*oldv-oldv*Diagonal(old.values))/(norm(h)+1e-14)
    got=W._quantum_projected_eigensystem(h,chi)
    @test isequal(got.values,old.values)
    @test isequal(got.vectors,oldv)
    @test isequal(got.spatial,oldspatial)
    @test isequal(got.eigen_residual,expected)
    changed=copy(got.vectors); changed[1,1]+=0.1
    @test W._quantum_postphase_residual(h,changed,got.values,got.norm_floor) > got.eigen_residual
    @test W._quantum_projected_eigensystem(zeros(ComplexF64,2,2),chi).eigen_residual == 0
    @test_throws W.QuantumPreviewRefusal W._quantum_projected_eigensystem(fill(ComplexF64(NaN),2,2),chi)
    @test_throws W.QuantumPreviewRefusal W._quantum_projected_eigensystem(ComplexF64[1 1; 0 1],chi)
end
