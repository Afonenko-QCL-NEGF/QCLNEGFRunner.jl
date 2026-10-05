module OpticalSourceReceipt
include("../support/common.jl")
using HDF5, SHA, YAML
include("../support/native_physics_fixture.jl")
const R=QCLNEGFRunner
@testset "Diagnostic optics bind the source receipt without rewriting the full state" begin
    solution=native_physics_fixture(;energy_nodes=17)
    response=bare_bubble_optical_response(solution.problem,solution.scba.green,[1,2].*u"meV";threaded=false)
    mktempdir() do directory
        commit=R.commit_point_artifacts(directory,solution;algorithms=AlgorithmOptions(),storage_class=:archive,
            identity=Dict{String,Any}("point_id"=>"p","execution_id"=>"e","attempt"=>1,"plan_fingerprint"=>"fixture"))
        physical=joinpath(dirname(commit),"physics.h5")
        original=bytes2hex(open(sha256,physical))
        receipt=R.verify_recovery_receipt(commit)
        assessment=R.QCLScientificWorkflow.solution_scientific_assessment(solution)
        optical=joinpath(dirname(commit),"optical.h5")
        R.save_optical_physics(optical,response;source_sha256=original,source_receipt=receipt,
            identity=receipt["identity"],stationary_quality=solution.scba.quality,stationary_assessment=assessment)
        @test bytes2hex(open(sha256,physical))==original
        @test R.verify_recovery_receipt(commit)["commit_sha256"]==receipt["commit_sha256"]
        h5open(optical,"r") do file
            metadata=file["metadata"]
            @test YAML.load(String(read(metadata["source_state_receipt_json"]));dicttype=Dict{String,Any})==receipt
            @test YAML.load(String(read(metadata["identity_json"]));dicttype=Dict{String,Any})==receipt["identity"]
            @test YAML.load(String(read(metadata["stationary_quality_json"]));dicttype=Dict{String,Any})==assessment
            @test !haskey(file,"state_dimensionless")
            @test length(read(file["optical/photon_energy_eV"]))==2
            @test !assessment["scientific_accepted"]
        end
    end
end
end
