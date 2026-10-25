# Additive metadata projection of resolved typed inputs. No grid/profile/basis/solve.
const CONFIGURATOR_STRUCTURE_SCHEMA = "qcl-negf.structure-editor.v1"
const CONFIGURATOR_STRUCTURE_ITEMS = 256
const CONFIGURATOR_STRUCTURE_BYTES = 1024*1024
_cfg_structure_unavailable() = Dict{String,Any}(
    "schema"=>CONFIGURATOR_STRUCTURE_SCHEMA, "status"=>"unavailable",
    "reason"=>"unsupported_structure_editor")
_structure_refuse() = _cfg_refuse("unsupported_structure_editor","structure_editor")
function _structure_scalar(value)
    value isa Real && !(value isa Bool) && isfinite(value) &&
        abs(value)<=CONFIGURATOR_SAFE_INTEGER || _structure_refuse()
    result=Float64(value)
    isfinite(result) || _structure_refuse()
    return result
end
_structure_quantity(unit,value) = _structure_scalar(ustrip(unit,value))
function _structure_layer(layer::QCLNEGFRunner.Layer)
    material=String(layer.material)
    isvalid(material) && ncodeunits(material)<=256 || _structure_refuse()
    return Dict{String,Any}(
        "thickness_nm"=>_structure_quantity(u"nm",layer.d),
        "material"=>material,
        "aluminium_fraction"=>_structure_scalar(layer.x_Al),
        "conduction_band_edge_eV"=>_structure_quantity(u"eV",layer.Eᶜ),
        "longitudinal_relative_mass"=>_structure_scalar(layer.mᶻᵣ),
        "transverse_relative_mass"=>_structure_scalar(layer.m_parallelᵣ),
        "relative_permittivity"=>_structure_scalar(layer.εᵣ),
        "doped"=>layer.doped,
    )
end
function _structure_execution(execution,entry,source_id,default_rules)
    config=execution.configuration; physical=config.physical
    1<=length(physical.layers)<=CONFIGURATOR_STRUCTURE_ITEMS || _structure_refuse()
    length(physical.interfaces)<=CONFIGURATOR_STRUCTURE_ITEMS || _structure_refuse()
    layers=[_structure_layer(layer) for layer in physical.layers]
    histories=Dict(k=>copy(v) for (k,v) in config.provenance.sources if startswith(k,"physical."))
    binding=Dict{String,Any}(
        "execution_id"=>execution.id, "variant_id"=>execution.variant_id,
        "catalog_source_id"=>source_id, "template_id"=>entry["id"],
        "template_sha256"=>entry["study_sha256"], "model"=>deepcopy(entry["model"]),
        "execution_provenance"=>Dict("sources"=>deepcopy(config.provenance.sources)),
        "default_rule_sources"=>copy(default_rules),
        "physical_rule_source"=>"Runner:src/infrastructure/config/configuration.jl@sha256:"*
            default_rules["Runner:src/infrastructure/config/configuration.jl"]*"#_parse_physical",
        "input_assigning_histories"=>histories,
    )
    binding_bytes=ncodeunits(_cfg_json(binding))
    binding_bytes<=CONFIGURATOR_STRUCTURE_BYTES || _structure_refuse()
    # Presets are explicit tuples of this model, never a universal material DB.
    # Histories identify complete resolving inputs, not fabricated per-number DOI.
    presets=Any[]; seen=Set{String}(); preset_bytes=binding_bytes
    geometry=Any[]; left=0.0
    for (index,layer) in enumerate(layers)
        right=_structure_scalar(left+layer["thickness_nm"])
        push!(geometry,Dict("index_1based"=>index,"left_nm"=>left,"right_nm"=>right))
        left=right
        tuple=Dict(k=>v for (k,v) in layer if !(k in ("thickness_nm","doped")))
        key=bytes2hex(sha256(canonical_bytes(tuple)))
        if !(key in seen)
            preset_bytes+=ncodeunits(_cfg_json(tuple))+binding_bytes
            preset_bytes<=CONFIGURATOR_STRUCTURE_BYTES || _structure_refuse()
            push!(seen,key)
            tuple["source_binding"]=binding
            push!(presets,tuple)
        end
    end
    return Dict{String,Any}(
        "execution_id"=>execution.id, "variant_id"=>execution.variant_id,
        "inputs"=>Dict(
            "layers"=>layers,
            "interfaces_nm"=>[_structure_quantity(u"nm",x) for x in physical.interfaces],
            "donor_sheet_density_per_m2"=>_structure_quantity(u"m^-2",physical.N_dop²ᴰ),
            "ionization_fraction"=>_structure_scalar(physical.f_ion),
            "position_origin_nm"=>_structure_quantity(u"nm",physical.z₀),
            "reference_energy_eV"=>_structure_quantity(u"eV",physical.E_ref)),
        "geometry"=>Dict("period_nm"=>left, "layers"=>geometry,
            "coordinate_scope"=>"one structural period before position-origin/bias sampling"),
        "material_presets"=>presets, "source_binding"=>binding,
    )
end
function _cfg_structure_editor(plan,entry,source_id,default_rules)
    try
        executions=Any[]; bytes=0
        for execution in plan.executions
            projection=_structure_execution(execution,entry,source_id,default_rules)
            bytes+=ncodeunits(_cfg_json(projection))
            bytes<=CONFIGURATOR_STRUCTURE_BYTES || _structure_refuse()
            push!(executions,projection)
        end
        result=Dict{String,Any}("schema"=>CONFIGURATOR_STRUCTURE_SCHEMA,
            "status"=>"available", "executions"=>executions)
        ncodeunits(_cfg_json(result))<=CONFIGURATOR_STRUCTURE_BYTES || _structure_refuse()
        return result
    catch error
        error isa ConfiguratorRefusal && error.code=="unsupported_structure_editor" || rethrow()
        return _cfg_structure_unavailable()
    end
end
