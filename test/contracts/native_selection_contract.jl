isdefined(@__MODULE__, :FinalNativeCommitTests) || include("final_native_commit.jl")
module NativeSelectionContractTests
using Test, QCLNEGFRunner, QCLNEGF, SHA
const R = QCLNEGFRunner
const F = parentmodule(@__MODULE__).FinalNativeCommitTests
# Gross aggregate SOURCE fixture credit covers sequential public verifier ceilings.
# It is not a runtime grant or a packet/file ceiling.
const CAP = 1024 * 1024^2
const P20_DIRECTORY_FAULT_SHIM=get(ENV,"QCL_P20_DIRECTORY_FAULT_SHIM","")

function document(source)
    row = Dict{String,Any}("id"=>"point", "execution_id"=>"exec", "attempt"=>1,
        "coordinates"=>Dict("temperature_K"=>70.0,"voltage_per_period_V"=>0.05,"branch"=>"branch","order"=>1),
        "initialization"=>Dict("kind"=>"cold","source_point_id"=>nothing,"checkpoint"=>nothing,"fallback_reason"=>nothing),
        "status"=>"failed","quality"=>"invalid","converged"=>false,"warnings"=>Any[],"observables"=>Dict(),
        "data"=>Dict("native_source"=>source,"optical_attachment"=>nothing,
            "phase_source"=>Dict("status"=>"disabled","session_id"=>nothing,"current_path"=>nothing,"reason"=>"fixture")),
        "postprocessing"=>Dict("optical"=>Dict("status"=>"not_requested","error"=>nothing)))
    Dict{String,Any}("schema"=>"qcl-negf-series-result-v4","contract_set"=>"qcl-negf.results.v2",
        "plan_fingerprint"=>"fixture","plan_scientific_fingerprint"=>"fixture","root_definition_id"=>"fixture",
        "name"=>"fixture","status"=>"failed","model_version"=>"0.2.0","inclusions"=>Any[],
        "executions"=>[Dict("id"=>"exec","definition_id"=>"fixture","variant_id"=>"v","method_id"=>"m",
            "purpose"=>"diagnostic","label"=>"fixture","operation"=>"stationary","point_ids"=>["point"],"repetition"=>1)],
        "expected_point_count"=>1,"available_point_count"=>1,"points"=>[row],"attempt_history"=>[deepcopy(row)])
end
function selection(rr, triple; artifact_root=".")
    Dict{String,Any}("artifact_root"=>artifact_root,"selected_state"=>checkpoint_reference(triple.checkpoint),
        "plan"=>deepcopy(rr.request.plan_ref),"model"=>deepcopy(rr.request.model_ref))
end

@testset "Publish original failed native result and exact original selected inputs" begin
    f = F.final_fixture(); rr = F.final_recorder("selection-basic", f)
    triple = F.final_commit(f, rr; presentation_sink=_ -> nothing)
    native = R._p05_native_source("."; triple...)
    result = document(native); selected = selection(rr, triple)
    # The absent public carrier is the original RED, exercised with actual public IO fixtures.
    published = try
        R.publish_native_selection!(F.FINAL_ROOT, result; selected_inputs=[selected], maximum_metadata_bytes=CAP)
    catch error
        @info "selection publication failure" exception=(error, catch_backtrace())
        error
    end
    @test published isa NamedTuple
    if published isa NamedTuple
        @test keys(published) == (:result, :selection)
        expected = IOBuffer(); write_scientific_result(expected, result)
        result_bytes = take!(expected)
        @test read(joinpath(F.FINAL_ROOT, "series_result.json")) == result_bytes
        wire = R._p04_parse(read(joinpath(F.FINAL_ROOT, "native-selection.json"), String))
        @test wire == Dict("version"=>1,"selected_inputs"=>[selected])
        for (claim, name) in ((published.result,"series_result.json"),(published.selection,"native-selection.json"))
            raw = read(joinpath(F.FINAL_ROOT, name))
            @test claim == Dict("path"=>name,"bytes"=>length(raw),"sha256"=>bytes2hex(sha256(raw)))
        end
    else
        @info "original missing publication carrier" exception=published
    end
end

function clear_controls()
    for name in ("series_result.json", "native-selection.json")
        path=joinpath(F.FINAL_ROOT,name)
        (ispath(path) || islink(path)) && rm(path)
    end
end
function publish(result, rows; cap=CAP)
    R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=rows,maximum_metadata_bytes=cap)
end

