module ScopedPauseReceipt
include("../support/common.jl")
include("../support/native_physics_fixture.jl")
const R=QCLNEGFRunner
@testset "Pause acknowledgement requires a verified scoped bundle" begin
    solution=native_physics_fixture(; energy_nodes=17)
    identity=Dict{String,Any}("point_id"=>"p","execution_id"=>"e","attempt"=>1,"plan_fingerprint"=>"fixture")
    mktempdir() do root
        @test R.main(["pause",root,"--execution-id","e","--attempt","1"])==0
        @test R.pause_requested(root,identity)
        @test !R.pause_requested(root,merge(identity,Dict("attempt"=>2)))
        @test R.main(["verify-pause",root,"--execution-id","e","--attempt","1"])==2
        commit=R.commit_point_artifacts(joinpath(root,"attempt-1"),solution;identity,
            algorithms=AlgorithmOptions(),analysis=false,reserve_bytes=0,
            execution_progress=Dict("schema"=>"qcl-negf-execution-progress-v1","contract_set"=>"qcl-negf.results.v1",
                "execution_id"=>"e","active_point_id"=>"p","plan_fingerprint"=>"fixture","completed_points"=>Any[]))
        R.write_pause_receipt(root,commit,identity)
        @test R.main(["verify-pause",root,"--execution-id","e","--attempt","1"])==0
        @test R.main(["verify-pause",root,"--execution-id","e","--attempt","1","--archive-byte-budget","1"])==0
        @test R.main(["verify-stop",root,"--execution-id","e","--attempt","1","--archive-byte-budget","1"])==0
        @test R.main(["verify-pause",root,"--execution-id","e","--attempt","1","--archive-byte-budget","0"])==2
        @test R.main(["verify-pause",root,"--execution-id","e","--attempt","2"])==2
        write(joinpath(dirname(commit),"physics.h5"),"corrupt")
        @test R.main(["verify-pause",root,"--execution-id","e","--attempt","1"])==2
    end
end
end
