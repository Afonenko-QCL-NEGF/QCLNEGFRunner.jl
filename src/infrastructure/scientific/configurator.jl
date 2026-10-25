# One-shot, no-solve adapter. Limits refuse inputs; they never change science.
const CONFIGURATOR_REQUEST_BYTES = 256*1024
const CONFIGURATOR_YAML_BYTES = 128*1024
const CONFIGURATOR_CAPTURE_BYTES = 1024*1024
const CONFIGURATOR_PLAN_BYTES = 4*1024*1024
const CONFIGURATOR_RESPONSE_BYTES = 8*1024*1024
struct ConfiguratorRefusal <: Exception
    code::String
    path::String
end
_cfg_refuse(code,path="request") = throw(ConfiguratorRefusal(code,path))
_cfg_json(value) = sprint(io->_light_json(io,value))
_cfg_sha(value) = bytes2hex(sha256(value))

# DTO-only exact scalar encoding. Scientific objects and the frozen plan string
# are never passed through an integer coercion or reparsed/reserialized.
const CONFIGURATOR_SAFE_INTEGER = 9007199254740991
_cfg_dto(value::Bool)=value
_cfg_dto(value::Integer)= -CONFIGURATOR_SAFE_INTEGER<=value<=CONFIGURATOR_SAFE_INTEGER ?
    value : Dict("kind"=>"integer","decimal"=>string(value))
function _cfg_dto(value::Float64)
    isfinite(value) || _cfg_refuse("nonfinite")
    return -CONFIGURATOR_SAFE_INTEGER<=value<=CONFIGURATOR_SAFE_INTEGER ?
        value : Dict("kind"=>"float64","decimal"=>repr(value))
end
_cfg_dto(value::AbstractDict)=Dict(String(k)=>_cfg_dto(v) for (k,v) in value)
_cfg_dto(value::Union{AbstractVector,Tuple})=[_cfg_dto(v) for v in value]
_cfg_dto(value)=value


# Independent strict JSON syntax walk, before YAML's scalar decoding. Keys are
# decoded before duplicate checking, so escaped spellings cannot evade it.
function _configurator_json(text::AbstractString; maximum=CONFIGURATOR_REQUEST_BYTES)
    ncodeunits(text)<=maximum && isvalid(text) || _cfg_refuse("input_limit")
    chars=collect(text); index=Ref(1); count=Ref(0)
    peek()=index[]>length(chars) ? '\0' : chars[index[]]
    whitespace()=(while peek() in (' ','\t','\r','\n'); index[]+=1; end)
    function quoted()
        peek()=='"' || _cfg_refuse("invalid_json")
        start=index[]; index[]+=1
        while peek()!='"'
            c=peek(); (c=='\0' || Int(c)<32) && _cfg_refuse("invalid_json")
            if c=='\\'
                index[]+=1; e=peek()
                e in ('"','\\','/','b','f','n','r','t','u') || _cfg_refuse("invalid_json")
                if e=='u'
                    for _ in 1:4
                        index[]+=1
                        peek() in "0123456789abcdefABCDEF" || _cfg_refuse("invalid_json")
                    end
                end
            end
            index[]+=1
        end
        index[]+=1
        token=String(chars[start:index[]-1])
        # YAML JSON-compatible scalar reader decodes unicode escapes.
        decoded=YAML.load(token)
        decoded isa AbstractString && isvalid(decoded) || _cfg_refuse("invalid_json")
        return String(decoded)
    end
    function value(depth)
        # Each recursive frame owns its container; do not capture the outer
        # function's final result binding when descending into objects/arrays.
        local result
        depth<=64 || _cfg_refuse("depth_limit")
        count[]+=1; count[]<=100000 || _cfg_refuse("node_limit")
        whitespace(); c=peek()
        if c=='{'
            index[]+=1; whitespace(); result=Dict{String,Any}()
            if peek()=='}'; index[]+=1; return result; end
            while true
                whitespace(); key=quoted(); haskey(result,key) && _cfg_refuse("duplicate_key")
                whitespace(); peek()==':' || _cfg_refuse("invalid_json"); index[]+=1
                result[key]=value(depth+1); whitespace()
                peek()=='}' && (index[]+=1; return result)
                peek()==',' || _cfg_refuse("invalid_json"); index[]+=1
            end
        elseif c=='['
            index[]+=1; whitespace(); result=Any[]
            if peek()==']'; index[]+=1; return result; end
            while true
                push!(result,value(depth+1)); whitespace()
                peek()==']' && (index[]+=1; return result)
                peek()==',' || _cfg_refuse("invalid_json"); index[]+=1
            end
        elseif c=='"'
            return quoted()
        end
        start=index[]
        while !(peek() in ('\0',' ',',',']','}','\t','\r','\n')); index[]+=1; end
        token=String(chars[start:index[]-1])
        token=="true" && return true
        token=="false" && return false
        token=="null" && return nothing
        occursin(r"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$",token) || _cfg_refuse("invalid_json")
        parsed=occursin(r"[.eE]",token) ? tryparse(Float64,token) : tryparse(Int,token)
        parsed isa Real && !(parsed isa Bool) && isfinite(parsed) || _cfg_refuse("invalid_json")
        return parsed
    end
    result=value(0); whitespace(); index[]>length(chars) || _cfg_refuse("invalid_json")
    result isa AbstractDict || _cfg_refuse("object_required")
    return result
end

