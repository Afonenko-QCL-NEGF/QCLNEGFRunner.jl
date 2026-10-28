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

include("structure_editor.jl")

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
            point_configuration=_point_resolved_configuration(execution.configuration,point)
            push!(point_sections,Dict("point_id"=>point.id,"sections"=>resolved_snapshot_dict(resolved_configuration_snapshot(point_configuration))["sections"]))
        end
        push!(effective,Dict("execution_id"=>execution.id,
            "sections"=>resolved_snapshot_dict(resolved_configuration_snapshot(execution.configuration))["sections"],"point_sections"=>point_sections))
    end
    # YAML remains authoritative. Return a short projection only for exact
    # template equivalence; expert/variant drafts are explicitly read-only.
    lossless=canonical_bytes(draft)==canonical_bytes(template)
    default_rules=_cfg_default_rule_sources()
    diffs=Any[]
    # Match the planner's configured comparison baseline, even when the study
    # has only changed variants or declares its baseline after them.
    baseline=resolve_scientific_configuration(repository,definition,
        ScientificVariant("comparison-baseline","configured",Dict{String,Any}(),
            String[],:controlled_axis),Dict{String,Any}())
    for execution in plan.executions
        variant=only(v for v in parsed.variants if v.id==execution.variant_id)
        push!(diffs,merge(Dict("id"=>variant.id,"comparison_kind"=>String(variant.comparison_kind),
            "overrides"=>deepcopy(variant.overrides)),resolved_configuration_diff(
                baseline,execution.configuration;controlled_paths=variant.controlled_paths)))
    end
    return Dict{String,Any}("status"=>"available","draft_sha256"=>_cfg_sha(bytes),
        "semantic_draft_sha256"=>_cfg_sha(canonical_bytes(semantic)),"catalog_source_id"=>source_id,
        "template"=>entry,"draft_yaml"=>YAML.write(draft),
        "short_form"=>Dict("lossless"=>lossless,"reason"=>(lossless ? nothing : "authoritative_yaml_requires_preservation")),
        "variant_diffs"=>diffs,
        "resolved_snapshots"=>[Dict("execution_id"=>e["id"],"snapshot"=>e["resolved_snapshot"]) for e in data["executions"]],
        "resource_estimates"=>[Dict("execution_id"=>e["id"],"estimate"=>e["resource_estimate"]) for e in data["executions"]],
        "resolved_inputs"=>[Dict("execution_id"=>e.id,"configuration"=>deepcopy(e.configuration.raw),
            "assigning_sources"=>deepcopy(e.configuration.provenance.sources)) for e in plan.executions],
        "effective_defaults"=>effective,"default_rule_sources"=>default_rules,
        "structure_editor"=>_cfg_structure_editor(plan,entry,source_id,default_rules),
        "plan"=>frozen,"plan_sha256"=>_cfg_sha(frozen),
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
        if error isa QCLNEGFRunner.ConfigurationError
            refusal=first(split(error.message,':';limit=2))
            refusal in ("unsupported_snapshot_phase","unsupported_projection",
                "invalid_controlled_path","invalid_controlled_counterfactual","snapshot_mismatch") &&
                (code=refusal)
        end
        # Public errors contain neither filesystem locators nor parser traceback.
        path=error isa ConfiguratorRefusal ? error.path : "draft"
        if error isa QCLNEGFRunner.ConfigurationError &&
           ncodeunits(error.path)<=256 && occursin(r"^[A-Za-z0-9_.\[\]-]+$",error.path)
            path=error.path
        end
        Dict("status"=>"error","error"=>Dict("code"=>code,"path"=>path,"message"=>"Preview refused: "*code))
    end
    response=_cfg_dto(response)
    # An additive editor must not invalidate an otherwise valid bounded preview.
    if get(response,"status",nothing)=="available" &&
       ncodeunits(_cfg_json(response))>CONFIGURATOR_RESPONSE_BYTES
        response["structure_editor"]=_cfg_structure_unavailable()
    end
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
