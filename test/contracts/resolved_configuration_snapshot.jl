module ResolvedConfigurationSnapshotContracts
using Test, QCLNEGFRunner, YAML, Unitful
const W = QCLNEGFRunner.QCLScientificWorkflow
const BASE = normpath(joinpath(@__DIR__, "..", "fixtures", "research-inputs", "model", "reference-2019-70k.yaml"))

@testset "Public resolved configuration contract exists" begin
    for name in (:resolved_configuration_snapshot, :resolved_snapshot_dict,
                 :resolved_configuration_diff, :scientific_resource_estimate)
        @test isdefined(QCLNEGFRunner, name)
    end
end

if isdefined(QCLNEGFRunner, :resolved_configuration_snapshot)
@testset "Frozen plan binds full resolved and point identities" begin
    plan=resolve_scientific_plan(joinpath(@__DIR__,"..","fixtures","configurations","resource-proposal-study.yaml"))
    frozen=scientific_plan_dict(plan)
    @test get(frozen,"resolved_snapshot_schema",nothing)=="qcl-negf-resolved-configuration-v1"
    @test haskey(only(frozen["executions"]),"resolved_snapshot")
    resources_only=deepcopy(frozen)
    only(resources_only["nodes"])["estimated_memory_bytes"]+=1
    @test W._scientific_fingerprint(resources_only)==frozen["scientific_fingerprint"]
    @test W._plan_fingerprint(resources_only)!=frozen["fingerprint"]
    if haskey(only(frozen["executions"]),"resolved_snapshot")
        @test load_scientific_plan(frozen).fingerprint==plan.fingerprint
        point=only(frozen["points"])
        config=only(plan.executions).configuration
        point_raw=resolved_configuration_dict(config)
        point_raw["physical"]["voltage_per_period"]="0.0 V"
        point_config=QCLNEGFRunner._resolve_configuration(point_raw,config.provenance)
        @test point["effective_inputs"]["model_sha256"]==
            resolved_snapshot_dict(resolved_configuration_snapshot(point_config))["model_binding"]["sha256"]
        # The execution template still has its original bias; it is not the point passport.
        @test point["effective_inputs"]["model_sha256"]!=
            only(frozen["executions"])["resolved_snapshot"]["model_binding"]["sha256"]
        bad=deepcopy(frozen)
        only(bad["executions"])["resolved_snapshot"]["sections"]["numerical"]["used"]["N_E"]=3
        bad["fingerprint"]=W._plan_fingerprint(bad)
        @test_throws ArgumentError load_scientific_plan(bad)
        grant=deepcopy(frozen)
        only(grant["executions"])["resource_estimate"]["admitted_memory_bytes"]=1
        grant["fingerprint"]=W._plan_fingerprint(grant)
        @test_throws ArgumentError load_scientific_plan(grant)
        missing=deepcopy(frozen);delete!(missing,"resolved_snapshot_schema")
        missing["fingerprint"]=W._plan_fingerprint(missing)
        @test_throws ArgumentError load_scientific_plan(missing)
        # Model identity remains stable for an equivalent explicit default in raw.
        config=only(plan.executions).configuration
        raw=resolved_configuration_dict(config);raw["domain_adaptation"]=Dict{String,Any}("maximum_expansions"=>2)
        equivalent=QCLNEGFRunner._resolve_configuration(raw,config.provenance)
        @test resolved_snapshot_dict(resolved_configuration_snapshot(equivalent))["model_binding"]==
            only(frozen["executions"])["resolved_snapshot"]["model_binding"]
        equivalent_frozen=deepcopy(frozen)
        only(equivalent_frozen["executions"])["resolved_snapshot"]=
            resolved_snapshot_dict(resolved_configuration_snapshot(equivalent))
        @test W._scientific_fingerprint(equivalent_frozen)==frozen["scientific_fingerprint"]
        mktempdir() do dir
            field_raw=resolved_configuration_dict(config)
            field_raw["physical"]["voltage_per_period"]=nothing
            field_raw["physical"]["field_bias"]="1.0e7 V/m"
            config_path=joinpath(dir,"field.yaml");YAML.write_file(config_path,field_raw)
            recipe=Dict("schema"=>"qcl-negf-study-v2","kind"=>"study","id"=>"field-input",
                "operation"=>"operator_algebra","configuration"=>Dict("sources"=>[config_path]),
                "axes"=>Dict("temperatures"=>Dict("values"=>[70],"unit"=>"K"),
                    "voltages"=>Dict("values"=>[0],"unit"=>"mV")))
            path=joinpath(dir,"study.yaml");YAML.write_file(path,recipe)
            @test_nowarn resolve_scientific_plan(path)
        end
    end