function _cfg_tree(value,depth=0,count=Ref(0))
    depth<=64 || _cfg_refuse("depth_limit")
    count[]+=1; count[]<=100000 || _cfg_refuse("node_limit")
    if value isa AbstractDict
        for (k,v) in value
            k isa AbstractString || _cfg_refuse("non_string_key")
            _cfg_tree(v,depth+1,count)
        end
    elseif value isa AbstractVector
        for v in value; _cfg_tree(v,depth+1,count); end
    elseif value isa Real
        isfinite(value) || _cfg_refuse("nonfinite")
    elseif !(value isa Union{Nothing,AbstractString,Bool})
        _cfg_refuse("unsupported_scalar")
    end
    return value
end
# Consume the owning YAML parser's iterative events before compose/construct.
# Scalar quotes/comments/block scalars are classified by YAML, never counted as
# structural brackets here. Both block and flow containers have the same cap.
function _cfg_yaml_preflight(text::AbstractString)
    events=YAML.EventStream(YAML.TokenStream(IOBuffer(text)))
    depth=0; nodes=0; documents=0
    while true
        event=YAML.forward!(events)
        event isa YAML.StreamEndEvent && break
        event===nothing && _cfg_refuse("invalid_yaml")
        if event isa Union{YAML.SequenceStartEvent,YAML.MappingStartEvent}
            depth+=1; nodes+=1
            depth<=64 || _cfg_refuse("depth_limit")
        elseif event isa Union{YAML.SequenceEndEvent,YAML.MappingEndEvent}
            depth-=1
            depth>=0 || _cfg_refuse("invalid_yaml")
        elseif event isa YAML.ScalarEvent
            nodes+=1
        elseif event isa YAML.AliasEvent
            _cfg_refuse("unsupported_yaml_alias_or_tag")
        elseif event isa YAML.DocumentStartEvent
            documents+=1
            documents<=1 || _cfg_refuse("multiple_yaml_documents")
        end
        nodes<=100000 || _cfg_refuse("node_limit")
    end
    depth==0 && documents==1 || _cfg_refuse("invalid_yaml")
    return nothing
end
function _cfg_load_yaml_documents(text)
    strict=(constructor,node)->YAML.construct_mapping(Dict{Any,Any},constructor,node;strict_unique_keys=true)
    documents=YAML.load_all(text,Dict("tag:yaml.org,2002:map"=>strict))
    first_document=iterate(documents)
    first_document===nothing && _cfg_refuse("invalid_yaml")
    document,state=first_document
    iterate(documents,state)===nothing || _cfg_refuse("multiple_yaml_documents")
    return document
end
function _configurator_yaml(text::AbstractString; loader=_cfg_load_yaml_documents)
    ncodeunits(text)<=CONFIGURATOR_YAML_BYTES && isvalid(text) || _cfg_refuse("yaml_limit")
    # Aliases/anchors/tags remain deliberately unsupported at this HTTP boundary,
    # conservatively also inside quoted/comment text; clients retain original text.
    occursin(r"[&*!]",text) && _cfg_refuse("unsupported_yaml_alias_or_tag")
    data=try
        _cfg_yaml_preflight(text)
        loader(text)
    catch error
        error isa ConfiguratorRefusal && rethrow()
        _cfg_refuse("invalid_yaml")
    end
    data isa AbstractDict || _cfg_refuse("object_required")
    return QCLNEGFRunner._string_keyed_yaml(_cfg_tree(data), "")
end
function _configurator_path(root,relative)
    relative isa AbstractString && !isempty(relative) || _cfg_refuse("invalid_catalog_path")
    isabspath(relative) && _cfg_refuse("foreign_path")
    occursin('\\',relative) && _cfg_refuse("foreign_path")
    path=normpath(joinpath(root,relative)); base=realpath(root)
    isfile(path) || _cfg_refuse("missing_catalog_file")
    actual=realpath(path)
    startswith(actual,base*"/") || _cfg_refuse("foreign_path")
    return actual
end
function _cfg_keys(data,allowed;required=allowed,path="request")
    data isa AbstractDict || _cfg_refuse("object_required",path)
    isempty(setdiff(Set(keys(data)),Set(allowed))) || _cfg_refuse("unknown_field",path)
    all(haskey(data,k) for k in required) || _cfg_refuse("missing_field",path)
    return data
end
function _configurator_catalog(root,source_id)
    source_id isa AbstractString && occursin(r"^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,255}$",source_id) || _cfg_refuse("invalid_catalog_source")
    catalogpath=_configurator_path(root,"config/configurator-catalog.json")
    filesize(catalogpath)<=CONFIGURATOR_CAPTURE_BYTES || _cfg_refuse("catalog_limit")
    catalog=_configurator_json(read(catalogpath,String);maximum=CONFIGURATOR_CAPTURE_BYTES)
    _cfg_keys(catalog,("schema","templates"))
    catalog["schema"]=="qcl-negf-configurator-catalog-v1" || _cfg_refuse("unsupported_catalog")
    entries=catalog["templates"]; entries isa AbstractVector && 1<=length(entries)<=32 || _cfg_refuse("catalog_limit")
    total=filesize(catalogpath); seen=Set{String}(); result=Any[]
    for entry in entries
        _cfg_keys(entry,("id","name","study","model","protocol","description"))
        id=_identifier_input(entry["id"],"template_id"); id in seen && _cfg_refuse("duplicate_template"); push!(seen,id)
        item=deepcopy(entry)
        for key in ("name","description"); item[key] isa AbstractString || _cfg_refuse("invalid_catalog"); end
        for key in ("model","protocol"); _cfg_keys(item[key],("name","path")); end
        for (key,path) in (("study",item["study"]),("model",item["model"]["path"]),("protocol",item["protocol"]["path"]))
            file=_configurator_path(root,path); total+=filesize(file)
            total<=CONFIGURATOR_CAPTURE_BYTES || _cfg_refuse("catalog_limit")
            digest=_cfg_sha(read(file))
            key=="study" ? (item["study_sha256"]=digest) : (item[key]["sha256"]=digest)
        end
        item["protocol"]["version"]=source_id*":"*item["protocol"]["path"]
        push!(result,item)
    end
    return Dict("status"=>"available","catalog_source_id"=>source_id,"templates"=>result)
