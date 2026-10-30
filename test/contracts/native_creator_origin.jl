module NativeCreatorOriginTests
using Test, QCLNEGFRunner, SHA
const R=QCLNEGFRunner
const CALC="11111111-1111-4111-8111-111111111111"
const INPUT="22222222-2222-4222-8222-222222222222"
const OTHER="33333333-3333-4333-8333-333333333333"
const GRAPH_RAW="\n{\"format\":\"qcl-negf.git-graph.v1\",\"revision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"components\":[]}\n"
const PLAN_RAW=" \n{\"fingerprint\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"executions\":[{\"id\":\"E\"}]}\r\n"

# Only the scientific executor is replaced: the actual CLI and original-file
# validators run. The sentinel cannot allocate a Core problem or run a solve.
module OriginCLI
import QCLNEGFRunner as R
const ConfigurationError=R.ConfigurationError
module QCLScientificWorkflow
    const loaded=Ref{Any}()
    _load_scientific_plan_bytes(path)=loaded[]
end
const calls=Any[]
_capture_context(args...;kwargs...)=R._capture_context(args...;kwargs...)
_native_origin_inputs(args...;kwargs...)=R._native_origin_inputs(args...;kwargs...)
_load_source_graph_file(path)=R._load_source_graph_file(path)
execute_scientific_plan_staged(plan,output;kwargs...)=(push!(calls,(plan,output,(;kwargs...)));nothing)
write_scientific_result(io,result)=nothing
include(joinpath(@__DIR__,"..","..","src","cli.jl"))
end

module OriginStaged
import QCLNEGFRunner: ScientificPlan, ExecutionEnvelope, VerifiedExactCheckpoint, PhaseObservationPolicy,
    _P05PlanCapture, _native_origin_ids, default_execution_envelope,
    _scientific_resource_preflight, _require_source_graph
const calls=Any[]
# Actual staging dispatch, with only the downstream scientific compute replaced.
execute_scientific_plan(plan,output;kwargs...)=(push!(calls,(output,(;kwargs...)));:sentinel_exit)
include(joinpath(@__DIR__,"..","..","src","composition","scratch_execution.jl"))
end

function native_document()
    file(uuid,raw)=Dict("node_uuid"=>uuid,"bytes"=>string(sizeof(raw)),"sha256"=>bytes2hex(sha256(raw)))
    Dict{String,Any}("schema"=>"qcl-negf.aiida-native-execution.v1","request_id"=>OTHER,"execution_id"=>"E",
        "input_plan"=>file(OTHER,PLAN_RAW),"source_graph"=>file(OTHER,GRAPH_RAW),"access_receipt_ref"=>"access",
        "storage"=>Dict{String,Any}("namespace_id"=>"native","storage_identity"=>"storage",
            "relative_execution_root"=>"native/new-domain","computer_uuid"=>OTHER,"execution_binding_uuid"=>INPUT,
            "retention_policy_id"=>"policy","retention_owner_id"=>"owner","hold_ref"=>"hold","access_binding_ref"=>"access"),
        "code"=>Dict{String,Any}("code_uuid"=>OTHER,"computer_uuid"=>OTHER,
            "solver_executable"=>"/nix/store/synthetic/bin/qcl-negf","release_id"=>"release","build_receipt_ref"=>"build"))
end
function fixture(f)
    mktempdir() do root
        job=mkpath(joinpath(root,"upload"))
        plan=joinpath(job,"plan.json");graph=joinpath(job,"source-graph.json");native=joinpath(job,"native-execution.json")
        write(plan,PLAN_RAW);write(graph,GRAPH_RAW)
        document=native_document();write(native," \n"*R._p04_json(document)*"\n")
        output=joinpath(root,"jobs with spaces","native","new-domain")
        f((;root,job,plan,graph,native,document,output))
    end
end
read_origin(x;kwargs...)=R._native_origin_inputs(x.plan,x.graph,x.native,x.output,CALC,"E";
    frozen_plan_bytes=Vector{UInt8}(codeunits(PLAN_RAW)),kwargs...)

