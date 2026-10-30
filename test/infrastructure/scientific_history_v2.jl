module ScientificHistoryV2Tests
using QCLNEGFRunner, QCLNEGF, Test, SHA, Unitful, LinearAlgebra
const R04=QCLNEGFRunner
const C04=QCLNEGF
const P04_ROOT=isempty(get(ENV,"QCL_P04_TEST_ROOT","")) ? mktempdir(;prefix="qcl-p04-history-",cleanup=false) : abspath(ENV["QCL_P04_TEST_ROOT"])
include("../support/exact_persistence_fixture.jl")
@testset "Typed history v2 seals complete outer vectors and constant pin" begin
    recorder=p04_recorder("history")
    @test R04.record_scientific_history!(recorder,p04_row())===nothing
    outer=p04_row(;sequence=11,stage=:outer)
    @test R04.record_scientific_history!(recorder,outer)===nothing
    outer.row.populations[1]=99.0;outer.row.density[1]=-99.0
    pin=R04.flush_scientific_history!(recorder)
    @test pin["records"]=="2" && pin["scba_rows"]=="1" && pin["outer_rows"]=="1"
    @test pin["head"]["schema"]=="qcl-negf.scientific-catalog.v1"
    before=deepcopy(pin)
    @test R04.flush_scientific_history!(recorder)==before
    @test_throws ArgumentError R04.record_scientific_history!(recorder,p04_row(;sequence=11))
    @test isfile(joinpath(P04_ROOT,"history","current.json"))
end

@testset "Same-leaf and sealed updates preserve original append locators" begin
    recorder=p04_recorder("updates")
    R04.record_scientific_history!(recorder,p04_row())
    R04.record_scientific_history!(recorder,p04_row(;sequence=10,action=:witness_update))
    @test R04.flush_scientific_history!(recorder)["records"]=="2"
    R04.record_scientific_history!(recorder,p04_row(;sequence=13,action=:witness_update))
    @test R04.flush_scientific_history!(recorder)["witness_updates"]=="2"
    @test_throws ArgumentError R04.record_scientific_history!(recorder,p04_row(;sequence=16))
    @test_throws ArgumentError R04.record_scientific_history!(recorder,p04_row(2;sequence=16,action=:witness_update))
    @test_throws ArgumentError R04.record_scientific_history!(recorder,p04_row(4;sequence=16))
    R04.record_scientific_history!(recorder,p04_row(;sequence=19,domain=1))
    @test length(recorder.active)==1 && recorder.stage[1]==1
    @test_throws ArgumentError R04.record_scientific_history!(recorder,p04_row(2;sequence=22,domain=0))
    R04.flush_scientific_history!(recorder)
end

@testset "Actual codec ranks, IEEE bits, empty axes and bounded stage metadata" begin
    r=p04_recorder("codec-shapes")
    bits=UInt64[0,0x8000000000000000,0x7ff0000000000000,0xfff0000000000000,0x7ff8000000000001,0x7ff8000000000002]
    realvalues=copy(reinterpret(Float64,bits))
    arrays=Any[]
    literal_arrays=Any[realvalues,reshape(complex.(realvalues,reverse(realvalues)),2,3),
        reshape(ComplexF64[complex(i,-i) for i in 1:12],3,2,1,2),Float64[],
        zeros(ComplexF64,0,3),zeros(ComplexF64,0,2,1,1),Bool[false,true,false],
        Int64[typemin(Int64),typemax(Int64)],
        reshape(ComplexF64[complex(i,-i) for i in 1:257^2],257,257)]
    wires=[R04._p04_encode(v,arrays) for v in literal_arrays]
    ref=R04._p04_payload!(r,"codec-arrays.h5",arrays,"qcl-negf-scientific-history-v5","science.history")
    for wire in wires;R04._p04_bind_arrays!(wire,ref);end
    open(joinpath(P04_ROOT,"codec-shapes.json"),"w") do io
        R04._p04_json(io,Dict("scope"=>"manufactured_codec_only_not_exact_admission","arrays"=>wires))
    end
    @test length(wires)==9
    bounded=p04_recorder("bounded";maximum_buffer_records=1)
    sequence=0
    for outer in 1:3
        for inner in 1:3
            sequence+=3
            R04.record_scientific_history!(bounded,p04_row(inner;sequence,outer))
            @test length(bounded.active)==inner
            @test length(bounded.verified)<=3
            @test all(locator->all(!(v isa C04.ScientificHistorySnapshot || v isa AbstractArray) for v in values(locator)),values(bounded.active))
        end
        sequence+=3
        R04.record_scientific_history!(bounded,p04_row(;sequence,outer,stage=:outer))
        @test length(bounded.verified)<=3
    end
    @test bounded.pin["records"]=="12"
    sample=p04_row()
    bad=C04.ScientificHistorySnapshot(:unknown,(getfield(sample,n) for n in fieldnames(typeof(sample))[2:end])...)
    @test_throws ArgumentError R04.record_scientific_history!(bounded,bad)
    @test length(R04._p04_types().nodes)==129
    @test_throws ArgumentError R04._p04_encode(()->nothing,Any[])
    @test_throws ArgumentError R04._p04_encode(Dict{String,Any}("bad"=>[1]),Any[];allow_any=true)