end
function _configurator_form(template,fields)
    _cfg_keys(fields,("temperature_K","voltage_per_period_mV","voltage_mode","scba_to_poisson","variant");required=(),path="fields")
    data=deepcopy(template)
    for (key,axis,unit) in (("temperature_K","temperatures","K"),("voltage_per_period_mV","voltages","mV"))
        haskey(fields,key) || continue
        v=fields[key]; v isa Real && !(v isa Bool) && isfinite(v) && (key=="temperature_K" ? v>0 : v>=0) || _cfg_refuse("invalid_field","fields."*key)
        axes=get!(data,"axes",Dict{String,Any}())
        haskey(axes,"branches") && _cfg_refuse("unsupported_form_projection","axes.branches")
        axes[axis]=Dict("values"=>[v],"unit"=>unit)
    end
    policies=get!(data,"policies",Dict{String,Any}())
    if haskey(fields,"voltage_mode")
        fields["voltage_mode"] in ("independent","strict") || _cfg_refuse("invalid_field","fields.voltage_mode")
        get!(policies,"voltage",Dict{String,Any}())["mode"]=fields["voltage_mode"]
    end
    if haskey(fields,"scba_to_poisson")
        fields["scba_to_poisson"] isa AbstractString || _cfg_refuse("invalid_field","fields.scba_to_poisson")
        policies["scba_to_poisson"]=fields["scba_to_poisson"]
    end
    if haskey(fields,"variant")
        variant=fields["variant"]
        _cfg_keys(variant,("id","method_id","overrides","controlled_paths","comparison_kind");required=("id","overrides","controlled_paths","comparison_kind"),path="fields.variant")
        data["variants"]=vcat(get(data,"variants",[Dict("id"=>"baseline","method_id"=>"configured")]),[deepcopy(variant)])
    end
    return data
end

struct CapturedConfiguratorDefinition <: AbstractScientificDefinitionRepository
    definition::ScientificDefinition
    base::ResolvedRunConfiguration
end
read_scientific_definition(r::CapturedConfiguratorDefinition,::String)=r.definition
scientific_memory_estimate(::CapturedConfiguratorDefinition,c::ResolvedRunConfiguration)=
    scientific_memory_estimate(FilesystemScientificDefinitions(),c)
function resolve_scientific_configuration(r::CapturedConfiguratorDefinition,d,v,i)
    configuration=_resolve_scientific_configuration(r.base,d,v,i)
    directory=configuration.output.directory
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$",directory) &&
        all(part->!(part in (".","..")),split(directory,'/')) || _cfg_refuse("foreign_path","configuration.output.directory")
    return configuration
end

# Finite owning projections. No reflection/repr/raw-map substitution is used.
_cfg_project(x::Nothing)=nothing
_cfg_project(x::Bool)=x
_cfg_project(x::AbstractString)=String(x)
_cfg_project(x::Symbol)=String(x)
function _cfg_project(x::Real)
    isfinite(x) || _cfg_refuse("unsupported_projection")
    return x
end
_cfg_project(x::Unitful.AbstractQuantity)=Dict("value"=>ustrip(x),"unit"=>string(unit(x)))
_cfg_project(x::Union{AbstractVector,Tuple})=[_cfg_project(v) for v in x]
_cfg_project(x)=_cfg_refuse("unsupported_projection")
import ..QCLNEGFRunner
function _cfg_project(x::QCLNEGFRunner.Layer)
    return Dict{String,Any}(
        "d"=>_cfg_project(x.d),
        "material"=>_cfg_project(x.material),
        "x_Al"=>_cfg_project(x.x_Al),
        "Eᶜ"=>_cfg_project(x.Eᶜ),
        "mᶻᵣ"=>_cfg_project(x.mᶻᵣ),
        "m_parallelᵣ"=>_cfg_project(x.m_parallelᵣ),
        "εᵣ"=>_cfg_project(x.εᵣ),
        "doped"=>_cfg_project(x.doped),
    )
end
function _cfg_project(x::QCLNEGFRunner.PhysicalParameters)
    return Dict{String,Any}(
        "layers"=>_cfg_project(x.layers),
        "N_dop²ᴰ"=>_cfg_project(x.N_dop²ᴰ),
        "f_ion"=>_cfg_project(x.f_ion),
        "F_bias"=>_cfg_project(x.F_bias),
        "z₀"=>_cfg_project(x.z₀),
        "E_ref"=>_cfg_project(x.E_ref),
        "Tᴸ"=>_cfg_project(x.Tᴸ),
        "Tᴸᴼ"=>_cfg_project(x.Tᴸᴼ),
        "ε_s"=>_cfg_project(x.ε_s),
        "ε_∞"=>_cfg_project(x.ε_∞),
        "ħωᴸᴼ"=>_cfg_project(x.ħωᴸᴼ),
        "q_s"=>_cfg_project(x.q_s),
        "qᴸᴼ_s"=>_cfg_project(x.qᴸᴼ_s),
        "Δᴵᶠᴿ"=>_cfg_project(x.Δᴵᶠᴿ),
        "Λᴵᶠᴿ"=>_cfg_project(x.Λᴵᶠᴿ),
        "Ξ"=>_cfg_project(x.Ξ),
        "ρ_m"=>_cfg_project(x.ρ_m),
        "v_s"=>_cfg_project(x.v_s),
        "ΔV_alloy"=>_cfg_project(x.ΔV_alloy),
        "Ω₀"=>_cfg_project(x.Ω₀),
        "g_s"=>_cfg_project(x.g_s),
        "interfaces"=>_cfg_project(x.interfaces),
    )