end
@testset "Resolved typed values, origins, semantic identity and ownership" begin
    mktempdir() do dir
        function resolve(name, raw)
            path=joinpath(dir,name*".yaml"); YAML.write_file(path,raw)
            return load_run_configuration(path)
        end
        a=load_run_configuration(BASE)
        sa=resolved_configuration_snapshot(a); da=resolved_snapshot_dict(sa)
        metadata_only=deepcopy(a)
        metadata_only.raw["run"]["name"]="mutated-raw-name"
        @test_throws ConfigurationError resolved_configuration_snapshot(metadata_only)
        @test da["sections"]["physical"]["used"]["Tᴸ"]==Dict("value"=>70.0,"unit"=>"K")
        @test da["sections"]["scattering"]["used"]["LO"]===true
        @test da["sections"]["domain_adaptation"]["used"]["maximum_expansions"]==2
        @test haskey(da["sections"]["algorithms"]["input_assigning_histories"],"execution.solver_backend")
        @test haskey(da["sections"]["production"]["input_assigning_histories"],"execution.solver_backend")
        raw=resolved_configuration_dict(a); raw["domain_adaptation"]=Dict{String,Any}("maximum_expansions"=>2)
        b=resolve("explicit",raw); db=resolved_snapshot_dict(resolved_configuration_snapshot(b))
        @test da["model_binding"]==db["model_binding"]
        @test da["raw_configuration"]!=db["raw_configuration"]
        @test db["sections"]["domain_adaptation"]["origin"]=="owning_resolution_rule"
        @test !isempty(db["sections"]["domain_adaptation"]["input_assigning_histories"])
        ua=resolved_configuration_dict(a); ua["numerical"]["energy_max"]="1 eV"
        ub=deepcopy(ua); ub["numerical"]["energy_max"]="1000 meV"
        ca=resolve("eV",ua); cb=resolve("meV",ub)
        @test ca.numerical.E_max===cb.numerical.E_max
        @test resolved_snapshot_dict(resolved_configuration_snapshot(ca))["model_binding"]==
              resolved_snapshot_dict(resolved_configuration_snapshot(cb))["model_binding"]
        energy_raw=resolved_configuration_dict(a);energy_raw["numerical"]["energy_max"]="0.50 eV"
        energy_diff=resolved_configuration_diff(a,resolve("energy-atom",energy_raw))
        energy_row=only(filter(row->occursin("E_max",row["path"]),energy_diff["changes"]))
        @test energy_row["path"]=="/sections/numerical/E_max"
        @test energy_row["before"]==Dict("value"=>0.45,"unit"=>"eV")
        @test energy_row["after"]==Dict("value"=>0.50,"unit"=>"eV")
        da["sections"]["numerical"]["used"]["N_E"]=1
        a.raw["numerical"]["energy_nodes"]=3
        @test resolved_snapshot_dict(sa)["sections"]["numerical"]["used"]["N_E"]!=1
        @test resolved_snapshot_dict(sa)["raw_configuration"]["numerical"]["energy_nodes"]!=3
        @test_throws ConfigurationError resolved_configuration_snapshot(a)
        a=load_run_configuration(BASE)
        callback_options=QCLNEGFRunner.with_production_options(a.production;event_sink=identity)
        runtime=ResolvedRunConfiguration((name===:production ? callback_options : getfield(a,name)
            for name in fieldnames(ResolvedRunConfiguration))...)
        @test_throws ConfigurationError resolved_configuration_snapshot(runtime)
        changed=resolved_configuration_dict(a); changed["numerical"]["energy_nodes"]=101
        grid=resolve("grid",changed)
        diff=resolved_configuration_diff(a,grid;controlled_paths=["numerical.energy_nodes"])
        @test diff["comparable"]
        @test !isempty(diff["changes"])
        changed["scattering"]["lo_phonon"]=false
        bad=resolve("undeclared",changed)
        @test !resolved_configuration_diff(a,bad;controlled_paths=["numerical.energy_nodes"])["comparable"]
        @test_throws ConfigurationError resolved_configuration_diff(a,grid;controlled_paths=["numerical.unknown"])
        @test_throws ConfigurationError resolved_configuration_diff(a,grid;controlled_paths=["numerical","numerical.energy_nodes"])
        @test_throws ConfigurationError resolved_configuration_diff(a,grid;controlled_paths=["execution"])
        @test resolved_configuration_diff(a,a;controlled_paths=["domain_adaptation.maximum_expansions"])["comparable"]
        renamed=resolved_configuration_dict(a); renamed["run"]["name"]="translated"
        @test resolved_configuration_diff(a,resolve("name",renamed))["comparable"]
        estimate=scientific_resource_estimate(a;worker_capacity=1)
        @test estimate["estimated_numerical_peak_bytes"]>0
        @test estimate["measured_rss_bytes"]===nothing
        @test estimate["admitted_memory_bytes"]===nothing
        @test estimate["total_memory_request_bytes"]===nothing
        @test estimate["retained_resident_bytes"]==0
        @test_throws ArgumentError scientific_resource_estimate(a;worker_capacity=true)
        adaptive=resolved_configuration_dict(a)
        adaptive["domain_adaptation"]=Dict("mode"=>"expand_energy_window","maximum_energy_nodes"=>10001)
        policy=resolve("adaptive",adaptive)
        begin
            receipt=scientific_resource_estimate(policy;worker_capacity=1)
            @test receipt["declared_maximum_energy_nodes"]==10001
            @test receipt["estimated_numerical_peak_bytes"]==receipt["declared_cap"]["peak_bytes"]+
                2receipt["declared_cap"]["resident_bytes"]+receipt["initial"]["resident_bytes"]
        end
    end
end
end
end
