module StructureEditorContract
using Test, YAML, SHA, QCLNEGFRunner
const W = QCLNEGFRunner.QCLScientificWorkflow
json(x) = sprint(io -> QCLNEGFRunner._light_json(io, x))
# SI↔nm conversion may round once in each direction; literal zeros stay exact.
# The 8-eps relative bound covers conversion arithmetic, not a physics tolerance.
function literal_equal(actual, expected)
    if expected isa AbstractDict
        return actual isa AbstractDict && Set(keys(actual))==Set(keys(expected)) &&
            all(literal_equal(actual[k],v) for (k,v) in expected)
    elseif expected isa AbstractVector
        return actual isa AbstractVector && length(actual)==length(expected) &&
            all(literal_equal(a,e) for (a,e) in zip(actual,expected))
    elseif expected isa AbstractFloat
        return actual isa Real && !(actual isa Bool) &&
            (expected==0 ? actual==0 : isapprox(actual,expected;rtol=8eps(Float64),atol=0))
    end
    return actual==expected
end
const PATHS = ["physical.layers", "physical.interfaces", "physical.donor_sheet_density",
    "physical.ionization_fraction", "physical.position_origin", "physical.reference_energy"]
barrier() = Dict{String,Any}("thickness"=>"2 nm", "material"=>"AlGaAs",
    "aluminium_fraction"=>0.25, "conduction_band_edge"=>"0.2 eV",
    "longitudinal_relative_mass"=>0.09, "transverse_relative_mass"=>0.09,
    "relative_permittivity"=>12.9, "doped"=>false)
well() = Dict{String,Any}("thickness"=>"3 nm", "material"=>"GaAs",
    "aluminium_fraction"=>0.0, "conduction_band_edge"=>"0 eV",
    "longitudinal_relative_mass"=>0.067, "transverse_relative_mass"=>0.067,
    "relative_permittivity"=>12.9, "doped"=>true)
function fixture(f)
    mktempdir() do root
        mkpath(joinpath(root,"model")); mkpath(joinpath(root,"studies")); mkpath(joinpath(root,"config"))
        model=YAML.load_file(joinpath(@__DIR__,"..","fixtures","research-inputs","model","reference-2019-70k.yaml"))
        p=model["physical"]
        merge!(p,Dict("layers"=>[barrier(),well()], "interfaces"=>["0 nm","2 nm"],
            "donor_sheet_density"=>"1e14 m^-2", "ionization_fraction"=>0.5,
            "position_origin"=>"0 nm", "reference_energy"=>"0 eV"))
        YAML.write_file(joinpath(root,"model","tiny.yaml"),model)
        write(joinpath(root,"model","policy.yaml"),"numerical:\n  energy_nodes: 201\n")
        template=Dict{String,Any}("schema"=>"qcl-negf-study-v2", "kind"=>"study", "id"=>"tiny",
            "configuration"=>Dict("sources"=>["../model/tiny.yaml","../model/policy.yaml"]),
            "axes"=>Dict("temperatures"=>Dict("values"=>[70],"unit"=>"K"),
                "voltages"=>Dict("values"=>[0],"unit"=>"mV")),
            "policies"=>Dict("scba_to_poisson"=>"strict_fail_fast", "voltage"=>Dict("mode"=>"independent")))
        study=joinpath(root,"studies","tiny.yaml")
        YAML.write_file(study,template)
        catalog=Dict("schema"=>"qcl-negf-configurator-catalog-v1", "templates"=>[
            Dict("id"=>"tiny", "name"=>"Tiny", "description"=>"literal fixture, unpublished",
                "study"=>"studies/tiny.yaml", "model"=>Dict("name"=>"Tiny","path"=>"model/tiny.yaml"),
                "protocol"=>Dict("name"=>"Policy","path"=>"model/policy.yaml"))])
        write(joinpath(root,"config","configurator-catalog.json"),json(catalog))
        request=Dict{String,Any}("mode"=>"form", "template_id"=>"tiny",
            "catalog_source_id"=>"fixture-unpublished", "fields"=>Dict{String,Any}())
        f((;root, model, template, study, request))
    end