end
function _cfg_project(x::QCLNEGFRunner.NumericalParameters)
    return Dict{String,Any}(
        "N_z"=>_cfg_project(x.N_z),
        "N_b"=>_cfg_project(x.N_b),
        "P_basis"=>_cfg_project(x.P_basis),
        "E_min"=>_cfg_project(x.E_min),
        "E_max"=>_cfg_project(x.E_max),
        "N_E"=>_cfg_project(x.N_E),
        "M_E"=>_cfg_project(x.M_E),
        "k_max"=>_cfg_project(x.k_max),
        "N_k"=>_cfg_project(x.N_k),
        "N_φ"=>_cfg_project(x.N_φ),
        "qz_max"=>_cfg_project(x.qz_max),
        "N_qz"=>_cfg_project(x.N_qz),
        "η_seed"=>_cfg_project(x.η_seed),
    )
end
function _cfg_project(x::QCLNEGFRunner.SolverTolerances)
    return Dict{String,Any}(
        "r_D"=>_cfg_project(x.r_D),
        "r_A"=>_cfg_project(x.r_A),
        "r_K"=>_cfg_project(x.r_K),
        "r_Σ"=>_cfg_project(x.r_Σ),
        "r_λ"=>_cfg_project(x.r_λ),
        "r_P"=>_cfg_project(x.r_P),
        "r_U"=>_cfg_project(x.r_U),
        "r_n"=>_cfg_project(x.r_n),
        "r_neutral"=>_cfg_project(x.r_neutral),
        "r_J"=>_cfg_project(x.r_J),
        "r_C"=>_cfg_project(x.r_C),
        "r_power"=>_cfg_project(x.r_power),
        "r_PSD"=>_cfg_project(x.r_PSD),
        "r_caus"=>_cfg_project(x.r_caus),
        "r_sum"=>_cfg_project(x.r_sum),
        "r_obs"=>_cfg_project(x.r_obs),
        "r_ζ"=>_cfg_project(x.r_ζ),
        "r_imag"=>_cfg_project(x.r_imag),
        "r_tail"=>_cfg_project(x.r_tail),
        "r_edge"=>_cfg_project(x.r_edge),
        "r_roundoff"=>_cfg_project(x.r_roundoff),
    )
end
function _cfg_project(x::QCLNEGFRunner.DiagnosticQualityPolicy)
    return Dict{String,Any}(
        "enabled"=>_cfg_project(x.enabled),
        "keldysh_threshold"=>_cfg_project(x.keldysh_threshold),
        "self_energy_threshold"=>_cfg_project(x.self_energy_threshold),
        "normalization_threshold"=>_cfg_project(x.normalization_threshold),
        "required_consecutive_passes"=>_cfg_project(x.required_consecutive_passes),
        "target_fixed_point_threshold"=>_cfg_project(x.target_fixed_point_threshold),
        "coarse_wait_iterations"=>_cfg_project(x.coarse_wait_iterations),
        "strict_attempt_iterations"=>_cfg_project(x.strict_attempt_iterations),
        "observable_threshold"=>_cfg_project(x.observable_threshold),
        "positivity_threshold"=>_cfg_project(x.positivity_threshold),
        "causality_threshold"=>_cfg_project(x.causality_threshold),
        "outer_threshold"=>_cfg_project(x.outer_threshold),
    )
end
function _cfg_project(x::QCLNEGFRunner.ResearchTrendPolicy)
    return Dict{String,Any}(
        "window"=>_cfg_project(x.window),
        "minimum_reduction"=>_cfg_project(x.minimum_reduction),
        "promising_threshold"=>_cfg_project(x.promising_threshold),
        "max_regression"=>_cfg_project(x.max_regression),
        "max_oscillation"=>_cfg_project(x.max_oscillation),
    )
end
function _cfg_project(x::QCLNEGFRunner.ConvergencePolicy)
    return Dict{String,Any}(
        "mode"=>_cfg_project(x.mode),
        "trend"=>_cfg_project(x.trend),
        "minimum_scba_iterations"=>_cfg_project(x.minimum_scba_iterations),
        "required_consecutive_scba_passes"=>_cfg_project(x.required_consecutive_scba_passes),
        "minimum_poisson_iterations"=>_cfg_project(x.minimum_poisson_iterations),
        "required_consecutive_poisson_passes"=>_cfg_project(x.required_consecutive_poisson_passes),
        "stagnation_window"=>_cfg_project(x.stagnation_window),
        "stagnation_relative_improvement"=>_cfg_project(x.stagnation_relative_improvement),
        "diagnostic_quality"=>_cfg_project(x.diagnostic_quality),
    )
end
function _cfg_project(x::QCLNEGFRunner.SolverOptions)
    return Dict{String,Any}(
        "α_Σ"=>_cfg_project(x.α_Σ),
        "α_P"=>_cfg_project(x.α_P),
        "max_scba"=>_cfg_project(x.max_scba),
        "max_poisson"=>_cfg_project(x.max_poisson),
        "tolerances"=>_cfg_project(x.tolerances),
        "convergence"=>_cfg_project(x.convergence),
        "energy_tail_window_fraction"=>_cfg_project(x.energy_tail_window_fraction),
        "momentum_tail_window_fraction"=>_cfg_project(x.momentum_tail_window_fraction),
    )
end
function _cfg_project(x::QCLNEGFRunner.ScatteringOptions)
    return Dict{String,Any}(
        "LO"=>_cfg_project(x.LO),
        "acoustic"=>_cfg_project(x.acoustic),
        "impurity"=>_cfg_project(x.impurity),
        "IFR"=>_cfg_project(x.IFR),
        "alloy"=>_cfg_project(x.alloy),
    )
