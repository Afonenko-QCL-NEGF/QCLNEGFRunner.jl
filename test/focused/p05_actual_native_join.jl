module P05ActualNativeJoin
using Test, QCLNEGFRunner, QCLNEGF, Unitful
const R=QCLNEGFRunner
include("../contracts/final_native_commit.jl")
const F=FinalNativeCommitTests
const R04=R
const C04=QCLNEGF
const P04_ROOT=F.FINAL_ROOT
include("../support/exact_persistence_fixture.jl")

@testset "actual caller cleanup seals only open healthy history and preserves primary error" begin
    @test isdefined(R,:_p05_flush_open_history!)
    if isdefined(R,:_p05_flush_open_history!)
        @test R._p05_flush_open_history!(nothing,nothing)===nothing
        closed=F.TRANSACTION[].rr.r
        pin=deepcopy(closed.pin)
        @test R._p05_flush_open_history!(closed,nothing)===nothing
        @test closed.closed && closed.pin==pin
        open_rec=p04_recorder("native-join-open-cleanup";clock_ns=()->UInt64(0))
        record_scientific_history!(open_rec,p04_row())
        @test !isempty(open_rec.buffer)
        @test R._p05_flush_open_history!(open_rec,nothing)===nothing
        @test isempty(open_rec.buffer) && open_rec.pin["records"]=="1"
        failed=p04_recorder("native-join-failed-cleanup";clock_ns=()->UInt64(0))
        record_scientific_history!(failed,p04_row());failed.failed=true
        @test R._p05_flush_open_history!(failed,ErrorException("primary"))===nothing
        @test failed.failed && !isempty(failed.buffer) && failed.pin["records"]=="0"
        broken=p04_recorder("native-join-broken-cleanup";clock_ns=()->UInt64(0))
        record_scientific_history!(broken,p04_row())
        history=joinpath(broken.directory,"history");mkpath(history)
        mv(history,history*"-original");write(history,"not a directory")
        primary=ErrorException("original Core error")
        error=try R._p05_flush_open_history!(broken,primary);nothing catch e;e end
        @test error isa CompositeException && first(error.exceptions)===primary && length(error.exceptions)==2
    end
end

@testset "intermediate CP selects original input refs from actual request" begin
    f=F.final_fixture();rr=F.final_recorder("intermediate-inputs",f)
    cp=commit_exact_checkpoint!(rr.r,f.solution.problem,f.state;f.binding...,status=rr.initial_status,
        request=rr.request,maximum_metadata_bytes=64*1024^2)
    opened=open_exact_checkpoint(F.FINAL_ROOT,checkpoint_reference(cp);maximum_metadata_bytes=64*1024^2)
    pair=verify_checkpoint_inputs(opened;plan_ref=rr.request.plan_ref,model_ref=rr.request.model_ref,
        maximum_metadata_bytes=64*1024^2)
    @test keys(pair)==(:plan,:model)
    @test pair.plan==rr.request.plan_ref && pair.model==rr.request.model_ref
    manifest=R._p04_parse(opened.manifest_json)
    for (ref,role) in ((pair.plan,"plan"),(pair.model,"model"))
        rows=filter(x->x["path"]==ref["path"],manifest["artifacts"])
        @test length(rows)==1
        @test only(rows)["role"]==role && only(rows)["profile"]=="science" && isempty(only(rows)["dependencies"])
    end
    for key in ("path","bytes","sha256","schema","media_type")
        bad=deepcopy(pair.plan);bad[key]=key=="bytes" ? "1" : "wrong"
        @test_throws ArgumentError verify_checkpoint_inputs(opened;plan_ref=bad,model_ref=pair.model,maximum_metadata_bytes=64*1024^2)
    end
    @test_throws ArgumentError verify_checkpoint_inputs(opened;plan_ref=pair.model,model_ref=pair.plan,maximum_metadata_bytes=64*1024^2)
    @test_throws ArgumentError verify_checkpoint_inputs(opened;plan_ref=pair.plan,model_ref=pair.model,maximum_metadata_bytes=1)
    @test pair.model["sha256"]!=checkpoint_reference(cp)["identity"]["model_sha256"]
    # An unrelated valid input leaf cannot select or replace the explicit pair.
    unused=joinpath(F.FINAL_ROOT,"unused-input-model.json")
    write(unused,read(joinpath(F.FINAL_ROOT,pair.model["path"])))
    unused_ref=R._p04_ref(F.FINAL_ROOT,unused,pair.model["schema"])
    selected_ref=p04_forge(cp,"inputs-extra-leaf";manifest_mutator=m->push!(m["artifacts"],R._p04_artifact(unused_ref,"model";dependencies=String[])))
    selected=open_exact_checkpoint(F.FINAL_ROOT,selected_ref;maximum_metadata_bytes=64*1024^2)
    @test verify_checkpoint_inputs(selected;plan_ref=pair.plan,model_ref=pair.model,maximum_metadata_bytes=64*1024^2)==pair
    for (name,mutation) in (("role",a->(a["role"]="plan")),("profile",a->(a["profile"]="local")),
            ("dependency",a->push!(a["dependencies"],pair.plan["path"])))
        ref=p04_forge(cp,"inputs-wrong-"*name;manifest_mutator=m->mutation(only(filter(a->a["path"]==pair.model["path"],m["artifacts"]))))
        @test_throws ArgumentError begin
            bad=open_exact_checkpoint(F.FINAL_ROOT,ref;maximum_metadata_bytes=64*1024^2)
            verify_checkpoint_inputs(bad;plan_ref=pair.plan,model_ref=pair.model,maximum_metadata_bytes=64*1024^2)
        end
    end
    @test !rr.r.closed
