using Test, QCLNEGFRunner, QCLNEGF, SHA, Unitful, LinearAlgebra
const R04 = QCLNEGFRunner
const C04 = QCLNEGF
const P04_ROOT = mktempdir(; prefix="qcl-p05-entry-", cleanup=true)
include("../support/exact_persistence_fixture.jl")
root = normpath(joinpath(@__DIR__, "..", ".."))
@testset "legacy public entrypoints fail closed before execution" begin
    configured = read(joinpath(root, "src/composition/configured_run.jl"), String)
    sweep = read(joinpath(root, "src/composition/production_workflow.jl"), String)
    for (source,build) in ((configured,"configured = build_configured_problem(configuration)"),(sweep,"base_cache=build_production_cache(base_problem"))
        gate=findfirst("throw(ArgumentError(\"native5_configured_consumer_unavailable",source)
        allocation=findfirst(build,source)
        @test gate!==nothing && allocation!==nothing && first(gate)<first(allocation)
    end
end

@testset "direct sweep refuses before creating output" begin
    f = p04_exact_fixture()
    target = joinpath(P04_ROOT, "must-not-exist")
    err = try
        run_production_sweep(f.problem, [], []; output_directory=target)
        nothing
    catch ex
        ex
    end
    @test err isa ArgumentError
    @test occursin("native5_configured_consumer_unavailable", sprint(showerror, err))
    @test !ispath(target)
end

@testset "configured entry refuses before any output" begin
    config = load_run_configuration(joinpath(root, "test/fixtures/configurations/exact_cpu.yaml"))
    mktempdir() do dir
        cd(dir) do
            err = try
                run_from_configuration(config)
                nothing
            catch ex
                ex
            end
            @test err isa ArgumentError
            @test occursin("native5_configured_consumer_unavailable", sprint(showerror, err))
            @test isempty(readdir(dir))
        end
    end
end