end
function _cfg_project(x::QCLNEGFRunner.ScaleSystem)
    return Dict{String,Any}(
        "E₀"=>_cfg_project(x.E₀),
        "L₀"=>_cfg_project(x.L₀),
        "m_ref"=>_cfg_project(x.m_ref),
        "E₀_eV"=>_cfg_project(x.E₀_eV),
        "E₀_J"=>_cfg_project(x.E₀_J),
        "L₀_m"=>_cfg_project(x.L₀_m),
        "λ_P"=>_cfg_project(x.λ_P),
        "J₀"=>_cfg_project(x.J₀),
    )
end
function _cfg_project(x::QCLNEGFRunner.PhysicalModelOptions)
    return Dict{String,Any}(
        "screening"=>_cfg_project(x.screening),
        "screening_temperature_K"=>Dict("value"=>x.screening_temperature_K,"unit"=>"K"),
        "screening_mass_ratio"=>_cfg_project(x.screening_mass_ratio),
        "dispersion"=>_cfg_project(x.dispersion),
        "nonparabolicity_per_eV"=>Dict("value"=>x.nonparabolicity_per_eV,"unit"=>"eV^-1"),
        "lo_population"=>_cfg_project(x.lo_population),
        "lo_fixed_occupation"=>_cfg_project(x.lo_fixed_occupation),
        "lo_decay_ps"=>Dict("value"=>x.lo_decay_ps,"unit"=>"ps"),
        "lo_mode_density_per_m3"=>Dict("value"=>x.lo_mode_density_per_m3,"unit"=>"m^-3"),
        "electron_electron"=>_cfg_project(x.electron_electron),
    )
end
function _cfg_project(x::QCLNEGFRunner.ElectronElectronOptions)
    return Dict{String,Any}(
        "mode"=>_cfg_project(x.mode),
        "screening_dimension"=>_cfg_project(x.screening_dimension),
        "transfer_wavenumber"=>_cfg_project(x.transfer_wavenumber),
        "electron_temperature"=>_cfg_project(x.electron_temperature),
        "effective_mass_ratio"=>_cfg_project(x.effective_mass_ratio),
        "carrier_density_si"=>Dict("value"=>x.carrier_density_si,"unit"=>(x.screening_dimension==2 ? "m^-2" : "m^-3")),
        "include_exchange"=>_cfg_project(x.include_exchange),
    )
end
function _cfg_project(x::QCLNEGFRunner.DomainAdaptationPolicy)
    return Dict{String,Any}(
        "mode"=>_cfg_project(x.mode),
        "maximum_expansions"=>_cfg_project(x.maximum_expansions),
        "maximum_energy_nodes"=>_cfg_project(x.maximum_energy_nodes),
        "growth_fraction"=>_cfg_project(x.growth_fraction),
        "tail_threshold"=>_cfg_project(x.tail_threshold),
    )
end
function _cfg_project(x::QCLNEGFRunner.AlgorithmOptions)
    return Dict{String,Any}(
        "solver_backend"=>_cfg_project(x.solver_backend),
        "energy_shift"=>_cfg_project(x.energy_shift),
        "hilbert"=>_cfg_project(x.hilbert),
        "contraction"=>_cfg_project(x.contraction),
        "kernel_build"=>_cfg_project(x.kernel_build),
        "mixing"=>_cfg_project(x.mixing),
        "localization"=>_cfg_project(x.localization),
        "embedding"=>_cfg_project(x.embedding),
        "embedding_periods"=>_cfg_project(x.embedding_periods),
        "occupation_normalization"=>_cfg_project(x.occupation_normalization),
        "low_rank_relative_tolerance"=>_cfg_project(x.low_rank_relative_tolerance),
        "low_rank_maximum_rank"=>_cfg_project(x.low_rank_maximum_rank),
        "anderson_history_depth"=>_cfg_project(x.anderson_history_depth),
        "anderson_damping"=>_cfg_project(x.anderson_damping),
        "anderson_regularization"=>_cfg_project(x.anderson_regularization),
        "retarded_real_part"=>_cfg_project(x.retarded_real_part),
        "self_energy_structure"=>_cfg_project(x.self_energy_structure),
        "transverse_momentum"=>_cfg_project(x.transverse_momentum),
    )
end
function _cfg_project(x::QCLNEGFRunner.SCBAPhysicsMarkerPolicy)
    return Dict{String,Any}(
        "cadence"=>_cfg_project(x.cadence),
        "max_spectral_blocks"=>_cfg_project(x.max_spectral_blocks),
        "relative_mode_weight_floor"=>_cfg_project(x.relative_mode_weight_floor),
    )
end
function _cfg_project(x::QCLNEGFRunner.ProductionOptions)
    return Dict{String,Any}(
        "memory_budget_bytes"=>_cfg_project(x.memory_budget_bytes),
        "energy_chunk"=>_cfg_project(x.energy_chunk),
        "hilbert_columns"=>_cfg_project(x.hilbert_columns),
        "parallel_backend"=>_cfg_project(x.parallel_backend),
        "worker_count"=>_cfg_project(x.worker_count),
        "residual_chunk"=>_cfg_project(x.residual_chunk),
        "phase_timing"=>_cfg_project(x.phase_timing),
        "physics_markers"=>_cfg_project(x.physics_markers),
        "verify_fft_roundoff"=>_cfg_project(x.verify_fft_roundoff),
        "checkpoint_every_outer"=>_cfg_project(x.checkpoint_every_outer),
        "checkpoint_every_scba"=>_cfg_project(x.checkpoint_every_scba),
        "progress_every_scba"=>_cfg_project(x.progress_every_scba),
        "progress_every_outer"=>_cfg_project(x.progress_every_outer),
        "algorithms"=>_cfg_project(x.algorithms),
        "event_sink"=>_cfg_project(x.event_sink),
        "checkpoint_request"=>_cfg_project(x.checkpoint_request),
        "phase_request"=>_cfg_project(x.phase_request),
        "outer_iteration"=>_cfg_project(x.outer_iteration),
    )
