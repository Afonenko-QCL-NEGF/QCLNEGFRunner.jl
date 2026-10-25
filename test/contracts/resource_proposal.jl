module ResourceProposalContract
using Test, SHA, LinearAlgebra, QCLNEGFRunner
const W=QCLNEGFRunner.QCLScientificWorkflow
json(x)=sprint(io->QCLNEGFRunner._light_json(io,x))

function policy_raw(;plan_sha256="a"^64,extra...)
    merge(Dict{String,Any}("schema"=>"qcl-negf-runtime-margin-policy-v1","policy_id"=>"fixture-margin",
        "runner_source_id"=>"runner-fixture","core_source_id"=>"core-fixture","runtime_id"=>"runtime-fixture",
        "plan_sha256"=>plan_sha256,"maximum_solver_threads"=>12,"maximum_hard_memory_bytes"=>64*1024^3,
        "coverage_contract"=>"disjoint_non_numerical_v1","runtime_upper_bytes"=>60,
        "allocator_retention_upper_bytes"=>20,"confidence"=>"approved_conservative_uncalibrated",
        "approval_ref"=>"synthetic-only-not-production","calibration_ref"=>nothing),Dict(String(k)=>v for (k,v) in extra))
end
function installed_policy(directory,raw)
    path=joinpath(directory,"policy.json");write(path,json(raw));chmod(path,0o444)
    sha=bytes2hex(sha256(read(path)))
    W._resource_load_policy(path,sha,"runtime-fixture","runner-fixture","core-fixture"),
        Dict{String,Any}("policy_id"=>raw["policy_id"],"policy_sha256"=>sha),path
end
hardware(total,available=total;threads=2)=QCLNEGFRunner.HardwareProfile(
    threads,threads,total,available,"synthetic",total,total,total,0,threads,Float64(threads),"","fixture","fixture")
function unavailable_detail(f)
    error=try f();nothing catch failure;failure end
    @test error isa W.ResourceForecastUnavailable
    return error isa W.ResourceForecastUnavailable ? error.detail : nothing
end

@testset "literal auto manual envelope boundaries share the runtime budget" begin
    mktempdir() do directory
        trusted,selector,path=installed_policy(directory,policy_raw())
        automatic=QCLNEGFRunner.AutomaticExecutionConfiguration(0.1,80,0.05,12,4,32,8,8,4,8,2)
        config=(execution=(strategy=:auto_exact,automatic=automatic),)
        h=hardware(1000)
        rp=(memory_budget_bytes=900,)
        fit=W._resource_margin_budget(config,rp,h,trusted;numerical_required_bytes=900)
        @test fit["numerical_budget_bytes"]==900
        @test fit["generic_reserve_bytes"]==100
        @test fit["non_numerical_upper_bytes"]==80
        @test fit["numerical_headroom_bytes"]==0
        @test fit["unassigned_generic_reserve_bytes"]==20
        @test unavailable_detail(()->W._resource_margin_budget(config,rp,h,trusted;numerical_required_bytes=901))=="numerical_does_not_fit"
        fit=W._resource_margin_budget(config,(memory_budget_bytes=850,),hardware(1000,950),trusted;numerical_required_bytes=850)
        @test fit["numerical_budget_bytes"]==850
        @test fit["generic_reserve_bytes"]==100
        chmod(path,0o644)
        larger,_,_=installed_policy(directory,policy_raw(runtime_upper_bytes=90,allocator_retention_upper_bytes=30))
        @test unavailable_detail(()->W._resource_margin_budget(config,rp,h,larger;numerical_required_bytes=850))=="margin_not_covered"
        manual=(execution=(strategy=:manual,automatic=automatic),)
        fit=W._resource_margin_budget(manual,(memory_budget_bytes=920,),h,trusted;numerical_required_bytes=920)
        @test fit["numerical_budget_bytes"]==920
        @test fit["generic_reserve_bytes"]==0
        @test fit["boundary"]=="standalone_manual"
        @test unavailable_detail(()->W._resource_margin_budget(manual,(memory_budget_bytes=921,),h,trusted;numerical_required_bytes=100))=="manual_margin_does_not_fit"
        envelope=QCLNEGFRunner.ExecutionEnvelope("fixture",900,60,20,1000,2,[0,1])
        fit=W._resource_margin_budget(config,rp,h,trusted;envelope,numerical_required_bytes=900)
        @test fit["numerical_budget_bytes"]==900
        @test fit["generic_reserve_bytes"]==0
        @test fit["unassigned_generic_reserve_bytes"]===nothing
        @test fit["boundary"]=="explicit_envelope"
        @test fit["envelope"]["hard_memory_bytes"]==1000
        chmod(path,0o644)
        wrong,_,_=installed_policy(directory,policy_raw(runtime_upper_bytes=61,allocator_retention_upper_bytes=19))
        @test unavailable_detail(()->W._resource_margin_budget(config,rp,h,wrong;envelope,numerical_required_bytes=900))=="runtime_partition_undercovered"
        @test unavailable_detail(()->W._resource_margin_budget(config,rp,hardware(1000;threads=13),trusted;numerical_required_bytes=1))=="margin_policy_scope_exceeded"
        @test unavailable_detail(()->W._resource_margin_budget(config,rp,hardware(65*1024^3),trusted;numerical_required_bytes=1))=="margin_policy_scope_exceeded"
    end
