module ConfiguratorPreviewContract
using Test, YAML, SHA, QCLNEGFRunner
const W = QCLNEGFRunner.QCLScientificWorkflow
json(x) = sprint(io -> QCLNEGFRunner._light_json(io,x))
@testset "recursive JSON containers retain independent local bindings" begin
    # Exact four-key healthy request from the failing diagnostic domain. Fields
    # must not replace the outer request when parsed after catalog_source_id.
    request=W._configurator_json("{\"mode\":\"form\",\"template_id\":\"oracle\",\"catalog_source_id\":\"fixture-v1\",\"fields\":{}}")
    @test Set(keys(request))==Set(["mode","template_id","catalog_source_id","fields"])
    @test request["mode"]=="form"
    @test request["template_id"]=="oracle"
    @test request["catalog_source_id"]=="fixture-v1"
    @test request["fields"]==Dict{String,Any}()
    nested=W._configurator_json("{\"left\":{\"items\":[{\"id\":\"one\"},{}]},\"right\":{\"items\":[{\"id\":\"two\"},[]]},\"tail\":\"root\"}")
    @test Set(keys(nested))==Set(["left","right","tail"])
    @test nested["left"]["items"]==[Dict("id"=>"one"),Dict{String,Any}()]
    @test nested["right"]["items"]==Any[Dict("id"=>"two"),Any[]]
    @test nested["tail"]=="root"
    @test nested["left"]!==nested["right"]
    @test nested["left"]["items"]!==nested["right"]["items"]
    nested["left"]["items"][1]["id"]="changed"
    @test nested["right"]["items"][1]["id"]=="two"
    push!(nested["left"]["items"],"left-only")
    @test length(nested["right"]["items"])==2
    @test nested["tail"]=="root"
end
@testset "strict bounded transport before resolver" begin
    for text in ("{\"mode\":\"form\",\"mode\":\"yaml\"}", "{\"x\":NaN}", "{\"x\":1,}", "[]", "{\"x\":1e999}")
        @test_throws Exception W._configurator_json(text)
    end
    @test W._configurator_json("{\"x\":1.25e-7,\"s\":\"a\\n\"}")["x"] == 1.25e-7
    @test_throws Exception W._configurator_yaml("x: 1\nx: 2\n")
    @test_throws Exception W._configurator_yaml("x:\n  y: 1\n  y: 2\n")
    @test_throws Exception W._configurator_yaml("1: value\n")
    @test_throws Exception W._configurator_yaml("x: 1\n---\ny: 2\n")
    @test_throws Exception W._configurator_yaml("x: &a [*a]\n")
    @test_throws Exception W._configurator_json(repeat("[",65)*"0"*repeat("]",65))
end
@testset "catalog confinement and authoritative expert draft" begin
    mktempdir() do root
        write(joinpath(root,"inside.yaml"),"x: 1\n")
        @test W._configurator_path(root,"inside.yaml") == realpath(joinpath(root,"inside.yaml"))
        @test_throws Exception W._configurator_path(root,"/etc/passwd")
        @test_throws Exception W._configurator_path(root,"../outside.yaml")
        symlink("/etc/passwd",joinpath(root,"escape.yaml"))
        @test_throws Exception W._configurator_path(root,"escape.yaml")
    end
end
@testset "form edits preserve unspecified expert leaves and explicit variants" begin
    template=Dict{String,Any}("axes"=>Dict("temperatures"=>Dict("values"=>[70],"unit"=>"K"),
        "voltages"=>Dict("values"=>[0],"unit"=>"V")), "configuration"=>Dict("sources"=>["model.yaml"],
        "overrides"=>Dict("kernel_construction"=>Dict("impurity_angular_tolerance"=>1e-7))))
    changed=W._configurator_form(template,Dict{String,Any}("temperature_K"=>70,"voltage_per_period_mV"=>0,
        "scba_to_poisson"=>"strict_fail_fast","voltage_mode"=>"independent"))
    @test changed["configuration"] == template["configuration"]
    @test changed["axes"]["temperatures"] == Dict("values"=>[70],"unit"=>"K")
    @test changed["axes"]["voltages"] == Dict("values"=>[0],"unit"=>"mV")
    @test changed["policies"]["scba_to_poisson"] == "strict_fail_fast"
    @test_throws Exception W._configurator_form(template,Dict("unknown"=>1))
    @test_throws Exception W._configurator_form(template,Dict("temperature_K"=>"70"))
    @test template["axes"]["voltages"]["unit"] == "V"