end
@testset "actual callbacks bind same pre-Core request without retaining borrowed problem" begin
    f=F.final_fixture();rr=F.final_recorder("callback-request",f)
    cb=R._p05_science_callbacks(rr.r,f.solution.problem;f.binding...,status=()->rr.initial_status,
        request=rr.request,maximum_metadata_bytes=64*1024^2)
    @test cb.checkpoint_context_sink(f.solution.problem,f.state)===nothing
    @test cb.terminal[]===f.state
    @test all(n->getfield(cb.checkpoint_context_sink,n)!==f.solution.problem,fieldnames(typeof(cb.checkpoint_context_sink)))
    @test !hasproperty(cb,:terminal_problem)
    @test_throws ArgumentError cb.checkpoint_context_sink(f.solution.problem,f.state)
end
@testset "actual native callsites select public callbacks and final triple" begin
    root=normpath(joinpath(@__DIR__,"..",".."))
    scientific=read(joinpath(root,"src/composition/scientific_execution.jl"),String)
    production=read(joinpath(root,"src/composition/production_workflow.jl"),String)
    configured=read(joinpath(root,"src/composition/configured_run.jl"),String)
    adapter=read(joinpath(root,"src/composition/production_runtime_adapter.jl"),String)
    # SOURCE route gate: persisted final truth must flow through the public native
    # commit, and old state/legacy writer callbacks may not remain on that route.
    @test occursin("_p05_commit_final_with_presentation!",scientific)
    @test !occursin("commit=commit_point_artifacts(",scientific)
    @test occursin("request=prepared_final_request.request",scientific)
    @test occursin("native_publication_sink",production)
    @test occursin("checkpoint_context_sink=point_context",production)
    @test !occursin("restart = load_production_restart(",production)
    @test !occursin("storage=_configured_storage_observers(configuration",split(configured,"function run_from_configuration",limit=2)[2])
    @test occursin("native_context",adapter)
    @test !occursin("checkpoint_publisher = _RuntimeCheckpointPublisher(",adapter)
end

function selected_document(source)
    point=Dict{String,Any}("id"=>"point","execution_id"=>"exec","attempt"=>1,
        "coordinates"=>Dict("temperature_K"=>70.0,"voltage_per_period_V"=>0.05,"branch"=>"branch","order"=>1),
        "initialization"=>Dict("kind"=>"cold","source_point_id"=>nothing,"checkpoint"=>nothing,"fallback_reason"=>nothing),
        "status"=>"completed","quality"=>"invalid","converged"=>false,"warnings"=>Any[],"observables"=>Dict("display_nonfinite"=>NaN),
        "data"=>Dict{String,Any}("native_source"=>source,"phase_source"=>Dict("status"=>"disabled","session_id"=>nothing,"current_path"=>nothing,"reason"=>"fixture"),"optical_attachment"=>nothing),
        "postprocessing"=>Dict("optical"=>Dict("status"=>"not_requested","error"=>nothing)))
    Dict{String,Any}("schema"=>"qcl-negf-series-result-v4","contract_set"=>"qcl-negf.results.v2", "plan_fingerprint"=>"fixture","plan_scientific_fingerprint"=>"fixture",
        "root_definition_id"=>"fixture","name"=>"fixture","status"=>"completed_with_warnings","model_version"=>"0.2.0","inclusions"=>Any[],
        "executions"=>[Dict("id"=>"exec","definition_id"=>"fixture","variant_id"=>"v","method_id"=>"m","purpose"=>"diagnostic","label"=>"fixture","operation"=>"stationary","point_ids"=>["point"],"repetition"=>1)],
        "expected_point_count"=>1,"available_point_count"=>1,"points"=>[point],"attempt_history"=>[deepcopy(point)])