end

@testset "installed policy authority is exact bounded and never a request amount" begin
    mktempdir() do directory
        trusted,selector,path=installed_policy(directory,policy_raw())
        binding=(plan_sha256="a"^64,runner_source_id="runner-fixture",core_source_id="core-fixture",runtime_id="runtime-fixture")
        @test W._resource_entry_policy((trusted_policy=trusted,entry_binding=binding))===trusted
        @test_throws Exception W._resource_entry_policy((trusted_policy=trusted,entry_binding=merge(binding,(plan_sha256="b"^64,))))
        @test_throws Exception W._resource_entry_policy((trusted_policy=trusted,))
        @test_throws Exception W._resource_load_policy(path,"0"^64,"runtime-fixture","runner-fixture","core-fixture")
        @test_throws Exception W._resource_load_policy(path,selector["policy_sha256"],"foreign-runtime","runner-fixture","core-fixture")
        link=joinpath(directory,"symlink.json");symlink(path,link)
        @test_throws Exception W._resource_load_policy(link,selector["policy_sha256"],"runtime-fixture","runner-fixture","core-fixture")
        for raw in (policy_raw(runtime_upper_bytes=0),policy_raw(runtime_upper_bytes=true),
                    policy_raw(runtime_upper_bytes=1.0),policy_raw(coverage_contract="partial_overlap"),
                    policy_raw(runtime_upper_bytes=typemax(Int),allocator_retention_upper_bytes=1),
                    policy_raw(confidence="calibrated_within_scope"),policy_raw(approval_ref="bad\nref"))
            chmod(path,0o644)
            @test_throws Exception installed_policy(directory,raw)
        end
    end
end

@testset "finite CPU descent uses literal byte fit without reserve duplication" begin
    calls=Int[]
    forecast(c)=begin
        push!(calls,c)
        # Independent tiny components: numerical 100 + 10 bytes per worker;
        # trusted boundary already withholds 30 from the 150-byte grant.
        (peak_bytes=100+10c, numerical_budget_bytes=120)
    end
    chosen=W._resource_choose(4,forecast)
    @test chosen.requested_solver_threads==2
    @test chosen.peak_bytes==120
    @test calls==[4,3,2]
    @test W._resource_choose(1,c->(peak_bytes=121,numerical_budget_bytes=120))===nothing
    @test W._resource_choose(0,forecast)===nothing
    for invalid in (true,0.5,257,-1)
        @test_throws Exception W._resource_choose(invalid,forecast)
    end
    @test_throws Exception W._resource_choose(1,c->(peak_bytes=true,numerical_budget_bytes=120))
    @test_throws Exception W._resource_choose(1,c->(peak_bytes=NaN,numerical_budget_bytes=120))
end

