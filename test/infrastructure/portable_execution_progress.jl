module PortableExecutionProgress
include("../support/common.jl")
using HDF5
include("../support/native_physics_fixture.jl")
const R=QCLNEGFRunner
const S=R.QCLScientificWorkflow
function complete_final(root,solution,identity)
    recorder=R.ScientificHistoryRecorder(joinpath(root,"fixture-history"),identity,Ref(0),Ref(0))
    row=SCBAIteration(1,ntuple(_->NaN,16)...,nothing,nothing)
    R.record_scientific_history!(recorder,:scba,1,row,solution.problem)
    history_path=R.flush_scientific_history!(recorder)
    configuration=load_run_configuration(joinpath(TEST_ROOT,"fixtures","configurations","studies-smoke.yaml")).raw
    return R.commit_point_artifacts(root,solution;identity,algorithms=AlgorithmOptions(),
        storage_class=:archive,archive_root=joinpath(root,"archive",identity["execution_id"],identity["point_id"]),
        configuration,history_paths=[history_path])
end
@testset "A portable second point retains the first final without recalculating it" begin
    solution=native_physics_fixture(;energy_nodes=17)
    p1=S.ScientificPoint("p1","execution",70.0,0.05,"forward",1,nothing,:cold)
    p2=S.ScientificPoint("p2","execution",70.0,0.06,"forward",2,nothing,:cold)
    fingerprint="frozen"
    mktempdir() do source
        identity=Dict{String,Any}("point_id"=>"p1","execution_id"=>"execution","attempt"=>1,"plan_fingerprint"=>fingerprint)
        first_final=complete_final(source,solution,identity)
        record=S._point_result(p1,1,S._initialization("cold"),:completed,:unconverged,false;
            data=Dict{String,Any}("result_commit"=>relpath(first_final,source),"full_state"=>relpath(joinpath(dirname(first_final),"physics.h5"),source)))
        progress=S._scientific_execution_progress([record],p2,source,fingerprint)
        current_identity=merge(identity,Dict("point_id"=>"p2"))
        recovery=R.commit_point_artifacts(source,solution;identity=current_identity,algorithms=AlgorithmOptions(),
            analysis=false,execution_progress=progress,reserve_bytes=0)
        manifest=R.verify_point_artifacts(recovery)
        @test any(a->a["role"]=="execution.progress",manifest["artifacts"])
        original=read(joinpath(dirname(first_final),"physics.h5"))
        mktempdir() do target
            @test_throws ArgumentError S._import_completed_archives!(progress,nothing,target,
                S.RecoveryOutputPolicy(true,1800.0,2,8*1024^3,0))
            @test_throws ArgumentError S._import_completed_archives!(progress,source,target,
                S.RecoveryOutputPolicy(true,1800.0,2,8*1024^3,0);archive_byte_budget=1)
            imported=S._import_completed_archives!(progress,source,target,
                S.RecoveryOutputPolicy(true,1800.0,2,8*1024^3,0))
            @test only(imported).id=="p1"
            @test only(imported).attempt==1
            @test read(joinpath(target,"archive","execution","p1","final","physics.h5"))==original
            @test R.verify_recovery_receipt(joinpath(target,"archive","execution","p1","final","commit.json"))["state_id"]==
                R.verify_recovery_receipt(first_final)["state_id"]
            write(joinpath(dirname(first_final),"physics.h5"),"corrupt")
            @test_throws ArgumentError S._import_completed_archives!(progress,source,joinpath(target,"damaged"),
                S.RecoveryOutputPolicy(true,1800.0,2,8*1024^3,0))
        end
    end
end
@testset "A prior stationary archive needs physical, history and model closure before import" begin
    solution=native_physics_fixture(;energy_nodes=17)
    p1=S.ScientificPoint("p1","execution",70.0,0.05,"forward",1,nothing,:cold)
    p2=S.ScientificPoint("p2","execution",70.0,0.06,"forward",2,nothing,:cold)
    mktempdir() do source
        identity=Dict{String,Any}("point_id"=>"p1","execution_id"=>"execution","attempt"=>1,"plan_fingerprint"=>"frozen")
        commit=complete_final(source,solution,identity)
        manifest=R.verify_point_artifacts(commit)
        filter!(a->!(a["role"] in ("science.history","model")),manifest["artifacts"])
        open(io->R._light_json(io,manifest),commit,"w")
        R._write_bundle_receipt(commit)
        record=S._point_result(p1,1,S._initialization("cold"),:completed,:unconverged,false;
            data=Dict{String,Any}("result_commit"=>relpath(commit,source),"full_state"=>relpath(joinpath(dirname(commit),"physics.h5"),source)))
        progress=S._scientific_execution_progress([record],p2,source,"frozen")
        target=joinpath(source,"import-target")
        @test_throws ArgumentError S._import_completed_archives!(progress,source,target,
            S.RecoveryOutputPolicy(true,1800.0,2,8*1024^3,0))
        @test !isdir(joinpath(target,"archive"))
    end
end
end
