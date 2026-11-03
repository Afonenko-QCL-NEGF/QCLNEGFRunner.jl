module P05StationaryNative5Path
using Test,QCLNEGFRunner,QCLNEGF,YAML,SHA,Unitful,LinearAlgebra
const R=QCLNEGFRunner
const W=R.QCLScientificWorkflow
const PACKET=get(ENV,"QCL_STATIONARY_TEST_OUTPUT",mktempdir(;cleanup=false))
const GRAPH=R._load_source_graph_file(ENV["QCL_STATIONARY_TEST_SOURCE_GRAPH"])
const ORIGIN=(calcjob_uuid="00000000-0000-4000-8000-000000000101",
    native_execution_uuid="00000000-0000-4000-8000-000000000102")

# Existing study-smoke remains an explicitly numerical program fixture. These
# tiny iteration stops do not modify the immutable full P26 research candidate.
function fixture(directory;change=d->nothing)
    base=joinpath(pkgdir(R),"test/fixtures/configurations/studies-smoke.yaml")
    definition=Dict{String,Any}("schema"=>"qcl-negf-study-v2","kind"=>"study",
        "id"=>"stationary-native5-program","purpose"=>"diagnostic","operation"=>"stationary",
        "configuration"=>Dict("sources"=>[base],"overrides"=>Dict(
            "physical"=>Dict("voltage_per_period"=>"0 mV"),
            "numerical"=>Dict("energy_min"=>"-0.5 eV","energy_max"=>"1.5 eV"),
            "solver"=>Dict("maximum_scba_iterations"=>2,"maximum_poisson_iterations"=>1),
            "production"=>Dict("worker_count"=>1,"parallel_backend"=>"blas","checkpoint_every_scba"=>0),
            "execution"=>Dict("strategy"=>"manual","julia_threads"=>2,"blas_threads"=>1))),
        "variants"=>[Dict("id"=>"baseline","method_id"=>"configured")],
        "axes"=>Dict("temperatures"=>Dict("values"=>[70],"unit"=>"K"),
            "voltages"=>Dict("values"=>[0],"unit"=>"mV")),
        "policies"=>Dict("scba_to_poisson"=>"adaptive_working","voltage"=>Dict("mode"=>"independent","invalid_predecessor"=>"stop_branch")),
        "output"=>Dict("archive"=>Dict("full_final"=>true,"optical"=>false),
            "telemetry"=>Dict("enabled"=>false),"recovery"=>Dict("enabled"=>true,"reserve_bytes"=>0)))
    change(definition)
    mkpath(directory);path=joinpath(directory,"study.yaml");YAML.write_file(path,definition)
    plan=resolve_scientific_plan(path;maximum_solver_runs=4)
    buffer=IOBuffer();write_scientific_plan(buffer,plan);bytes=take!(buffer)
    write(joinpath(directory,"plan.json"),bytes)
    (;plan,bytes)
end

mutable struct ForeignMutableCapture
    bytes::Vector{UInt8}
end
@testset "deadline remains a counted closed caller resident" begin
    a=R._p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
    try
        roots=(;entry=(),resources=(),construction=(),continuation=(),history=(),observers=(),inputs_publication=())
        with_clock=merge(roots,(;inputs_publication=(R.CheckpointDeadline(;interval_seconds=1800),)))
        grant=64*1024^2
        @test R._p05_input_metadata_limit(grant,with_clock;observer_admission=a)<
            R._p05_input_metadata_limit(grant,roots;observer_admission=a)
        foreign=merge(roots,(;inputs_publication=(ForeignMutableCapture(UInt8[1]),)))
        @test_throws ArgumentError R._p05_input_metadata_limit(grant,foreign;observer_admission=a)
    finally
        R._p05_end_observers!(a)
    end
end