@testset "explicit estimator capacity and runtime reservation retain defaults" begin
    config=load_run_configuration(joinpath(@__DIR__,"..","fixtures","configurations","studies-smoke.yaml"))
    repository=W.FilesystemScientificDefinitions()
    @test W.scientific_memory_estimate(repository,config)==
          W.scientific_memory_estimate(repository,config;worker_capacity=Sys.CPU_THREADS)
    for invalid in (true,0,0.5,-1)
        @test_throws ArgumentError W.scientific_memory_estimate(repository,config;worker_capacity=invalid)
    end
    required=W.scientific_memory_estimate(repository,config;worker_capacity=2)
    components=QCLNEGFRunner.estimate_production_memory(config.numerical,4;
        dense_mechanism_count=4,options=config.production,worker_capacity=2)
    # Three-state Dyson work per simultaneous worker: two 3x3 complex
    # matrices, 64 complex work vectors and four BLAS integer pivots.
    @test components.breakdown[:dyson_inverse_workspace]==2*(288+3072+4*sizeof(LinearAlgebra.BlasInt))
    resource_plan=(memory_budget_bytes=typemax(Int),
        hardware=(total_memory_bytes=typemax(Int),available_memory_bytes=typemax(Int),julia_threads=12,logical_cpus=2))
    @test W._scientific_memory_reservation(config,resource_plan,nothing)["estimated_peak_bytes"]==required
    @test W._scientific_memory_reservation(config,resource_plan,nothing)["worker_capacity"]==2
end

