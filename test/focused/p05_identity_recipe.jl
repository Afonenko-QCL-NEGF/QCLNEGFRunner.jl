using Test, QCLNEGFRunner
const R=QCLNEGFRunner; const W=R.QCLScientificWorkflow
@testset "point identity binds selected axes, branch and attempt" begin
    plan=resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    execution=only(plan.executions); point=only(plan.points)
    @test W._point_axis_inputs(point.temperature_K,point.voltage_per_period_V) == W._point_axis_inputs(point)
    identity=W._scientific_point_identity(plan,execution,point,2;run_id="run",plan_sha256=repeat("a",64))
    @test Set(keys(identity))==Set(["run_id","execution_id","point_id","attempt","branch_id","model_sha256","plan_sha256"])
    @test identity["attempt"]=="2"
    @test identity["model_sha256"]==W._point_passport(execution.configuration,point)["model_sha256"]
    @test identity["branch_id"]==R.QCLApplicationRuntime.content_id("branch",Dict("execution_id"=>point.execution_id,"branch"=>point.branch))
    @test_throws ArgumentError W._scientific_point_identity(plan,execution,point,0;run_id="run",plan_sha256=repeat("a",64))
    other=W.ScientificPoint(point.id,point.execution_id,point.temperature_K,point.voltage_per_period_V+0.001,point.branch,point.order,point.predecessor_id,point.initialization)
    @test_throws ArgumentError W._scientific_point_identity(plan,execution,other,2;run_id="run",plan_sha256=repeat("a",64))
    records=[Dict("path"=>"QCLNEGF/src/a.jl","bytes"=>1,"sha256"=>repeat("a",64))]
    sources=Dict("solver_source_files"=>records)
    expected=R.QCLApplicationRuntime.content_id("run",Dict("plan_fingerprint"=>plan.fingerprint,"source_files"=>records))
    @test W._scientific_run_id(plan,sources,nothing)==expected
    @test W._scientific_run_id(plan,sources,"coordinator-run")=="coordinator-run"
    @test_throws ArgumentError W._scientific_run_id(plan,Dict{String,Any}(),nothing)
end
@testset "scientific request binds frozen bytes and actual P03 point before solve" begin
    plan=resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    execution=only(plan.executions);point=only(plan.points)
    bytes=Vector{UInt8}(codeunits(sprint(write_scientific_plan,plan)))
    mktempdir() do root
        capture=W._freeze_scientific_plan(plan,root;frozen_plan_bytes=bytes)
        identity=W._scientific_point_identity(plan,execution,point,1;run_id="fixture-run",plan_sha256=capture.plan_sha256)
        missing()=Dict("state"=>"not_measured","reason"=>"fixture","evidence"=>nothing)
        status=Dict{String,Any}("process"=>Dict("state"=>"running","exit_code"=>nothing,"reason"=>nothing),
            (name=>missing() for name in ("convergence","physics","discretization","experimental"))...)
        graph=Dict("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),"components"=>Any[])
        dir=joinpath(root,"attempt");mkdir(dir)
        rec=R.ScientificHistoryRecorder(dir;artifact_root=root,identity,source_epoch="epoch",provenance=graph,status,maximum_scba_rows=3)
        roots=(;entry=(plan,execution,point),resources=(),construction=(),continuation=(),history=(rec,),observers=(),inputs_publication=(capture,status))
        @test isdefined(W,:_p05_prepare_scientific_request!)
        if isdefined(W,:_p05_prepare_scientific_request!)
            a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
            try
            prepared=W._p05_prepare_scientific_request!(rec,capture,execution.configuration,point;
                grant_bytes=512*1024^2,live_roots=roots,observer_admission=a)
            @test prepared.request.plan_ref["sha256"]==capture.plan_sha256
            @test read(joinpath(root,prepared.request.plan_ref["path"]))==bytes
            @test bytes2hex(R.SHA.sha256(R.canonical_bytes(prepared.model_preimage)))==identity["model_sha256"]
            @test !ispath(joinpath(dir,"current.json"))
            finally
                R._p05_end_observers!(a)
            end
        end
    end
end
@testset "scientific caller publishes P03 request before entering Core" begin
    source=read(joinpath(dirname(dirname(pathof(R))),"src/composition/scientific_execution.jl"),String)
    start=findfirst("function execute_scientific_plan(",source)
    @test start!==nothing
    if start!==nothing
        body=source[first(start):end]
        request=findfirst("_p05_prepare_scientific_request!(history_recorder",body)
        solve=findfirst("solve_adaptive_production(problem;",body)
        @test request!==nothing && solve!==nothing && first(request)<first(solve)
    end
end
@testset "final writer input keeps process and external evidence only" begin
    process=Dict{String,Any}("state"=>"succeeded","exit_code"=>nothing,"reason"=>nothing)
    prior=Dict{String,Any}(
        "discretization"=>Dict("state"=>"not_measured","reason"=>"not_established","evidence"=>nothing),
        "experimental"=>Dict("state"=>"not_measured","reason"=>"not_evaluated","evidence"=>nothing))
    @test isdefined(W,:_p05_final_status_input)
    if isdefined(W,:_p05_final_status_input)
        status=W._p05_final_status_input(process,prior)
        @test Set(keys(status))==Set(["process","discretization","experimental"])
        @test status["process"]["state"]=="succeeded"
        @test !haskey(status,"convergence") && !haskey(status,"physics")
        process["state"]="failed"; prior["experimental"]["reason"]="changed"
        @test status["process"]["state"]=="succeeded"
        @test status["experimental"]["reason"]=="not_evaluated"
    end
end

@testset "final status preserves nested external evidence without science inference" begin
    if isdefined(W,:_p05_final_status_input)
        process=Dict{String,Any}("state"=>"failed","exit_code"=>3,"reason"=>"fixture_failure")
        ref=Dict{String,Any}("path"=>"evidence/discretization.json","bytes"=>7,
            "sha256"=>repeat("a",64),"details"=>Dict("labels"=>["initial"]))
        prior=Dict{String,Any}(
            "discretization"=>Dict{String,Any}("state"=>"recorded","reason"=>nothing,"evidence"=>ref),
            "experimental"=>Dict{String,Any}("state"=>"not_measured","reason"=>"unknown","evidence"=>nothing),
            "physics"=>Dict("state"=>"pass"),"convergence"=>Dict("state"=>"pass"))
        status=W._p05_final_status_input(process,prior)
        @test Set(keys(status))==Set(["process","discretization","experimental"])
        @test status["process"]==process
        @test status["discretization"]["evidence"]==ref
        ref["details"]["labels"][1]="changed"
        @test status["discretization"]["evidence"]["details"]["labels"]==["initial"]
        status["process"]["reason"]="local"
        status["experimental"]["reason"]="local"
        @test process["reason"]=="fixture_failure"
        @test prior["experimental"]["reason"]=="unknown"
        @test_throws KeyError W._p05_final_status_input(process,Dict("discretization"=>prior["discretization"]))
    end
end

@testset "actual scientific final join selects returned problem and exact public port" begin
    source=read(joinpath(dirname(dirname(pathof(R))),"src/composition/scientific_execution.jl"),String)
    @test occursin("request=prepared_final_request.request",source)
    @test occursin("_p05_commit_final_with_presentation!(history_recorder,solution,terminal",source)
    @test !occursin("terminal_problem",source)
    @test !occursin("isempty(records) || write_stop_receipt",source)
    @test occursin("Q1 typed transport-close",source)
end
