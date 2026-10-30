module CaptureCreditTests
using Test
using QCLNEGFRunner
using YAML
const R=QCLNEGFRunner

# Exercise the real CLI parser/forwarding with a scientific backend sentinel.
# No plan factory, kernel, SCBA or Poisson runs in this engineering fixture.
module CaptureCLISentinel
import QCLNEGFRunner as R
const ConfigurationError=R.ConfigurationError
module QCLScientificWorkflow
    const loaded=Ref{Any}()
    _load_scientific_plan_bytes(path)=loaded[]
end
const calls=Any[]
_capture_context(args...;kwargs...)=R._capture_context(args...;kwargs...)
_load_source_graph_file(path)=R._load_source_graph_file(path)
execute_scientific_plan_staged(plan,output;kwargs...)=(push!(calls,(plan,output,(;kwargs...)));nothing)
write_scientific_result(io,result)=nothing
include(joinpath(@__DIR__,"..","..","src","cli.jl"))
end

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

@testset "Paired native admission separates transport attempt from solver continuation" begin
    mktempdir() do root
        uuid="00000000-0000-4000-8000-000000000001"
        plan_raw=" \n{\"fingerprint\":\"$(repeat("a",64))\",\"executions\":[{\"id\":\"E\"}]}\n"
        graph_raw="\n{\"format\":\"qcl-negf.git-graph.v1\",\"revision\":\"$(repeat("c",40))\",\"components\":[]}\n"
        plan_path=joinpath(root,"plan.json");write(plan_path,plan_raw)
        graph_path=joinpath(root,"source-graph.json");write(graph_path,graph_raw)
        nodefile(raw)=Dict("node_uuid"=>uuid,"bytes"=>string(sizeof(raw)),"sha256"=>bytes2hex(R.sha256(raw)))
        native=Dict("schema"=>"qcl-negf.aiida-native-execution.v1","request_id"=>uuid,"execution_id"=>"E",
            "input_plan"=>nodefile(plan_raw),"source_graph"=>nodefile(graph_raw),"access_receipt_ref"=>"access-receipt",
            "storage"=>Dict("namespace_id"=>"native","storage_identity"=>"storage","relative_execution_root"=>"native/new-domain",
                "computer_uuid"=>uuid,"execution_binding_uuid"=>uuid,"retention_policy_id"=>"policy","retention_owner_id"=>"owner",
                "hold_ref"=>"hold","access_binding_ref"=>"access"),
            "code"=>Dict("code_uuid"=>uuid,"computer_uuid"=>uuid,"solver_executable"=>"/nix/store/synthetic/bin/qcl-negf",
                "release_id"=>"release","build_receipt_ref"=>"build"))
        native_path=joinpath(root,"native-execution.json")
        spec=Dict("schema"=>"qcl-negf.capture-spec.v1",
            "selection"=>Dict("calcjob_uuid"=>uuid,"execution_id"=>"E","attempt"=>3,"plan_fingerprint"=>repeat("a",64)),
            "plan"=>Dict("path"=>"plan.json","bytes"=>sizeof(plan_raw),"sha256"=>bytes2hex(R.sha256(plan_raw))),
            "capture_token"=>repeat("b",32),"allocation_id"=>"calcjob-process:$(uuid):3",
            "allocated_logical_cpus"=>nothing,"scratch_root"=>nothing,
            "credits"=>Dict("performance_bytes"=>32*1024^2,"scalar_bytes"=>64*1024^2,"io_bytes"=>128*1024^2,"reserve_bytes"=>0))
        spec_path=joinpath(root,"capture-spec.json")
        publish()=(R.QCLScientificWorkflow._scientific_json(spec_path,spec);R.QCLScientificWorkflow._scientific_json(native_path,native))
        publish()
        output=joinpath(root,"jobs with spaces","native","new-domain")
        plan=(fingerprint=repeat("a",64),)
        # Old ordinary checks remain strict for absent attempt/canonical jobs output.
        @test R._capture_context(plan,output,"E",nothing;spec_path)===nothing
        @test R._capture_context(plan,joinpath(root,"result"),"E",3;spec_path)!==nothing
        frozen=Vector{UInt8}(codeunits(plan_raw))
        context=R._capture_context(plan,output,"E",nothing;spec_path,native_execution_path=native_path,
            frozen_plan_bytes=frozen,source_plan_path=plan_path,source_graph_path=graph_path)
        @test frozen==Vector{UInt8}(codeunits(plan_raw))
        @test context!==nothing
        CaptureCLISentinel.QCLScientificWorkflow.loaded[]=(plan=plan,bytes=frozen,capture=nothing)
        empty!(CaptureCLISentinel.calls)
        argv=["run-plan",plan_path,output,"--execution-id","E","--source-graph",graph_path]
        withenv("QCL_NEGF_CAPTURE_SPEC"=>spec_path,"QCL_NEGF_NATIVE_CAPTURE_INPUT"=>native_path,"QCL_TELEMETRY_ENDPOINT"=>nothing) do
            @test CaptureCLISentinel.main(argv)==0
            @test length(CaptureCLISentinel.calls)==1
            forwarded=last(CaptureCLISentinel.calls)
            @test forwarded[2]==output && forwarded[3].capture_context!==nothing && forwarded[3].attempt===nothing
            @test CaptureCLISentinel.main(vcat(argv,["--attempt","2"]))==0
            @test last(CaptureCLISentinel.calls)[3].capture_context===nothing && last(CaptureCLISentinel.calls)[3].attempt==2
            @test CaptureCLISentinel.main(vcat(argv,["--scratch-root",joinpath(root,"scratch")]))==0
            @test last(CaptureCLISentinel.calls)[3].capture_context===nothing
            @test CaptureCLISentinel.main(vcat(argv,["--archive-byte-budget","123"]))==0
            @test last(CaptureCLISentinel.calls)[3].capture_context===nothing
            @test length(CaptureCLISentinel.calls)==4
        end
        withenv("QCL_NEGF_CAPTURE_SPEC"=>spec_path,"QCL_NEGF_NATIVE_CAPTURE_INPUT"=>nothing,"QCL_TELEMETRY_ENDPOINT"=>nothing) do
            ordinary=["run-plan",plan_path,joinpath(root,"result"),"--execution-id","E","--attempt","3","--source-graph",graph_path]
            @test CaptureCLISentinel.main(ordinary)==0
            @test last(CaptureCLISentinel.calls)[3].capture_context!==nothing && last(CaptureCLISentinel.calls)[3].attempt==3
        end
        if context!==nothing
            R._capture_locator(context,:direct,output,0)
            locator=YAML.load_file(joinpath(root,"capture-source.json"))
            @test locator["actual_root"]==output && locator["capture_token"]==repeat("b",32)
            @test locator["mode"]=="direct"
        end
        admit(;out=output,attempt=nothing,scratch_root=nothing,native_file=native_path,plan_file=plan_path,graph_file=graph_path)=
            R._capture_context(plan,out,"E",attempt;spec_path,scratch_root,native_execution_path=native_file,
                source_plan_path=plan_file,source_graph_path=graph_file)
        # Native scratch and explicit CLI/native counter are unsupported, no credit.
        @test admit(attempt=3)===nothing
        @test admit(scratch_root=joinpath(root,"scratch"))===nothing
        @test admit(out=joinpath(root,"wrong"))===nothing
        @test admit(out="native/new-domain")===nothing
        @test admit(native_file=joinpath(root,"missing.json"))===nothing
        @test admit(plan_file=graph_path)===nothing
        @test admit(graph_file=plan_path)===nothing
        for mutate in (
            ()->(native["execution_id"]="other"),
            ()->(native["input_plan"]["sha256"]=repeat("f",64)),
            ()->(native["source_graph"]["bytes"]="0"),
            ()->(native["storage"]["relative_execution_root"]="../native/new-domain"),
            ()->(native["storage"]["computer_uuid"]="invalid"),
            ()->(native["code"]["computer_uuid"]="00000000-0000-4000-8000-000000000002"),
            ()->(native["extra"]="unexpected"),
            ()->(native["input_plan"]["bytes"]="01"),
            ()->(native["storage"]["relative_execution_root"]="native//new-domain"),
            ()->(native["storage"]["relative_execution_root"]="native\\new-domain"),
            ()->(native["code"]["solver_executable"]="/usr/bin/qcl-negf"),
            ()->(spec["capture_token"]="invalid"),
            ()->(spec["capture_token"]=repeat("b",32)*"\n"),
            ()->(spec["selection"]["calcjob_uuid"]=uuid*"\n"),
            ()->(spec["plan"]["extra"]="unexpected"),
            ()->(spec["plan"]["sha256"]=repeat("f",64)),
            ()->(spec["selection"]["attempt"]="3"),
            ()->(spec["selection"]["attempt"]=true),
            ()->(spec["selection"]["attempt"]=0),
            ()->(spec["credits"]["performance_bytes"]+=1))
            saved_native=deepcopy(native);saved_spec=deepcopy(spec)
            mutate();publish();@test admit()===nothing
            native=saved_native;spec=saved_spec;publish()
        end
        @test admit()!==nothing
        # Bounds, strict JSON and symlink refusal cannot authorize native credit.
        native_raw=read(native_path)
        write(native_path,vcat(native_raw,fill(UInt8(' '),16385)))
        @test admit()===nothing
        write(native_path,"{\"schema\":1,\"schema\":2}")
        @test admit()===nothing
        write(native_path,native_raw)
        graph_saved=read(graph_path);write(graph_path,vcat(graph_saved,UInt8[0x20]))
        @test admit()===nothing
        write(graph_path,graph_saved)
        alternate=joinpath(root,"native-original.json");mv(native_path,alternate);symlink(alternate,native_path)
        @test admit()===nothing
        rm(native_path);mv(alternate,native_path)
        @test admit()!==nothing
        # Inputs and a source-array sentinel are never rewritten by admission/locator.
        sentinel=joinpath(root,"source-array.bin");sentinel_raw=UInt8[0x00,0xff,0x80,0x01];write(sentinel,sentinel_raw)
        R._capture_locator(context,:direct,output,0)
        @test read(plan_path,String)==plan_raw && read(graph_path,String)==graph_raw
        @test read(sentinel)==sentinel_raw
    end
end

end