end

@testset "Retained append path must remain unchanged before publishing an update" begin
    r=p04_recorder("rebound-update")
    R04.record_scientific_history!(r,p04_row());R04.flush_scientific_history!(r)
    ref=only(values(r.active))["leaf"];path=joinpath(P04_ROOT,ref["path"])
    mv(path,path*".original";force=false);symlink(path*".original",path)
    R04.record_scientific_history!(r,p04_row(;sequence=10,action=:witness_update))
    @test_throws ArgumentError R04.flush_scientific_history!(r)
end

@testset "Recorded evidence requires existing verified bytes" begin
    status=p04_status()
    status["convergence"]=Dict("state"=>"recorded","reason"=>nothing,"evidence"=>Dict(
        "path"=>"absent-evidence.json","bytes"=>"0","sha256"=>repeat("0",64),
        "media_type"=>"application/json","schema"=>"manufactured-owning-evidence"))
    @test_throws ArgumentError R04.ScientificHistoryRecorder(joinpath(P04_ROOT,"missing-evidence");
        artifact_root=P04_ROOT,identity=p04_identity(),source_epoch="missing",provenance=p04_provenance(),
        status,maximum_scba_rows=3)
end

@testset "Every published public graph node has a constructor codec fixture" begin
    f=p04_exact_fixture();r=p04_recorder("graph-closure");layout=R04._p04_types();arrays=Any[]
    ids=sort!(collect(keys(layout.nodes)))
    scoped(id)=layout.types[id] in (Any,Dict{String,Any})
    wires=Any[R04._p04_encode(p04_graph_value(layout.types[id],f),arrays;allow_any=scoped(id)) for id in ids]
    ref=R04._p04_payload!(r,"graph-arrays.h5",arrays,"qcl-negf-scientific-history-v5","science.history")
    for wire in wires;R04._p04_bind_arrays!(wire,ref);end
    context=(root=P04_ROOT,references=Dict(ref["path"]=>ref),verified=Dict{String,Any}(),files=Dict{String,Any}(),validate_only=false)
    reconstructed=Any[];again=Any[]
    try
        for (id,wire) in zip(ids,wires)
            value=R04._p04_decode(wire,layout.types[id],context;allow_any=scoped(id))
            push!(again,R04._p04_encode(value,reconstructed;allow_any=scoped(id)))
        end
    finally;for file in values(context.files);close(file);end;end
    for wire in again;R04._p04_bind_arrays!(wire,ref);end
    for (id,wire,roundtrip) in zip(ids,wires,again)
        @testset "$id" begin;@test wire==roundtrip;end
    end
    @test length(ids)==129
    open(joinpath(P04_ROOT,"graph-closure.json"),"w") do io
        R04._p04_json(io,Dict("core_layout_sha256"=>R04._P04_LAYOUT,"samples"=>Dict(id=>wire for (id,wire) in zip(ids,wires))))
    end
end

# These checks distinguish real scientific publication from sideband-only metadata.
p30_load(path)=R04._p04_parse(read(path,String))
p30_path(name)=joinpath(P04_ROOT,name,"performance-anchor-current.json")
function p30_current(path)
    raw=read(path,String);value=R04._p04_parse(raw)
    immutable=joinpath(dirname(path),"performance-anchors",bytes2hex(sha256(raw))*".json")
    @test read(immutable,String)==raw
    value
end
@testset "Performance sideband never creates science for an empty recorder" begin
    path=p30_path("anchor-empty")
    r=p04_recorder("anchor-empty-science";performance_anchor_path=path)
    a=p30_current(path)
    @test a["invocation"]==Dict("source_epoch"=>"epoch1") && a["scientific"]===nothing
    @test a["phase_identity"]==p04_identity()
    @test !ispath(joinpath(r.directory,"current.json")) && !ispath(joinpath(r.directory,"history"))
    R04.flush_scientific_history!(r)
    @test p30_current(path)==a && !ispath(joinpath(r.directory,"current.json"))
    @test !ispath(joinpath(P04_ROOT,"history","performance-anchor-current.json")) # opt-in only
