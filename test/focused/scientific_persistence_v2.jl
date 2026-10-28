# Constructor/persistence only. No solve, completed-map measurement or package preparation.
using QCLNEGFRunner, QCLNEGF, Test, SHA
@test length(QCLNEGFRunner._p04_layout().nodes)==129 # Main has not imported Unitful.
using Unitful, LinearAlgebra
@test length(QCLNEGFRunner._p04_layout().nodes)==129
println("[P04] package loaded; constructor-only packet");flush(stdout)
const R04=QCLNEGFRunner
const C04=QCLNEGF
const P04_ROOT=get(ENV,"QCL_P04_TEST_ROOT","")
isabspath(P04_ROOT) && isdir(P04_ROOT) || error("Supply fresh owned QCL_P04_TEST_ROOT")
@testset "P04 public exact persistence boundary" begin
    @test isdefined(R04,:VerifiedExactCheckpoint)
    @test isdefined(R04,:commit_exact_checkpoint!)
    @test isdefined(R04,:open_exact_checkpoint)
    @test isdefined(R04,:load_exact_solver_state)
end
flush(stdout)
@testset "Strict nested metadata JSON" begin
    @test R04._p04_parse("{\"a\":{\"b\":1},\"c\":2}")==Dict("a"=>Dict("b"=>1),"c"=>2)
    @test_throws ArgumentError R04._p04_parse("{\"a\":1,\"a\":2}")
    @test_throws ArgumentError R04._p04_parse("{\"a\":{\"b\":1,\"b\":2}}")
    @test_throws ArgumentError R04._p04_parse("{\"a\":NaN}")
    for value in ("0","01","1\n","18446744073709551616",1)
        @test_throws ArgumentError R04._p04_u64(value;positive=true)
    end
    @test R04._p04_u64("18446744073709551615")==typemax(UInt64)
    @test_throws ArgumentError R04._p04_id("epoch\n")
    @test R04._p04_parse("{\"a\":1}\n")==Dict("a"=>1)
    @test R04._p04_parse(" \n { \"a\": 1 }\r\n")==Dict("a"=>1)
    @test R04._p04_parse("[1,\n2]\n")==Any[1,2]
end

@testset "Canonical typed decimal admission preserves widths without normalization" begin
    context=(root="",references=Dict{String,Any}(),verified=Dict{String,Any}(),files=Dict{String,Any}(),validate_only=false)
    wire(T,decimal)=Dict("kind"=>"integer","type"=>string(T),"decimal"=>decimal)
    for T in (Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32,UInt64)
        for value in unique((typemin(T),zero(T),one(T),typemax(T)))
            @test R04._p04_decode(wire(T,string(value)),T,context)===value
        end
        for decimal in ("-0","+1","01","00","-01"," 1","1 ","1\n","1\r\n","1\t","\n1","1\n\n","")
            @test_throws ArgumentError R04._p04_decode(wire(T,decimal),T,context)
        end
        @test_throws ArgumentError R04._p04_decode(wire(T,string(BigInt(typemax(T))+1)),T,context)
        @test_throws ArgumentError R04._p04_decode(wire(T,string(BigInt(typemin(T))-1)),T,context)
    end
end

@testset "Canonical SourceGraph revisions require the complete string" begin
    provenance=Dict("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),"components"=>[
        Dict("path"=>"components/Core","revision"=>repeat("b",40),"url"=>"https://example.invalid/Core")])
    @test R04._p04_validate_provenance(provenance)===nothing
    for suffix in ("\n"," ","\r\n")
        value=deepcopy(provenance);value["revision"]*=suffix
        @test_throws ArgumentError R04._p04_validate_provenance(value)
        value=deepcopy(provenance);value["components"][1]["revision"]*=suffix
        @test_throws ArgumentError R04._p04_validate_provenance(value)
    end
end

@testset "RowKey admission derives scalar types from the public snapshot" begin
    integer(decimal)=Dict("kind"=>"integer","type"=>"Int64","decimal"=>decimal)
    row=Dict{String,Any}("domain_revision"=>integer("0"),"discretization_id"=>"grid","basis_id"=>"basis",
        "stage"=>Dict("kind"=>"symbol","value"=>"scba"),"outer_iteration"=>integer("1"),"inner_iteration"=>integer("1"))
    @test R04._p04_admit_row_key(row)===row
    for name in ("domain_revision","outer_iteration","inner_iteration")
        for decimal in (string(typemin(Int64)),"0",string(typemax(Int64)))
            value=deepcopy(row);value[name]=integer(decimal)
            @test R04._p04_admit_row_key(value)===value
        end
        for decimal in ("1\n","1 ","+1","-0","01",string(BigInt(typemax(Int64))+1))
            value=deepcopy(row);value[name]=integer(decimal)
            @test_throws ArgumentError R04._p04_admit_row_key(value)
        end
        value=deepcopy(row);value[name]["type"]="UInt16"
        @test_throws ArgumentError R04._p04_admit_row_key(value)
    end
    value=deepcopy(row);value["inner_iteration"]=nothing
    @test R04._p04_admit_row_key(value)===value
end
println("[P04] history/actual codec fixtures");flush(stdout)
include("../infrastructure/scientific_history_v2.jl")
println("[P04] exact/crash/ancestry fixtures");flush(stdout)
include("../infrastructure/exact_checkpoint_v2.jl")
println("[P04] constructor-only packet complete");flush(stdout)