@testset "exact frozen bytes and installed source identities precede forecast" begin
    plan=resolve_scientific_plan(joinpath(@__DIR__,"..","fixtures","configurations","resource-proposal-study.yaml"))
    raw=sprint(io->write_scientific_plan(io,plan))
    # Snapshot the exact UTF-8 bytes as a String for the JSON/SHA oracles.
    original=String(collect(codeunits(raw)))
    target=Dict("logical_cpu_limit"=>12,"memory_limit_bytes"=>28*1024^3,
        "available_memory_bytes"=>26*1024^3,"affinity_limit"=>12,
        "quota_full_cpu_limit"=>12,"resource_policy_id"=>"fixture-net-capacity")
    request=Dict{String,Any}("plan"=>raw,"plan_sha256"=>bytes2hex(sha256(raw)),
        "expected_runner_source_id"=>"runner-fixture","expected_core_source_id"=>"core-fixture",
        "target"=>target,"candidate_cpu_max"=>12,"runtime_margin_policy"=>nothing)
    result=W.resource_proposal(json(request),"runner-fixture","core-fixture")
    @test result["status"]=="unavailable"
    @test result["reasons"]==["memory_forecast_unavailable"]
    @test result["launch_allowed"]===false
    @test result["allocated_cpus_upper"]===nothing
    @test result["allocation_width_binding"]=="unavailable"
    @test result["plan_sha256"]==bytes2hex(sha256(raw))
    @test raw==original
    @test json(W._configurator_json(raw;maximum=4*1024^2))==json(W._configurator_json(original;maximum=4*1024^2))
    for key in ("plan_sha256","expected_runner_source_id","expected_core_source_id")
        bad=deepcopy(request);bad[key]="foreign"
        @test W.resource_proposal(json(bad),"runner-fixture","core-fixture")["status"]=="error"
    end
    bad=deepcopy(request);bad["plan"]=raw*"\n"
    @test W.resource_proposal(json(bad),"runner-fixture","core-fixture")["status"]=="error"
    bad=deepcopy(request);bad["target"]["quota_full_cpu_limit"]=0.5
    @test W.resource_proposal(json(bad),"runner-fixture","core-fixture")["status"]=="unavailable"
    for invalid in (true,0,257)
        bad=deepcopy(request);bad["candidate_cpu_max"]=invalid
        @test W.resource_proposal(json(bad),"runner-fixture","core-fixture")["status"]=="error"
    end
    mktempdir() do directory
        trusted,selector,path=installed_policy(directory,policy_raw(plan_sha256=bytes2hex(sha256(raw))))
        approved=deepcopy(request);approved["runtime_margin_policy"]=selector
        result=W.resource_proposal(json(approved),"runner-fixture","core-fixture";trusted_policy=trusted,runtime_id="runtime-fixture")
        @test result["status"]=="available"
        @test result["requested_solver_threads"]==12
        @test result["memory_limit_bytes"]==26*1024^3
        @test result["launch_allowed"]===false
        @test result["allocated_cpus_upper"]===nothing
        @test result["plan_sha256"]==bytes2hex(sha256(original))
        before=W._configurator_json(original;maximum=4*1024^2)
        @test result["plan_fingerprint"]==before["fingerprint"]
        @test result["plan_scientific_fingerprint"]==before["scientific_fingerprint"]
        @test raw==original
        @test !isempty(result["point_forecasts"])
        @test all(p->p["margin"]["generic_reserve_bytes"]>=80,result["point_forecasts"])
        foreign=deepcopy(approved);foreign["runtime_margin_policy"]["policy_sha256"]="0"^64
        @test W.resource_proposal(json(foreign),"runner-fixture","core-fixture";trusted_policy=trusted,runtime_id="runtime-fixture")["status"]=="unavailable"
        forged=deepcopy(approved);forged["runtime_margin_policy"]["runtime_upper_bytes"]=1
        @test W.resource_proposal(json(forged),"runner-fixture","core-fixture";trusted_policy=trusted,runtime_id="runtime-fixture")["status"]=="error"
        @test W.resource_proposal(json(approved),"runner-fixture","core-fixture")["status"]=="unavailable"
        # Installed CLI suffix reads its own immutable authority; it never
        # accepts a browser file path or approval flag from stdin.
        input=joinpath(directory,"approved.json");output=joinpath(directory,"approved-response.json")
        write(input,json(approved))
        status=open(input) do source
            open(output,"w") do destination
                redirect_stdin(source) do
                    redirect_stdout(destination) do
                        QCLNEGFRunner.main(["resource-proposal","--runner-source-id","runner-fixture","--core-source-id","core-fixture",
                            "--runtime-id","runtime-fixture","--margin-policy-file",path,"--margin-policy-sha256",selector["policy_sha256"]])
                    end
                end
            end
        end
        @test status==0
        delivered=W._configurator_json(read(output,String);maximum=1024^2)
        @test delivered["status"]=="available"
        @test delivered["launch_allowed"]===false
        config=only(W.load_scientific_plan(before).executions).configuration
        candidate=W._resource_candidate(config,hardware(28*1024^3;threads=2),trusted)
        context=(trusted_policy=trusted,entry_binding=(plan_sha256=bytes2hex(sha256(original)),
            runner_source_id="runner-fixture",core_source_id="core-fixture",runtime_id="runtime-fixture"))
        reservation=W._scientific_memory_reservation(candidate.configuration,candidate.resource_plan,nothing;margin_context=context)
        @test reservation["worker_capacity"]==2
        @test reservation["margin"]==candidate.margin
        @test unavailable_detail(()->W._scientific_memory_reservation(candidate.configuration,candidate.resource_plan,nothing;
            margin_context=(trusted_policy=trusted,)))=="margin_context_invalid"
    end
    mktempdir() do directory
        input=joinpath(directory,"request.json");output=joinpath(directory,"response.json")
        write(input,json(request))
        status=open(input) do source
            open(output,"w") do destination
                redirect_stdin(source) do
                    redirect_stdout(destination) do
                        QCLNEGFRunner.main(["resource-proposal","--runner-source-id","runner-fixture","--core-source-id","core-fixture"])
                    end
                end
            end
        end
        @test status==2
        delivered=W._configurator_json(read(output,String);maximum=1024^2)
        @test delivered["plan_sha256"]==bytes2hex(sha256(raw))
        @test delivered["reasons"]==["memory_forecast_unavailable"]
        @test delivered["launch_allowed"]===false
    end
end

