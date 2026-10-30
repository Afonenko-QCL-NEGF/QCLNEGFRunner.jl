# Stored observations are outside the frozen exact-state graph. No numerical policy lives here.
const _P05_ANALYSIS_SCHEMA="qcl-negf-physics-analysis-v5"
const _P05_SCATTERING=("LO","acoustic","impurity","IFR","alloy")
const _P05_PLAN_FORMATS=Dict(:scientific_plan_v2=>("qcl-negf-scientific-plan-v2","application/json"),
    :nested_sweep=>("qcl-negf.nested-sweep-plan.v1","text/plain"))
_p05_add(a::Int,b::Int)=Base.checked_add(a,b)
_p05_mul(a::Int,b::Int)=Base.checked_mul(a,b)
const _P05_SCHEMA_WORKSPACE=8*1024^2
function _p05_cap(value)
    _p04_require(value isa Int && !(value isa Bool) && value>0,"final metadata/allocation cap must be positive Int")
    value
end
function _p05_charge!(remaining,n::Int)
    _p04_require(0<=n<=remaining[],"aggregate final metadata allowance exceeded")
    remaining[]-=n;nothing
end

# Conservative Julia object/string/JSON allowance, counted before constructing wire trees.
# Numeric payload arrays are descriptors here; their separate numeric residency is charged by Core.
function _p05_metadata_cost(value,limit::Int;portable=false)
    remaining=Ref(_p05_cap(limit))
    function visit(x,depth)
        _p04_require(depth<=256,"final metadata depth exceeds256")
        _p05_charge!(remaining,4096)
        if x isa String
            _p04_require(isvalid(x),"invalid UTF-8 metadata")
            _p05_charge!(remaining,_p05_mul(16,ncodeunits(x)))
        elseif x isa AbstractDict
            for (k,v) in x;visit(k,depth+1);visit(v,depth+1);end
        elseif x isa AbstractArray
            if !portable && isbitstype(eltype(x)) && eltype(x)<:Number
                _p05_charge!(remaining,_p05_mul(4096,ndims(x)+8))
            else
                for item in x;visit(item,depth+1);end
            end
        elseif x isa Tuple
            for item in x;visit(item,depth+1);end
        elseif !(x===nothing || x isa Union{Number,Bool,Symbol})
            for name in fieldnames(typeof(x));visit(getfield(x,name),depth+1);end
        end
        nothing
    end
    visit(value,0);limit-remaining[]
end

mutable struct _P05JSONBuffer <: IO
    buffer::IOBuffer
    remaining::Int
end
Base.iswritable(::_P05JSONBuffer)=true
function Base.unsafe_write(io::_P05JSONBuffer,p::Ptr{UInt8},n::UInt)
    _p04_require(n<=io.remaining,"final JSON byte allowance exceeded")
    io.remaining-=Int(n);Base.unsafe_write(io.buffer,p,n)
end
function Base.write(io::_P05JSONBuffer,x::UInt8)
    _p04_require(io.remaining>0,"final JSON byte allowance exceeded")
    io.remaining-=1;write(io.buffer,x)
end
function _p05_json(value,limit::Int)
    io=_P05JSONBuffer(IOBuffer(),_p05_cap(limit));_p04_json(io,value)
    String(take!(io.buffer))
end
_p05_decode(value,T)=_p04_decode(value,T,(;validate_only=true))
_p05_f64(value::Float64)=Dict("kind"=>"ieee","type"=>"f64","bits"=>string(reinterpret(UInt64,value);base=16,pad=16))
_p05_int(value::Int)=Dict("kind"=>"integer","type"=>"Int64","decimal"=>string(value))
_p05_flags(value::QCLNEGF.ScatteringOptions)=Dict(string(name)=>getfield(value,name) for name in fieldnames(typeof(value)))
function _p05_portable(value,depth=0)
    _p04_require(depth<=256,"portable metadata exceeds depth")
    if value isa AbstractDict
        _p04_require(all(k->k isa String && isvalid(k),keys(value)),"portable keys must be UTF-8 strings")
        for child in values(value);_p05_portable(child,depth+1);end
    elseif value isa AbstractVector
        for child in value;_p05_portable(child,depth+1);end
    else
        _p04_require(value===nothing || value isa Union{Bool,Integer} || value isa String && isvalid(value) ||
            value isa AbstractFloat && isfinite(value),"nonportable/nonfinite metadata")
    end
    value
end

struct FinalPointRequest
    plan_ref::Dict{String,Any}
    model_ref::Dict{String,Any}
    temperature_K::Float64
    voltage_per_period_V::Float64
    scattering_requested::QCLNEGF.ScatteringOptions
    kind::Symbol
    function FinalPointRequest(;plan_ref::AbstractDict,model_ref::AbstractDict,temperature_K::Float64,
        voltage_per_period_V::Float64,scattering_requested::QCLNEGF.ScatteringOptions,kind::Symbol)
        _p04_require(haskey(_P05_PLAN_FORMATS,kind) && all(isfinite,(temperature_K,voltage_per_period_V)),"invalid final request kind/coordinates")
        for reference in (plan_ref,model_ref);_p04_file_fields(reference);end
        schema,media=_P05_PLAN_FORMATS[kind]
        _p04_require(plan_ref["schema"]==schema && plan_ref["media_type"]==media &&
            model_ref["schema"]=="qcl-negf-resolved-configuration-v3" && model_ref["media_type"]=="application/json" &&
            plan_ref["path"]!=model_ref["path"],"final input reference profile differs")
        new(deepcopy(plan_ref),deepcopy(model_ref),temperature_K,voltage_per_period_V,scattering_requested,kind)
    end
end

function _p05_yaml_impl(bytes::Vector{UInt8},limit::Int)
    _p04_require(length(bytes)<=limit,"nested YAML byte allowance exceeded")
    text=String(copy(bytes));_p04_require(isvalid(text),"invalid UTF-8 YAML")
    events=YAML.EventStream(YAML.TokenStream(IOBuffer(text)))
    depth=0;documents=0;remaining=Ref(limit)
    while true
        event=YAML.forward!(events);event===nothing && break
        _p05_charge!(remaining,4096)
        _p04_require(!(event isa YAML.AliasEvent),"YAML aliases are forbidden")
        if event isa YAML.DocumentStartEvent
            documents+=1
            _p04_require(documents==1 && (event.tags===nothing || isempty(event.tags)),"YAML multiple documents/tag directives forbidden")
        elseif event isa Union{YAML.ScalarEvent,YAML.SequenceStartEvent,YAML.MappingStartEvent}
            _p04_require(event.anchor===nothing,"YAML anchors are forbidden")
            _p04_require(event.tag===nothing || event.tag in ("tag:yaml.org,2002:str","tag:yaml.org,2002:int",
                "tag:yaml.org,2002:float","tag:yaml.org,2002:bool","tag:yaml.org,2002:null",
                "tag:yaml.org,2002:seq","tag:yaml.org,2002:map"),"YAML nonportable tag forbidden")
            if event isa YAML.ScalarEvent
                _p05_charge!(remaining,ncodeunits(event.value))
            else
                depth+=1;_p04_require(depth<=256,"YAML nesting exceeds256")
            end
        elseif event isa Union{YAML.SequenceEndEvent,YAML.MappingEndEvent}
            depth-=1
        end
    end
    value=try
        QCLSchemaProvenance._strict_mapping_from_bytes(bytes,"final frozen plan";metadata=true)
    catch error
        error isa QCLSchemaProvenance.SchemaProvenanceError || rethrow()
        throw(ArgumentError(sprint(showerror,error)))
    end
    _p05_portable(value)
end

function _p05_yaml(bytes::Vector{UInt8},limit::Int)
    try
        _p05_yaml_impl(bytes,limit)
    catch error
        error isa Union{YAML.ScannerError,YAML.ParserError,YAML.ComposerError,YAML.ConstructorError,QCLSchemaProvenance.SchemaProvenanceError} || rethrow()
        throw(ArgumentError(sprint(showerror,error)))
    end