@testset "Native creator origin" begin
@testset "Native origin CLI is mandatory with capture off, and both flags are paired" begin
    fixture() do x
        OriginCLI.QCLScientificWorkflow.loaded[]=(plan=(fingerprint=repeat("b",64),),
            bytes=Vector{UInt8}(codeunits(PLAN_RAW)),capture=nothing)
        empty!(OriginCLI.calls)
        argv=["run-plan",x.plan,x.output,"--execution-id","E","--source-graph",x.graph,
            "--native-execution",x.native,"--native-calcjob-uuid",CALC]
        withenv("QCL_NEGF_CAPTURE_SPEC"=>nothing,"QCL_NEGF_NATIVE_CAPTURE_INPUT"=>nothing,"QCL_TELEMETRY_ENDPOINT"=>nothing) do
            @test OriginCLI.main(argv)==0
            @test length(OriginCLI.calls)==1
            if !isempty(OriginCLI.calls)
                kw=last(OriginCLI.calls)[3]
                @test kw.native_origin==(calcjob_uuid=CALC,native_execution_uuid=INPUT)
                @test kw.capture_context===nothing && kw.attempt===nothing
            end
            for bad in (argv[1:end-2],vcat(argv[1:7],argv[10:11]),vcat(argv,["--attempt","3"]),
                    vcat(argv,["--scratch-root",joinpath(x.root,"scratch")]),vcat(argv,["--archive-byte-budget","123"]),
                    vcat(argv,["--native-calcjob-uuid",CALC]))
                before=length(OriginCLI.calls)
                @test OriginCLI.main(bad)==2
                @test length(OriginCLI.calls)==before
                @test !ispath(x.output)
            end
            # The unmodified ordinary argument path still reaches the executor once.
            @test OriginCLI.main(argv[1:7])==0
            @test last(OriginCLI.calls)[3].capture_context===nothing
            # Missing/corrupt optional capture cannot bypass the mandatory input check.
            bad=deepcopy(x.document);bad["input_plan"]["sha256"]=repeat("f",64)
            write(x.native,R._p04_json(bad));before=length(OriginCLI.calls)
            @test OriginCLI.main(argv)==2 && length(OriginCLI.calls)==before
        end
    end
end

@testset "Actual staged entry keeps the private origin and ordinary scientific arguments" begin
    S=R.QCLScientificWorkflow
    plan=R.ScientificPlan{Nothing}("fixture",:run,"fixture",repeat("a",64),1,
        R.ScientificInclusion[],S.ScientificExecution{Nothing}[],R.ScientificPoint[],S.ScientificExecutionNode[])
    mktempdir() do root
        output=joinpath(root,"output");scratch=joinpath(root,"scratch")
        origin=(calcjob_uuid=CALC,native_execution_uuid=INPUT)
        raw=Vector{UInt8}(codeunits(PLAN_RAW));graph=R._p04_parse(GRAPH_RAW)
        empty!(OriginStaged.calls)
        @test OriginStaged.execute_scientific_plan_staged(plan,output;source_graph=graph,
            execution_id="E",native_origin=origin,frozen_plan_bytes=raw)==:sentinel_exit
        forwarded=only(OriginStaged.calls)
        @test forwarded[1]==output && forwarded[2].native_origin==origin
        @test forwarded[2].frozen_plan_bytes==Vector{UInt8}(codeunits(PLAN_RAW))
        @test forwarded[2].attempt===nothing && forwarded[2].parent_checkpoint===nothing
        @test_throws ArgumentError OriginStaged.execute_scientific_plan_staged(plan,output;source_graph=graph,
            native_origin=origin,scratch_root=scratch)
        @test length(OriginStaged.calls)==1 && !ispath(output) && !ispath(scratch)
        for entry in (R.execute_scientific_plan,R.execute_scientific_plan_staged)
            @test_throws ArgumentError entry(plan,output;native_origin=(calcjob_uuid=CALC,native_execution_uuid="invalid"))
            @test !ispath(output)
        end
    end
end