end
end

module ConfiguratorResolvedOracle
using Test, YAML, SHA, QCLNEGFRunner
const W=QCLNEGFRunner.QCLScientificWorkflow
json(x)=sprint(io->QCLNEGFRunner._light_json(io,x))
@testset "independent resolved oracle and common semantic provenance" begin
    mktempdir() do root
        mkpath(joinpath(root,"config","model")); mkpath(joinpath(root,"config","studies"))
        cp(joinpath(@__DIR__,"..","fixtures","research-inputs","model","reference-2019-70k.yaml"),joinpath(root,"config","model","model.yaml"))
        write(joinpath(root,"config","model","policy.yaml"),"numerical:\n  energy_nodes: 201\n")
        template=Dict{String,Any}("schema"=>"qcl-negf-study-v2","kind"=>"study","id"=>"oracle",
            "configuration"=>Dict("sources"=>["../model/model.yaml","../model/policy.yaml"]),
            "axes"=>Dict("temperatures"=>Dict("values"=>[70],"unit"=>"K"),"voltages"=>Dict("values"=>[0],"unit"=>"mV")),
            "policies"=>Dict("scba_to_poisson"=>"strict_fail_fast","voltage"=>Dict("mode"=>"independent")))
        YAML.write_file(joinpath(root,"config","studies","study.yaml"),template)
        catalog=Dict("schema"=>"qcl-negf-configurator-catalog-v1","templates"=>[
            Dict("id"=>"oracle","name"=>"Oracle","study"=>"config/studies/study.yaml","description"=>"fixture",
                "model"=>Dict("name"=>"Model","path"=>"config/model/model.yaml"),
                "protocol"=>Dict("name"=>"Policy","path"=>"config/model/policy.yaml"))])
        write(joinpath(root,"config","configurator-catalog.json"),json(catalog))
        request=Dict("mode"=>"form","template_id"=>"oracle","catalog_source_id"=>"fixture-v1","fields"=>Dict())
        form=W.configurator_preview(json(request),root,"fixture-v1")
        @test form["status"]=="available"
        if form["status"]=="available"
            request["mode"]="yaml"; delete!(request,"fields"); request["yaml"]=form["draft_yaml"]
            yaml=W.configurator_preview(json(request),root,"fixture-v1")
            @test yaml["status"]=="available"
            @test yaml["plan"]==form["plan"]
            @test yaml["draft_sha256"]!=form["draft_sha256"]
            @test yaml["semantic_draft_sha256"]==form["semantic_draft_sha256"]
            @test yaml["resolved_snapshots"]==form["resolved_snapshots"]
            @test only(form["resolved_snapshots"])["snapshot"]["model_binding"]["sha256"]==
                only(W._configurator_json(form["plan"];maximum=4*1024^2)["executions"])["resolved_snapshot"]["model_binding"]["sha256"]
            @test only(form["resource_estimates"])["estimate"]["admitted_memory_bytes"]===nothing
            @test bytes2hex(sha256(form["plan"]))==form["plan_sha256"]
            # Compare the existing filesystem/public resolver, not just the same
            # captured adapter twice. Only known source-locator/full-FP deltas
            # are removed; resources, scientific FP, all inputs and points stay.
            public_plan=W.resolve_scientific_plan(joinpath(root,"config","studies","study.yaml");maximum_solver_runs=100)
            public=W.scientific_plan_dict(public_plan)
            preview=W._configurator_json(form["plan"];maximum=4*1024^2)
            @test public["scientific_fingerprint"]==preview["scientific_fingerprint"]
            for document in (public,preview)
                delete!(document,"fingerprint")
                for execution in document["executions"]
                    delete!(execution,"provenance")
                    # Capture labels differ between filesystem and bounded transport;
                    # effective values/model/default rule identities must remain equal.
                    for section in values(execution["resolved_snapshot"]["sections"])
                        delete!(section,"input_assigning_histories")
                    end
                end
            end
            @test public==preview
            @test only(form["resolved_inputs"])["configuration"]["numerical"]["energy_nodes"]==201
            @test only(form["effective_defaults"])["sections"]["production"]["used"]["memory_budget_bytes"]==
                Dict("kind"=>"integer","decimal"=>string(typemax(Int)))
            # Run the real no-solve CLI dispatch with file-backed stdin/stdout;
            # no new Julia subprocess, dependency install or solver invocation.
            cli_input=joinpath(root,"request.json"); cli_output=joinpath(root,"response.json")
            form_request=Dict("mode"=>"form","template_id"=>"oracle","catalog_source_id"=>"fixture-v1","fields"=>Dict())
            write(cli_input,json(form_request))
            status=open(cli_input,"r") do input
                open(cli_output,"w") do output
                    redirect_stdin(input) do
                        redirect_stdout(output) do
                            QCLNEGFRunner.main(["configure","--catalog-root",root,"--catalog-source-id","fixture-v1"])
                        end
                    end
                end
            end
            @test status==0
            cli=W._configurator_json(read(cli_output,String);maximum=8*1024^2)
            @test cli["status"]=="available"
            @test cli["plan"]==form["plan"]
            @test cli["plan_sha256"]==form["plan_sha256"]
            # Exact-scalar conversion is outside the plan's byte/hash domain.
            unencoded=W._configurator_preview(json(form_request),root,"fixture-v1")
            @test unencoded["plan"]==form["plan"]
            @test unencoded["plan_sha256"]==form["plan_sha256"]

            plan=W._configurator_json(form["plan"];maximum=4*1024^2)
            @test only(plan["points"])["temperature_K"]==70.0
            @test only(plan["points"])["voltage_per_period_V"]==0.0
            cfg=only(form["effective_defaults"])["sections"]
            @test cfg["physical"]["used"]["Tᴸ"]["value"]==70.0
            @test cfg["scattering"]["used"]["LO"]===true
            @test cfg["scattering"]["used"]["acoustic"]===true
            @test cfg["scattering"]["used"]["impurity"]===true
            @test cfg["scattering"]["used"]["IFR"]===true
            @test cfg["physical_models"]["used"]["electron_electron"]["mode"]=="none"
            @test cfg["solver"]["used"]["convergence"]["mode"]=="strict_fail_fast"
            @test cfg["domain_adaptation"]["used"]["maximum_expansions"]==2
            point_sections=only(only(form["effective_defaults"])["point_sections"])["sections"]
            @test endswith(last(point_sections["physical"]["input_assigning_histories"]["physical.voltage_per_period"]),
                "#generated:point-axes")
            @test haskey(only(form["resolved_snapshots"])["snapshot"]["default_rule_sources"],
                "Core:src/numerics/reference/scba.jl")
            @test !haskey(only(form["resolved_inputs"])["configuration"],"domain_adaptation")
            # The declared numerical variant passes; an extra physics change does not.
            variant=Dict("id"=>"grid","comparison_kind"=>"discretization",
                "controlled_paths"=>["numerical.energy_nodes"],
                "overrides"=>Dict("numerical"=>Dict("energy_nodes"=>101)))
            changed=deepcopy(template); changed["variants"]=[Dict("id"=>"baseline"),variant]
            request["yaml"]=YAML.write(changed)
            varied=W.configurator_preview(json(request),root,"fixture-v1")
            @test varied["status"]=="available"
            grid_only=deepcopy(template);grid_only["variants"]=[deepcopy(variant)]
            request["yaml"]=YAML.write(grid_only)
            single=W.configurator_preview(json(request),root,"fixture-v1")
            @test single["status"]=="available"
            if single["status"]=="available"
                single_diff=only(single["variant_diffs"])
                @test single_diff["comparable"]===true
                @test single_diff["base_model_sha256"]!=single_diff["candidate_model_sha256"]
                node_diff=only(filter(row->row["path"]=="/sections/numerical/N_E",single_diff["changes"]))
                @test node_diff["before"]==201
                @test node_diff["after"]==101
                reordered=deepcopy(changed);reverse!(reordered["variants"])
                request["yaml"]=YAML.write(reordered)
                order_preview=W.configurator_preview(json(request),root,"fixture-v1")
                @test order_preview["status"]=="available"
                if order_preview["status"]=="available"
                    baseline_diff=only(filter(d->d["id"]=="baseline",order_preview["variant_diffs"]))
                    @test baseline_diff["comparable"]===true
                    @test isempty(baseline_diff["changes"])
                    @test only(filter(d->d["id"]=="grid",order_preview["variant_diffs"]))==single_diff
                end
            end
            invalid_axis=deepcopy(changed)
            invalid_axis["variants"][2]["controlled_paths"]=["numerical.unknown"]
            request["yaml"]=YAML.write(invalid_axis)
            @test W.configurator_preview(json(request),root,"fixture-v1")["error"]["code"]=="invalid_controlled_path"
            request["yaml"]=YAML.write(changed)
            if varied["status"]=="available"
                grid=only(filter(e->e["variant_id"]=="grid",W._configurator_json(varied["plan"];maximum=4*1024^2)["executions"]))
                @test grid["resolved_configuration"]["numerical"]["energy_nodes"]==101
                @test grid["effective_inputs"]["energy_nodes"]==101
                @test grid["resolved_configuration"]["physical"]==only(form["resolved_inputs"])["configuration"]["physical"]
                @test grid["resolved_configuration"]["scattering"]==only(form["resolved_inputs"])["configuration"]["scattering"]
            end
            variant["overrides"]["scattering"]=Dict("lo_phonon"=>false)
            request["yaml"]=YAML.write(changed)
            @test W.configurator_preview(json(request),root,"fixture-v1")["status"]=="error"
            changed=deepcopy(template)
            reverse!(changed["configuration"]["sources"])
            request["yaml"]=YAML.write(changed)
            reversed=W.configurator_preview(json(request),root,"fixture-v1")
            @test reversed["status"]=="available"
            if reversed["status"]=="available"
                @test only(reversed["resolved_inputs"])["configuration"]["numerical"]["energy_nodes"]==2401
                @test only(reversed["effective_defaults"])["sections"]["numerical"]["used"]["N_E"]==2401
                @test reversed["plan"]!=form["plan"]
                @test reversed["semantic_draft_sha256"]!=form["semantic_draft_sha256"]
            end
            # Explicit same-valued assignment keeps its history and full YAML.
            expert=YAML.load(form["draft_yaml"])
            expert["configuration"]["overrides"]=Dict("domain_adaptation"=>Dict("maximum_expansions"=>2))
            request["yaml"]=YAML.write(expert)
            explicit=W.configurator_preview(json(request),root,"fixture-v1")
            @test explicit["status"]=="available"
            if explicit["status"]=="available"
                @test !explicit["short_form"]["lossless"]
                @test !isempty(only(explicit["resolved_inputs"])["assigning_sources"]["domain_adaptation.maximum_expansions"])
            end
            expert["configuration"]["overrides"]["domain_adaptation"]["unknown_expert_leaf"]=1
            request["yaml"]=YAML.write(expert)
            @test W.configurator_preview(json(request),root,"fixture-v1")["status"]=="error"
            # Valid Core Float64 scientific field: a large density is not an
            # unsafe untagged integer-valued JS Number in metadata views.
            density=YAML.load(form["draft_yaml"])
            density["configuration"]["overrides"]=Dict("physical_models"=>Dict(
                "lo_population"=>"rate_balance","lo_decay_ps"=>1.0,"lo_mode_density_per_m3"=>1e22))
            request["yaml"]=YAML.write(density)
            density_request=json(request)
            density_preview=W.configurator_preview(density_request,root,"fixture-v1")
            @test density_preview["status"]=="available"
            if density_preview["status"]=="available"
                expected_density=Dict("kind"=>"float64","decimal"=>repr(1e22))
                @test only(density_preview["resolved_inputs"])["configuration"]["physical_models"]["lo_mode_density_per_m3"]==expected_density
                @test only(density_preview["effective_defaults"])["sections"]["physical_models"]["used"]["lo_mode_density_per_m3"]==
                    Dict("value"=>expected_density,"unit"=>"m^-3")
                internal=W._configurator_preview(density_request,root,"fixture-v1")
                @test internal["plan"]==density_preview["plan"]
                @test internal["plan_sha256"]==density_preview["plan_sha256"]
                @test only(W._configurator_json(density_preview["plan"];maximum=4*1024^2)["executions"])["resolved_configuration"]["physical_models"]["lo_mode_density_per_m3"]==1e22
            end
        end
    end
