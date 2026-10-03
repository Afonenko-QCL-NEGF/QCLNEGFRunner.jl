module BoundedPortableRecovery
include("../support/common.jl")
using HDF5, SHA
include("../support/native_physics_fixture.jl")
const R=QCLNEGFRunner

@testset "Recovery publication verifies, bounds generations and falls back" begin
    solution=native_physics_fixture(; energy_nodes=17)
    identity=Dict{String,Any}("point_id"=>"p", "execution_id"=>"e", "attempt"=>1, "plan_fingerprint"=>"fixture")
    mktempdir() do directory
        paths=String[]
        for _ in 1:12
            push!(paths, R.commit_point_artifacts(directory, solution; identity,
                algorithms=AlgorithmOptions(), analysis=false, storage_class=:recovery,
                retain_generations=2, byte_budget=8*1024^3, reserve_bytes=0))
        end
        generations=filter(name->startswith(name,"generation-"), readdir(joinpath(directory,"artifacts")))
        @test length(generations)==2
        latest=R.load_recovery_commit(directory)
        @test latest==paths[end]
        manifest=R.verify_point_artifacts(latest)
        @test !haskey(manifest,"science_parent_commit")
        @test manifest["state_sequence"]==12
        @test isfile(joinpath(dirname(latest),"receipt.json"))
        copied=joinpath(directory,"portable")
        cp(dirname(latest),copied)
        @test R.verify_point_artifacts(joinpath(copied,"commit.json"))["state_id"]==manifest["state_id"]
        write(joinpath(dirname(latest),"physics.h5"),"corrupt")
        @test R.load_recovery_commit(directory)==paths[end-1]
        write(joinpath(dirname(paths[end-1]),"physics.h5"),"corrupt")
        @test_throws ArgumentError R.load_recovery_commit(directory)
    end
end

@testset "Failed staging retains acknowledged recovery and final remains separate" begin
    solution=native_physics_fixture(; energy_nodes=17)
    mktempdir() do directory
        previous=R.commit_point_artifacts(directory,solution; algorithms=AlgorithmOptions(),
            storage_class=:recovery,analysis=false,reserve_bytes=0)
        @test_throws ArgumentError R.commit_point_artifacts(directory,solution;
            algorithms=AlgorithmOptions(),storage_class=:recovery,analysis=false,
            byte_budget=1,reserve_bytes=0)
        @test R.load_recovery_commit(directory)==previous
        @test !any(startswith(name,"pending-") for name in readdir(joinpath(directory,"artifacts")))
        final=R.commit_point_artifacts(directory,solution; algorithms=AlgorithmOptions(),storage_class=:archive)
        @test final==joinpath(directory,"archive","final","commit.json")
        @test !R.verify_point_artifacts(final)["scientific_accepted"]
        @test isfile(joinpath(dirname(final),"physics.h5"))
        @test_throws ArgumentError R.commit_point_artifacts(directory,solution;
            algorithms=AlgorithmOptions(),storage_class=:archive,terminal_status="paused")
    end
end

@testset "An explicit algorithm must not overwrite a different executed contract" begin
    solution=native_physics_fixture(; energy_nodes=17)
    solution.observables[:restart_contract]=R._solver_restart_contract(solution.options,AlgorithmOptions())
    mktempdir() do directory
        @test_throws ArgumentError R.commit_point_artifacts(directory,solution;
            algorithms=AlgorithmOptions(mixing=:anderson),analysis=false)
    end
end
@testset "An interrupted publication does not acknowledge or prune the prior checkpoint" begin
    solution=native_physics_fixture(;energy_nodes=17)
    mktempdir() do directory
        prior=R.commit_point_artifacts(directory,solution;algorithms=AlgorithmOptions(),analysis=false,reserve_bytes=0)
        for boundary in (:before_publish,:after_publish,:after_verify)
            @test_throws ErrorException R.commit_point_artifacts(directory,solution;
                algorithms=AlgorithmOptions(),analysis=false,reserve_bytes=0,
                publication_hook=stage->stage===boundary ? error("injected publication interruption") : nothing)
            @test R.load_recovery_commit(directory)==prior
        end
        newest=R.commit_point_artifacts(directory,solution;algorithms=AlgorithmOptions(),analysis=false,reserve_bytes=0)
        write(joinpath(dirname(newest),"physics.h5"),"corrupt")
        @test R.load_recovery_commit(directory)==prior
        pending=joinpath(directory,"artifacts","pending-killed")
        mkpath(pending)
        write(joinpath(pending,"physics.h5"),"incomplete")
        @test R.load_recovery_commit(directory)==prior
    end
end

end