@testset "Optional capture never selects a different native CalcJob" begin
    fixture() do x
        raw=read(x.native)
        spec=Dict("schema"=>"qcl-negf.capture-spec.v1",
            "selection"=>Dict("calcjob_uuid"=>CALC,"execution_id"=>"E","attempt"=>7,"plan_fingerprint"=>repeat("b",64)),
            "plan"=>Dict("path"=>"plan.json","bytes"=>sizeof(PLAN_RAW),"sha256"=>bytes2hex(sha256(PLAN_RAW))),
            "capture_token"=>repeat("a",32),"allocation_id"=>"calcjob-process:$(CALC):7",
            "allocated_logical_cpus"=>nothing,"scratch_root"=>nothing,
            "credits"=>Dict("performance_bytes"=>32*1024^2,"scalar_bytes"=>64*1024^2,"io_bytes"=>128*1024^2,"reserve_bytes"=>0))
        spec_path=joinpath(x.job,"capture-spec.json");write(spec_path,R._p04_json(spec))
        argv=["run-plan",x.plan,x.output,"--execution-id","E","--source-graph",x.graph,
            "--native-execution",x.native,"--native-calcjob-uuid",CALC]
        OriginCLI.QCLScientificWorkflow.loaded[]=(plan=(fingerprint=repeat("b",64),),
            bytes=Vector{UInt8}(codeunits(PLAN_RAW)),capture=nothing)
        withenv("QCL_NEGF_CAPTURE_SPEC"=>spec_path,"QCL_NEGF_NATIVE_CAPTURE_INPUT"=>x.native,"QCL_TELEMETRY_ENDPOINT"=>nothing) do
            @test OriginCLI.main(argv)==0
            @test last(OriginCLI.calls)[3].capture_context!==nothing
            @test last(OriginCLI.calls)[3].attempt===nothing
            spec["selection"]["calcjob_uuid"]=OTHER;spec["allocation_id"]="calcjob-process:$(OTHER):7"
            write(spec_path,R._p04_json(spec))
            @test OriginCLI.main(argv)==0
            @test last(OriginCLI.calls)[3].native_origin==(calcjob_uuid=CALC,native_execution_uuid=INPUT)
            @test last(OriginCLI.calls)[3].capture_context===nothing
        end
        @test read(x.native)==raw
    end
end

@testset "Actual bounded original input assertions, no rewriting or output creation" begin
    @test isdefined(R,:_native_origin_inputs)
    if isdefined(R,:_native_origin_inputs)
        fixture() do x
            before=(read(x.plan),read(x.graph),read(x.native))
            @test read_origin(x)==(calcjob_uuid=CALC,native_execution_uuid=INPUT)
            changed=deepcopy(x.document);changed["storage"]["execution_binding_uuid"]=OTHER
            write(x.native,R._p04_json(changed))
            @test read_origin(x)==(calcjob_uuid=CALC,native_execution_uuid=OTHER)
            # Valid original INPUT UUID changes remain assertions to be joined
            # to actual immutable AiiDA nodes; Runner cannot authenticate a DB.
            write(x.native,before[3])
            @test before==(read(x.plan),read(x.graph),read(x.native)) && !ispath(x.output)
            for mutate in (
                    d->(d["input_plan"]["sha256"]=repeat("f",64)),d->(d["source_graph"]["bytes"]="01"),
                    d->(d["input_plan"]["node_uuid"]="invalid"),d->(d["storage"]["execution_binding_uuid"]=INPUT*"\n"),
                    d->(d["storage"]["execution_binding_uuid"]="00000000-0000-0000-0000-000000000000"),
                    d->(d["execution_id"]="other"),d->(d["storage"]["relative_execution_root"]="../native/new-domain"),
                    d->(d["storage"]["relative_execution_root"]="native//new-domain"),
                    d->(d["code"]["computer_uuid"]=CALC),d->(d["code"]["solver_executable"]="/usr/bin/qcl-negf"),
                    d->(d["code"]["extra"]="unknown"),d->(d["extra"]=true))
                bad=deepcopy(x.document);mutate(bad);write(x.native,R._p04_json(bad))
                @test_throws ArgumentError read_origin(x)
                @test !ispath(x.output)
            end
            write(x.native,before[3])
            for bad in (CALC*"\n",uppercase(CALC),"00000000-0000-0000-0000-000000000000","invalid")
                # CALC has no a-f letters; explicit uppercase noncanonical UUID follows below.
                bad==CALC && continue
                @test_throws ArgumentError R._native_origin_inputs(x.plan,x.graph,x.native,x.output,bad,"E";
                    frozen_plan_bytes=before[1])
            end
            @test_throws ArgumentError R._native_origin_inputs(x.plan,x.graph,x.native,x.output,
                "AAAAAAAA-aaaa-4aaa-8aaa-aaaaaaaaaaaa","E";frozen_plan_bytes=before[1])
            write(x.plan,vcat(before[1],UInt8[0x20]));@test_throws ArgumentError read_origin(x);write(x.plan,before[1])
            write(x.native,fill(UInt8(' '),65537));@test_throws ArgumentError read_origin(x)
            write(x.native,"{\"schema\":1,\"schema\":2}");@test_throws ArgumentError read_origin(x)
            write(x.native,before[3]);original=joinpath(x.job,"original-native.json");mv(x.native,original);symlink(original,x.native)
            @test_throws ArgumentError read_origin(x)
            rm(x.native);mv(original,x.native)
            @test_throws ArgumentError R._native_origin_inputs(x.plan,x.graph,x.native,x.output*"/../new-domain",CALC,"E";
                frozen_plan_bytes=before[1])
            @test read_origin(x)==(calcjob_uuid=CALC,native_execution_uuid=INPUT)
        end
    end
