module ArchiveDependencyBudgetPreflight
using Test, SHA, YAML
const _RESULT_CONTRACT_SET="qcl-negf.results.v1"
source=read(joinpath(@__DIR__,"../../src/infrastructure/persistence/point_artifacts.jl"),String)
start=first(findfirst("function _verify_prior_final_dependencies",source))
finish=first(findfirst("function _verify_execution_progress_dependencies",source))-1
verify_recovery_receipt(path)=error("heavy native verifier must not run for an incomplete index")
include_string(@__MODULE__,source[start:finish],"production_archive_dependency_preflight.jl")
_contained_result_file(root,relative)=joinpath(root,relative)
serializer=read(joinpath(@__DIR__,"../../src/infrastructure/persistence/light_results.jl"),String)
first_json=first(findfirst("function _light_json",serializer))
last_json=first(findfirst("function _light_svg_series",serializer))-1
include_string(@__MODULE__,serializer[first_json:last_json],"production_light_json.jl")
@testset "Incomplete archive indexes refuse before any heavy receipt verification" begin
    mktempdir() do root
        final=joinpath(root,"e","p1","final")
        mkpath(final)
        artifacts=Any[]
        for (role,name,bytes) in (("physics.full","physics.h5",zeros(UInt8,100000)),
                ("science.history","history.h5",UInt8[1]),("model","resolved_configuration.json",UInt8[2]))
            write(joinpath(final,name),bytes)
            push!(artifacts,Dict("role"=>role,"path"=>name,"bytes"=>length(bytes),"sha256"=>bytes2hex(sha256(bytes))))
        end
        commit=Dict("storage_class"=>"archive","artifacts"=>artifacts)
        open(io->_light_json(io,commit),joinpath(final,"commit.json"),"w")
        write(joinpath(final,"receipt.json"),"{}")
        files=[Dict("path"=>name,"bytes"=>filesize(joinpath(final,name)),"sha256"=>bytes2hex(open(sha256,joinpath(final,name))))
            for name in ("commit.json","receipt.json","history.h5","resolved_configuration.json")]
        point=Dict("status"=>"completed","execution_id"=>"e","id"=>"p1","attempt"=>1,"data"=>Dict())
        progress=Dict("schema"=>"qcl-negf-execution-progress-v1","contract_set"=>_RESULT_CONTRACT_SET,
            "execution_id"=>"e","active_point_id"=>"p2","plan_fingerprint"=>"frozen",
            "completed_points"=>[Dict("point"=>point,"final_commit"=>"e/p1/final/commit.json","files"=>files)])
        calls=Ref(0)
        verifier=path->begin
            calls[]+=1
            error("attempted heavy verification")
        end
        @test_throws ArgumentError _verify_prior_final_dependencies(progress,root;
            byte_budget=sum(f["bytes"] for f in files)+1,receipt_verifier=verifier)
        @test calls[]==0
    end
end
end
