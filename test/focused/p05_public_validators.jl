using Test, QCLNEGFRunner, QCLNEGF
@testset "configuration and report use public Core validation" begin
    runner = dirname(dirname(pathof(QCLNEGFRunner)))
    config = read(joinpath(runner, "src/infrastructure/config/configuration.jl"), String)
    report = read(joinpath(runner, "src/presentation/expert_report.jl"), String)
    @test !occursin(r"\b_check_(options|algorithm_options|production_options|production_kernel_options)\b", config)
    @test !occursin("_check_scba_result_classification", report)
    @test QCLNEGF.validate_options(QCLNEGF.SolverOptions()) isa QCLNEGF.SolverOptions
    @test_throws ArgumentError QCLNEGF.validate_result_classification(true, :unconverged, :strictly_converged)
end
@testset "Runner no longer binds unused private numerical implementations" begin
    for name in (:_AndersonWorkspace, :_anderson_mix!, :_kernel_pair_index)
        @test !isdefined(QCLNEGFRunner,name)
    end
end