end
function _cfg_project(x::QCLNEGFRunner.ProductionKernelOptions)
    return Dict{String,Any}(
        "initial_lookup_nodes"=>_cfg_project(x.initial_lookup_nodes),
        "maximum_lookup_nodes"=>_cfg_project(x.maximum_lookup_nodes),
        "relative_tolerance"=>_cfg_project(x.relative_tolerance),
        "lookup_power"=>_cfg_project(x.lookup_power),
        "validation_fractions"=>_cfg_project(x.validation_fractions),
        "angular_validation_pairs"=>_cfg_project(x.angular_validation_pairs),
        "impurity_angular_tolerance"=>_cfg_project(x.impurity_angular_tolerance),
        "strict"=>_cfg_project(x.strict),
    )
end
function _cfg_project(x::QCLNEGFRunner.AutomaticExecutionConfiguration)
    return Dict{String,Any}(
        "memory_reserve_fraction"=>_cfg_project(x.memory_reserve_fraction),
        "minimum_memory_reserve_bytes"=>_cfg_project(x.minimum_memory_reserve_bytes),
        "workspace_budget_fraction"=>_cfg_project(x.workspace_budget_fraction),
        "workspace_complex_arrays_per_energy_block"=>_cfg_project(x.workspace_complex_arrays_per_energy_block),
        "minimum_outer_parallel_threads"=>_cfg_project(x.minimum_outer_parallel_threads),
        "large_basis_threshold"=>_cfg_project(x.large_basis_threshold),
        "minimum_energy_chunk"=>_cfg_project(x.minimum_energy_chunk),
        "energy_chunk_alignment"=>_cfg_project(x.energy_chunk_alignment),
        "blocks_per_worker"=>_cfg_project(x.blocks_per_worker),
        "hilbert_columns_per_worker"=>_cfg_project(x.hilbert_columns_per_worker),
        "energy_jobs_per_worker"=>_cfg_project(x.energy_jobs_per_worker),
    )
end
function _cfg_project(x::QCLNEGFRunner.ExecutionConfiguration)
    return Dict{String,Any}(
        "strategy"=>_cfg_project(x.strategy),
        "solver_backend"=>_cfg_project(x.solver_backend),
        "julia_threads"=>_cfg_project(x.julia_threads),
        "blas_threads"=>_cfg_project(x.blas_threads),
        "fail_on_thread_mismatch"=>_cfg_project(x.fail_on_thread_mismatch),
        "automatic"=>_cfg_project(x.automatic),
    )
end
function _cfg_project(x::QCLNEGFRunner.ProgressOutputConfiguration)
    return Dict{String,Any}(
        "enabled"=>_cfg_project(x.enabled),
        "terminal"=>_cfg_project(x.terminal),
        "significant_digits"=>_cfg_project(x.significant_digits),
        "human_every"=>_cfg_project(x.human_every),
        "event_log_file"=>_cfg_project(x.event_log_file),
        "latest_snapshot_file"=>_cfg_project(x.latest_snapshot_file),
        "dashboard_file"=>_cfg_project(x.dashboard_file),
    )
end
function _cfg_project(x::QCLNEGFRunner.DeviceGeometryConfiguration)
    return Dict{String,Any}(
        "periods"=>_cfg_project(x.periods),
        "ridge_width"=>_cfg_project(x.ridge_width),
        "cavity_length"=>_cfg_project(x.cavity_length),
    )
end
function _cfg_project(x::QCLNEGFRunner.OutputConfiguration)
    return Dict{String,Any}(
        "directory"=>_cfg_project(x.directory),
        "checkpoint_prefix"=>_cfg_project(x.checkpoint_prefix),
        "resume"=>_cfg_project(x.resume),
        "fail_fast"=>_cfg_project(x.fail_fast),
        "save_full_state"=>_cfg_project(x.save_full_state),
        "save_csv"=>_cfg_project(x.save_csv),
        "save_plots"=>_cfg_project(x.save_plots),
        "live_visualization"=>_cfg_project(x.live_visualization),
        "snapshot_every_scba"=>_cfg_project(x.snapshot_every_scba),
        "snapshot_every_outer"=>_cfg_project(x.snapshot_every_outer),
        "progress"=>_cfg_project(x.progress),
        "report_directory"=>_cfg_project(x.report_directory),
        "save_expert_markdown"=>_cfg_project(x.save_expert_markdown),
        "save_comparison_csv"=>_cfg_project(x.save_comparison_csv),
        "save_comparison_plots"=>_cfg_project(x.save_comparison_plots),
        "device_geometry"=>_cfg_project(x.device_geometry),
        "debug_hdf5"=>_cfg_project(x.debug_hdf5),
        "light_max_space_points"=>_cfg_project(x.light_max_space_points),
        "light_max_energy_points"=>_cfg_project(x.light_max_energy_points),
        "light_max_momentum_points"=>_cfg_project(x.light_max_momentum_points),
        "light_max_snapshots"=>_cfg_project(x.light_max_snapshots),
    )
end
function _cfg_project(x::QCLNEGFRunner.ConvergenceStudyConfiguration)
    return Dict{String,Any}(
        "spatial_nodes"=>_cfg_project(x.spatial_nodes),
        "energy_nodes"=>_cfg_project(x.energy_nodes),
        "momentum_nodes"=>_cfg_project(x.momentum_nodes),
        "angular_nodes"=>_cfg_project(x.angular_nodes),
    )