end
preview(x,req=x.request) = W.configurator_preview(json(req),x.root,"fixture-unpublished")
function physical_variant(id, layers; interfaces=["0 nm","2 nm"], density="2e14 m^-2")
    Dict("id"=>id, "comparison_kind"=>"physical_parameter", "controlled_paths"=>copy(PATHS),
        "overrides"=>Dict("physical"=>Dict("layers"=>layers, "interfaces"=>interfaces,
            "donor_sheet_density"=>density, "ionization_fraction"=>0.5,
            "position_origin"=>"0 nm", "reference_energy"=>"0 eV")))
end
tree_files(root) = sort([relpath(joinpath(dir,name),root)
    for (dir,_,names) in walkdir(root) for name in names])
@testset "typed literal structure, bound presets and no-solve preview" begin
    fixture() do x
        original=read(x.study); before=tree_files(x.root)
        result=preview(x)
        @test result["status"]=="available"
        if result["status"]!="available"; return; end
        editor=result["structure_editor"]
        @test editor["schema"]=="qcl-negf.structure-editor.v1"
        @test editor["status"]=="available"
        execution=only(editor["executions"])
        @test execution["variant_id"]=="baseline"
        @test literal_equal(execution["inputs"],Dict(
            "layers"=>[
                Dict("thickness_nm"=>2.0,"material"=>"AlGaAs","aluminium_fraction"=>0.25,
                    "conduction_band_edge_eV"=>0.2,"longitudinal_relative_mass"=>0.09,
                    "transverse_relative_mass"=>0.09,"relative_permittivity"=>12.9,"doped"=>false),
                Dict("thickness_nm"=>3.0,"material"=>"GaAs","aluminium_fraction"=>0.0,
                    "conduction_band_edge_eV"=>0.0,"longitudinal_relative_mass"=>0.067,
                    "transverse_relative_mass"=>0.067,"relative_permittivity"=>12.9,"doped"=>true)],
            "interfaces_nm"=>[0.0,2.0], "donor_sheet_density_per_m2"=>1e14,
            "ionization_fraction"=>0.5,"position_origin_nm"=>0.0,"reference_energy_eV"=>0.0))
        @test literal_equal(execution["geometry"],Dict("period_nm"=>5.0,
            "layers"=>[Dict("index_1based"=>1,"left_nm"=>0.0,"right_nm"=>2.0),
                Dict("index_1based"=>2,"left_nm"=>2.0,"right_nm"=>5.0)],
            "coordinate_scope"=>"one structural period before position-origin/bias sampling"))
        @test length(execution["material_presets"])==2
        @test execution["material_presets"][2]["conduction_band_edge_eV"]==0.0
        @test !haskey(execution["material_presets"][1],"doped")
        @test !haskey(execution["material_presets"][1],"thickness_nm")
        binding=execution["source_binding"]
        @test binding["execution_id"]==execution["execution_id"]
        @test binding["variant_id"]=="baseline"
        @test binding["catalog_source_id"]=="fixture-unpublished"
        @test binding["model"]["sha256"]==bytes2hex(sha256(read(joinpath(x.root,"model","tiny.yaml"))))
        @test binding["template_sha256"]==bytes2hex(sha256(original))
        @test !isempty(binding["input_assigning_histories"]["physical.layers"])
        @test execution["material_presets"][1]["source_binding"]==binding
        @test tree_files(x.root)==before
        @test read(x.study)==original
        req=deepcopy(x.request); delete!(req,"fields"); req["mode"]="yaml"; req["yaml"]=result["draft_yaml"]
        roundtrip=preview(x,req)
        @test roundtrip["plan"]==result["plan"]
        @test roundtrip["structure_editor"]==editor
        @test roundtrip["short_form"]["lossless"]
    end
