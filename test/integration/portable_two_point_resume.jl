module PortableTwoPointResume
include("../support/common.jl")
using YAML, SHA
const R=QCLNEGFRunner
@testset "Portable resume keeps a completed first point and the original second-point budget" begin
    base=joinpath(TEST_ROOT,"fixtures","configurations","studies-smoke.yaml")
    mktempdir() do workspace
        definition=Dict{String,Any}("schema"=>"qcl-negf-study-v2","kind"=>"study","id"=>"portable-two-point",
            "purpose"=>"diagnostic","configuration"=>Dict("sources"=>[base],"overrides"=>Dict(
                "numerical"=>Dict("energy_min"=>"-0.5 eV","energy_max"=>"1.5 eV"),
                "solver"=>Dict("maximum_scba_iterations"=>2,"maximum_poisson_iterations"=>1),
                "production"=>Dict("worker_count"=>1,"parallel_backend"=>"blas","checkpoint_every_scba"=>0),
                "execution"=>Dict("strategy"=>"manual"))),
            "axes"=>Dict("temperatures"=>Dict("values"=>[70],"unit"=>"K"),"voltages"=>Dict("values"=>[50,56],"unit"=>"mV")),
            "policies"=>Dict("voltage"=>Dict("mode"=>"strict","invalid_predecessor"=>"cold_start")),
            "output"=>Dict("archive"=>Dict("full_final"=>true,"optical"=>false),"recovery"=>Dict("reserve_bytes"=>0)))
        path=joinpath(workspace,"study.yaml")
        YAML.write_file(path,definition)
        plan=resolve_scientific_plan(path)
        execution=only(plan.executions)
        source=joinpath(workspace,"source")
        second=last(plan.points)
        R.request_pause(source,execution.id,1;point_id=second.id)
        paused=YAML.load(sprint(R._light_json,execute_scientific_plan(plan,source;execution_id=execution.id,attempt=1));dicttype=Dict{String,Any})
        if first(paused["points"])["status"]!="completed"
            println("Unexpected first-point status: ",sprint(R._light_json,first(paused["points"])))
        end
        @test paused["status"]=="paused"
        @test first(paused["points"])["status"]=="completed"
        @test last(paused["points"])["status"]=="paused"
        first_state=joinpath(source,first(paused["points"])["data"]["full_state"])
        first_hash=bytes2hex(open(sha256,first_state))
        @test R.verify_pause_receipt(source,execution.id,1)["status"]=="paused"
        saved_state=joinpath(workspace,"saved-prior-physics.h5")
        mv(first_state,saved_state)
        try
            @test_throws ArgumentError R.verify_stop_receipt(source,execution.id,1)
        finally
            mv(saved_state,first_state)
        end
        cp(first_state,saved_state)
        write(first_state,"corrupted prior final")
        try
            @test_throws ArgumentError R.verify_pause_receipt(source,execution.id,1)
            @test_throws ArgumentError R.verify_stop_receipt(source,execution.id,1)
        finally
            mv(saved_state,first_state;force=true)
        end
        bundle=dirname(joinpath(source,last(paused["points"])["data"]["result_commit"]))
        mktempdir() do copied
            cp(bundle,joinpath(copied,"recovery"))
            cp(joinpath(source,"archive"),joinpath(copied,"archive"))
            rm(source;recursive=true)
            output=joinpath(workspace,"resumed")
            @test_throws ArgumentError execute_scientific_plan(plan,joinpath(workspace,"missing-archive");execution_id=execution.id,attempt=2,
                recovery_bundle=joinpath(copied,"recovery"))
            resumed=YAML.load(sprint(R._light_json,execute_scientific_plan(plan,output;execution_id=execution.id,attempt=2,
                recovery_bundle=joinpath(copied,"recovery"),archive_bundle=copied));dicttype=Dict{String,Any})
            @test first(resumed["points"])["attempt"]==1
            @test first(resumed["points"])["status"]=="completed"
            @test bytes2hex(open(sha256,joinpath(output,first(resumed["points"])["data"]["full_state"])))==first_hash
            @test last(resumed["points"])["attempt"]==2
            @test last(resumed["points"])["initialization"]["kind"]=="checkpoint"
            @test last(resumed["points"])["status"]=="completed"
            commit=R.verify_point_artifacts(joinpath(output,last(resumed["points"])["data"]["result_commit"]))
            @test commit["restart_coordinates"]["last_inner"]<=2
            @test commit["restart_coordinates"]["last_completed_outer"]<=1
            @test !commit["scientific_accepted"]
            @test R.verify_stop_receipt(output,execution.id,2)["status"]=="completed_with_warnings"
            terminal=deepcopy(resumed)
            pop!(terminal["points"])
            R.QCLScientificWorkflow._scientific_json(joinpath(output,"series_result.json"),terminal)
            stop=YAML.load_file(joinpath(output,"stop-receipt.json");dicttype=Dict{String,Any})
            stop["result_sha256"]=bytes2hex(open(sha256,joinpath(output,"series_result.json")))
            R.QCLScientificWorkflow._scientific_json(joinpath(output,"stop-receipt.json"),stop)
            @test_throws ArgumentError R.verify_stop_receipt(output,execution.id,2)
        end
    end
end
end