end
function _cfg_project(x::QCLNEGFRunner.StudyMethodConfiguration)
    return Dict{String,Any}(
        "profile"=>_cfg_project(x.profile),
        "label"=>_cfg_project(x.label),
        "modifies_physics"=>_cfg_project(x.modifies_physics),
        "algorithm_family"=>_cfg_project(x.algorithm_family),
        "description"=>_cfg_project(x.description),
        "literature"=>_cfg_project(x.literature),
    )
end
function _cfg_project(x::QCLNEGFRunner.StudyConfiguration)
    return Dict{String,Any}(
        "mode"=>_cfg_project(x.mode),
        "voltages_per_period"=>_cfg_project(x.voltages_per_period),
        "temperatures"=>_cfg_project(x.temperatures),
        "comparison_profiles"=>_cfg_project(x.comparison_profiles),
        "reference_profile"=>_cfg_project(x.reference_profile),
        "methods"=>_cfg_project(x.methods),
        "repetitions"=>_cfg_project(x.repetitions),
        "calculate_optical_response"=>_cfg_project(x.calculate_optical_response),
        "photon_energy_min"=>_cfg_project(x.photon_energy_min),
        "photon_energy_max"=>_cfg_project(x.photon_energy_max),
        "photon_energy_points"=>_cfg_project(x.photon_energy_points),
        "optical_edge_tolerance"=>_cfg_project(x.optical_edge_tolerance),
        "convergence"=>_cfg_project(x.convergence),
    )
end
function _cfg_default_rule_sources()
    core_entry=pathof(QCLNEGFRunner.QCLNEGF)
    core_entry===nothing && _cfg_refuse("unsupported_projection")
    core_root=dirname(core_entry)
    result=Dict{String,String}()
    for (owner,root,paths) in (
        ("Runner",_package_path("src"),("infrastructure/config/configuration.jl",)),
        ("Core",core_root,("domain/types.jl","domain/electron_electron.jl","domain/algorithm_options.jl",
            "numerics/optimized/production_contracts.jl","numerics/optimized/kernels.jl")))
        for path in paths
            file=joinpath(root,path)
            isfile(file) || _cfg_refuse("unsupported_projection")
            result[owner*":src/"*path]=_cfg_sha(read(file))
        end
    end
    return result
end

function _cfg_effective(configuration)
    # Each projection points to its actual owning loader rule, which can combine
    # inputs and constructor defaults. Histories are complete rule inputs, NOT
    # invented per-field assigning sources or equality-based default guesses.
    result=Dict{String,Any}()
    for (field,section,rule) in (
        (:physical,"physical","_parse_physical"),(:numerical,"numerical","_parse_numerical"),
        (:scales,"scales","_parse_scales"),(:scattering,"scattering","_parse_scattering"),
        (:solver,"solver","_parse_solver"),(:production,"production","_parse_production"),
        (:kernels,"kernel_construction","_parse_kernels"),(:algorithms,"algorithms","_parse_algorithms"),
        (:execution,"execution","_parse_execution"),(:output,"output","_parse_output"),
        (:study,"study","_parse_study"),(:physical_models,"physical_models","_parse_physical_models"),
        (:domain_adaptation,"domain_adaptation","_parse_domain_adaptation"))
        histories=Dict(k=>copy(v) for (k,v) in configuration.provenance.sources if startswith(k,section*"."))
        result[section]=Dict("used"=>_cfg_project(getproperty(configuration,field)),
            "origin"=>"owning_resolution_rule", "rule_source"=>"Runner:src/infrastructure/config/configuration.jl@sha256:"*
                _cfg_sha(read(_package_path("src","infrastructure","config","configuration.jl")))*"#"*rule,
            "input_assigning_histories"=>histories)
    end
    return result
end

