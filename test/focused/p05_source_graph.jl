using Test, QCLNEGFRunner
const R=QCLNEGFRunner
@testset "exact writer needs an explicit captured source graph" begin
    graph=Dict{String,Any}("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),
        "components"=>[Dict("path"=>"components/QCLNEGF.jl","revision"=>repeat("b",40),"url"=>"https://example.org/core")])
    @test_throws ArgumentError R._require_source_graph(nothing)
    snapshot=R._require_source_graph(graph)
    @test snapshot==graph && snapshot !== graph
    graph["revision"]=repeat("c",40)
    @test snapshot["revision"]==repeat("a",40)
    @test_throws Exception R._require_source_graph(Dict("format"=>"fake"))
    mktempdir() do dir
        path=joinpath(dir,"graph.json")
        write(path,"{\"format\":\"qcl-negf.git-graph.v1\",\"revision\":\""*repeat("a",40)*"\",\"components\":[]}")
        @test R._load_source_graph_file(path)["revision"]==repeat("a",40)
        write(path,fill(UInt8(' '),256*1024+1))
        @test_throws ArgumentError R._load_source_graph_file(path)
    end
end
@testset "configured orchestration requires a source graph before reading input" begin
    error=try
        R.execute_configured_run("/nonexistent/p05-definition.yaml")
        nothing
    catch caught
        caught
    end
    @test error isa ArgumentError
    @test occursin("source_graph_unavailable",sprint(showerror,error))
end
@testset "legacy recovery bundle is refused before output creation" begin
    plan=resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    graph=Dict{String,Any}("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),"components"=>[])
    mktempdir() do dir
        for (call, output) in ((R.QCLScientificWorkflow.execute_scientific_plan,joinpath(dir,"direct")),
                               (R.execute_scientific_plan_staged,joinpath(dir,"staged")))
            error=try
                call(plan,output;source_graph=graph,recovery_bundle=joinpath(dir,"legacy"))
                nothing
            catch caught
                caught
            end
            @test error isa ArgumentError
            @test occursin("unsupported_format", sprint(showerror,error))
            @test !ispath(output)
        end
    end
end
@testset "missing graph refuses before any execution output" begin
    plan=resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    mktempdir() do dir
        direct=joinpath(dir,"direct"); staged=joinpath(dir,"staged")
        @test_throws ArgumentError R.QCLScientificWorkflow.execute_scientific_plan(plan,direct)
        @test !ispath(direct)
        @test_throws ArgumentError R.execute_scientific_plan_staged(plan,staged)
        @test !ispath(staged)
    end
end
