using Test, QCLNEGF, QCLNEGFRunner, Unitful, LinearAlgebra
const R=QCLNEGFRunner
@testset "full sheet density matrix keeps complex coherences and units" begin
    for file in ("src/infrastructure/persistence/point_artifacts.jl","src/composition/scientific_execution.jl")
        src=read(joinpath(dirname(dirname(pathof(R))),file),String)
        @test !occursin("_sheet_density_matrix_bar",src)
    end
    base=tutorial_numerics(); changes=(N_z=25,N_b=2,P_basis=1,N_E=9,N_k=2,N_qz=3,N_φ=4)
    n=NumericalParameters(;(name=>(hasproperty(changes,name) ? getproperty(changes,name) : getfield(base,name)) for name in fieldnames(NumericalParameters))...)
    problem=build_problem(physical=reference_parameters(f_ion=1/450),numerical=n,
        scattering=ScatteringOptions(LO=false,acoustic=false,impurity=false,IFR=false,alloy=false))
    g=zeros(ComplexF64,9,2,2,2)
    g[:,:,1,1].=1im; g[:,:,2,2].=2im; g[:,:,1,2].=0.4+0.3im; g[:,:,2,1].=-0.4+0.3im
    matrix=R._physical_sheet_density_matrix(problem,g)
    sumweights=sum(problem.grids.wᴱ)*sum(problem.grids.wᵏ)
    factor=problem.physical.g_s*sumweights/(2π*problem.scales.L₀_m^2)
    expected=factor.*ComplexF64[1 0.3-0.4im; 0.3+0.4im 2]
    @test size(matrix)==(2,2)
    @test matrix ≈ expected rtol=1e-13
    @test !iszero(imag(matrix[1,2]))
    @test real(tr(matrix)) ≈ 3factor rtol=1e-13
end