end
end

module ConfiguratorProjectionCoverage
using Test, Unitful, QCLNEGFRunner
const W=QCLNEGFRunner.QCLScientificWorkflow
# Future Core fields require an explicit projection decision instead of silently
# disappearing. This reflection is solely a test oracle, never the adapter.
@testset "finite owning projections cover every typed field" begin
    base=load_run_configuration(joinpath(@__DIR__,"..","fixtures","research-inputs","model","reference-2019-70k.yaml"))
    function covered(value)
        value isa Unitful.AbstractQuantity && return
        if value isa Union{Nothing,Real,Symbol,AbstractString}; return; end
        if value isa Union{AbstractVector,Tuple}
            foreach(covered,value); return
        end
        projection=W._cfg_project(value)
        @test Set(keys(projection))==Set(string.(fieldnames(typeof(value))))
        for name in fieldnames(typeof(value)); covered(getproperty(value,name)); end
    end
    for name in (:physical,:numerical,:scales,:scattering,:solver,:production,:kernels,:algorithms,:execution,:output,:study,:physical_models,:domain_adaptation)
        covered(getproperty(base,name))
    end
    @test_throws Exception W._cfg_project(Ref(1))
end
end


module ConfiguratorExactTransportAndYAMLPreflight
using Test, Unitful, QCLNEGFRunner
const W=QCLNEGFRunner.QCLScientificWorkflow
@testset "recursive exact integer DTO; raw scientific bytes remain strings" begin
    safe=9007199254740991
    values=(typemin(Int),-safe-1,-safe,0,safe,safe+1,typemax(Int))
    expected=(string(typemin(Int)),"-9007199254740992",nothing,nothing,nothing,"9007199254740992",string(typemax(Int)))
    for (value,decimal) in zip(values,expected)
        actual=W._cfg_dto(value)
        @test actual==(decimal===nothing ? value : Dict("kind"=>"integer","decimal"=>decimal))
    end
    for value in (Float64(-safe),0.0,Float64(safe))
        @test W._cfg_dto(value)===value
    end
    for value in (-1e22,Float64(-safe-1),Float64(safe+1),1e22,floatmax(Float64))
        tagged=W._cfg_dto(value)
        @test tagged==Dict("kind"=>"float64","decimal"=>repr(value))
        @test parse(Float64,tagged["decimal"])===value
    end
    @test W._cfg_dto(Dict("nested"=>Any[1e22,true]))==
        Dict("nested"=>Any[Dict("kind"=>"float64","decimal"=>repr(1e22)),true])
    raw="{\"scientific_integer\":9223372036854775807,\"exponent\":1.25e-7}\n"
    views=Dict("plan"=>raw,"resolved_inputs"=>[Dict("configuration"=>Dict("nested"=>Any[typemin(Int),true]))],
        "variant_diffs"=>[Dict("overrides"=>Dict("budget"=>typemax(Int)))],
        "effective_defaults"=>[Dict("used"=>Dict("quantity"=>W._cfg_project(typemax(Int)*u"s")))])
    projected=W._cfg_dto(views)
    @test projected["plan"]===raw
    @test projected["resolved_inputs"][1]["configuration"]["nested"][1]==Dict("kind"=>"integer","decimal"=>string(typemin(Int)))
    @test projected["resolved_inputs"][1]["configuration"]["nested"][2]===true
    @test projected["variant_diffs"][1]["overrides"]["budget"]==Dict("kind"=>"integer","decimal"=>string(typemax(Int)))
    @test projected["effective_defaults"][1]["used"]["quantity"]["value"]==Dict("kind"=>"integer","decimal"=>string(typemax(Int)))
    @test views["variant_diffs"][1]["overrides"]["budget"]===typemax(Int)