@testset "Full state identity selects current before older same-sequence history" begin
    f=F.final_fixture()
    first=F.final_recorder("selection-old",f;attempt=1)
    old=F.final_commit(f,first;presentation_sink=_ -> nothing)
    next=F.final_recorder("selection-new",f;attempt=2)
    current=F.final_commit(f,next;presentation_sink=_ -> nothing)
    oldsource=R._p05_native_source(".";old...)
    source=R._p05_native_source(".";current...)
    result=document(source);result["points"][1]["attempt"]=2
    oldrow=deepcopy(result["points"][1]);oldrow["attempt"]=1;oldrow["data"]["native_source"]=oldsource
    result["attempt_history"]=[oldrow,deepcopy(result["points"][1])]
    older=selection(first,old);newer=selection(next,current)
    @test older["selected_state"]["state_sequence"]==newer["selected_state"]["state_sequence"]=="1"
    @test older["selected_state"]["manifest"]!=newer["selected_state"]["manifest"]
    clear_controls();claims=publish(result,[older,newer])
    wire=R._p04_parse(read(joinpath(F.FINAL_ROOT,"native-selection.json"),String))
    # Hand-selected order: points/current first, then first unseen history/full state.
    @test wire==Dict("version"=>1,"selected_inputs"=>[newer,older])
    before=read(joinpath(F.FINAL_ROOT,"native-selection.json"))
    @test publish(result,[newer,older])==claims
    @test read(joinpath(F.FINAL_ROOT,"native-selection.json"))==before
    wrong=deepcopy(newer);wrong["selected_state"]=deepcopy(older["selected_state"])
    @test_throws ArgumentError publish(result,[wrong,older])
    swapped=deepcopy(newer);swapped["plan"]=deepcopy(older["plan"])
    @test_throws ArgumentError publish(result,[swapped,older])
    @test read(joinpath(F.FINAL_ROOT,"native-selection.json"))==before
end

@testset "Missing extra duplicate input refs and unsafe roots refuse before publication" begin
    t=F.TRANSACTION[];base=selection(t.rr,t.result);result=document(R._p05_native_source(".";t.result...))
    cases=Any[Dict{String,Any}[],[base,deepcopy(base)]]
    for mutate in (x->(x["extra"]=true),x->delete!(x,"model"),
            x->(x["selected_state"]["state_sequence"]="999"),
            x->(x["artifact_root"]="../escape"),x->(x["artifact_root"]="sub/../"),
            x->(x["plan"]=deepcopy(x["model"])),x->(x["model"]["sha256"]="0"^64))
        bad=deepcopy(base);mutate(bad);push!(cases,[bad])
    end
    extra=deepcopy(base);extra["selected_state"]["state_id"]="extra";push!(cases,[base,extra])
    for rows in cases
        clear_controls()
        @test_throws ArgumentError publish(result,rows)
        @test !ispath(joinpath(F.FINAL_ROOT,"series_result.json"))
        @test !ispath(joinpath(F.FINAL_ROOT,"native-selection.json"))
    end
    clear_controls()
    @test_throws ArgumentError publish(result,[base];cap=1)
    @test_throws ArgumentError publish(result,[base];cap=64*1024^2)
    @test !ispath(joinpath(F.FINAL_ROOT,"series_result.json"))
    running=deepcopy(result);running["status"]="running"
    @test_throws ArgumentError publish(running,[base])
    bad=deepcopy(result);bad["points"][1]["id"]="foreign"
    @test_throws ArgumentError publish(bad,[base])
    root_alias=F.FINAL_ROOT*"/../"*basename(F.FINAL_ROOT)
    @test_throws ArgumentError R.publish_native_selection!(root_alias,result;selected_inputs=[base],maximum_metadata_bytes=CAP)
    alias=F.FINAL_ROOT*"-alias";symlink(F.FINAL_ROOT,alias)
    try
        @test_throws ArgumentError R.publish_native_selection!(alias,result;selected_inputs=[base],maximum_metadata_bytes=CAP)
    finally
        rm(alias)
    end
end

@testset "Publication conflicts symlinks and unknown ACK retain original bytes" begin
    t=F.TRANSACTION[];base=selection(t.rr,t.result);result=document(R._p05_native_source(".";t.result...))
    clear_controls();target=joinpath(F.FINAL_ROOT,"native-selection.json");write(target,"original conflict")
    @test_throws ArgumentError publish(result,[base])
    @test read(target,String)=="original conflict"
    @test isfile(joinpath(F.FINAL_ROOT,"series_result.json")) # pair publication is not atomic
    clear_controls();sentinel=joinpath(F.FINAL_ROOT,"untouched-control-target");write(sentinel,"untouched")
    symlink(sentinel,target)
    @test_throws ArgumentError publish(result,[base])
    @test read(sentinel,String)=="untouched";clear_controls()
    raw=IOBuffer();write_scientific_result(raw,result);expected=take!(raw)
    linked=joinpath(F.FINAL_ROOT,"linked-result");write(linked,expected)
    hardlink(linked,joinpath(F.FINAL_ROOT,"series_result.json"))
    @test_throws ArgumentError publish(result,[base]);@test read(linked)==expected
    clear_controls()
    previous=R._p04_read_observer[];primary=ErrorException("original selection ACK observation failure")
    R._p04_read_observer[]=(kind,path,bytes)->(basename(path)=="native-selection.json" && throw(primary);nothing)
    caught=try publish(result,[base]);nothing catch error;error finally;R._p04_read_observer[]=previous end
    @test caught===primary
    @test isfile(target) && read(joinpath(F.FINAL_ROOT,"series_result.json"))==expected
    retained=read(target);@test publish(result,[base]) isa NamedTuple
    @test read(target)==retained
    clear_controls()
    changed=Ref(false)
    R._p04_read_observer[]=(kind,path,bytes)->begin
        if basename(path)=="native-selection.json" && !changed[]
            changed[]=true;write(path,"changed after publication")
        end
        nothing
    end
    try
        @test_throws ArgumentError publish(result,[base])
    finally
        R._p04_read_observer[]=previous
    end
    @test read(target,String)=="changed after publication"
    @test_throws ArgumentError publish(result,[base])
end