end
@testset "native final source selects full refs and recorded scalars without getters" begin
    t=F.TRANSACTION[];source=R._p05_native_source(".";t.result...)
    @test Set(keys(source))==Set(("schema","kind","artifact_root","relation","selected_state","diagnostics","observations","reason"))
    @test source["kind"]=="final" && source["selected_state"]==checkpoint_reference(t.result.checkpoint)
    @test source["diagnostics"]==t.result.diagnostics && source["observations"]==t.result.observations
    metadata=R._p05_recorded_final(t.result,64*1024^2)
    @test metadata.summary["status"]=="scba_invalid_candidate"
    @test metadata.summary["converged"]===false
    @test R._p05_verify_native_source(F.FINAL_ROOT,source,128*1024^2) isa VerifiedExactCheckpoint
    @test_throws ArgumentError R._p05_native_source(".";checkpoint=t.result.checkpoint,diagnostics=t.result.diagnostics)
    for mutate in (x->(x["extra"]=nothing),x->(x["kind"]="invented"),x->(x["artifact_root"]="../escape"),
            x->(x["selected_state"]["manifest"]["sha256"]="0"^64),x->(x["observations"]=deepcopy(x["diagnostics"])))
        bad=deepcopy(source);mutate(bad)
        @test_throws ArgumentError R._p05_verify_native_source(F.FINAL_ROOT,bad,128*1024^2)
    end
    document=selected_document(source)
    @test R._p05_verify_native_result(F.FINAL_ROOT,document,256*1024^2)===nothing
    checked=R._p05_native_result_profile(document,256*1024^2)
    @test checked.wire["points"][1]["observables"]["display_nonfinite"]===nothing # display only, O1/D1 raw IEEE remains
    for mutate in (x->(x["extra"]=nothing),x->(x["points"][1]["data"]["full_state"]="fake.h5"),
            x->(x["points"][1]["id"]="wrong"),x->(x["points"][1]["attempt"]=2),
            x->(x["points"][1]["coordinates"]["temperature_K"]=NaN),
            x->(x["points"][1]["data"]["native_source"]["kind"]="absent"))
        bad=deepcopy(document);mutate(bad)
        @test_throws ArgumentError R._p05_verify_native_result(F.FINAL_ROOT,bad,256*1024^2)
    end
    @test_throws ArgumentError R._p05_verify_native_result(F.FINAL_ROOT,document,1)
    for mutate in (x->(x["diagnostics"]["unexpected"]=nothing),x->(x["selected_state"]["unexpected"]=nothing),
            x->(x["selected_state"]["manifest"]["media_type"]="text/plain"),
            x->(x["observations"]["media_type"]="application/json"),x->(x["artifact_root"]="../escape"),
            x->(x["observations"]=deepcopy(x["diagnostics"])))
        bad=deepcopy(document);delete!(bad,"attempt_history");mutate(bad["points"][1]["data"]["native_source"])
        @test_throws ArgumentError R._p05_native_result_profile(bad,256*1024^2)
        _,reads=p04_reads(()->(@test_throws ArgumentError R._p05_verify_native_result(F.FINAL_ROOT,bad,256*1024^2)))
        @test isempty(reads)
    end
    # Published outward semantic joins must refuse before file traversal.
    for mutate in (x->(push!(x["points"],deepcopy(x["points"][1]));x["available_point_count"]=2;x["expected_point_count"]=2),
            x->push!(x["attempt_history"],deepcopy(x["attempt_history"][1])),
            x->(x["attempt_history"][1]["quality"]="unconverged"),
            x->(x["points"][1]["postprocessing"]["optical"]["error"]="error without failed lifecycle"))
        bad=deepcopy(document);mutate(bad)
        @test_throws ArgumentError R._p05_native_result_profile(bad,256*1024^2)
    end
    retained=deepcopy(document)
    for row in (retained["points"][1],retained["attempt_history"][1])
        row["data"]["native_source"]["relation"]="retained_source"
        row["data"]["native_source"]["reason"]="previous attempt required"
    end
    @test_throws ArgumentError R._p05_verify_native_result(F.FINAL_ROOT,retained,256*1024^2)
