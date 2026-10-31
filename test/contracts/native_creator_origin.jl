module NativeCreatorOriginTests
using Test, QCLNEGFRunner, SHA, Logging
const R=QCLNEGFRunner
const CALC="11111111-1111-4111-8111-111111111111"
const INPUT="22222222-2222-4222-8222-222222222222"
const OTHER="33333333-3333-4333-8333-333333333333"
mutable struct Native3ScientificFailure <: Exception
    marker::Int
end
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
import QCLNEGFRunner as R
import QCLNEGFRunner: ScientificPlan, ExecutionEnvelope, VerifiedExactCheckpoint, PhaseObservationPolicy,
    _P05PlanCapture, _native_origin_ids, default_execution_envelope,
    _scientific_resource_preflight, _require_source_graph, _p04_require, _native_origin_uuid,
    _p04_json, _p04_parse, _light_json, _storage_bytes, _storage_available,
    _storage_budget_used, _storage_free_permit, _p04_stat, sha256
const QCLScientificWorkflow=R.QCLScientificWorkflow
const effect=Ref{Function}((output,kw)->:sentinel_exit)
const calls=Any[]
# Actual staging dispatch, with only the downstream scientific compute replaced.
execute_scientific_plan(plan,output;kwargs...)=(push!(calls,(output,(;kwargs...)));effect[](output,(;kwargs...)))
include(joinpath(@__DIR__,"..","..","src","composition","scratch_execution.jl"))
end

# Include the actual owning source; only the stability callback is replaced.
# Faults close the sole fixture-owned regular-file FD without descriptor reuse.
module OriginCloseFault
import QCLNEGFRunner as R
import QCLNEGFRunner: ScientificPlan, ExecutionEnvelope, VerifiedExactCheckpoint, PhaseObservationPolicy,
    _P05PlanCapture, _native_origin_ids, default_execution_envelope,
    _scientific_resource_preflight, _require_source_graph, _p04_require, _native_origin_uuid, _p04_id, _p04_keys,
    _p04_json, _p04_parse, _light_json, _storage_bytes, _storage_available,
    _storage_budget_used, _storage_free_permit, sha256
const QCLScientificWorkflow=R.QCLScientificWorkflow
const stat_effect=Ref{Function}(R._p04_stat)
_p04_stat(s)=stat_effect[](s)
include(joinpath(dirname(pathof(R)),"composition","scratch_execution.jl"))
end