end
@testset "History-only anchor pins original bytes only after scientific readback" begin
    path=p30_path("anchor-history")
    r=p04_recorder("anchor-history-science";performance_anchor_path=path)
    R04.record_scientific_history!(r,p04_row())
    R04._p04_flush_history!(r;hook=stage->begin
        if stage in (:manifest_published,:current_pointer_published)
            @test p30_current(path)["scientific"]===nothing
        end
    end)
    a=p30_current(path);science=a["scientific"];state=science["selected_state"]
    original=read(joinpath(P04_ROOT,state["manifest"]["path"]),String)
    @test science["manifest_utf8"]==original && science["artifact_root"]=="."
    @test bytes2hex(sha256(original))==state["manifest"]["sha256"]
    @test p30_load(joinpath(r.directory,"current.json"))["manifest"]==state["manifest"]
    @test R04._p04_parse(original)["checkpoint"]===nothing
    @test R04._p04_parse(original)["history"]["records"]=="1"
    @test science["relation"]=="produced" && science["source_origin"]===nothing
end
@testset "Science failures do not promote an unacknowledged sideband" begin
    for barrier in (:manifest_published,:current_pointer_published)
        path=p30_path("anchor-fail-"*String(barrier))
        r=p04_recorder("anchor-fail-science-"*String(barrier);performance_anchor_path=path)
        R04.record_scientific_history!(r,p04_row())
        primary=ErrorException("scientific failure at "*String(barrier))
        caught=try R04._p04_flush_history!(r;hook=stage->stage===barrier && throw(primary));nothing catch e;e end
        @test caught===primary && r.failed
        @test p30_current(path)["scientific"]===nothing
        if barrier===:current_pointer_published
            R04.flush_scientific_history!(r) # explicit reconciliation of the real current pointer
            @test p30_current(path)["scientific"]!==nothing && !r.failed
        end
    end
    path=p30_path("anchor-cancel")
    r=p04_recorder("anchor-cancel-science";performance_anchor_path=path)
    R04.record_scientific_history!(r,p04_row())
    primary=InterruptException()
    caught=try R04._p04_flush_history!(r;hook=stage->stage===:manifest_published && throw(primary));nothing catch e;e end
    @test caught===primary && p30_current(path)["scientific"]===nothing
end
@testset "Checkpoint and final anchors follow their actual current pointer" begin
    for terminal in (false,true)
        f=terminal ? p04_final_fixture() : p04_exact_fixture()
        name=terminal ? "anchor-final" : "anchor-cp";path=p30_path(name)
        r=p04_recorder(name*"-science";performance_anchor_path=path)
        R04.record_scientific_history!(r,p04_snapshot(f))
        status=p04_status()
        terminal && (status["process"]=Dict("state"=>"failed","exit_code"=>nothing,"reason"=>"manufactured_final"))
        cp=R04.commit_exact_checkpoint!(r,f.problem,f.state;f.bind...,status,closed=terminal,
            publication_hook=stage->begin
                stage===:current_pointer_published && @test p30_current(path)["scientific"]===nothing
            end)
        a=p30_current(path)
        @test a["scientific"]["selected_state"]==R04.checkpoint_reference(cp)
        @test a["scientific"]["manifest_utf8"]==read(joinpath(P04_ROOT,R04.checkpoint_reference(cp)["manifest"]["path"]),String)
        @test R04._p04_parse(a["scientific"]["manifest_utf8"])["closed"]===terminal
    end
end
@testset "Sideband failure leaves science successful and telemetry unavailable" begin
    path=p30_path("anchor-io-fail")
    r=p04_recorder("anchor-io-fail-science";performance_anchor_path=path)
    original=read(path,String);mv(path,path*".original");mkdir(path)
    R04.record_scientific_history!(r,p04_row());R04.flush_scientific_history!(r)
    @test !r.failed && isfile(joinpath(r.directory,"current.json")) && r.pin["records"]=="1"
    @test R04._p30_anchor_phase_source(r,nothing).status===:unavailable
    @test R04._p30_anchor_phase_source(r,nothing).reason===:performance_anchor_publication_failed
    @test read(path*".original",String)==original
    outside=joinpath(P04_ROOT,"..","performance-anchor-current.json")
    @test_throws ArgumentError p04_recorder("anchor-outside";performance_anchor_path=outside)