end
@testset "owning YAML events reject depth before constructing documents" begin
    calls=Ref(0)
    loader=text->begin
        calls[]+=1
        W._cfg_load_yaml_documents(text)
    end
    deep=repeat("[",100)*"0"*repeat("]",100)
    masked=("description: \""*repeat("}",100)*"\"\nx: "*deep*"\n",
        "description: '"*repeat("}",100)*"'\nx: "*deep*"\n",
        "# "*repeat("}",100)*"\nx: "*deep*"\n")
    for text in masked
        failure=try W._configurator_yaml(text;loader); nothing catch error; error end
        @test failure isa W.ConfiguratorRefusal
        if failure isa W.ConfiguratorRefusal; @test failure.code=="depth_limit"; end
        @test calls[]==0
    end
    block=join([repeat(" ",2*i)*"key:" for i in 0:99],"\n")*"\n"*repeat(" ",200)*"value: 0\n"
    @test_throws W.ConfiguratorRefusal W._configurator_yaml(block;loader)
    @test calls[]==0
    healthy="double: \""*repeat("[]{}",100)*"\"\nsingle: '"*repeat("}][{",100)*"'\n# }}} [[[\nx: [1, 2]\n"
    result=W._configurator_yaml(healthy;loader)
    @test calls[]==1
    @test result["double"]==repeat("[]{}",100)
    @test result["single"]==repeat("}][{",100)
    @test result["x"]==[1,2]
    @test_throws W.ConfiguratorRefusal W._configurator_yaml("x: ]\n";loader)
    @test calls[]==1
end
end
