module CaptureCreditTests
using Test
using QCLNEGFRunner
using YAML
const R=QCLNEGFRunner

@testset "Fixed operational capture reservation, one byte refusal and no plan mutation" begin
    reserve=R._CAPTURE_RESERVE_BYTES
    @test reserve==109051904
    @test R._capture_credit(String[],reserve+25,3,5,"unused";
        storage_reader=_ ->17,free_reader=_ ->reserve+8)==reserve
    @test R._capture_credit(String[],reserve+24,3,5,"unused";
        storage_reader=_ ->17,free_reader=_ ->reserve+8)==0
    @test R._capture_credit(String[],reserve+25,3,5,"unused";
        storage_reader=_ ->17,free_reader=_ ->reserve+7)==0
    # The same ordinary guard is still admissible with observation disabled.
    @test R._check_storage_budget(String[],25,3,5;storage_reader=_ ->17)==17
    mktempdir() do root
        source=mkpath(joinpath(root,"source"));write(joinpath(source,"scalar"),"x")
        @test_throws ArgumentError R.stage_result_tree(source,joinpath(root,"denied");
            byte_budget=reserve+1,reserve_bytes=0,capture_reserve_bytes=reserve)
        @test isfile(joinpath(source,"scalar")) && !ispath(joinpath(root,"denied"))
        @test R.stage_result_tree(source,joinpath(root,"accepted");
            byte_budget=reserve+2,reserve_bytes=0,capture_reserve_bytes=reserve)==joinpath(root,"accepted")
    end
end

@testset "Best-effort fixed locator preserves exact frozen input bytes" begin
    mktempdir() do root
        plan_raw="{\"fingerprint\":\"$(repeat("a",64))\"}"
        write(joinpath(root,"plan.json"),plan_raw)
        spec=Dict("schema"=>"qcl-negf.capture-spec.v1",
            "selection"=>Dict("calcjob_uuid"=>"00000000-0000-4000-8000-000000000001","execution_id"=>"E","attempt"=>2,"plan_fingerprint"=>repeat("a",64)),
            "plan"=>Dict("path"=>"plan.json","bytes"=>sizeof(plan_raw),"sha256"=>bytes2hex(R.sha256(plan_raw))),
            "capture_token"=>repeat("b",32),"allocation_id"=>"calcjob-process:00000000-0000-4000-8000-000000000001:2",
            "allocated_logical_cpus"=>nothing,"scratch_root"=>nothing,
            "credits"=>Dict("performance_bytes"=>32*1024^2,"scalar_bytes"=>64*1024^2,"io_bytes"=>128*1024^2,"reserve_bytes"=>0))
        spec_path=joinpath(root,"capture-spec.json");R.QCLScientificWorkflow._scientific_json(spec_path,spec)
        context=R._capture_context((fingerprint=repeat("a",64),),joinpath(root,"result"),"E",2;spec_path)
        @test context!==nothing
        R._capture_locator(context,:direct,joinpath(root,"result"),0)
        locator=YAML.load_file(joinpath(root,"capture-source.json"))
        @test locator["mode"]=="direct" && locator["capture_token"]==repeat("b",32)
        @test read(joinpath(root,"plan.json"),String)==plan_raw
        spec["plan"]["sha256"]=repeat("c",64);R.QCLScientificWorkflow._scientific_json(spec_path,spec)
        @test R._capture_context((fingerprint=repeat("a",64),),joinpath(root,"result"),"E",2;spec_path)===nothing
    end
end
end