@testset "Captured controls detach caller containers and retain actual request refs only" begin
    t=F.TRANSACTION[];base=selection(t.rr,t.result);result=document(R._p05_native_source(".";t.result...))
    clear_controls();raw=IOBuffer();write_scientific_result(raw,result);expected=take!(raw)
    rows=[deepcopy(base)];previous=R._p04_read_observer[];changed=Ref(false)
    R._p04_read_observer[]=(kind,path,bytes)->begin
        if !changed[]
            changed[]=true;empty!(result["points"]);rows[1]["model"]["sha256"]="0"^64
        end
        nothing
    end
    try
        @test publish(result,rows) isa NamedTuple
    finally
        R._p04_read_observer[]=previous
    end
    @test changed[] && read(joinpath(F.FINAL_ROOT,"series_result.json"))==expected
    @test R._p04_parse(read(joinpath(F.FINAL_ROOT,"native-selection.json"),String))["selected_inputs"]==[base]
    kept=Dict{String,Any}[]
    @test R._p07_retain_input_pair!(kept,".",t.result.checkpoint,t.rr.request,CAP)===nothing
    @test kept==[base]
    @test R._p07_retain_input_pair!(kept,".",t.result.checkpoint,t.rr.request,CAP)===nothing
    @test length(kept)==1
    @test Base.summarysize(kept)<64*1024
end

@testset "Explicit absent sources have no fabricated input pair" begin
    result=document(R._p05_native_source(".";reason="no accepted native state"))
    clear_controls();@test publish(result,Dict{String,Any}[]) isa NamedTuple
    @test R._p04_parse(read(joinpath(F.FINAL_ROOT,"native-selection.json"),String))==Dict("version"=>1,"selected_inputs"=>Any[])
end

@testset "Current produced final publication uses held commit handles" begin
    f=F.FIXTURE[];rr=F.final_recorder("durable-current-final",f)
    triple=F.final_commit(f,rr;presentation_sink=_ -> nothing)
    result=document(R._p05_native_source(".";triple...));row=selection(rr,triple)
    clear_controls()
    previous=R._p04_read_observer[];reads=Tuple{Symbol,String,Int}[]
    R._p04_read_observer[]=(kind,path,bytes)->push!(reads,(kind,path,bytes))
    published=try
        R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=[row],maximum_metadata_bytes=CAP,
            published_final_checkpoints=[triple.checkpoint])
    catch error
        error
    finally
        R._p04_read_observer[]=previous
    end
    @test published isa NamedTuple
    if published isa NamedTuple
        @test keys(published)==(:result,:selection)
        @test !any(kind===:hash && occursin("/checkpoint/arrays-",path) for (kind,path,_) in reads)
        @test any(kind===:directory_sync for (kind,_,_) in reads)
        raw=IOBuffer();write_scientific_result(raw,result)
        @test read(joinpath(F.FINAL_ROOT,"series_result.json"))==take!(raw)
        for handles in (R.VerifiedExactCheckpoint[],[triple.checkpoint,triple.checkpoint])
            clear_controls()
            @test_throws ArgumentError R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=[row],
                maximum_metadata_bytes=CAP,published_final_checkpoints=handles)
            @test !ispath(joinpath(F.FINAL_ROOT,"series_result.json"))
        end
        foreign=F.TRANSACTION[].result.checkpoint
        clear_controls()
        @test_throws ArgumentError R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=[row],
            maximum_metadata_bytes=CAP,published_final_checkpoints=[foreign])
        for mutate in (m->(m["closed"]=false),m->(m["invocation"]["source_epoch"]="other-epoch"))
            manifest=R._p04_parse(triple.checkpoint.manifest_json);mutate(manifest)
            bad=R.VerifiedExactCheckpoint(triple.checkpoint.root,checkpoint_reference(triple.checkpoint),manifest,
                R._p04_parse(triple.checkpoint.declaration_json),deepcopy(triple.checkpoint.verified),Val(:verified))
            clear_controls()
            @test_throws ArgumentError R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=[row],
                maximum_metadata_bytes=CAP,published_final_checkpoints=[bad])
            @test !ispath(joinpath(F.FINAL_ROOT,"series_result.json"))
        end
        nonfinal=document(R._p05_native_source(".";checkpoint=triple.checkpoint,reason="explicit checkpoint source"))
        clear_controls()
        @test_throws ArgumentError R.publish_native_selection!(F.FINAL_ROOT,nonfinal;selected_inputs=[row],
            maximum_metadata_bytes=CAP,published_final_checkpoints=[triple.checkpoint])
        @test !ispath(joinpath(F.FINAL_ROOT,"series_result.json"))
        clear_controls()
        @test_throws ArgumentError R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=[row],
            maximum_metadata_bytes=1,published_final_checkpoints=[triple.checkpoint])
        mixed=deepcopy(result);absent=document(R._p05_native_source(".";reason="not produced"))["points"][1]
        absent["id"]="missing";push!(mixed["points"],absent)
        mixed["attempt_history"]=deepcopy(mixed["points"])
        mixed["executions"][1]["point_ids"]=["point","missing"]
        mixed["expected_point_count"]=mixed["available_point_count"]=2
        clear_controls();@test publish(mixed,[row]) isa NamedTuple
        clear_controls()
        @test_throws ArgumentError R.publish_native_selection!(F.FINAL_ROOT,mixed;selected_inputs=[row],
            maximum_metadata_bytes=CAP,published_final_checkpoints=[triple.checkpoint])
        clear_controls();primary=ErrorException("named ancestor sync cut")
        R._p04_read_observer[]=(kind,path,bytes)->(kind===:directory_sync && throw(primary);nothing)
        caught=try
            R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=[row],maximum_metadata_bytes=CAP,
                published_final_checkpoints=[triple.checkpoint]);nothing
        catch error
            error
        finally
            R._p04_read_observer[]=previous
        end
        @test caught===primary
        @test !ispath(joinpath(F.FINAL_ROOT,"series_result.json"))
        directory=joinpath(F.FINAL_ROOT,"durable-current-final","checkpoint")
        backup=directory*"-held";foreign=joinpath(F.FINAL_ROOT,"unrelated-sync-target");mkdir(foreign)
        replaced=Ref(false)
        R._p04_read_observer[]=(kind,path,bytes)->begin
            if kind===:directory_sync && path==directory && !replaced[]
                mv(directory,backup);symlink(foreign,directory);replaced[]=true
            end
            nothing
        end
        failure=try
            R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=[row],maximum_metadata_bytes=CAP,
                published_final_checkpoints=[triple.checkpoint]);nothing
        catch error
            error
        finally
            R._p04_read_observer[]=previous
            if replaced[];rm(directory);mv(backup,directory);end
        end
        @test replaced[] && (failure isa ArgumentError || failure isa Base.IOError)
        @test !ispath(joinpath(F.FINAL_ROOT,"series_result.json"))
        # A same-name payload change after the sync barrier still invalidates its
        # held immutable proof. No speculative control publication is accepted.
        changed=Ref(false)
        payload=only(filter(a->a["role"]=="physics.full",R._p04_parse(triple.checkpoint.manifest_json)["artifacts"]))
        path=joinpath(F.FINAL_ROOT,payload["path"]);raw=read(path)
        R._p04_read_observer[]=(kind,_,bytes)->begin
            if kind===:directory_sync && !changed[]
                changed[]=true;write(path,raw)
            end
            nothing
        end
        try
            @test_throws ArgumentError R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=[row],
                maximum_metadata_bytes=CAP,published_final_checkpoints=[triple.checkpoint])
        finally
            R._p04_read_observer[]=previous
        end
        @test changed[] && !ispath(joinpath(F.FINAL_ROOT,"series_result.json"))
    else
        @info "missing held final publication path" exception=published
    end