end
@testset "physical variant public resolver oracle and immutable nonphysical inputs" begin
    fixture() do x
        baseline=preview(x); original=read(x.study)
        req=deepcopy(x.request)
        req["fields"]["variant"]=physical_variant("reordered",[well(),barrier()])
        changed=preview(x,req)
        @test changed["status"]=="available"
        if changed["status"]!="available"; return; end
        executions=changed["structure_editor"]["executions"]
        @test length(executions)==2
        edited=only(filter(e->e["variant_id"]=="reordered",executions))
        @test literal_equal(edited["geometry"]["layers"],[
            Dict("index_1based"=>1,"left_nm"=>0.0,"right_nm"=>3.0),
            Dict("index_1based"=>2,"left_nm"=>3.0,"right_nm"=>5.0)])
        @test edited["inputs"]["interfaces_nm"]==[0.0,2.0]
        @test edited["inputs"]["donor_sheet_density_per_m2"]==2e14
        @test edited["execution_id"]!=only(baseline["structure_editor"]["executions"])["execution_id"]
        @test !changed["short_form"]["lossless"]
        frozen=W._configurator_json(changed["plan"];maximum=4*1024^2)
        base_raw=only(baseline["resolved_inputs"])["configuration"]
        for execution in changed["resolved_inputs"], key in keys(base_raw)
            key=="physical" && continue
            actual=deepcopy(execution["configuration"][key]); expected=deepcopy(base_raw[key])
            # The existing resolver intentionally generates run.name per variant.
            if key=="run"; delete!(actual,"name"); delete!(expected,"name"); end
            @test actual==expected
        end
        # Independent filesystem resolver on exactly the authored semantic study.
        authored=YAML.load(changed["draft_yaml"])
        YAML.write_file(x.study,authored)
        public=W.scientific_plan_dict(W.resolve_scientific_plan(x.study;maximum_solver_runs=100))
        for doc in (public,frozen)
            delete!(doc,"fingerprint")
            for e in doc["executions"]; delete!(e,"provenance"); end
        end
        @test public==frozen
        write(x.study,original)
        longer=well(); longer["thickness"]="4 nm"
        req["fields"]["variant"]=physical_variant("longer",[longer,barrier()])
        result=preview(x,req)
        @test result["status"]=="available"
        if result["status"]=="available"
            longer_execution=only(filter(e->e["variant_id"]=="longer",result["structure_editor"]["executions"]))
            @test literal_equal(longer_execution["geometry"]["period_nm"],6.0)
            @test longer_execution["variant_id"]!=edited["variant_id"]
        end
        @test read(x.study)==original
        repeated=deepcopy(x.request)
        repeated["fields"]["variant"]=physical_variant("repeated",[well(),well(),barrier()])
        repeated_result=preview(x,repeated)
        @test repeated_result["status"]=="available"
        if repeated_result["status"]=="available"
            repeated_execution=only(filter(e->e["variant_id"]=="repeated",repeated_result["structure_editor"]["executions"]))
            @test length(repeated_execution["material_presets"])==2
            @test length(repeated_execution["inputs"]["layers"])==3
        end
    end
end
@testset "existing loader refuses invalid structure; editor caps preserve valid preview" begin
    fixture() do x
        for (key,bad) in (("thickness","2 K"),("thickness","0 nm"),
            ("aluminium_fraction",1.1),("longitudinal_relative_mass",-0.1),
            ("doped","true"),("unknown_leaf",1))
            layer=well(); layer[key]=bad
            req=deepcopy(x.request); req["fields"]["variant"]=physical_variant("bad",[layer,barrier()])
            @test preview(x,req)["status"]=="error"
        end
        for layers in (Any[],)
            req=deepcopy(x.request); req["fields"]["variant"]=physical_variant("empty",layers)
            @test preview(x,req)["status"]=="error"
        end
        duplicate=deepcopy(x.request); duplicate["fields"]["variant"]=physical_variant("baseline",[well(),barrier()])
        @test preview(x,duplicate)["status"]=="error"
        @test W.configurator_preview("{\"x\":NaN}",x.root,"fixture-unpublished")["status"]=="error"
        for (layers,interfaces) in (([well() for _ in 1:257],["0 nm"]),
            ([well(),barrier()],["0 nm" for _ in 1:257]))
            req=deepcopy(x.request); req["fields"]["variant"]=physical_variant("large",layers;interfaces)
            result=preview(x,req)
            @test result["status"]=="available"
            if result["status"]=="available"
                @test result["structure_editor"]["status"]=="unavailable"
                @test result["structure_editor"]["reason"]=="unsupported_structure_editor"
                @test haskey(result,"draft_yaml") && haskey(result,"plan")
            end
        end
        req=deepcopy(x.request)
        req["fields"]["variant"]=physical_variant("unsafe",[well(),barrier()];density="1e22 m^-2")
        unsafe=preview(x,req)
        @test unsafe["status"]=="available"
        if unsafe["status"]=="available"
            @test unsafe["structure_editor"]["status"]=="unavailable"
            @test haskey(unsafe,"resolved_inputs")
        end
    end
end
end