function _configurator_preview(bytes::AbstractString,root,source_id)
    request=_configurator_json(bytes)
    _cfg_keys(request,("mode","template_id","catalog_source_id","fields","yaml");required=("mode","template_id","catalog_source_id"))
    request["catalog_source_id"]==source_id || _cfg_refuse("catalog_source_mismatch")
    mode=request["mode"]; mode in ("form","yaml") || _cfg_refuse("invalid_mode")
    haskey(request,mode=="form" ? "fields" : "yaml") && !haskey(request,mode=="form" ? "yaml" : "fields") || _cfg_refuse("exclusive_payload")
    catalog=_configurator_catalog(root,source_id)
    entries=filter(e->e["id"]==request["template_id"],catalog["templates"])
    length(entries)==1 || _cfg_refuse("unknown_template")
    entry=only(entries); study_path=_configurator_path(root,entry["study"])
    template=_configurator_yaml(read(study_path,String))
    draft=if mode=="form"
        _configurator_form(template,request["fields"])
    else
        request["yaml"] isa AbstractString || _cfg_refuse("invalid_yaml")
        _configurator_yaml(request["yaml"])
    end
    get(draft,"kind","study")=="study" && !haskey(draft,"includes") && !haskey(draft,"select") || _cfg_refuse("unsupported_study_kind")
    config=_cfg_keys(get(draft,"configuration",nothing),("sources","overrides");required=("sources",),path="configuration")
    sources=config["sources"]; sources isa AbstractVector && 1<=length(sources)<=16 || _cfg_refuse("source_limit")
    allowed=Set(_configurator_path(root,entry[k]["path"]) for k in ("model","protocol"))
    raw=Dict{String,Any}(); provenance=Dict{String,Vector{String}}(); files=String[]
    total=0
    # Capture and validate every permitted source before calling the resolver.
    for relative in sources
        relative isa AbstractString && !isabspath(relative) || _cfg_refuse("foreign_path","configuration.sources")
        path=_configurator_path(root,relpath(joinpath(dirname(study_path),relative),root))
        path in allowed || _cfg_refuse("non_catalog_source","configuration.sources")
        total+=filesize(path); total<=CONFIGURATOR_CAPTURE_BYTES || _cfg_refuse("catalog_limit")
        text=read(path,String); mapping=_configurator_yaml(text)
        label="/@qcl-configurator/research/"*_cfg_sha(source_id)*"/"*relpath(path,realpath(root))*"@sha256:"*_cfg_sha(text)
        push!(files,label); _deep_merge!(raw,mapping,provenance,label)
    end
    # Canonical semantic domain is independent of request bytes/mode. Relative
    # source spellings normalize to catalog-relative identities in this hash only.
    semantic=deepcopy(draft)
    semantic["configuration"]["sources"]=files
    logical="/@qcl-configurator/draft/"*_cfg_sha(source_id)*"/"*_cfg_sha(canonical_bytes(semantic))
    parsed=_parse_scientific_definition(study_path,draft)
    definition=ScientificDefinition(logical,parsed.id,parsed.name,parsed.kind,parsed.tags,
        parsed.children,parsed.configuration_sources,parsed.overrides,parsed.variants,
        parsed.temperatures,parsed.branches,parsed.policies,parsed.outputs,parsed.purpose,
        parsed.repetitions,parsed.operation)
    QCLNEGFRunner.validate_configuration_schema(raw)
    base=_resolve_configuration(raw,ConfigurationProvenance(String[],files,provenance))
    repository=CapturedConfiguratorDefinition(definition,base)
    plan=resolve_scientific_plan(repository,logical;maximum_solver_runs=100)
    length(plan.executions)<=100 || _cfg_refuse("execution_limit")
    data=scientific_plan_dict(plan)
    frozen=sprint(io->write_scientific_plan(io,plan))
    ncodeunits(frozen)<=CONFIGURATOR_PLAN_BYTES || _cfg_refuse("plan_limit")
    effective=Any[]
    for execution in plan.executions
        point_sections=Any[]
        for point in plan.points
            point.execution_id==execution.id || continue
            point_raw=_point_resolved_raw(execution.configuration,point)
            point_configuration=_resolve_configuration(point_raw,execution.configuration.provenance)
            push!(point_sections,Dict("point_id"=>point.id,"sections"=>_cfg_effective(point_configuration)))
        end
        push!(effective,Dict("execution_id"=>execution.id,
            "sections"=>_cfg_effective(execution.configuration),"point_sections"=>point_sections))
    end
    # YAML remains authoritative. Return a short projection only for exact
    # template equivalence; expert/variant drafts are explicitly read-only.
    lossless=canonical_bytes(draft)==canonical_bytes(template)
    return Dict{String,Any}("status"=>"available","draft_sha256"=>_cfg_sha(bytes),
        "semantic_draft_sha256"=>_cfg_sha(canonical_bytes(semantic)),"catalog_source_id"=>source_id,
        "template"=>entry,"draft_yaml"=>YAML.write(draft),
        "short_form"=>Dict("lossless"=>lossless,"reason"=>(lossless ? nothing : "authoritative_yaml_requires_preservation")),
        "variant_diffs"=>[Dict("id"=>v.id,"comparison_kind"=>String(v.comparison_kind),
            "controlled_paths"=>v.controlled_paths,"overrides"=>deepcopy(v.overrides)) for v in parsed.variants],
        "resolved_inputs"=>[Dict("execution_id"=>e.id,"configuration"=>deepcopy(e.configuration.raw),
            "assigning_sources"=>deepcopy(e.configuration.provenance.sources)) for e in plan.executions],
        "effective_defaults"=>effective,"default_rule_sources"=>_cfg_default_rule_sources(),"plan"=>frozen,"plan_sha256"=>_cfg_sha(frozen),
        "fingerprint"=>data["fingerprint"],"scientific_fingerprint"=>data["scientific_fingerprint"],
        "counts"=>Dict("points"=>length(plan.points),"executions"=>length(plan.executions)),
        "estimates"=>data["resources"])
end

"""Bounded metadata preview; never runs/admits/submits a scientific execution."""
function configurator_preview(bytes::AbstractString,root::AbstractString,source_id::AbstractString)
    response=try
        _configurator_preview(bytes,root,source_id)
    catch error
        code=error isa ConfiguratorRefusal ? error.code : "invalid_configuration"
        # Public errors contain neither filesystem locators nor parser traceback.
        path=error isa ConfiguratorRefusal ? error.path : "draft"
        if error isa QCLNEGFRunner.ConfigurationError &&
           ncodeunits(error.path)<=256 && occursin(r"^[A-Za-z0-9_.\[\]-]+$",error.path)
            path=error.path
        end
        Dict("status"=>"error","error"=>Dict("code"=>code,"path"=>path,"message"=>"Preview refused: "*code))
    end
    response=_cfg_dto(response)
    ncodeunits(_cfg_json(response))<=CONFIGURATOR_RESPONSE_BYTES || return Dict(
        "status"=>"error","error"=>Dict("code"=>"response_limit","path"=>"response","message"=>"Preview response exceeds bound"))
    return response
end
function configurator_catalog(root::AbstractString,source_id::AbstractString)
    try
        return _cfg_dto(_configurator_catalog(root,source_id))
    catch
        return Dict("status"=>"error","error"=>Dict("code"=>"catalog_unavailable","path"=>"catalog","message"=>"Trusted catalog unavailable"))
    end
end
