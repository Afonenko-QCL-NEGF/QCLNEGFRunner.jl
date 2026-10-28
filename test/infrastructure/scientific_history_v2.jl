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
end # module
