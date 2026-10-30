isdefined(@__MODULE__, :FinalNativeCommitTests) || include("final_native_commit.jl")
module NativeSelectionContractTests
using Test, QCLNEGFRunner, SHA
const R = QCLNEGFRunner
const F = parentmodule(@__MODULE__).FinalNativeCommitTests
# Gross aggregate SOURCE fixture credit covers sequential public verifier ceilings.
# It is not a runtime grant or a packet/file ceiling.
const CAP = 1024 * 1024^2

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
end