end
@testset "Borrowed source keeps current phase and original scientific invocation separate" begin
    oldorigin=(calcjob_uuid="11111111-1111-1111-1111-111111111111",native_execution_uuid="22222222-2222-2222-2222-222222222222")
    currentorigin=(calcjob_uuid="33333333-3333-3333-3333-333333333333",native_execution_uuid="44444444-4444-4444-4444-444444444444")
    olddir=joinpath(P04_ROOT,"anchor-parent-science");mkdir(olddir)
    oldepoch=R04._native_source_epoch(oldorigin;nonce=UInt64(7))
    old=R04.ScientificHistoryRecorder(olddir;artifact_root=P04_ROOT,identity=p04_identity(),source_epoch=oldepoch,
        provenance=p04_provenance(),status=p04_status(),maximum_scba_rows=3)
    f=p04_exact_fixture();R04.record_scientific_history!(old,p04_snapshot(f))
    cp=R04.commit_exact_checkpoint!(old,f.problem,f.state;f.bind...,status=p04_status())
    path=p30_path("anchor-borrowed");source=(status=:available,session_id="current-session",current_path="phase-current.json",reason=nothing)
    R04._p30_begin_performance_anchor(P04_ROOT,path,p04_identity(2),source,currentorigin)
    r=p04_recorder("anchor-borrowed-science";attempt=2,parent=cp,performance_anchor_path=path)
    @test p30_current(path)["scientific"]===nothing
    @test R04._p30_borrowed_anchor!(r,cp)
    a=p30_current(path);science=a["scientific"]
    @test a["phase_identity"]==p04_identity(2) && a["invocation"]==Dict("source_epoch"=>"epoch2")
    @test a["origin"]["calcjob_uuid"]==currentorigin.calcjob_uuid && a["phase_source"]["session_id"]=="current-session"
    @test science["selected_state"]==R04.checkpoint_reference(cp) && science["invocation"]["source_epoch"]==oldepoch
    @test science["source_origin"]["calcjob_uuid"]==oldorigin.calcjob_uuid && science["relation"]=="borrowed"
    @test !ispath(joinpath(r.directory,"current.json"))
    ref=R04.checkpoint_reference(cp)["manifest"];write(joinpath(P04_ROOT,ref["path"]),"changed original")
    @test !R04._p30_borrowed_anchor!(r,cp)
    @test R04._p30_anchor_phase_source(r,source).status===:unavailable
end

@testset "Phase0 sideband path failure is telemetry failure only" begin
    root=joinpath(P04_ROOT,"anchor-phase0-symlink");mkdir(root)
    target=joinpath(root,"original.json");write(target,"original-owned-by-fixture")
    path=joinpath(root,"performance-anchor-current.json");symlink(target,path)
    result=try R04._p30_begin_performance_anchor(root,path,p04_identity(),nothing,nothing) catch error;error end
    @test result isa R04._PerformanceAnchor
    if result isa R04._PerformanceAnchor
        @test result.failed && result.value["scientific"]===nothing
        @test result.value["phase_source"]["status"]=="unavailable"
    end
    @test read(target,String)=="original-owned-by-fixture" && islink(path)
end
@testset "Immutable sideband precedes current and identical metadata reuses its original" begin
    path=p30_path("anchor-order")
    a=R04._p30_begin_performance_anchor(P04_ROOT,path,p04_identity(),nothing,nothing)
    before=read(path,String);a.value["invocation"]=Dict("source_epoch"=>"order-epoch")
    raw=R04._p04_json(a.value);immutable=joinpath(dirname(path),"performance-anchors",bytes2hex(sha256(raw))*".json")
    @test R04._p30_publish_performance_anchor!(a;publication_hook=stage->begin
        if stage===:immutable_published
            @test read(immutable,String)==raw && read(path,String)==before
        end
    end)
    signature=stat(immutable)
    @test p30_current(path)["invocation"]==Dict("source_epoch"=>"order-epoch")
    @test R04._p30_publish_performance_anchor!(a)
    @test stat(immutable).inode==signature.inode && stat(immutable).mtime==signature.mtime
end

@testset "Phase descriptor paths are relative to the captured artifact root" begin
    unrelated=joinpath(P04_ROOT,"unrelated-host-ancestry");mkdir(unrelated)
    mkdir(joinpath(unrelated,"target"));symlink(joinpath(unrelated,"target"),joinpath(unrelated,"alias"))
    relative=replace(relpath(joinpath(unrelated,"alias","phase-current.json"),"/"),'\\'=>'/')
    source=(status=:available,session_id="relative-session",current_path=relative,reason=nothing)
    projection=try R04._p30_phase_projection(source) catch error;error end
    @test projection isa AbstractDict
    if projection isa AbstractDict
        @test projection["current_path"]==relative
    end
end
end # module