end

@testset "Strong control publication propagates actual directory close errors" begin
    # A subprocess is required: Julia's ccall(:close) must resolve through the
    # real libc boundary at process startup. The shim closes only this owned
    # fixture directory FD, then reports EIO; it never substitutes a publisher.
    shim=get(ENV,"QCL_P20_DIRECTORY_FAULT_SHIM","")
    if isempty(shim)
        compiler=Sys.which("cc")
        if !Sys.islinux() || compiler===nothing
            @test_skip false # Linux /proc FD matching and a C compiler required.
        else
            directory=mktempdir(;prefix="qcl-directory-close-fault-",cleanup=false)
            source=joinpath(directory,"directory-fault.c");library=joinpath(directory,"directory-fault.so")
            write(source,raw"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
static int (*real_close)(int),(*real_fsync)(int);
static char target[PATH_MAX];
static int armed,close_at,sync_at,closes,syncs,close_faults,sync_faults;
void qcl_p20_arm(const char *path,int c,int s){
 snprintf(target,sizeof(target),"%s",path);close_at=c;sync_at=s;
 closes=syncs=close_faults=sync_faults=0;armed=1;
}
void qcl_p20_disarm(void){armed=0;}
int qcl_p20_closes(void){return closes;}
int qcl_p20_syncs(void){return syncs;}
int qcl_p20_close_faults(void){return close_faults;}
int qcl_p20_sync_faults(void){return sync_faults;}
static int matches(int fd){
 struct stat st;char name[64],path[PATH_MAX];
 if(!armed || fstat(fd,&st)!=0 || !S_ISDIR(st.st_mode))return 0;
 snprintf(name,sizeof(name),"/proc/self/fd/%d",fd);
 ssize_t n=readlink(name,path,sizeof(path)-1);
 if(n<0)return 0;path[n]=0;return strcmp(path,target)==0;
}
int close(int fd){
 if(!real_close)real_close=dlsym(RTLD_NEXT,"close");
 int match=matches(fd),rc=real_close(fd),saved=errno;
 if(match && rc==0 && ++closes==close_at){++close_faults;errno=EIO;return -1;}
 errno=saved;return rc;
}
int fsync(int fd){
 if(!real_fsync)real_fsync=dlsym(RTLD_NEXT,"fsync");
 int match=matches(fd),rc=real_fsync(fd),saved=errno;
 if(match && rc==0 && ++syncs==sync_at){++sync_faults;errno=EIO;return -1;}
 errno=saved;return rc;
}
""")
            run(`$compiler -shared -fPIC -O2 -o $library $source -ldl`)
            script="using QCLNEGFRunner,QCLNEGF; "*
                "@assert realpath(pathof(QCLNEGFRunner))=="*repr(realpath(pathof(QCLNEGFRunner)))*"; "*
                "@assert realpath(pathof(QCLNEGF))=="*repr(realpath(pathof(QCLNEGF)))*"; "*
                "println(\"FAULT_RUNNER=\",pathof(QCLNEGFRunner)); println(\"FAULT_CORE=\",pathof(QCLNEGF)); "*
                "include("*repr(@__FILE__)*")"
            command=`$(Base.julia_cmd()) --startup-file=no --history-file=no --compiled-modules=no --pkgimages=no --check-bounds=yes --threads=2 --project=$(dirname(Base.active_project())) -e $script`
            command=addenv(command,"QCL_P20_DIRECTORY_FAULT_SHIM"=>library,
                "LD_PRELOAD"=>join(filter(!isempty,[library,get(ENV,"LD_PRELOAD","")]),':'))
            child_passed=success(pipeline(command;stdout=stdout,stderr=stderr))
            @test child_passed
        end
    else
        # The expected break is a lost libc close return at either control name,
        # including its existing-file retry path. The earlier named-directory
        # barrier uses Julia's separately checked libuv close, outside this shim.
        # Actual public
        # commit returns and original control bytes remain the operands.
        f=F.final_fixture();rr=F.final_recorder("directory-close-fault",f)
        triple=F.final_commit(f,rr;presentation_sink=_ -> nothing)
        result=document(R._p05_native_source(".";triple...));row=selection(rr,triple)
        raw=IOBuffer();write_scientific_result(raw,result);expected=take!(raw)
        function boundary_case(close_at,sync_at;reuse=false)
            reuse || clear_controls()
            previous=R._p04_read_observer[];armed=Ref(false);claims=nothing;failure=nothing
            R._p04_read_observer[]=(kind,path,bytes)->begin
                if kind===:directory_sync && path==F.FINAL_ROOT && !armed[]
                    ccall((:qcl_p20_arm,P20_DIRECTORY_FAULT_SHIM),Cvoid,(Cstring,Cint,Cint),
                        F.FINAL_ROOT,close_at,sync_at);armed[]=true
                end
                nothing
            end
            try
                claims=R.publish_native_selection!(F.FINAL_ROOT,result;selected_inputs=[row],maximum_metadata_bytes=CAP,
                    published_final_checkpoints=[triple.checkpoint])
            catch error
                failure=error
            finally
                R._p04_read_observer[]=previous
                ccall((:qcl_p20_disarm,P20_DIRECTORY_FAULT_SHIM),Cvoid,())
            end
            closes=ccall((:qcl_p20_closes,P20_DIRECTORY_FAULT_SHIM),Cint,())
            syncs=ccall((:qcl_p20_syncs,P20_DIRECTORY_FAULT_SHIM),Cint,())
            close_faults=ccall((:qcl_p20_close_faults,P20_DIRECTORY_FAULT_SHIM),Cint,())
            sync_faults=ccall((:qcl_p20_sync_faults,P20_DIRECTORY_FAULT_SHIM),Cint,())
            println("DIRECTORY_FAULT=",R._p04_json(Dict("close_at"=>close_at,"sync_at"=>sync_at,
                "reuse"=>reuse,"armed"=>armed[],"closes"=>closes,"syncs"=>syncs,
                "close_faults"=>close_faults,"sync_faults"=>sync_faults,"returned_claims"=>claims isa NamedTuple,
                "error"=>failure===nothing ? nothing : sprint(showerror,failure))))
            @test armed[]
            @test close_faults==(close_at==0 ? 0 : 1)
            @test sync_faults==(sync_at==0 ? 0 : 1)
            if close_at==sync_at==0
                @test failure===nothing && claims isa NamedTuple
                @test closes==(reuse ? 2 : 4) && syncs==closes+1
            else
                @test claims===nothing && failure!==nothing
                @test closes==(close_at==0 ? sync_at-1 : close_at)
                if close_at!=0 && sync_at!=0
                    @test failure isa CompositeException
                    if failure isa CompositeException
                        @test length(failure.exceptions)==2
                        @test failure.exceptions[1] isa SystemError
                        @test occursin("fsync",sprint(showerror,failure.exceptions[1]))
                        @test occursin("close",sprint(showerror,failure.exceptions[2]))
                    end
                elseif sync_at!=0
                    @test failure isa SystemError && occursin("fsync",sprint(showerror,failure))
                else
                    @test occursin("close",sprint(showerror,failure))
                end
            end
            path=joinpath(F.FINAL_ROOT,"series_result.json")
            isfile(path) && @test read(path)==expected
        end
        boundary_case(0,0)
        for cut in 1:4;boundary_case(cut,0);end
        boundary_case(0,0)
        for cut in 1:2;boundary_case(cut,0;reuse=true);end
        boundary_case(0,2)
        for cut in 1:4;boundary_case(cut,cut+1);end
        boundary_case(0,0)
        boundary_case(0,0;reuse=true)
    end
end

# BEGIN positive native fixture contract
if isempty(P20_DIRECTORY_FAULT_SHIM)
@testset "Explicit constructor fixture keeps scientific failure and original strong publication" begin
    W=R.QCLScientificWorkflow
    source=joinpath(pkgdir(R),"examples","config","native-publication-fixture.yaml")
    available=isdefined(W,:_execute_native_publication_fixture)
    @test isfile(source)
    @test available
    if isfile(source) && available
        plan=resolve_scientific_plan(source;maximum_solver_runs=1)
        @test W._native_publication_fixture_mode(plan;execution_id="execution-1")=="native-publication-v1"
        @test length(plan.executions)==length(plan.points)==1
        @test plan.points[1].id=="point-1" && plan.points[1].initialization===:cold
        @test plan.executions[1].purpose===:benchmark && plan.executions[1].operation===:stationary
        @test_throws ArgumentError W._native_publication_fixture_mode(plan;execution_id="foreign")
        prior_blas=R.BLAS.get_num_threads();R.BLAS.set_num_threads(2)
        try
            resources=W._native_publication_fixture_resources(plan;execution_id="execution-1",envelope=nothing)
            @test resources.resource_plan.worker_count==1
            @test R.BLAS.get_num_threads()==1
        finally
            R.BLAS.set_num_threads(prior_blas)
        end
        # A real explicit grant that cannot contain the estimator is refused
        # without constructing a problem or any output directory.
        tiny=R.ExecutionEnvelope("fixture-denied",1,1,1,3,1,[0])
        @test_throws ArgumentError W._native_publication_fixture_resources(plan;execution_id="execution-1",envelope=tiny)
        ordinary=resolve_scientific_plan(joinpath(pkgdir(R),"examples","config","operator-algebra.yaml");maximum_solver_runs=1)
        @test W._native_publication_fixture_mode(ordinary;execution_id="execution-1")===nothing
        raw=scientific_plan_dict(plan)
        mktempdir() do root
            relocated=joinpath(root,"config")
            cp(dirname(source),relocated)
            relocated_plan=resolve_scientific_plan(joinpath(relocated,basename(source));maximum_solver_runs=1)
            @test relocated_plan.fingerprint!=plan.fingerprint
            @test W._native_publication_fixture_mode(relocated_plan;execution_id="execution-1")=="native-publication-v1"
        end
        for mutate in (d->(d["name"]="ordinary study"),
                d->(d["executions"][1]["purpose"]="diagnostic"),
                d->(d["executions"][1]["label"]="ordinary"),
                d->(d["points"][1]["initialization"]="continuation"),
                d->(d["executions"][1]["output"]["telemetry"]["enabled"]=true),
                d->(d["executions"][1]["policies"]["voltage"]["mode"]="strict"),
                d->(d["executions"][1]["resolved_snapshot"]["default_rule_sources"]["Core:src/domain/types.jl"]=repeat("f",64)),
                d->(push!(d["executions"][1]["resolved_snapshot"]["sections"]["physical"]["input_assigning_histories"]["physical.sound_velocity"],"invented-rule")),
                d->(push!(d["executions"][1]["provenance"]["sources"]["physical.sound_velocity"],"invented-rule")),
                d->(d["executions"][1]["resolved_snapshot"]["sections"]["physical"]["input_assigning_histories"]["physical.sound_velocity"][1]*="#changed-rule"),
                d->(d["unknown_fixture_key"]=true),
                d->(d["executions"][1]["resolved_configuration"]["numerical"]["energy_nodes"]=11),
                d->(d["executions"][1]["resolved_configuration"]["physical"]["donor_sheet_density"]="1e12 m^-2"))
            bad=deepcopy(raw);mutate(bad)
            @test_throws ArgumentError W._native_publication_fixture_mode(bad;execution_id="execution-1")
        end
        mktempdir() do root
            path=joinpath(root,"plan.json");io=IOBuffer();write_scientific_plan(io,plan);bytes=take!(io);write(path,bytes)
            output=joinpath(root,"not-born")
            error=try
                R._cli_heavy(["run-plan",path,output,"--execution-id","execution-1"]);nothing
            catch e;e;end
            @test error isa ArgumentError && occursin("engineering_fixture_entry_required",sprint(showerror,error))
            @test !ispath(output)
            if haskey(ENV,"QCL_FIXTURE_TEST_SOURCE_GRAPH")
                error=try
                    R.execute_scientific_plan(plan,output;execution_id="execution-1",
                        source_graph=R._load_source_graph_file(ENV["QCL_FIXTURE_TEST_SOURCE_GRAPH"]));nothing
                catch e;e;end
                @test error isa ArgumentError && occursin("native5_final_writer_unavailable",sprint(showerror,error))
            else
                @test_skip false # Actual source graph is a mandatory original input.
            end
            @test !ispath(output)
            @test_throws ArgumentError R._cli_heavy(["native-publication-fixture",path,output])
            @test !ispath(output)
        end
        # Actual native INPUT assertions and actual virgin birth are L operands;
        # external ORM/Code/installed/native qualification remains a Root gate.
        graph_path=get(ENV,"QCL_FIXTURE_TEST_SOURCE_GRAPH","")
        if isempty(graph_path)
            @test_skip false # Owning integration harness supplies its real selected graph.
        else
            graph=R._load_source_graph_file(graph_path)
            let root=mktempdir(;cleanup=false)
                job=joinpath(root,"original");mkdir(job)
                io=IOBuffer();write_scientific_plan(io,plan);bytes=take!(io)
                write(joinpath(job,"plan.json"),bytes);graph_bytes=read(graph_path);write(joinpath(job,"source-graph.json"),graph_bytes)
                uuid(n)="00000000-0000-4000-8000-"*lpad(string(n),12,'0')
                claim(n,raw)=Dict("node_uuid"=>uuid(n),"bytes"=>string(length(raw)),"sha256"=>bytes2hex(sha256(raw)))
                output=joinpath(root,"jobs","fixture","result")
                mkdir(joinpath(root,"jobs"))
                native=Dict("schema"=>"qcl-negf.aiida-native-execution.v1","request_id"=>uuid(2),"execution_id"=>"execution-1",
                    "input_plan"=>claim(3,bytes),"source_graph"=>claim(4,graph_bytes),"access_receipt_ref"=>"local-L-access",
                    "storage"=>Dict("namespace_id"=>"local-L","storage_identity"=>"local-L-storage","relative_execution_root"=>"fixture/result",
                        "computer_uuid"=>uuid(5),"execution_binding_uuid"=>uuid(6),"retention_policy_id"=>"local-L-policy",
                        "retention_owner_id"=>"local-L-owner","hold_ref"=>"local-L-hold","access_binding_ref"=>"local-L-access"),
                    "code"=>Dict("code_uuid"=>uuid(7),"computer_uuid"=>uuid(5),"solver_executable"=>ENV["QCL_FIXTURE_TEST_INSTALLED_CODE"],
                        "release_id"=>"local-L-original","build_receipt_ref"=>"local-L-assertion"))
                write(joinpath(job,"native-execution.json"),R._p04_json(native))
                spec=Dict("schema"=>"qcl-negf.capture-spec.v3","selection"=>Dict("calcjob_uuid"=>uuid(1),"execution_id"=>"execution-1","attempt"=>1,"plan_fingerprint"=>plan.fingerprint),
                    "plan"=>Dict("path"=>"plan.json","bytes"=>length(bytes),"sha256"=>bytes2hex(sha256(bytes))),
                    "capture_token"=>bytes2hex(sha256(bytes))[1:32],"allocation_id"=>"calcjob-process:$(uuid(1)):1",
                    "allocated_logical_cpus"=>nothing,"scratch_root"=>nothing,"native_performance"=>Dict("run_uuid"=>uuid(8)),
                    "credits"=>Dict("performance_bytes"=>32*1024^2,"scalar_bytes"=>64*1024^2,"io_bytes"=>128*1024^2,"reserve_bytes"=>0))
                spec_path=joinpath(job,"capture-spec.json");write(spec_path,R._p04_json(spec))
                argv=["native-publication-fixture",joinpath(job,"plan.json"),output,"--execution-id","execution-1",
                    "--source-graph",joinpath(job,"source-graph.json"),"--native-execution",joinpath(job,"native-execution.json"),"--native-calcjob-uuid",uuid(1)]
                # Original raw fields that typed plan reconstruction discards
                # must be refused before any output or locator is born. Keep
                # fingerprints and native INPUT claims valid for each mutation.
                for (variant,mutate) in (("unknown_top_key",d->(d["unknown_fixture_key"]=true)),
                        ("resource_schedule",d->(d["resources"]["scheduling"]="foreign_schedule")),
                        ("archive_preflight",d->(d["science_archive_preflight"]=Dict("foreign"=>true))))
                    raw=scientific_plan_dict(plan);mutate(raw);raw["fingerprint"]=W._plan_fingerprint(raw)
                    original_bytes=Vector{UInt8}(codeunits(R._p04_json(raw)))
                    variant_job=joinpath(job,variant);mkdir(variant_job)
                    write(joinpath(variant_job,"plan.json"),original_bytes)
                    write(joinpath(variant_job,"source-graph.json"),graph_bytes)
                    original_native=deepcopy(native);original_native["input_plan"]=claim(3,original_bytes)
                    original_native["storage"]["relative_execution_root"]=variant*"/result"
                    native_path=joinpath(variant_job,"native-execution.json");write(native_path,R._p04_json(original_native))
                    original_spec=deepcopy(spec);original_spec["selection"]["plan_fingerprint"]=raw["fingerprint"]
                    original_spec["plan"]["bytes"]=length(original_bytes)
                    original_spec["plan"]["sha256"]=bytes2hex(sha256(original_bytes))
                    original_spec["capture_token"]=bytes2hex(sha256(original_bytes))[1:32]
                    original_spec_path=joinpath(variant_job,"capture-spec.json");write(original_spec_path,R._p04_json(original_spec))
                    original_output=joinpath(root,"jobs",variant,"result")
                    original_argv=["native-publication-fixture",joinpath(variant_job,"plan.json"),original_output,
                        "--execution-id","execution-1","--source-graph",joinpath(variant_job,"source-graph.json"),
                        "--native-execution",native_path,"--native-calcjob-uuid",uuid(1)]
                    error=withenv("QCL_NEGF_CAPTURE_SPEC"=>original_spec_path,"QCL_NEGF_NATIVE_CAPTURE_INPUT"=>native_path) do
                        try R._cli_heavy(original_argv);nothing catch e;e end
                    end
                    error_text=error===nothing ? nothing : sprint(showerror,error)
                    println("NATIVE_FIXTURE_RAW_PROFILE=",R._p04_json(Dict("variant"=>variant,
                        "error"=>error_text,"output_born"=>ispath(original_output),
                        "locator_published"=>ispath(joinpath(variant_job,"capture-source.json")))))
                    @test error isa ArgumentError && occursin("native_publication_fixture_profile_mismatch",sprint(showerror,error))
                    @test !ispath(original_output)
                    @test !ispath(joinpath(variant_job,"capture-source.json"))
                    # The implementation entry must keep the full-document gate
                    # even when its caller already supplies an owned directory.
                    loaded=W._load_scientific_plan_bytes(joinpath(variant_job,"plan.json"))
                    owned=joinpath(variant_job,"entry-owned");mkdir(owned)
                    error=try
                        W._execute_native_publication_fixture(loaded.plan,owned;
                            frozen_plan_capture=loaded.capture,execution_id="execution-1",
                            source_graph=graph,native_origin=nothing,envelope=nothing);nothing
                    catch e;e end
                    @test error isa ArgumentError && occursin("native_publication_fixture_profile_mismatch",sprint(showerror,error))
                    @test isempty(readdir(owned))
                end
                # Metadata context alone cannot authorise birth.
                @test_throws ArgumentError R._cli_heavy(argv)
                @test !ispath(output) && !ispath(joinpath(job,"capture-source.json"))
                # Replace only the existing free-space boundary for this exact
                # parent; every other path still queries the actual filesystem.
                # This differentiates valid metadata from actual credit admission.
                @eval R begin
                    const _fixture_test_storage_denied=Ref{Union{Nothing,String}}(nothing)
                    const _fixture_test_strong_publications=Ref(0)
                    function _storage_available(path::String)
                        path==_fixture_test_storage_denied[] && return 0
                        invoke(_storage_available,Tuple{Any},path)
                    end
                    function _p07_final_directories!(path::String,finals,budget)
                        _fixture_test_strong_publications[]+=1
                        invoke(_p07_final_directories!,Tuple{Any,Any,Any},path,finals,budget)
                    end
                end
                withenv("QCL_NEGF_CAPTURE_SPEC"=>spec_path,"QCL_NEGF_NATIVE_CAPTURE_INPUT"=>joinpath(job,"native-execution.json")) do
                    R._fixture_test_storage_denied[]=joinpath(root,"jobs")
                    try
                        error=try Base.invokelatest(R._cli_heavy,argv);nothing catch e;e end
                        @test error isa ArgumentError && occursin("capture credit unavailable",sprint(showerror,error))
                        @test !ispath(output) && !ispath(joinpath(job,"capture-source.json"))
                    finally
                        R._fixture_test_storage_denied[]=nothing
                    end
                    @test Base.invokelatest(R._cli_heavy,argv)==0
                    @test R._fixture_test_strong_publications[]==1
                    @test_throws Exception Base.invokelatest(R._cli_heavy,argv) # no EEXIST adoption/retry
                end
                locator=R._p04_parse(read(joinpath(job,"capture-source.json"),String))
                @test locator["schema"]=="qcl-negf.capture-source.v3"
                result=R._p04_parse(read(joinpath(output,"series_result.json"),String))
                @test result["status"]=="failed" && isempty(result["attempt_history"])
                point=only(result["points"])
                @test point["status"]=="failed" && point["quality"]=="invalid" && !point["converged"]
                @test any(w->w["code"]=="SYNTHETIC_NATIVE_PUBLICATION_FIXTURE" && w["scope"]=="execution" &&
                    w["message"]=="synthetic; not_scientific; constructor-only; no SCBA/Poisson",point["warnings"])
                @test point["data"]["native_source"]["kind"]=="final"
                @test !ispath(joinpath(output,"performance")) && !ispath(joinpath(output,"performance-source.json"))
                selection=R._p04_parse(read(joinpath(output,"native-selection.json"),String))
                @test length(selection["selected_inputs"])==1
                @test only(selection["selected_inputs"])["selected_state"]==point["data"]["native_source"]["selected_state"]
                @test read(joinpath(output,only(selection["selected_inputs"])["plan"]["path"]))==bytes
                # Only bounded JSON metadata is read here; numerical HDF5
                # payloads remain untouched after the actual strong publication.
                selected=only(selection["selected_inputs"])["selected_state"]
                manifest=R._p04_parse(read(joinpath(output,selected["manifest"]["path"]),String))
                declaration=R._p04_parse(read(joinpath(output,manifest["checkpoint"]["path"]),String))
                context=declaration["state"]["fields"]["measurement_context"]["fields"]
                @test declaration["numerical_binding"]["execution"]["fields"]["blas_threads"]["decimal"]=="1"
                @test context["backend"]==Dict("kind"=>"symbol","value"=>"not_executed")
                @test context["hilbert_roundoff_measured"]===nothing && context["map_kernels_shared_with_solver"]===nothing
                @test context["final_state_alignment"]==Dict("kind"=>"symbol","value"=>"producer_aligned")
                @test manifest["provenance"]==graph && manifest["lineage"]["parent_state"]===nothing
                @test manifest["status"]["process"]==Dict("state"=>"succeeded","exit_code"=>0,"reason"=>nothing)
                for name in ("discretization","experimental")
                    @test manifest["status"][name]==Dict("state"=>"not_measured","reason"=>"constructor_only","evidence"=>nothing)
                end
                @test !point["observables"]["scientific_assessment"]["scientific_accepted"]
                println("NATIVE_FIXTURE_LOCAL_L_ROOT=",root)
            end
        end
    end
end
end
# END positive native fixture contract
end