@testset "actual manual scheduling is preserved or refused without rewriting" begin
    base=load_run_configuration(joinpath(@__DIR__,"..","fixtures","configurations","studies-smoke.yaml"))
    raw=resolved_configuration_dict(base)
    raw["execution"]["strategy"]="manual"
    raw["production"]["worker_count"]=2
    parsed=QCLNEGFRunner._resolve_configuration(raw,base.provenance)
    options=QCLNEGFRunner.with_production_options(parsed.production;memory_budget_bytes=4*1024^3)
    config=typeof(parsed)((name===:production ? options : getfield(parsed,name) for name in fieldnames(typeof(parsed)))...)
    saved=deepcopy(config.raw)
    mktempdir() do directory
        trusted,_,_=installed_policy(directory,policy_raw())
        candidate=W._resource_candidate(config,hardware(28*1024^3;threads=2),trusted)
        @test candidate.configuration.raw==saved
        @test candidate.margin["boundary"]=="standalone_manual"
        @test candidate.margin["numerical_budget_bytes"]==4*1024^3
        bad=deepcopy(raw);bad["execution"]["blas_threads"]=2
        incompatible=QCLNEGFRunner._resolve_configuration(bad,base.provenance)
        @test_throws Exception W._resource_candidate(incompatible,hardware(28*1024^3;threads=2),trusted)
        @test incompatible.raw["execution"]["blas_threads"]==2
    end
end

@testset "actual raw entry A cannot cover independently frozen typed plan B" begin
    fixture=joinpath(@__DIR__,"..","fixtures","configurations","resource-proposal-study.yaml")
    plan_a=resolve_scientific_plan(fixture)
    raw_a=sprint(io->write_scientific_plan(io,plan_a))
    mktempdir() do directory
        definition=QCLNEGFRunner.YAML.load_file(fixture;dicttype=Dict{String,Any})
        definition["configuration"]["sources"]=[normpath(joinpath(dirname(fixture),"../research-inputs/model/reference-2019-70k.yaml"))]
        definition["axes"]["voltages"]["values"]=[1]
        path_b=joinpath(directory,"definition-b.json");write(path_b,json(definition))
        plan_b=resolve_scientific_plan(path_b)
        @test only(plan_a.points).voltage_per_period_V==0
        @test only(plan_b.points).voltage_per_period_V==0.001
        @test plan_a.fingerprint!=plan_b.fingerprint
        trusted,_,_=installed_policy(directory,policy_raw(plan_sha256=bytes2hex(sha256(raw_a))))
        entry=W._resource_bind_entry(raw_a,trusted,"runner-fixture","core-fixture","runtime-fixture")
        healthy=W._resource_execution_plan(plan_a,entry)
        @test healthy.fingerprint==plan_a.fingerprint
        @test bytes2hex(sha256(entry.raw_plan))==bytes2hex(sha256(raw_a))
        @test raw_a==sprint(io->write_scientific_plan(io,plan_a))
        @test unavailable_detail(()->W._resource_execution_plan(plan_b,entry))=="margin_plan_mismatch"
        destination=joinpath(directory,"must-not-exist")
        # attempt0 is a trap after mkdir and before storage/preparation/arrays.
        # A regression past binding fails this oracle without ever solving.
        @test unavailable_detail(()->execute_scientific_plan(plan_b,destination;margin_context=entry,attempt=0))=="margin_plan_mismatch"
        @test !ispath(destination)
        supplied=(trusted_policy=trusted,entry_binding=(plan_sha256=bytes2hex(sha256(raw_a)),
            runner_source_id="runner-fixture",core_source_id="core-fixture",runtime_id="runtime-fixture"))
        @test unavailable_detail(()->execute_scientific_plan(plan_a,destination;margin_context=supplied,attempt=0))=="actual_raw_entry_required"
        @test !ispath(destination)
        @test unavailable_detail(()->W._resource_bind_entry(raw_a*"\n",trusted,"runner-fixture","core-fixture","runtime-fixture"))=="margin_policy_entry_mismatch"
        @test unavailable_detail(()->W._resource_bind_entry(raw_a,trusted,"foreign-runner","core-fixture","runtime-fixture"))=="margin_policy_entry_mismatch"
        @test unavailable_detail(()->W._resource_bind_entry(raw_a,trusted,"runner-fixture","core-fixture","foreign-runtime"))=="margin_policy_entry_mismatch"
    end
end
end