end
@testset "actual final delivery uses separate mandatory synchronous ports" begin
    t=F.TRANSACTION[];terminal=F.FIXTURE[].state
    bundle=(;stationary_assessment=Dict("retained"=>true),validation=Dict("status"=>"invalid"),positivity=Dict("status"=>"invalid_candidate"))
    order=Symbol[]
    checkpoint_observer=(s,it,iv)->(@test s===terminal && it==2 && iv==3;push!(order,:state))
    native_publication_sink=(x,it,iv)->(@test x===t.result;push!(order,:native))
    final_presentation_sink=(x,it,iv)->(@test x===bundle;push!(order,:display))
    @test R._p05_deliver_final!(t.result,bundle,terminal,2,3;checkpoint_observer,native_publication_sink,final_presentation_sink)===nothing
    @test order==[:state,:native,:display]
    original=ErrorException("mandatory native sink failure");empty!(order)
    failure=try
        R._p05_deliver_final!(t.result,bundle,terminal,2,3;checkpoint_observer,
            native_publication_sink=(args...)->throw(original),final_presentation_sink)
        nothing
    catch error;error;end
    @test failure===original && order==[:state]
    @test_throws ArgumentError R._p05_deliver_final!((;checkpoint=t.result.checkpoint),bundle,terminal,1,1;checkpoint_observer=nothing,native_publication_sink=nothing,final_presentation_sink=nothing)
end
@testset "scratch validates explicit selected graph before publication and cleanup" begin
    document=selected_document(R._p05_native_source(".";F.TRANSACTION[].result...))
    mktempdir() do parent
        missing=joinpath(parent,"missing-cap")
        @test_throws ArgumentError R.stage_result_tree(F.FINAL_ROOT,missing;byte_budget=1024^3,reserve_bytes=0,native_result=document)
        @test !ispath(missing) && isdir(F.FINAL_ROOT)
        for (name,cap,selection) in (("insufficient",1,document),("wrong-ref",256*1024^2,deepcopy(document)))
            name=="wrong-ref" && (selection["points"][1]["data"]["native_source"]["observations"]["sha256"]="0"^64)
            target=joinpath(parent,name)
            @test_throws ArgumentError R.stage_result_tree(F.FINAL_ROOT,target;byte_budget=1024^3,reserve_bytes=0,native_result=selection,maximum_metadata_bytes=cap)
            @test !ispath(target) && isdir(F.FINAL_ROOT)
        end
        target=joinpath(parent,"healthy")
        @test R.stage_result_tree(F.FINAL_ROOT,target;byte_budget=1024^3,reserve_bytes=0,native_result=document,maximum_metadata_bytes=256*1024^2)==target
        @test R._p05_verify_native_result(target,document,256*1024^2)===nothing
        @test isdir(F.FINAL_ROOT)
    end
end

@testset "published outward fixture is finite and explicitly selected" begin
    document=R._p05_native_result_profile(selected_document(R._p05_native_source(".";F.TRANSACTION[].result...)),256*1024^2).wire
    file=joinpath(F.FINAL_ROOT,"outward-v4.json")
    write(file,R._p04_json(document))
    @test isfile(file)
    println("OUTWARD_FIXTURE_ROOT=",F.FINAL_ROOT)
end

end