@testset "ordinary actual Core return owns nonconverged native5 final" begin
    inputs=joinpath(PACKET,"inputs");f=fixture(inputs)
    output=joinpath(PACKET,"original-result")
    result=R.execute_scientific_plan(f.plan,output;execution_id=only(f.plan.executions).id,
        frozen_plan_bytes=f.bytes,source_graph=GRAPH,native_origin=ORIGIN)
    @test result["schema"]=="qcl-negf-series-result-v4"
    # The consumer sees the original emitted wire, not internal Symbol fields.
    result=R._p04_parse(read(joinpath(output,"series_result.json"),String))
    point=only(result["points"]);source=point["data"]["native_source"]
    @test point["status"]=="completed"
    @test point["converged"]===false
    @test source["kind"]=="final" && source["relation"]=="current_point_attempt"
    @test source["selected_state"]["identity"]["point_id"]==only(f.plan.points).id
    @test source["selected_state"]["identity"]["model_sha256"]==
        W._point_passport(only(f.plan.executions).configuration,only(f.plan.points))["model_sha256"]
    opened=R.open_exact_checkpoint(output,source["selected_state"];maximum_metadata_bytes=1024^3)
    final=R.verify_final_artifacts(opened;diagnostics_ref=source["diagnostics"],
        observations_ref=source["observations"],maximum_metadata_bytes=1024^3)
    @test final.observations==source["observations"]
    declaration=R._p04_parse(opened.declaration_json)
    @test startswith(declaration["invocation"]["source_epoch"],"c1-")
    observed=R._p05_read_analysis(output,source["observations"],declaration["identity"],
        declaration["invocation"],"final_observations",Ref(1024^3))
    @test observed["source_mode"]=="produced"
    @test observed["context"]["inputs"]["V_period_V"]==Dict("kind"=>"ieee","type"=>"f64","bits"=>"0000000000000000")
    @test observed["context"]["inputs"]["T_L_K"]==Dict("kind"=>"ieee","type"=>"f64","bits"=>"4051800000000000")
    @test observed["context"]["inputs"]["T_LO_K"]==Dict("kind"=>"ieee","type"=>"f64","bits"=>"4051800000000000")
    @test observed["summary"]["converged"]===false
    @test observed["request"]["temperature_K"]==Dict("kind"=>"ieee","type"=>"f64","bits"=>"4051800000000000")
    @test observed["request"]["voltage_per_period_V"]==Dict("kind"=>"ieee","type"=>"f64","bits"=>"0000000000000000")
    @test read(joinpath(output,observed["request"]["plan"]["path"]))==f.bytes
    @test isfile(joinpath(output,"native-selection.json"))
    @test R._p05_verify_native_result(output,result,1024^3)===nothing
    write(joinpath(PACKET,"original-source.json"),R._p04_json(source))
    println("STATIONARY_ORIGINAL_ROOT=",output)
end
@testset "unsupported stationary operands refuse before scientific point output" begin
    changes=[
        "optical"=>(d->(d["output"]["archive"]["optical"]=true)),
        "multipoint"=>(d->(d["axes"]["voltages"]["values"]=[0,1])),
        "adaptive"=>(d->(d["configuration"]["overrides"]["domain_adaptation"]=Dict("mode"=>"expand_energy_window"))),
        "educational"=>(d->begin
            d["configuration"]["overrides"]["execution"]["solver_backend"]="educational"
            d["configuration"]["overrides"]["algorithms"]=Dict("energy_shift"=>"dense","hilbert"=>"direct")
        end)]
    for (name,change) in changes
        f=fixture(joinpath(PACKET,"unsupported-"*name);change)
        output=joinpath(PACKET,"refused-"*name)
        @test_throws ArgumentError R.execute_scientific_plan(f.plan,output;
            execution_id=first(f.plan.executions).id,frozen_plan_bytes=f.bytes,source_graph=GRAPH,native_origin=ORIGIN)
        @test !ispath(output)
    end
    f=fixture(joinpath(PACKET,"closed-operands"))
    for (name,extra) in (("no-origin",(;native_origin=nothing)),("attempt-two",(;attempt=2)),
            ("import",(;archive_bundle="not-an-import-authority")),("no-original-plan",(;frozen_plan_bytes=nothing)))
        output=joinpath(PACKET,"refused-"*name)
        args=merge((;execution_id=only(f.plan.executions).id,frozen_plan_bytes=f.bytes,source_graph=GRAPH,native_origin=ORIGIN),extra)
        @test_throws ArgumentError R.execute_scientific_plan(f.plan,output;args...)
        @test !ispath(output)
    end
    reused=joinpath(PACKET,"reused");mkdir(reused);write(joinpath(reused,"series_result.json"),"original nonparseable marker")
    @test_throws ArgumentError R.execute_scientific_plan(f.plan,reused;execution_id=only(f.plan.executions).id,
        frozen_plan_bytes=f.bytes,source_graph=GRAPH,native_origin=ORIGIN)
    @test read(joinpath(reused,"series_result.json"),String)=="original nonparseable marker"
    @test !ispath(joinpath(reused,"executions"))
end

end