end

@testset "Literal source epoch and metadata-only manifest preserve original parent" begin
    @test isdefined(R,:_native_source_epoch)
    if isdefined(R,:_native_source_epoch)
        origin=(calcjob_uuid=CALC,native_execution_uuid=INPUT)
        expected="c1-11111111111141118111111111111111-22222222222242228222222222222222-18446744073709551615"
        @test R._native_source_epoch(origin;nonce=typemax(UInt64))==expected
        @test R._native_source_epoch(nothing;nonce=UInt64(17))=="epoch-17"
        @test R._native_source_epoch(origin;nonce=UInt64(0))=="c1-11111111111141118111111111111111-22222222222242228222222222222222-0"
        for bad in ((calcjob_uuid=CALC,native_execution_uuid="bad"),
                (calcjob_uuid=CALC,native_execution_uuid=INPUT,verified=true),
                (calcjob_uuid=repeat("a",129),native_execution_uuid=INPUT))
            @test_throws ArgumentError R._native_source_epoch(bad;nonce=UInt64(1))
        end
        mktempdir() do root
            identity=Dict("run_id"=>"run","execution_id"=>"E","point_id"=>"point","attempt"=>"2","branch_id"=>"branch",
                "model_sha256"=>repeat("a",64),"plan_sha256"=>repeat("b",64))
            unmeasured()=Dict("state"=>"not_measured","reason"=>"metadata_constructor_only","evidence"=>nothing)
            status=Dict{String,Any}("process"=>Dict("state"=>"running","exit_code"=>nothing,"reason"=>nothing),
                (name=>unmeasured() for name in ("convergence","physics","discretization","experimental"))...)
            provenance=R._p04_parse(GRAPH_RAW)
            parent_identity=merge(identity,Dict("attempt"=>"1"))
            parent_ref=Dict("identity"=>parent_identity,"state_id"=>"epoch-old-state-1","state_sequence"=>"1",
                "manifest"=>Dict("path"=>"original/manifest.json","bytes"=>"123","sha256"=>repeat("c",64),
                    "media_type"=>"application/json","schema"=>"qcl-negf.result-manifest.v1"))
            # Synthetic verified-handle metadata exercises only recorder retention;
            # it is deliberately not evidence of an actual verified checkpoint read.
            parent=R.VerifiedExactCheckpoint(root,parent_ref,Dict("invocation"=>Dict("source_epoch"=>"epoch-old")),
                Dict("witness_targets"=>Any[]),Dict{String,Any}(),Val(:verified))
            original=(parent.reference_json,parent.manifest_json,parent.declaration_json)
            r=R.ScientificHistoryRecorder(joinpath(root,"new");artifact_root=root,identity,source_epoch=expected,
                provenance,status,maximum_scba_rows=3,parent_checkpoint=parent)
            manifest=R._p04_manifest(r,typemax(UInt64),R._p04_empty_pin(),nothing,Dict{String,Any}[],nothing,status,false)
            @test manifest["state_id"]=="c1-11111111111141118111111111111111-22222222222242228222222222222222-18446744073709551615-state-18446744073709551615"
            @test sizeof(manifest["state_id"])==116
            @test manifest["lineage"]["parent_state"]==parent_ref
            @test original==(parent.reference_json,parent.manifest_json,parent.declaration_json)
            @test manifest["invocation"]==Dict("source_epoch"=>expected)
        end
    end
end
end
end