function native_document(;plan_raw=PLAN_RAW,graph_raw=GRAPH_RAW)
    file(uuid,raw)=Dict("node_uuid"=>uuid,"bytes"=>string(sizeof(raw)),"sha256"=>bytes2hex(sha256(raw)))
    Dict{String,Any}("schema"=>"qcl-negf.aiida-native-execution.v1","request_id"=>OTHER,"execution_id"=>"E",
        "input_plan"=>file(OTHER,plan_raw),"source_graph"=>file(OTHER,graph_raw),"access_receipt_ref"=>"access",
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

# Trailing JSON whitespace changes the whole raw claim, without changing the
# parsed document or shortening provenance in a real scientific plan.
pad_json(raw,bytes)=raw*repeat(" ",bytes-sizeof(raw))


function native3_spec(x)
    Dict{String,Any}("schema"=>"qcl-negf.capture-spec.v3",
        "selection"=>Dict("calcjob_uuid"=>CALC,"execution_id"=>"E","attempt"=>7,"plan_fingerprint"=>repeat("b",64)),
        "plan"=>Dict("path"=>"plan.json","bytes"=>sizeof(PLAN_RAW),"sha256"=>bytes2hex(sha256(PLAN_RAW))),
        "capture_token"=>repeat("a",32),"allocation_id"=>"calcjob-process:$(CALC):7",
        "allocated_logical_cpus"=>nothing,"scratch_root"=>nothing,"native_performance"=>Dict{String,Any}("run_uuid"=>OTHER),
        "credits"=>Dict("performance_bytes"=>33554432,"scalar_bytes"=>67108864,"io_bytes"=>134217728,"reserve_bytes"=>0))
end
function native3_context(x;spec=native3_spec(x))
    path=joinpath(x.job,"capture-spec.json");write(path,R._p04_json(spec))
    R._capture_context((fingerprint=repeat("b",64),),x.output,"E",nothing;spec_path=path,
        native_execution_path=x.native,source_plan_path=x.plan,source_graph_path=x.graph,
        frozen_plan_bytes=Vector{UInt8}(codeunits(PLAN_RAW)),native_origin=read_origin(x))
end
function engineering_plan(;budget=1073741824,recovery=false)
    S=R.QCLScientificWorkflow
    outputs=S.ScientificOutputs(;recovery=S.RecoveryOutputPolicy(recovery,1800.0,2,budget,0))
    execution=S.ScientificExecution{Nothing}("E","fixture","v","m",String[],nothing,
        S.ScientificPolicies(),outputs,0,:diagnostic,1,:engineering,"fixture",Dict{String,Any}())
    R.ScientificPlan{Nothing}("fixture",:run,"fixture",repeat("b",64),1,R.ScientificInclusion[],
        [execution],R.ScientificPoint[],S.ScientificExecutionNode[])
end


@testset "File close preserves primary and diagnoses secondary; close alone refuses" begin
    F=OriginCloseFault
    for role in (:locator,:inherited_mandatory), breakclose in (false,true),
            primary in (nothing,InterruptException(),Native3ScientificFailure(29))
        fixture() do x
            mkpath(joinpath(x.root,"jobs with spaces"))
            context=native3_context(x);@test context!==nothing
            context===nothing && return
            before_fd=length(readdir("/proc/self/fd"));stat_calls=Ref(0);closed=Ref(0);effects=Ref(0)
            path=role==:locator ? context.path : x.plan
            F.stat_effect[]=s->begin
                stat_calls[]+=1
                # A primary is raised at the first stability callback. Without
                # a primary, close only after the final (fourth) saved/named
                # stamp, so the body succeeds and close itself is the refusal.
                inject=primary!==nothing ? stat_calls[]==1 : breakclose && stat_calls[]==4
                if inject
                    if breakclose
                        matches=String[]
                        for fd in readdir("/proc/self/fd")
                            try
                                readlink("/proc/self/fd/"*fd)==path && push!(matches,fd)
                            catch
                            end
                        end
                        @test length(matches)==1
                        @test ccall(:close,Cint,(Cint,),parse(Cint,only(matches)))==0
                        closed[]+=1
                    end
                    primary===nothing || throw(primary)
                end
                R._p04_stat(s)
            end
            logger=Test.TestLogger(;min_level=Logging.Warn)
            caught=try
                Logging.with_logger(logger) do
                    if role==:locator
                        F._with_native_capture_birth(context,x.output) do
                            effects[]+=1
                            :scientific_sentinel
                        end
                    else
                        F._native_origin_inputs(x.plan,x.graph,x.native,x.output,CALC,"E";
                            frozen_plan_bytes=Vector{UInt8}(codeunits(PLAN_RAW)))
                    end
                end
                nothing
            catch error
                error
            finally
                F.stat_effect[]=R._p04_stat
            end
            if primary!==nothing
                @test caught===primary
                @test effects[]==0
                if breakclose
                    @test any(record->get(record.kwargs,:exception,nothing) isa Base.IOError,logger.logs)
                else
                    @test isempty(logger.logs)
                end
            elseif breakclose
                @test caught isa Base.IOError
                @test effects[]==0
            else
                @test caught===nothing
                @test effects[]==(role==:locator ? 1 : 0)
            end
            @test closed[]==(breakclose ? 1 : 0)
            @test length(readdir("/proc/self/fd"))==before_fd
            role==:inherited_mandatory && @test !ispath(x.output)
            @test !ispath(joinpath(x.output,"manifest.json"))
        end
    end
end

@testset "Native3 refuses old shapes and invalid run/transport identity without birth" begin
    fixture() do x
        @test native3_context(x)!==nothing
        for mutate in (d->(d["schema"]="qcl-negf.capture-spec.v1"),
                d->(d["schema"]="qcl-negf.capture-spec.v2"),
                d->delete!(d,"native_performance"),d->(d["native_performance"]["extra"]=true),
                d->(d["native_performance"]["run_uuid"]="00000000-0000-0000-0000-000000000000"),
                d->(d["native_performance"]["run_uuid"]=OTHER*"\n"),
                d->(d["selection"]["attempt"]=9007199254740992),
                d->(d["selection"]["attempt"]=true),d->(d["extra"]=true))
            bad=native3_spec(x);mutate(bad)
            @test native3_context(x;spec=bad)===nothing
            @test !ispath(x.output) && !ispath(joinpath(x.job,"capture-source.json"))
        end
    end
end

@testset "Native3 actual credit precedes exclusive birth and held lifetime" begin
    fixture() do x
        # jobs anchor is an existing owned operand, never created from the spec.
        mkpath(joinpath(x.root,"jobs with spaces"))
        context=native3_context(x)
        @test context!==nothing
        if context!==nothing
            origin=read_origin(x);graph=R._p04_parse(GRAPH_RAW)
            call(;plan=engineering_plan())=OriginStaged.execute_scientific_plan_staged(plan,x.output;
                execution_id="E",source_graph=graph,native_origin=origin,capture_context=context)
            before_fd=length(readdir("/proc/self/fd"));empty!(OriginStaged.calls)
            @test call(plan=engineering_plan(;budget=1))==:sentinel_exit
            @test length(OriginStaged.calls)==1 && !ispath(x.output)
            @test !ispath(joinpath(x.job,"capture-source.json"))
            for schedule in (:observer_first,:science_first)
                OriginStaged.effect[]=(output,kw)->begin
                    locator=R._p04_parse(read(joinpath(x.job,"capture-source.json"),String))
                    @test locator["schema"]=="qcl-negf.capture-source.v3"
                    @test Set(keys(locator))==Set(["schema","capture_token","execution_id","plan_fingerprint","mode","actual_root","epoch","root_birth"])
                    @test locator["actual_root"]==x.output && locator["mode"]=="direct" && locator["epoch"]===0
                    b=locator["root_birth"]
                    @test Set(keys(b))==Set(["boot_id","mount_namespace_device","mount_namespace_inode","producer_pid","producer_start_ticks","device","inode"])
                    @test b["producer_pid"]==string(getpid()) && b["inode"]==string(stat(output).inode)
                    @test b["device"]==string(stat(output).device)
                    @test all(v isa String for v in values(b))
                    @test b["boot_id"]==strip(read("/proc/sys/kernel/random/boot_id",String))
                    @test b["mount_namespace_inode"]==string(stat("/proc/self/ns/mnt").inode)
                    @test stat(output).mode & 0o7777==0o700
                    @test length(readdir("/proc/self/fd"))>before_fd
                    schedule==:science_first && mkdir(joinpath(output,"science-child"))
                    observed=Base.Filesystem.open(output,Base.JL_O_RDONLY|Base.JL_O_NOFOLLOW|Base.JL_O_DIRECTORY)
                    try
                        @test string(stat(observed).inode)==b["inode"]
                        schedule==:observer_first && mkdir(joinpath(output,"science-child"))
                    finally
                        close(observed)
                    end
                    :sentinel_exit
                end
                @test call()==:sentinel_exit
                @test length(readdir("/proc/self/fd"))==before_fd
                @test isdir(x.output) && !ispath(joinpath(x.output,"manifest.json"))
                # A second invocation cannot reconstruct/adopt the born root.
                count=length(OriginStaged.calls)
                @test_throws ArgumentError call()
                @test length(OriginStaged.calls)==count
                rm(x.output;recursive=true);rm(joinpath(x.job,"capture-source.json"))
            end
            OriginStaged.effect[]=(output,kw)->:sentinel_exit
        end
    end
end

@testset "Native3 nofollow EEXIST replacement locator uncertainty and primary unwind" begin
    fixture() do x
        mkpath(joinpath(x.root,"jobs with spaces"))
        context=native3_context(x);@test context!==nothing
        if context!==nothing
            graph=R._p04_parse(GRAPH_RAW);origin=read_origin(x)
            call()=OriginStaged.execute_scientific_plan_staged(engineering_plan(),x.output;
                execution_id="E",source_graph=graph,native_origin=origin,capture_context=context)
            fd_before=length(readdir("/proc/self/fd"));empty!(OriginStaged.calls)
            mkdir(joinpath(x.root,"jobs with spaces","native"));mkdir(x.output)
            @test_throws ArgumentError call() # even our own empty final is never adopted
            @test isempty(OriginStaged.calls) && isempty(readdir(x.output))
            rm(x.output);rm(dirname(x.output))
            alien=mkpath(joinpath(x.root,"alien"));symlink(alien,dirname(x.output))
            @test_throws ArgumentError call()
            @test isempty(readdir(alien)) && isempty(OriginStaged.calls)
            rm(dirname(x.output))
            # Actual atomic publication fails against a directory; science never starts.
            locator=joinpath(x.job,"capture-source.json");mkdir(locator)
            @test_throws Exception call()
            @test isempty(OriginStaged.calls) && isdir(x.output)
            @test length(readdir("/proc/self/fd"))==fd_before
            rm(locator);rm(x.output)
            # A cancellation retains its identity even when final named validation fails.
            for primary in (InterruptException(),Native3ScientificFailure(17))
                OriginStaged.effect[]=(output,kw)->begin
                    mv(output,output*"-old");mkdir(output)
                    throw(primary)
                end
                caught=try call();nothing catch e;e end
                @test caught===primary && isdir(x.output*"-old") && isdir(x.output)
                @test length(readdir("/proc/self/fd"))==fd_before
                rm(x.output);rm(x.output*"-old");rm(locator)
            end
            # Without a primary exception, late replacement must refuse successful return.
            OriginStaged.effect[]=(output,kw)->(mv(output,output*"-old");mkdir(output);:sentinel_exit)
            @test_throws ArgumentError call()
            @test length(readdir("/proc/self/fd"))==fd_before
            OriginStaged.effect[]=(output,kw)->:sentinel_exit
        end
    end
end


@testset "Native3 exact same-handle locator retry refuses changed bytes and closes once" begin
    fixture() do x
        mkpath(joinpath(x.root,"jobs with spaces"))
        context=native3_context(x);@test context!==nothing
        if context!==nothing
            fd_before=length(readdir("/proc/self/fd"))
            birth=R._native_capture_birth(context,x.output)
            try
                R._native_capture_locator!(birth,context)
                locator=joinpath(x.job,"capture-source.json");raw=read(locator)
                inode=stat(x.output).inode
                @test R._native_capture_locator!(birth,context)===nothing
                @test read(locator)==raw && stat(x.output).inode==inode
                @test_throws ArgumentError R._native_capture_locator!(birth,merge(context,(token=repeat("f",32),)))
                @test read(locator)==raw
                write(locator,vcat(raw,UInt8[0x20]))
                @test_throws ArgumentError R._native_capture_locator!(birth,context)
                @test stat(x.output).inode==inode
                # A held descriptor is not authority for a rebound selected name.
                mv(dirname(x.output),dirname(x.output)*"-old");mkdir(dirname(x.output))
                @test_throws ArgumentError R._native_capture_validate(birth)
            finally
                R._native_capture_close!(birth)
                @test R._native_capture_close!(birth)===nothing
            end
            @test length(readdir("/proc/self/fd"))==fd_before
        end
    end
end

@testset "Native3 original missing anchor and unsafe parent refuse before root and locator" begin
    fixture() do x
        context=native3_context(x);@test context!==nothing
        if context!==nothing
            fd_before=length(readdir("/proc/self/fd"))
            @test_throws ArgumentError R._native_capture_birth(context,x.output)
            @test !ispath(x.output) && !ispath(joinpath(x.job,"capture-source.json"))
            mkpath(dirname(x.output));chmod(dirname(x.output),0o777)
            try
                @test_throws ArgumentError R._native_capture_birth(context,x.output)
                @test !ispath(x.output)
            finally
                chmod(dirname(x.output),0o700)
            end
            @test length(readdir("/proc/self/fd"))==fd_before
        end
    end
end



@testset "Native3 real close uncertainty still releases remaining owned descriptors once" begin
    fixture() do x
        mkpath(joinpath(x.root,"jobs with spaces"))
        context=native3_context(x);@test context!==nothing
        if context!==nothing
            fd_before=length(readdir("/proc/self/fd"))
            birth=R._native_capture_birth(context,x.output)
            # Make a genuinely invalid owned FD, without opening any descriptor
            # in between. The remaining descriptors must still all be closed.
            @test ccall(:close,Cint,(Cint,),birth.directories[end].fd)==0
            @test_throws ArgumentError R._native_capture_close!(birth)
            @test R._native_capture_close!(birth)===nothing
            @test length(readdir("/proc/self/fd"))==fd_before
            @test isdir(x.output) && !ispath(joinpath(x.job,"capture-source.json"))
        end
    end
end

@testset "Ordinary1 direct and recovery dispatch retain best-effort locator without early birth" begin
    fixture() do x
        spec=native3_spec(x);spec["schema"]="qcl-negf.capture-spec.v1";delete!(spec,"native_performance")
        path=joinpath(x.job,"capture-spec.json");write(path,R._p04_json(spec))
        output=joinpath(x.job,"result")
        context=R._capture_context((fingerprint=repeat("b",64),),output,"E",7;spec_path=path)
        @test context!==nothing
        if context!==nothing
            OriginStaged.effect[]=(out,kw)->begin
                @test out==output && !ispath(output)
                locator=R._p04_parse(read(joinpath(x.job,"capture-source.json"),String))
                @test locator["schema"]=="qcl-negf.capture-source.v1" && length(locator)==7
                @test !haskey(locator,"root_birth") && locator["mode"]=="direct"
                @test kw.native_origin===nothing && kw.attempt===7
                :ordinary_exit
            end
            try
                for recovery in (false,true)
                    scratch=recovery ? joinpath(x.root,"scratch") : nothing
                    @test OriginStaged.execute_scientific_plan_staged(engineering_plan(;recovery),output;
                        execution_id="E",source_graph=R._p04_parse(GRAPH_RAW),attempt=7,
                        capture_context=context,scratch_root=scratch)==:ordinary_exit
                    @test !ispath(output) && (scratch===nothing || !ispath(scratch))
                end
            finally
                OriginStaged.effect[]=(output,kw)->:sentinel_exit
            end
        end
    end
end

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
        spec=Dict("schema"=>"qcl-negf.capture-spec.v3","native_performance"=>Dict{String,Any}("run_uuid"=>OTHER),
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

@testset "Original plan accepts one MiB; other native inputs retain 64 KiB" begin
    expected=(calcjob_uuid=CALC,native_execution_uuid=INPUT)
    # Independent literal boundaries: changing the plan's allowance back to
    # 64 KiB must reject both admitted cases; raising a metadata role must fail
    # its +1 case. All claims describe the complete whitespace-padded file.
    for bytes in (1048575,1048576,1048577)
        fixture() do x
            raw=pad_json(PLAN_RAW,bytes)
            document=native_document(;plan_raw=raw)
            write(x.plan,raw);write(x.native,R._p04_json(document))
            @test sizeof(raw)==bytes && R._p04_parse(raw)==R._p04_parse(PLAN_RAW)
            admit()=R._native_origin_inputs(x.plan,x.graph,x.native,x.output,CALC,"E";
                frozen_plan_bytes=Vector{UInt8}(codeunits(raw)))
            if bytes<=1048576
                @test admit()==expected
            else
                @test_throws ArgumentError admit()
            end
            @test read(x.plan,String)==raw && !ispath(x.output)
        end
    end
    for role in (:graph,:native), bytes in (65535,65536,65537)
        fixture() do x
            graph_raw=role==:graph ? pad_json(GRAPH_RAW,bytes) : GRAPH_RAW
            document=native_document(;graph_raw)
            native_raw=R._p04_json(document)
            role==:native && (native_raw=pad_json(native_raw,bytes))
            write(x.graph,graph_raw);write(x.native,native_raw)
            @test sizeof(role==:graph ? graph_raw : native_raw)==bytes
            if bytes<=65536
                @test read_origin(x)==expected
            else
                @test_throws ArgumentError read_origin(x)
            end
            @test !ispath(x.output)
        end
    end
end

@testset "Admitted large plan retains original raw, alias, UUID and FD guards" begin
    fixture() do x
        raw=pad_json(PLAN_RAW,1048576)
        document=native_document(;plan_raw=raw)
        write(x.plan,raw);write(x.native,R._p04_json(document))
        frozen=Vector{UInt8}(codeunits(raw))
        admit()=R._native_origin_inputs(x.plan,x.graph,x.native,x.output,CALC,"E";frozen_plan_bytes=frozen)
        @test admit()==(calcjob_uuid=CALC,native_execution_uuid=INPUT)
        for mutate in (d->(d["input_plan"]["bytes"]="1048575"),
                d->(d["input_plan"]["sha256"]=repeat("f",64)),
                d->(d["input_plan"]["node_uuid"]="invalid"),
                d->(d["storage"]["execution_binding_uuid"]=INPUT*"\n"))
            bad=deepcopy(document);mutate(bad);write(x.native,R._p04_json(bad))
            @test_throws ArgumentError admit()
        end
        write(x.native,R._p04_json(document))
        # A matching original declaration cannot make a different frozen byte
        # sequence valid; truncated or same-size changed originals also reject.
        write(x.plan,raw[1:end-1]);@test_throws ArgumentError admit()
        write(x.plan,replace(raw,' '=>'\t'));@test_throws ArgumentError admit()
        write(x.plan,raw)
        saved=joinpath(x.job,"saved-plan.json")
        mv(x.plan,saved);symlink(saved,x.plan)
        @test_throws ArgumentError admit()
        rm(x.plan);mv(saved,x.plan)
        alias=joinpath(x.job,"alias-plan.json")
        @test ccall(:link,Cint,(Cstring,Cstring),x.plan,alias)==0
        @test_throws ArgumentError admit()
        rm(alias)
        if Sys.islinux()
            # Count the actual process descriptors after both success and
            # exceptional exits, including failures after all files are read.
            fd_before=length(readdir("/proc/self/fd"))
            for _ in 1:4
                @test admit()==(calcjob_uuid=CALC,native_execution_uuid=INPUT)
                bad=deepcopy(document);bad["input_plan"]["sha256"]=repeat("f",64)
                write(x.native,R._p04_json(bad));@test_throws ArgumentError admit()
                write(x.native,R._p04_json(document))
            end
            @test length(readdir("/proc/self/fd"))==fd_before
        end
        @test read(x.plan)==frozen && !ispath(x.output)
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