end
# Count JSON tokens before the existing strict parser allocates its object tree.
function _p05_parse(text::String,budget)
    _p05_string(text);_p05_charge!(budget,_p05_mul(32,ncodeunits(text)))
    quoted=false;escaped=false;token=false;depth=0
    for byte in codeunits(text)
        if quoted
            if escaped;escaped=false
            elseif byte==0x5c;escaped=true
            elseif byte==0x22;quoted=false
            end
        elseif byte==0x22
            _p05_charge!(budget,4096);quoted=true;token=false
        elseif byte in (0x7b,0x5b)
            _p05_charge!(budget,4096);depth+=1;_p04_require(depth<=256,"JSON metadata nesting exceeds256");token=false
        elseif byte in (0x7d,0x5d)
            depth-=1;token=false
        elseif byte in (0x20,0x09,0x0a,0x0d,0x2c,0x3a)
            token=false
        elseif !token
            _p05_charge!(budget,4096);token=true
        end
    end
    _p04_parse(text)
end

_p05_name(value)=_p04_require(value isa String && occursin(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}\z",value),"invalid nested plan name")
function _p05_nested_plan(value)
    _p04_keys(value,("name","root"));_p05_name(value["name"])
    paths=Set{String}();node=value["root"];depth=0
    while true
        depth+=1;_p04_require(depth<=256,"nested tree exceeds bound")
        _p05_name(node["name"])
        if node["kind"]=="leaf"
            _p04_keys(node,("kind","name"));break
        end
        _p04_keys(node,("kind","name","axes","child"))
        _p04_require(node["kind"]=="level" && node["axes"] isa AbstractVector && !isempty(node["axes"]),"invalid nested level")
        names=Set{String}()
        for axis in node["axes"]
            _p04_keys(axis,("name","values"));_p05_name(axis["name"])
            path=node["name"]*"."*axis["name"]
            _p04_require(!(axis["name"] in names) && !(path in paths) && axis["values"] isa AbstractVector && !isempty(axis["values"]),"duplicate/empty axis")
            push!(names,axis["name"]);push!(paths,path)
            canonical=Set{Vector{UInt8}}()
            for item in axis["values"]
                code=canonical_bytes(item);_p04_require(!(code in canonical),"duplicate canonical axis value");push!(canonical,code)
            end
        end
        node=node["child"]
    end
    value
end
function _p05_model(value,identity,flags)
    _p04_keys(value,("schema","contract_set","configuration","configuration_hash","hash_encoding"))
    _p04_require(value["schema"]=="qcl-negf-resolved-configuration-v3" && value["contract_set"]==_P04_CONTRACT &&
        value["hash_encoding"]=="qcl-negf-canonical-bytes-v1","unsupported final point model")
    model=value["configuration"];_p04_keys(model,("scope","inputs","derived"))
    _p04_require(model["scope"]=="stationary_transport_inputs_v1","wrong point model scope")
    _p04_keys(model["inputs"],("physical","numerical","scales","scattering","solver","kernel_construction","algorithms","physical_models","domain_adaptation","production"))
    for (name,section) in model["inputs"];_p04_require(section isa AbstractDict,"model section must be mapping");end
    _p04_keys(model["inputs"]["production"],("physics_markers","verify_fft_roundoff"))
    _p04_require(model["inputs"]["production"]["verify_fft_roundoff"] isa Bool,"roundoff request must be Bool")
    _p04_keys(model["inputs"]["scattering"],_P05_SCATTERING)
    _p04_require(all(x->x isa Bool,values(model["inputs"]["scattering"])) && model["inputs"]["scattering"]==flags,"requested model scattering differs")
    _p04_keys(model["derived"],("effective_seed_eV",));_p05_portable(model)
    _p04_require(model["derived"]["effective_seed_eV"] isa Real && !(model["derived"]["effective_seed_eV"] isa Bool),"effective seed must be numeric")
    _p04_require(value["configuration_hash"]==identity["model_sha256"]==bytes2hex(sha256(canonical_bytes(model))),"canonical actual point model differs")
    value
end
function _p05_plan(value,identity,request)
    T,V=request.temperature_K,request.voltage_per_period_V
    bits(x)=_p05_f64(Float64(x))
    if request.kind===:nested_sweep
        _p05_nested_plan(value);_p04_require(value["name"]=="configured_operating_points","configured plan differs")
        node=value["root"]
        for (level,axis,coordinate) in (("temperature","temperature_K",T),("voltage","voltage_per_period_V",V))
            _p04_require(node["kind"]=="level" && node["name"]==level && length(node["axes"])==1 && node["axes"][1]["name"]==axis,"configured coordinate tree differs")
            values=node["axes"][1]["values"]
            _p04_require(all(x->x isa Real && !(x isa Bool) && isfinite(Float64(x)),values) &&
                any(x->bits(x)==bits(coordinate),values),"coordinate absent from frozen plan")
            node=node["child"]
        end
        _p04_require(node==Dict("kind"=>"leaf","name"=>"poisson_scba"),"configured leaf differs")
    else
        _p04_keys(value,("schema","model_revision","root_definition_id","root_kind","name","fingerprint","scientific_fingerprint",
            "maximum_solver_runs","computation_count","inclusions","executions","points","resources","nodes","campaign","science_archive_preflight","resolved_snapshot_schema"))
        _p04_require(value["schema"]=="qcl-negf-scientific-plan-v2" && value["resolved_snapshot_schema"]=="qcl-negf-resolved-configuration-v1","wrong scientific plan")
        _p05_scientific_profile(value)
        points=filter(p->p["id"]==identity["point_id"],value["points"])
        executions=filter(e->e["id"]==identity["execution_id"],value["executions"])
        _p04_require(length(points)==length(executions)==1,"scientific point/execution absent/ambiguous")
        point=only(points);execution=only(executions);passport=point["effective_inputs"]
        _p04_require(point["execution_id"]==execution["id"] && point["id"] in execution["point_ids"] &&
            passport["axes_applied"]===true && passport["model_sha256"]==identity["model_sha256"],"point membership/model differs")
        for (key,coordinate) in (("temperature_K",T),("voltage_per_period_V",V))
            _p04_require(bits(point[key])==bits(passport[key])==bits(coordinate),"scientific coordinate/passport differs")
        end
    end
    value
end

function _p05_input_ref(root,ref,budget)
    _p04_file_fields(ref);path=_p04_path(root,ref["path"])
    _p04_require(isfile(path) && filesize(path)<=budget[],"input metadata budget/missing file")
    open(path,"r") do io
        before=_p04_stat(stat(io));_p04_require(before==_p04_stat(stat(path)),"input path rebound")
        _p05_charge!(budget,_p05_mul(7,Int(before[3])))
        text=_p04_read_json_text(io,budget,before[3]);bytes=Vector{UInt8}(codeunits(text))
        _p04_require(before==_p04_stat(stat(io)) && before==_p04_stat(stat(_p04_path(root,ref["path"]))) &&
            string(length(bytes))==ref["bytes"] && bytes2hex(sha256(bytes))==ref["sha256"],"input FileRef bytes/hash differ")
        if ref["media_type"]=="application/json"
            _p05_parse(text,budget)
        else
            value=_p05_yaml(bytes,budget[])
            _p05_charge!(budget,_p05_metadata_cost(value,budget[];portable=true));value
        end
    end
end

# Exact published descriptor profile; source-binding inventory records the owning schema SHA.
const _P05_VIEW_SPECS=(
    ("context","x_scaled","Float64",Any["z"],"1",Any["z_nm"],Any["wX"],false),
    ("context","wX","Float64",Any["z"],"1",Any["z_nm"],Any["wX"],false),
    ("context","energy_scaled","Float64",Any["E"],"1",Any["energy_eV"],Any["wE"],false),
    ("context","wE","Float64",Any["E"],"1",Any["energy_eV"],Any["wE"],false),
    ("context","momentum_scaled","Float64",Any["k"],"1",Any["k_per_nm"],Any["wk"],false),
    ("context","wk","Float64",Any["k"],"1",Any["k_per_nm"],Any["wk"],false),
    ("context","z_nm","Float64",Any["z"],"nm",Any["z_nm"],Any["wX"],false),
    ("context","energy_eV","Float64",Any["E"],"eV",Any["energy_eV"],Any["wE"],false),
    ("context","k_per_nm","Float64",Any["k"],"nm^-1",Any["k_per_nm"],Any["wk"],false),
    ("context","state_index","Int64",Any["state"],"1",Any["state_index"],Any[nothing],false),
    ("context","trusted_energy","Bool",Any["E"],"1",Any["energy_eV"],Any["wE"],false),
    ("views","potential_structure_eV","Float64",Any["z"],"eV",Any["z_nm"],Any["wX"],false),
    ("views","potential_external_eV","Float64",Any["z"],"eV",Any["z_nm"],Any["wX"],false),
    ("views","potential_hartree_eV","Float64",Any["z"],"eV",Any["z_nm"],Any["wX"],false),
    ("views","potential_total_eV","Float64",Any["z"],"eV",Any["z_nm"],Any["wX"],false),
    ("views","density_per_m3","Float64",Any["z"],"m^-3",Any["z_nm"],Any["wX"],false),
    ("views","spatial_energy_density_per_eV_m3","Float64",Any["E","z"],"eV^-1 m^-3",Any["energy_eV","z_nm"],Any["wE","wX"],true),
    ("views","spectral_trace_per_eV","Float64",Any["E","k"],"eV^-1",Any["energy_eV","k_per_nm"],Any["wE","wk"],false),
    ("views","occupied_trace_per_eV","Float64",Any["E","k"],"eV^-1",Any["energy_eV","k_per_nm"],Any["wE","wk"],false),
    ("views","localized_levels_eV","Float64",Any["state"],"eV",Any["state_index"],Any[nothing],true),
    ("views","effective_levels_eV","Float64",Any["state"],"eV",Any["state_index"],Any[nothing],true),
    ("views","localized_wavefunctions_per_sqrt_nm","ComplexF64",Any["z","state"],"nm^-1/2",Any["z_nm","state_index"],Any["wX",nothing],false),
    ("views","effective_wavefunctions_per_sqrt_nm","ComplexF64",Any["z","state"],"nm^-1/2",Any["z_nm","state_index"],Any["wX",nothing],true),
    ("views","effective_transform","ComplexF64",Any["state","state_prime"],"1",Any["state_index","state_index"],Any[nothing,nothing],true),
    ("views","sheet_density_matrix_per_m2","ComplexF64",Any["state","state_prime"],"m^-2",Any["state_index","state_index"],Any[nothing,nothing],false),
    ("views","effective_density_matrix_per_m2","ComplexF64",Any["state","state_prime"],"m^-2",Any["state_index","state_index"],Any[nothing,nothing],true),
)
const _P05_CONTEXT_SYMBOLS=Dict(
    "energy_shift_discretization"=>["nodal_linear", "finite_volume_piecewise_constant"],
    "localization"=>["pzp", "none", "real_space"],
    "boundary_condition"=>["stationary_field_periodic_embedding"],
    "basis_contract"=>["orthonormal_finite_projected"],
    "energy_reference"=>["scaled_E0_plus_E_ref"],
    "effective_gauge"=>["k0_ascending_spatial_first_max_real_positive"],
)

_p05_string(x;nonblank=false,maximum=typemax(Int))=_p04_require(x isa String && isvalid(x) &&
    length(x)<=maximum && (!nonblank || !isempty(strip(x))),"invalid final plain string")
function _p05_descriptor(group,name,array,spec)
    owner,field,type,axes,units,coordinates,weights,nullable=spec
    _p04_require(string(eltype(array))==type,"local array dtype differs")
    Dict{String,Any}("dataset"=>"/"*group*"/arrays/"*name,"eltype"=>type,
        "shape"=>string.(collect(size(array))),"order"=>"F","axes"=>copy(axes),"units"=>units,
        "coordinate_fields"=>copy(coordinates),"weight_fields"=>copy(weights))
end
function _p05_view_records(snapshot::QCLNEGF.FinalObservationSnapshot,arrays)
    c=snapshot.context;v=snapshot.views
    _p04_require(c.inputs.g_s>=0,"g_s is negative")
    context=Dict{String,Any}("dimensions"=>Dict(name=>string(n) for (name,n) in zip(("Nz","NE","Nk","Nb"),c.dimensions)),
        "domain_revision"=>_p05_int(c.domain_revision),"discretization_id"=>c.discretization_id,"basis_id"=>c.basis_id,
        "scales"=>Dict(string(n)=>_p05_f64(getfield(c.scales,n)) for n in fieldnames(QCLNEGF.FinalObservationScales)),
        "inputs"=>Dict(string(n)=>(n===:g_s ? _p05_int(getfield(c.inputs,n)) : _p05_f64(getfield(c.inputs,n)))
            for n in fieldnames(QCLNEGF.FinalObservationInputs)),
        "problem_scattering"=>_p04_encode(c.problem_scattering,Any[]),
        "enabled_scattering"=>String.(collect(c.enabled_scattering)),"selfenergy_families"=>String.(collect(c.selfenergy_families)),
        "physical_models"=>_p04_encode(c.physical_models,Any[]),"algorithms"=>_p04_encode(c.algorithms,Any[]))
    for (name,allowed) in _P05_CONTEXT_SYMBOLS
        value=String(getfield(c,Symbol(name)));_p04_require(value in allowed,"new context Symbol requires profile update");context[name]=value
    end
    views=Dict{String,Any}("current_density_A_per_m2"=>_p05_f64(v.current_density_A_per_m2),
        "sheet_density_per_m2"=>_p05_f64(v.sheet_density_per_m2))
    for spec in _P05_VIEW_SPECS
        owner,name=spec[1:2];value=getfield(owner=="context" ? c : v,Symbol(name))
        destination=owner=="context" ? context : views
        if value===nothing
            _p04_require(spec[8],"required final array missing");destination[name]=nothing
        else
            descriptor=_p05_descriptor("final_observations",name,value,spec)
            destination[name]=descriptor;push!(arrays,descriptor["dataset"]=>value)
        end
    end
    context,views
end
function _p05_summary(summary::QCLNEGF.FinalScientificSummary)
    status=String(summary.status);_p05_string(status;maximum=256)
    _p04_require(summary.outer_confirmation_count>=0 && summary.quality in (:strict,:invalid,:approximate,:unconverged) &&
        summary.discretization_verified===:not_measured,"unsupported scientific summary profile")
    Dict{String,Any}(string(name)=>(name===:outer_confirmation_count ? _p05_int(getfield(summary,name)) :
        getfield(summary,name) isa Symbol ? String(getfield(summary,name)) : getfield(summary,name))
        for name in fieldnames(QCLNEGF.FinalScientificSummary))
end
const _P05_ISSUE_TARGETS=("spatial_energy_density_per_eV_m3","localized_levels_eV","effective_levels_eV",
    "effective_wavefunctions_per_sqrt_nm","effective_transform","effective_density_matrix_per_m2","positivity")
const _P05_ISSUE_REASONS=("nonfinite_green","nonfinite_hartree","projection_failed","nonfinite_hamiltonian","eigensystem_failed","positivity_measurement_failed")
function _p05_issues(issues)
    rows=Dict{String,Any}[];targets=Set{String}()
    for issue in issues
        target,status,reason=String.((issue.target,issue.status,issue.reason))
        _p04_require(target in _P05_ISSUE_TARGETS && !(target in targets) && status in ("error","not_measured") &&
            reason in _P05_ISSUE_REASONS,"unsupported/duplicate observation issue")
        _p05_string(issue.detail);push!(targets,target)
        push!(rows,Dict("target"=>target,"status"=>status,"reason"=>reason,"detail"=>issue.detail))
    end
    rows
end
_p05_fields(value)=value["fields"]
_p05_symbol(value)=_p05_decode(value,Symbol)
function _p05_state_bindings(declaration)
    state=_p05_fields(declaration["state"]);scba=_p05_fields(state["scba"]);green=_p05_fields(scba["green"])
    components(f)=Dict(a=>_p05_fields(f)[b] for (a,b) in (("retarded","Σᴿ"),("lesser","Σˡ"),("greater","Σᵍ")))
    sources=Dict{String,Any}()
    for entry in scba["scattering"]["entries"]
        name=String(_p05_symbol(entry["key"]));_p04_require(!haskey(sources,name),"duplicate checkpoint family")
        sources[name]=components(entry["value"])
    end
    order=String.(_p05_symbol.(state["family_order"]))
    _p04_require(length(order)>=2 && order[end-1:end]==["embedding_plus","embedding_minus"],"exact embedding suffix differs")
    families=order[1:end-2]
    _p04_require(length(unique(families))==length(families) && Set(families)==Set(keys(sources)),"actual family set differs")
    Dict{String,Any}("green"=>Dict(a=>green[b] for (a,b) in (("retarded","Gᴿ"),("lesser","Gˡ"),("greater","Gᵍ"),("spectral","A"))),
        "scattering"=>[merge(Dict("family"=>family),sources[family]) for family in families],
        "embedding"=>Dict(a=>components(scba[b]) for (a,b) in (("total","embedding"),("plus","embedding_plus"),("minus","embedding_minus"))))
end
function _p05_request(request::FinalPointRequest,context)
    T,V=_p05_f64(request.temperature_K),_p05_f64(request.voltage_per_period_V)
    checks=Dict{String,Any}()
    for (name,wanted,actual) in (("temperature",T,context["inputs"]["T_L_K"]),("voltage",V,context["inputs"]["V_period_V"]))
        equal=wanted==actual
        _p04_require(equal || name=="voltage","requested temperature differs from actual context")
        checks[name]=Dict("status"=>equal ? "verified" : "not_verified","reason"=>equal ? nothing : "field_period_roundtrip",
            "requested"=>wanted,"actual"=>actual)
    end
    Dict("kind"=>String(request.kind),"plan"=>request.plan_ref,"model"=>request.model_ref,"temperature_K"=>T,
        "voltage_per_period_V"=>V,"scattering_requested"=>_p05_flags(request.scattering_requested),"coordinate_checks"=>checks)
end
function _p05_observations(snapshot,declaration,checkpoint_ref,diagnostics_ref,request,parent,arrays)
    context,views=_p05_view_records(snapshot,arrays);issues=_p05_issues(snapshot.issues)
    state=_p05_fields(declaration["state"])
    restoration=if snapshot.source_mode===:produced
        nothing
    else
        _p04_require(parent isa VerifiedExactCheckpoint,"completed restore requires explicit verified parent")
        pm=_p04_parse(parent.manifest_json);pd=_p04_parse(parent.declaration_json)
        Dict("parent_state"=>_p04_parse(parent.reference_json),"parent_checkpoint"=>pm["checkpoint"],"history"=>pd["history"],
            "original"=>Dict("checkpoint"=>checkpoint_ref,"field"=>"final_evidence","integrity"=>state["integrity"]),
            "revalidation"=>_p04_encode(snapshot.revalidation,Any[]),"independent_oracle"=>_p04_encode(snapshot.independent_oracle,Any[]))
    end
    Dict{String,Any}("schema"=>"qcl-negf.final-observations.v1","contract_set"=>_P04_CONTRACT,
        (key=>declaration[key] for key in ("identity","invocation","state_id","state_sequence"))...,
        "checkpoint"=>checkpoint_ref,"diagnostics"=>diagnostics_ref,"source_mode"=>String(snapshot.source_mode),
        "binding"=>Dict("identity"=>_p04_encode(snapshot.identity,Any[]),"terminal_integrity"=>_p04_encode(snapshot.terminal_integrity,Any[])),
        "context"=>context,"request"=>_p05_request(request,context),"state_bindings"=>_p05_state_bindings(declaration),
        "views"=>views,"summary"=>_p05_summary(snapshot.summary),"restoration"=>restoration,"issues"=>issues)
end

# Native analysis has a different closed tree from exact-state/history payloads.
function _p05_storage(dataset,descriptor)
    _p04_require(dataset isa HDF5.Dataset && length(attributes(dataset))==0 && size(dataset)==reverse(_p04_shape(descriptor["shape"])),"analysis dataset rank/shape differs")
    _p04_require(ENDIAN_BOM==0x04030201,"analysis profile requires qualified little-endian host")
    T=get(Dict("Float64"=>Float64,"Int64"=>Int64,"ComplexF64"=>ComplexF64,"Bool"=>Bool),descriptor["eltype"],nothing)
    _p04_require(T!==nothing,"unsupported analysis dtype")
    dtype=HDF5.datatype(dataset);expected=T===Bool ? _p04_bool_type() : HDF5.datatype(T)
    properties=HDF5.get_create_properties(dataset)
    try
        _p04_require(HDF5.API.h5t_equal(dtype,expected),"analysis dtype/endian/member layout differs")
        _p04_require(length(properties.filters)<=2 && all(i->HDF5.API.h5p_get_filter(properties,i-1,C_NULL,C_NULL,C_NULL,0,C_NULL,C_NULL) in
            (HDF5.API.H5Z_FILTER_SHUFFLE,HDF5.API.H5Z_FILTER_DEFLATE),1:length(properties.filters)),"analysis custom/lossy filter forbidden")
        if T===Float64
            _p04_require(HDF5.API.h5t_equal(dtype,HDF5.API.H5T_IEEE_F64LE),"Float64 storage is not little endian")
        elseif T===Int64
            _p04_require(HDF5.API.h5t_equal(dtype,HDF5.API.H5T_STD_I64LE),"Int64 storage is not little endian")
        elseif T===ComplexF64
            _p04_require(HDF5.API.h5t_get_class(dtype)==HDF5.API.H5T_COMPOUND && HDF5.API.h5t_get_size(dtype)==16 &&
                HDF5.API.h5t_get_nmembers(dtype)==2,"complex compound storage differs")
            for (index,name,offset) in ((0,"r",0),(1,"i",8))
                member=HDF5.Datatype(HDF5.API.h5t_get_member_type(dtype,index))
                try
                    _p04_require(HDF5.API.h5t_get_member_name(dtype,index)==name && HDF5.API.h5t_get_member_offset(dtype,index)==offset &&
                        HDF5.API.h5t_equal(member,HDF5.API.H5T_IEEE_F64LE),"complex member order/offset/endian differs")
                finally;close(member);end
            end
        end
    finally;close(properties);close(expected);close(dtype);end
    nothing
end
function _p05_analysis_arrays(declaration,representation)
    _p04_require(declaration isa AbstractDict,"analysis declaration is not mapping")
    if representation=="final_observations"
        _p04_require(all(haskey(declaration,n) && declaration[n] isa AbstractDict for n in ("context","views")),"observation owners absent")
        [owner[name] for owner in (declaration["context"],declaration["views"]) for name in keys(owner)
            if owner[name] isa AbstractDict && haskey(owner[name],"dataset")]
    else
        _p04_require(haskey(declaration,"positivity") && declaration["positivity"] isa AbstractDict &&
            haskey(declaration["positivity"],"data"),"diagnostic owner absent")
        data=declaration["positivity"]["data"]
        data===nothing && return Any[]
        _p04_require(data isa AbstractDict && haskey(data,"integrals") && data["integrals"] isa AbstractDict &&
            all(haskey(data["integrals"],spec[1]) for spec in _P05_INTEGRAL_SPECS),"diagnostic integrals absent")
        [data["integrals"][spec[1]] for spec in _P05_INTEGRAL_SPECS]
    end
end
function _p05_read_analysis(root,reference,identity,invocation,representation,budget)
    _p04_file_fields(reference)
    _p04_require(reference["schema"]==_P05_ANALYSIS_SCHEMA && reference["media_type"]=="application/x-hdf5","wrong analysis FileRef")
    path=_p04_path(root,reference["path"]);_p04_require(isfile(path),"analysis source missing")
    file=h5open(path,"r")
    try
        _p04_require(Sys.isunix(),"same-open analysis requires qualified Unix sec2 driver")
        fdptr=HDF5.API.h5f_get_vfd_handle(file,HDF5.API.H5P_DEFAULT)
        stream=Base.fdio(unsafe_load(convert(Ptr{Cint},fdptr)),false)
        signature=try
            before=_p04_stat(stat(stream));_p04_require(before==_p04_stat(stat(path)),"analysis path rebound")
            position=Base.position(stream);seekstart(stream)
            hash=try;bytes2hex(sha256(stream));finally;seek(stream,position);end
            _p04_require(string(before[3])==reference["bytes"] && hash==reference["sha256"] && before==_p04_stat(stat(stream)) &&
                before==_p04_stat(stat(path)),"same-open analysis bytes/hash/path differ")
            before
        finally;close(stream);end
        _require_internal_hdf5_storage(file;maximum_depth=3,maximum_group_entries=32,maximum_links=40)
        _p04_require(length(attributes(file))==0 && Set(keys(file))==Set(("metadata",representation)),"unknown analysis root")
        meta=file["metadata"]
        try
            _p04_require(Set(keys(meta))==Set(("identity_json","invocation_json")) && length(attributes(meta))==6 && Set(keys(attributes(meta)))==Set(
                ("schema","schema_version","contract_set","artifact_role","representation","core_layout_sha256")),"unknown analysis metadata")
            for (key,value) in (("schema",_P05_ANALYSIS_SCHEMA),("schema_version","5.0"),("contract_set",_P04_CONTRACT),
                    ("artifact_role","physics.analysis"),("representation",representation),("core_layout_sha256",_P04_LAYOUT))
                _p04_require(_p05_attribute(meta,key,budget)==value,"analysis header differs")
            end
            _p04_require(_p05_read_scalar(meta,"identity_json",budget,path)==identity &&
                _p05_read_scalar(meta,"invocation_json",budget,path)==invocation,"analysis envelope differs")
        finally;close(meta);end
        group=file[representation]
        declaration=try
            _p04_require(length(attributes(group))==0 && Set(keys(group))==Set(("declaration_json","arrays")),"unknown analysis group")
            value=_p05_read_scalar(group,"declaration_json",budget,path)
            value
        finally;close(group);end
        arrays=_p05_analysis_arrays(declaration,representation);expected=Set{String}()
        for descriptor in arrays
            _p04_require(all(haskey(descriptor,n) for n in ("dataset","eltype","shape")) && descriptor["dataset"] isa String,
                "incomplete local descriptor")
            name=last(split(descriptor["dataset"],'/'));push!(expected,name)
            _p04_require(descriptor["dataset"]=="/"*representation*"/arrays/"*name,"analysis locator outside owner")
            _p04_require(haskey(file,descriptor["dataset"]),"declared local dataset missing")
            dataset=file[descriptor["dataset"]]
            try;_p05_storage(dataset,descriptor);finally;close(dataset);end
        end
        group=file[representation*"/arrays"]
        try;_p04_require(length(attributes(group))==0 && Set(keys(group))==expected,"unknown/missing analysis datasets");finally;close(group);end
        _p04_require(signature==_p04_stat(stat(_p04_path(root,reference["path"]))),"analysis changed during verification")
        declaration
    finally;close(file);end
end

function _p05_selected(inventory,reference,role,dependencies)
    _p04_file_fields(reference);row=get(inventory,reference["path"],nothing)
    _p04_require(row!==nothing && all(get(row,key,nothing)==value for (key,value) in reference) &&
        row["role"]==role && row["profile"]=="science" && row["dependencies"]==dependencies,"selected full FileRef/role/profile/dependencies differ")
end
function _p05_dag(inventory,selected)
    active=Set{String}();complete=Set{String}();pending=[(selected,false)]
    while !isempty(pending)
        path,leaving=pop!(pending)
        _p04_require(haskey(inventory,path),"selected dependency missing")
        if leaving
            delete!(active,path);push!(complete,path)
        elseif !(path in complete)
            _p04_require(!(path in active),"selected dependency cycle")
            push!(active,path);push!(pending,(path,true))
            for child in reverse(inventory[path]["dependencies"]);push!(pending,(child,false));end
        end
    end
    nothing
end
function _p05_restoration_check(value,manifest,declaration,parent)
    state=_p05_fields(declaration["state"]);summary=value["summary"];receipt=value["restoration"]
    if value["source_mode"]=="produced"
        _p04_require(receipt===nothing && parent===nothing,"produced must not carry completed contexts")
        original=_p05_fields(state["final_evidence"])
        _p04_require(summary["status"]==String(_p05_symbol(original["original_status"])) &&
            summary["converged"]==original["original_converged"],"original final classification differs")
        return nothing
    end
    _p04_require(value["source_mode"]=="completed_restore" && parent isa VerifiedExactCheckpoint,"completed restore requires explicit verified parent")
    _p04_keys(receipt,("parent_state","parent_checkpoint","history","original","revalidation","independent_oracle"))
    pm=_p04_parse(parent.manifest_json);pd=_p04_parse(parent.declaration_json);old=_p05_fields(pd["state"])
    _p04_require(receipt["parent_state"]==manifest["lineage"]["parent_state"]==_p04_parse(parent.reference_json) &&
        receipt["parent_checkpoint"]==pm["checkpoint"] && receipt["history"]==pd["history"] &&
        pm["closed"] && _p05_symbol(old["boundary"])===:final && old["final_evidence"]!==nothing,"immediate parent/cutoff/final differs")
    _p04_require(all(state[name]==old[name] for name in ("identity","integrity","final_evidence")),"original Core evidence changed across attempt")
    _p04_require(receipt["original"]==Dict("checkpoint"=>value["checkpoint"],"field"=>"final_evidence","integrity"=>state["integrity"]),"original evidence locator differs")
    _p05_decode(receipt["revalidation"],QCLNEGF.RevalidationReceipt)
    _p05_decode(receipt["independent_oracle"],QCLNEGF.IndependentOracleReceipt)
    selected=_p05_fields(receipt["revalidation"]);oracle=_p05_fields(receipt["independent_oracle"])
    status=_p05_symbol(selected["status"]);passed=_p05_fields(selected["report"])["passed"]
    _p04_require(status in (:measured,:error) && (status!==:error || selected["reason"]!==nothing && !passed),"error selected receipt/report contradiction")
    context=_p05_fields(selected["context"])
    _p04_require(context["algorithms"]==value["context"]["algorithms"] && _p05_symbol(context["final_state_alignment"])===:restored_aligned &&
        (status!==:measured || _p05_symbol(context["backend"])===:production && context["map_kernels_shared_with_solver"]===true),"selected context differs")
    oracle_status=_p05_symbol(oracle["status"])
    _p04_require(oracle_status in (:measured,:not_measured,:unsupported,:error) && (oracle_status===:measured || oracle["reason"]!==nothing),"independent receipt status/reason differs")
    if oracle_status===:measured
        _p04_require(oracle["report"]!==nothing && oracle["context"]!==nothing,"independent report/context absent")
        c=_p05_fields(oracle["context"])
        _p04_require(_p05_symbol(c["backend"])===:reference && c["map_kernels_shared_with_solver"]===false,"independent reference context differs")
    end
    consistent=summary["converged"] ? passed && summary["status"]=="converged" :
        summary["status"]=="approximate" ? passed : !passed ? summary["status"]=="validation_failed" : summary["status"]==String(_p05_symbol(state["status"]))
    _p04_require(consistent,"recorded revalidation/current classification contradicts")
    nothing
end
function _p05_observation_check(value,diagnostics,manifest,declaration,reference,plan,model,parent)
    _p05_envelope(value,"qcl-negf.final-observations.v1",declaration,("diagnostics","source_mode","binding","context","request","state_bindings","views","summary","restoration","issues"))
    _p04_require(manifest["closed"] && manifest["status"]["process"]["state"] in ("succeeded","failed","cancelled","interrupted") &&
        value["checkpoint"]==manifest["checkpoint"]==diagnostics["checkpoint"],"analysis requires selected closed final checkpoint")
    state=_p05_fields(declaration["state"])
    _p04_require(_p05_symbol(state["boundary"])===:final && state["final_evidence"]!==nothing &&
        value["binding"]==Dict("identity"=>state["identity"],"terminal_integrity"=>state["integrity"]),"Core final binding differs")
    c=value["context"];v=value["views"]
    context_names=("dimensions","domain_revision","discretization_id","basis_id","scales","inputs","problem_scattering","enabled_scattering","selfenergy_families","physical_models","algorithms")
    _p04_keys(c,(context_names...,keys(_P05_CONTEXT_SYMBOLS)...,(spec[2] for spec in _P05_VIEW_SPECS if spec[1]=="context")...))
    _p04_keys(v,("current_density_A_per_m2","sheet_density_per_m2",(spec[2] for spec in _P05_VIEW_SPECS if spec[1]=="views")...))
    _p04_keys(c["dimensions"],("Nz","NE","Nk","Nb"))
    z,e,k,b=(Int(_p04_u64(c["dimensions"][n];positive=true)) for n in ("Nz","NE","Nk","Nb"))
    _p04_require(diagnostics["dimensions"]==Dict("energy"=>string(e),"momentum"=>string(k),"basis"=>string(b)) &&
        state["published_U"]["shape"]==state["published_n"]["shape"]==[string(z)],"actual domain differs")
    counts=Dict("z"=>z,"E"=>e,"k"=>k,"state"=>b,"state_prime"=>b)
    for spec in _P05_VIEW_SPECS
        owner,name,type,axes,units,coords,weights,nullable=spec;item=value[owner][name]
        item===nothing && (_p04_require(nullable,"required local array absent");continue)
        expected=Dict("dataset"=>"/final_observations/arrays/"*name,"eltype"=>type,"shape"=>String[],"order"=>"F",
            "axes"=>axes,"units"=>units,"coordinate_fields"=>coords,"weight_fields"=>weights)
        _p05_local_descriptor(item,expected,Tuple(counts[a] for a in axes))
    end
    for name in ("current_density_A_per_m2","sheet_density_per_m2");_p05_decode(v[name],Float64);end
    _p04_keys(c["scales"],("E0_eV","L0_m","J0_A_per_m2"))
    for item in values(c["scales"]);_p05_decode(item,Float64);end
    _p04_keys(c["inputs"],("F_bias_V_per_m","V_period_V","T_L_K","T_LO_K","E_ref_eV","N_dop_2D_per_m2","f_ion","z0_m","period_length_m","g_s"))
    for (name,item) in c["inputs"]
        name=="g_s" ? _p04_require(_p05_decode(item,Int64)>=0,"g_s is negative") : _p05_decode(item,Float64)
    end
    for (name,T) in (("problem_scattering",QCLNEGF.ScatteringOptions),("physical_models",QCLNEGF.PhysicalModelOptions),("algorithms",QCLNEGF.AlgorithmOptions))
        _p05_decode(c[name],T)
    end
    _p04_require(c["algorithms"]==_p05_fields(state["measurement_context"])["algorithms"],"algorithms differ from checkpoint")
    for (name,allowed) in _P05_CONTEXT_SYMBOLS;_p04_require(c[name] in allowed,"unsupported context convention");end
    for name in ("discretization_id","basis_id")
        _p04_require(c[name] isa String && occursin(r"^[0-9a-f]{64}\z",c[name]),"invalid domain ID")
    end
    adaptation=state["adaptation"]
    revision=_p05_decode(c["domain_revision"],Int64)
    _p04_require(revision>=0 && revision==(adaptation===nothing ? 0 : _p05_decode(_p05_fields(adaptation)["expansions"],Int64)),"domain revision differs")
    if adaptation!==nothing
        revisions=_p05_fields(adaptation)["revisions"]
        _p04_require(!isempty(revisions) && _p05_fields(last(revisions))["evidence"]!==nothing,"adaptation evidence absent")
        evidence=_p05_fields(_p05_fields(last(revisions))["evidence"])
        _p04_require(all(c[n]==evidence[n] for n in ("discretization_id","basis_id")),"actual adaptive IDs differ")
    end
    bindings=_p05_state_bindings(declaration)
    families=[r["family"] for r in bindings["scattering"]]
    _p04_require(value["state_bindings"]==bindings && c["selfenergy_families"]==families &&
        c["enabled_scattering"]==filter(!=("electron_electron"),families),"actual ordered family bindings differ")
    _p04_require(all(n->n in (_P05_SCATTERING...,"electron_electron"),families),"new producer family requires profile update")
    shape=string.([e,k,b,b]);scba=_p05_fields(state["scba"])
    for component in values(bindings["green"]);_p04_require(component["shape"]==shape,"Green domain differs");end
    for family in Iterators.flatten((bindings["scattering"],values(bindings["embedding"])))
        for name in ("retarded","lesser","greater");_p04_require(family[name]["shape"]==shape,"selfenergy domain differs");end
    end
    summary=value["summary"]
    _p04_keys(summary,("status","quality","converged","registry_version","iterative_converged","fixed_hartree_converged","physical_gates_passed","stationary_candidate_accepted","scientific_accepted","discretization_verified","scientific_acceptance_reason","outer_confirmation_count"))
    _p05_string(summary["status"];maximum=256)
    for name in ("registry_version","scientific_acceptance_reason");_p05_string(summary[name]);end
    _p04_require(summary["quality"] in ("strict","invalid","approximate","unconverged") && summary["discretization_verified"]=="not_measured" &&
        _p05_decode(summary["outer_confirmation_count"],Int64)>=0,"summary profile/count differs")
    for name in ("converged","iterative_converged","fixed_hartree_converged","physical_gates_passed","stationary_candidate_accepted")
        _p04_require(summary[name] isa Bool,"summary flag is not Bool")
    end
    _p04_require(summary["scientific_accepted"]===nothing || summary["scientific_accepted"] isa Bool,"scientific status is not Bool/null")
    request=value["request"]
    _p04_keys(request,("kind","plan","model","temperature_K","voltage_per_period_V","scattering_requested","coordinate_checks"))
    kind=request["kind"]=="nested_sweep" ? :nested_sweep : request["kind"]=="scientific_plan_v2" ? :scientific_plan_v2 : nothing
    _p04_require(kind!==nothing,"unsupported request kind")
    _p04_keys(request["scattering_requested"],_P05_SCATTERING)
    _p04_require(all(v->v isa Bool,values(request["scattering_requested"])) && request["scattering_requested"]==_p05_fields(c["problem_scattering"]),"requested flags differ from actual problem")
    T=_p05_decode(request["temperature_K"],Float64);V=_p05_decode(request["voltage_per_period_V"],Float64)
    typed=FinalPointRequest(;plan_ref=request["plan"],model_ref=request["model"],temperature_K=T,voltage_per_period_V=V,
        scattering_requested=QCLNEGF.ScatteringOptions(;(Symbol(k)=>v for (k,v) in request["scattering_requested"])...),kind)
    _p04_require(request==_p05_request(typed,c) && typed.plan_ref["sha256"]==value["identity"]["plan_sha256"],"request coordinate/raw plan binding differs")
    _p05_model(model,value["identity"],request["scattering_requested"]);_p05_plan(plan,value["identity"],typed)
    issues=value["issues"];_p04_require(issues isa AbstractVector,"issues is not vector")
    targets=Set{String}()
    for issue in issues
        _p04_keys(issue,("target","status","reason","detail"));_p05_string(issue["detail"])
        _p04_require(issue["target"] in _P05_ISSUE_TARGETS && !(issue["target"] in targets) &&
            issue["reason"] in _P05_ISSUE_REASONS && issue["status"] in ("error","not_measured"),"issue profile differs")
        push!(targets,issue["target"])
    end
    missing=Set(name for (name,item) in v if item===nothing)
    if diagnostics["positivity"]["data"]===nothing
        push!(missing,"positivity");matching=filter(i->i["target"]=="positivity",issues)
        _p04_require(length(matching)==1,"positivity failure lacks issue")
        issue=only(matching)
        _p04_require(diagnostics["positivity"]["status"]==issue["status"] && diagnostics["positivity"]["reason"]==issue["reason"]*": "*issue["detail"],"positivity failure receipt differs")
    end
    _p04_require(missing==targets,"issues do not cover exact unavailable fields")
    group=[v[n]===nothing for n in ("effective_levels_eV","effective_wavefunctions_per_sqrt_nm","effective_transform","effective_density_matrix_per_m2")]
    _p04_require(all(group) || !any(group),"effective view group incomplete")
    _p05_restoration_check(value,manifest,declaration,parent)
    inventory=Dict(a["path"]=>a for a in manifest["artifacts"])
    refs=(value["checkpoint"],value["diagnostics"],typed.plan_ref,typed.model_ref)
    paths=[ref["path"] for ref in refs]
    _p04_require(length(unique([paths;reference["path"]]))==5,"selected paths alias")
    _p05_selected(inventory,reference,"physics.analysis",paths)
    _p05_selected(inventory,value["diagnostics"],"physics.analysis",[value["checkpoint"]["path"]])
    _p05_selected(inventory,typed.plan_ref,"plan",String[]);_p05_selected(inventory,typed.model_ref,"model",String[])
    anchor=get(inventory,value["checkpoint"]["path"],nothing)
    _p04_require(anchor!==nothing && Set(anchor["dependencies"])==Set(p["path"] for p in declaration["payloads"]),"checkpoint payload frontier differs")
    for ref in declaration["payloads"]
        row=get(inventory,ref["path"],nothing)
        _p04_require(row!==nothing && all(get(row,k,nothing)==v for (k,v) in ref),"checkpoint payload full FileRef differs")
    end
    _p05_dag(inventory,reference["path"]);nothing
end

function _p05_read_scalar(parent,name,budget,path)
    dataset=parent[name];_p04_require(dataset isa HDF5.Dataset,"analysis JSON metadata is not dataset")
    dtype=HDF5.datatype(dataset);space=HDF5.dataspace(dataset)
    try
        _p04_require(dataset isa HDF5.Dataset && HDF5.API.h5s_get_simple_extent_type(space)==HDF5.API.H5S_SCALAR &&
            HDF5.API.h5t_get_class(dtype)==HDF5.API.H5T_STRING && !HDF5.API.h5t_is_variable_str(dtype) &&
            HDF5.API.h5t_get_cset(dtype)==HDF5.API.H5T_CSET_UTF8 && length(attributes(dataset))==0,"analysis metadata must be fixed UTF-8 scalar string")
        width=HDF5.API.h5t_get_size(dtype)
        _p04_require(width<=div(budget[],8),"analysis metadata allocation allowance exceeded")
        _p05_charge!(budget,_p05_mul(8,Int(width)))
        properties=HDF5.get_create_properties(dataset)
        try;_p04_require(length(properties.filters)==0,"filtered metadata strings forbidden");finally;close(properties);end
        _p04_read_observer[](:scalar_json,path,Int(width))
        _p05_parse(read(dataset,String),budget)
    finally;close(space);close(dtype);close(dataset);end
end

# Explicit existing scientific-plan profile. This does not resolve inputs or attest
# resource/scientific validity, and does not extend the configuration schema engine.
_p05_number(x)=_p04_require(x isa Real && !(x isa Bool) && isfinite(x),"finite plan number required")
_p05_integer(x;minimum=0)=_p04_require(x isa Integer && !(x isa Bool) && minimum<=x<=typemax(Int64),"plan integer outside profile")
_p05_digest(x)=_p04_require(x isa String && occursin(r"^[0-9a-f]{64}\z",x),"invalid plan digest")
function _p05_strings(items;ids=false,unique=false)
    _p04_require(items isa AbstractVector,"plan string vector required")
    for item in items;ids ? _p04_id(item) : _p05_string(item);end
    unique && _p04_require(length(Set(items))==length(items),"duplicate plan string")
end
function _p05_configuration_profile(value)
    try
        validate_configuration_schema(value)
    catch error
        error isa ConfigurationError || rethrow()
        throw(ArgumentError(sprint(showerror,error)))
    end
    nothing
end
function _p05_output_profile(value)
    _p04_require(value isa AbstractDict && all(k->k in ("archive","recovery","telemetry"),keys(value)),"unknown output policy")
    profiles=Dict("archive"=>("full_final","optical","projections","intermediate_history"),
        "recovery"=>("enabled","interval_seconds","retain_generations","byte_budget","reserve_bytes"),"telemetry"=>("enabled","buffer_events"))
    for (group,record) in value
        _p04_require(record isa AbstractDict && all(k->k in profiles[group],keys(record)),"unknown output policy field")
        for (name,item) in record
            if name in ("full_final","optical","projections","enabled")
                _p04_require(item isa Bool && (name!="full_final" || item),"invalid archive flag")
            elseif name=="interval_seconds"
                _p05_number(item);_p04_require(item>0,"nonpositive recovery interval")
            else
                _p05_integer(item;minimum=name=="reserve_bytes" ? 0 : name=="retain_generations" ? 2 : 1)
            end
        end
    end
end
function _p05_resource_profile(value)
    _p04_require(value isa AbstractDict && get(value,"schema",nothing)=="qcl-negf-resource-estimate-v1" &&
        get(value,"decision_kind",nothing)=="planning_estimate","wrong resource profile")
    if get(value,"status",nothing)=="not_applicable"
        _p04_keys(value,("schema","status","decision_kind","estimated_numerical_peak_bytes"))
        _p04_require(value["estimated_numerical_peak_bytes"]===nothing,"inapplicable estimate has bytes");return
    end
    _p04_keys(value,("schema","decision_kind","status","confidence","worker_capacity","initial_energy_nodes","declared_maximum_energy_nodes",
        "adaptation_enabled","initial","declared_cap","retained_resident_bytes","estimated_numerical_peak_bytes","runtime_overhead_bytes",
        "allocator_overhead_bytes","measured_rss_bytes","admitted_memory_bytes","total_memory_request_bytes","unknown","basis"))
    _p04_require(value["status"]=="available" && value["confidence"]=="analytical_conservative_uncalibrated" && value["adaptation_enabled"] isa Bool &&
        value["unknown"]==["runtime_overhead","allocator_overhead","native_grant","measured_rss"],"planning estimate profile differs")
    for name in ("worker_capacity","initial_energy_nodes","declared_maximum_energy_nodes","retained_resident_bytes","estimated_numerical_peak_bytes")
        _p05_integer(value[name];minimum=name=="worker_capacity" ? 1 : name in ("initial_energy_nodes","declared_maximum_energy_nodes") ? 3 : 0)
    end
    for name in ("runtime_overhead_bytes","allocator_overhead_bytes","measured_rss_bytes","admitted_memory_bytes","total_memory_request_bytes")
        _p04_require(value[name]===nothing,"planning metadata claims runtime measurement/grant")
    end
    _p04_keys(value["basis"],("core_estimator_sha256","runner_formula_sha256"))
    for digest in values(value["basis"]);_p05_digest(digest);end
    for name in ("initial","declared_cap")
        record=value[name];_p04_keys(record,("resident_bytes","peak_bytes","breakdown"))
        for n in ("resident_bytes","peak_bytes");_p05_integer(record[n]);end
        _p04_require(record["breakdown"] isa AbstractDict,"invalid memory breakdown")
        for bytes in values(record["breakdown"]);_p05_integer(bytes);end
    end
end
function _p05_resolved_profile(value)
    _p04_keys(value,("schema","phase","raw_configuration","sections","derived","default_rule_sources","model_binding"))
    _p04_require(value["schema"]=="qcl-negf-resolved-configuration-v1" && value["phase"]=="resolved_declarative_inputs","wrong resolved plan envelope")
    _p05_configuration_profile(value["raw_configuration"])
    _p04_keys(value["sections"],("physical","numerical","scales","scattering","solver","production","kernel_construction","algorithms","execution","output","study","physical_models","domain_adaptation"))
    for section in values(value["sections"])
        _p04_keys(section,("used","origin","rule_source","input_assigning_histories"))
        _p04_require(section["origin"]=="owning_resolution_rule" && section["used"] isa AbstractDict &&
            section["input_assigning_histories"] isa AbstractDict,"resolved section profile differs")
        _p05_string(section["rule_source"])
        for history in values(section["input_assigning_histories"]);_p05_strings(history);end
    end
    _p04_keys(value["derived"],("effective_seed",));seed=value["derived"]["effective_seed"]
    _p04_keys(seed,("requested_scaled","effective_scaled","grid_floor_scaled","requested_eV","effective_eV","grid_floor_eV","working_eta_eV","clamped","rule"))
    for name in ("requested_scaled","effective_scaled","grid_floor_scaled","requested_eV","effective_eV","grid_floor_eV","working_eta_eV");_p05_number(seed[name]);end
    _p04_require(seed["clamped"] isa Bool,"invalid seed flag");_p05_string(seed["rule"])
    sources=value["default_rule_sources"]
    _p04_require(sources isa AbstractDict && !isempty(sources),"resolution rule sources absent")
    for digest in values(sources);_p05_digest(digest);end
    binding=value["model_binding"];_p04_keys(binding,("encoding","scope","sha256"))
    _p04_require(binding["encoding"]=="qcl-negf-canonical-bytes-v1" && binding["scope"]=="stationary_transport_inputs_v1","wrong resolved model binding")
    _p05_digest(binding["sha256"])
end
function _p05_scientific_profile(value)
    _p05_portable(value)
    _p04_require(value["model_revision"]=="transport-contract-v2" && value["root_kind"] in ("study","meta") &&
        value["campaign"]===nothing && (value["science_archive_preflight"]===nothing || value["science_archive_preflight"] isa AbstractDict),"scientific plan profile differs")
    _p04_id(value["root_definition_id"]);_p05_string(value["name"])
    for name in ("fingerprint","scientific_fingerprint");_p05_digest(value[name]);end
    _p05_integer(value["maximum_solver_runs"];minimum=1);_p05_integer(value["computation_count"])
    for group in ("inclusions","executions","points")
        rows=value[group];_p04_require(rows isa AbstractVector && all(row->row isa AbstractDict && haskey(row,"id"),rows),"plan rows invalid")
        _p04_require(length(Set(row["id"] for row in rows))==length(rows),"duplicate plan ID")
        for row in rows;_p04_id(row["id"]);end
    end
    _p04_require(length(value["points"])==value["computation_count"],"plan point count differs")
    for row in value["inclusions"]
        _p04_keys(row,("id","definition_id","parent_id","path","execution_ids","label"))
        _p04_id(row["definition_id"]);row["parent_id"]===nothing || _p04_id(row["parent_id"])
        _p05_strings(row["path"]);_p05_strings(row["execution_ids"];ids=true);_p05_string(row["label"])
    end
    for row in value["executions"]
        policy=haskey(row,"output") ? "output" : "outputs"
        _p04_keys(row,("id","definition_id","variant_id","method_id","label","point_ids","resolved_configuration","provenance","policies",
            "estimated_peak_bytes","purpose","repetition","operation","effective_inputs","resolved_snapshot","resource_estimate",policy))
        for name in ("definition_id","variant_id","method_id");_p04_id(row[name]);end
        _p05_string(row["label"]);_p05_strings(row["point_ids"];ids=true,unique=true);_p04_require(!isempty(row["point_ids"]),"empty point IDs")
        _p04_require(row["provenance"] isa AbstractDict && row["policies"] isa AbstractDict && row[policy] isa AbstractDict,"plan execution metadata invalid")
        policy=="output" && _p05_output_profile(row[policy])
        _p05_integer(row["estimated_peak_bytes"]);_p05_integer(row["repetition"];minimum=1)
        _p04_require(row["purpose"] in ("research","diagnostic","reproducibility","benchmark") && row["operation"] in
            ("stationary","operator_algebra","operator_metrics","operator_representation","operator_continuum","operator_cavity","operator_lo_equilibrium","operator_spectral_resolution","structure_spectrum"),"plan operation/purpose differs")
        effective=row["effective_inputs"]
        _p04_keys(effective,("seed","energy_shift","energy_nodes","energy_min_eV","energy_max_eV"))
        _p04_require(effective["seed"] isa AbstractDict,"seed metadata invalid");_p05_string(effective["energy_shift"])
        _p05_integer(effective["energy_nodes"];minimum=3);_p05_number(effective["energy_min_eV"]);_p05_number(effective["energy_max_eV"])
        _p05_configuration_profile(row["resolved_configuration"]);_p05_resolved_profile(row["resolved_snapshot"]);_p05_resource_profile(row["resource_estimate"])
    end
    for row in value["points"]
        _p04_keys(row,("id","execution_id","temperature_K","voltage_per_period_V","branch","order","predecessor_id","initialization","effective_inputs"))
        _p04_id(row["execution_id"]);_p05_number(row["temperature_K"]);_p05_number(row["voltage_per_period_V"])
        _p04_require(row["temperature_K"]>0 && row["voltage_per_period_V"]>=0,"invalid point coordinates")
        _p05_string(row["branch"];nonblank=true);_p05_integer(row["order"];minimum=1)
        row["predecessor_id"]===nothing || _p04_id(row["predecessor_id"])
        _p04_require(row["initialization"] in ("cold","predecessor"),"invalid point initialization")
        p=row["effective_inputs"]
        _p04_keys(p,("temperature_K","voltage_per_period_V","configuration_hash","hash_encoding","axes_applied","model_sha256"))
        _p05_number(p["temperature_K"]);_p05_number(p["voltage_per_period_V"])
        _p04_require(p["temperature_K"]>0 && p["axes_applied"]===true && p["hash_encoding"]=="qcl-negf-canonical-bytes-v1","point passport profile differs")
        _p05_digest(p["configuration_hash"]);_p05_digest(p["model_sha256"])
    end
    resources=value["resources"]
    _p04_require(resources isa AbstractDict && all(haskey(resources,n) for n in ("maximum_active_executions","estimated_peak_bytes","minimum_output_bytes")),"plan resources absent")
    _p04_require(value["nodes"] isa AbstractVector,"plan nodes invalid")
    for row in value["nodes"]
        _p04_keys(row,("execution_id","stage_id","depends_on","required_evidence","priority","reserve","estimated_memory_bytes","comparison_reference","comparison_kind","controlled_paths","comparable_fingerprint","forbidden_evidence"))
        _p05_string(row["execution_id"]);_p05_integer(row["estimated_memory_bytes"])
        _p04_require(row["stage_id"]=="standalone" && row["depends_on"]==[] && row["required_evidence"]==[] &&
            row["forbidden_evidence"]==[] && row["priority"]===0 && row["reserve"]===false,"execution node profile differs")
        row["comparison_reference"]===nothing || _p05_string(row["comparison_reference"])
        _p04_require(row["comparison_kind"] in ("controlled_axis","discretization","representation","boundary_model","physical_model","physical_parameter","initialization"),"comparison kind differs")
        _p05_strings(row["controlled_paths"];unique=true);_p05_digest(row["comparable_fingerprint"])
    end
    nothing
end

function _p05_attribute(parent,name,budget)
    attribute=attributes(parent)[name];dtype=HDF5.datatype(attribute);space=HDF5.dataspace(attribute)
    try
        _p04_require(HDF5.API.h5s_get_simple_extent_type(space)==HDF5.API.H5S_SCALAR &&
            HDF5.API.h5t_get_class(dtype)==HDF5.API.H5T_STRING && !HDF5.API.h5t_is_variable_str(dtype) &&
            HDF5.API.h5t_get_size(dtype)<=256,"analysis header must be bounded fixed scalar string")
        _p05_charge!(budget,_p05_mul(8,Int(HDF5.API.h5t_get_size(dtype))))
        value=read(attribute);_p05_string(value);value
    finally;close(space);close(dtype);close(attribute);end
end
function _p05_immutable_bytes(root,reference)
    _p04_file_fields(reference);path=_p04_path(root,reference["path"])
    _p04_require(isfile(path),"immutable input missing")
    open(path,"r") do io
        before=_p04_stat(stat(io));_p04_require(before==_p04_stat(stat(path)),"input path rebound during open")
        _p04_read_observer[](:hash,path,before[3])
        hash=bytes2hex(sha256(io))
        _p04_require(string(before[3])==reference["bytes"] && hash==reference["sha256"] && before==_p04_stat(stat(io)) &&
            before==_p04_stat(stat(_p04_path(root,reference["path"]))),"immutable input bytes/hash/path differ")
    end
    reference
end