# P05 actual22 F1 R1 regressions: actual producer bytes, never relabeled on healthy trace.
module P05ActualNativeJoinF1R1
using Test,QCLNEGFRunner
const R=QCLNEGFRunner
const W=R.QCLScientificWorkflow
@testset "F1 actual producer public writer parser profile stage same wire" begin
    plan=resolve_scientific_plan(joinpath(dirname(dirname(pathof(R))),"test/fixtures/configurations/resource-proposal-study.yaml"))
    actual=W._series_document(plan,W.ScientificPointResult[],:running)
    @test actual["schema"]=="qcl-negf-series-result-v4"
    @test actual["contract_set"]=="qcl-negf.results.v2"
    output=IOBuffer();write_scientific_result(output,actual);bytes=take!(output)
    parsed=R._p04_parse(String(copy(bytes)))
    @test parsed==actual
    @test R._p05_native_result_profile(parsed,64*1024^2).wire==actual
    mktempdir() do root
        source=joinpath(root,"source");mkpath(source)
        write(joinpath(source,"series_result.json"),bytes)
        reread,owner=W._read_series(source)
        @test reread==actual && owner==source
        target=joinpath(root,"staged")
        @test R.stage_result_tree(source,target;byte_budget=1024^2,reserve_bytes=0,maximum_metadata_bytes=64*1024^2,native_result=reread)==target
        @test isfile(joinpath(target,"series_result.json")) && read(joinpath(target,"series_result.json"))==bytes
        @test read(joinpath(source,"series_result.json"))==bytes
    end
    # This separately named compatibility fixture exercises old pair dispatch;
    # no healthy native trace above mutates/relabels the producer envelope.
    legacy=merge(actual,Dict("schema"=>"qcl-negf-series-result-v3","contract_set"=>"qcl-negf.results.v1"))
    legacy_output=IOBuffer();@test write_scientific_result(legacy_output,legacy)===nothing
    mktempdir() do root
        path=joinpath(root,"series_result.json");write(path,take!(legacy_output))
        @test first(W._read_series(path))==legacy
        @test_throws ArgumentError R._p05_native_result_profile(legacy,64*1024^2)
        for (schema,contract) in (("qcl-negf-series-result-v4","qcl-negf.results.v1"),
                ("qcl-negf-series-result-v3","qcl-negf.results.v2"),
                ("qcl-negf-series-result-v4","qcl-negf.results.v3"),("invented","qcl-negf.results.v2"))
            bad=merge(actual,Dict("schema"=>schema,"contract_set"=>contract))
            @test_throws ArgumentError write_scientific_result(IOBuffer(),bad)
            write(path,R._p04_json(bad))
            @test_throws ArgumentError W._read_series(path)
        end
    end
    destination=get(ENV,"P05_F1_OUTPUT_DIR","")
    if !isempty(destination)
        mkpath(destination)
        write(joinpath(destination,"actual-producer-writer.json"),bytes)
        @test read(joinpath(destination,"actual-producer-writer.json"))==bytes
    end
end
end

# P05 actual22 F1 R2 regressions: optional fields from the published outward schema.
module P05ActualNativeJoinF1R2
using Test,QCLNEGFRunner
const R=QCLNEGFRunner
const W=R.QCLScientificWorkflow
@testset "F1 published optional evidence and selection are closed before staging" begin
    plan=resolve_scientific_plan(joinpath(dirname(dirname(pathof(R))),"test/fixtures/configurations/resource-proposal-study.yaml"))
    actual=W._series_document(plan,W.ScientificPointResult[],:running)
    for evidence in (String[],[""],["source-L-control","α-μm"])
        healthy=merge(actual,Dict("evidence"=>evidence,"selected_execution_id"=>nothing,"attempt_history"=>Any[]))
        @test R._p05_native_result_profile(healthy,64*1024^2).wire==healthy
    end
    selected=merge(actual,Dict("selected_execution_id"=>first(actual["executions"])["id"]))
    @test R._p05_native_result_profile(selected,64*1024^2).wire==selected
    invalid=(Dict("unexpected_nested"=>Dict("path"=>"not-a-ref")),["duplicate","duplicate"],Any["string",1],Any[false],nothing,1,"not-an-array")
    mktempdir() do root
        source=joinpath(root,"source");mkdir(source);write(joinpath(source,"sentinel.txt"),"retained")
        for (i,evidence) in enumerate(invalid)
            bad=merge(actual,Dict("evidence"=>evidence))
            @test_throws ArgumentError R._p05_native_result_profile(bad,64*1024^2)
            target=joinpath(root,"bad-"*string(i))
            @test_throws ArgumentError R.stage_result_tree(source,target;byte_budget=1024^2,reserve_bytes=0,maximum_metadata_bytes=64*1024^2,native_result=bad)
            @test !ispath(target) && read(joinpath(source,"sentinel.txt"),String)=="retained"
        end
    end
    for (key,value) in (("attempt_history",Dict("unknown"=>nothing)),("attempt_history",Any[false]),
            ("selected_execution_id",1),("selected_execution_id",Dict("unknown"=>nothing)),("selected_execution_id","not-an-execution"))
        @test_throws ArgumentError R._p05_native_result_profile(merge(actual,Dict(key=>value)),64*1024^2)
    end
    destination=get(ENV,"P05_F1_OUTPUT_DIR","")
    if !isempty(destination)
        mkpath(destination)
        cases=Dict{String,Any}("evidence-valid"=>merge(actual,Dict("evidence"=>["source-L-control"])),
            "evidence-empty"=>merge(actual,Dict("evidence"=>[""])),
            "evidence-object"=>merge(actual,Dict("evidence"=>first(invalid))),
            "evidence-duplicate"=>merge(actual,Dict("evidence"=>invalid[2])),
            "evidence-number"=>merge(actual,Dict("evidence"=>invalid[3])))
        for (name,value) in cases
            io=IOBuffer();write_scientific_result(io,value);write(joinpath(destination,name*".json"),take!(io))
        end
    end
end
end
