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
end
