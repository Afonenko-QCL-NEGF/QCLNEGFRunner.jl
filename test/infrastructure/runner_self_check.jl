module RunnerSelfCheck
include("../support/common.jl")
const R=QCLNEGFRunner
@testset "Node self-check exercises an analytic kernel and HDF5 without scientific acceptance" begin
    @test R.main(["self-check"])==0
    report=R.runner_self_check()
    @test report["status"]=="completed"
    @test report["julia_version"]=="1.13.0"
    @test report["iterative_converged"]=="not_evaluated"
    @test !report["scientific_accepted"]
    @test report["analytic_absolute_error"]<=2e-15
    @test report["hdf5_roundtrip"]
    mktempdir() do directory
        file=joinpath(directory,"not-a-directory")
        write(file,"existing data")
        @test R.main(["self-check","--directory",file])==2
        @test read(file,String)=="existing data"
    end
end
end
