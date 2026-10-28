# Optional production checkpoint and summary persistence adapter.

function _p04_read_json_ref(root,reference,budget)
    _p04_file_fields(reference)
    _p04_require(reference["media_type"]=="application/json","metadata is not JSON")
    path=_p04_path(root,reference["path"])
    _p04_require(isfile(path) && filesize(path)<=budget[],"metadata byte budget exceeded/missing source")
    open(path,"r") do io
        _p04_read_observer[](:metadata,path,filesize(path))
        before=_p04_stat(stat(io));text=read(io,String);budget[]-=ncodeunits(text)
        _p04_require(before==_p04_stat(stat(path)) && before==_p04_stat(stat(io)) &&
            string(ncodeunits(text))==reference["bytes"] && bytes2hex(sha256(text))==reference["sha256"],"metadata bytes/hash/path differ")
        _p04_parse(text)
    end
end
function _p04_envelope(value,kind,fields)
    _p04_keys(value,fields)
    _p04_require(value["schema"]==_P04_SCHEMAS[kind] && value["contract_set"]==_P04_CONTRACT,"unsupported result format")
    _p04_identity(value["identity"]);_p04_keys(value["invocation"],("source_epoch",))
    _p04_id(value["invocation"]["source_epoch"])
    haskey(value,"state_id") && _p04_id(value["state_id"])
    for name in ("state_sequence","generation","entries","stream_ordinal")
        haskey(value,name) && _p04_u64(value[name];positive=true)
    end
    value
end
const _p04_registry=Ref{Any}(nothing)
function _p04_artifact_fields(root,item)
    _p04_keys(item,("path","bytes","sha256","media_type","schema","role","profile","dependencies"))
    _p04_file_fields(Dict(k=>item[k] for k in ("path","bytes","sha256","media_type","schema")))
    if _p04_registry[]===nothing
        _p04_registry[]=_p04_parse(read(joinpath(@__DIR__,"../../../schema/results-contract-set.json"),String))
    end
    registry=_p04_registry[]
    _p04_require(registry["contract_set"]==_P04_CONTRACT && any(a->a["role"]==item["role"] &&
        a["media_type"]==item["media_type"] && item["schema"] in a["schemas"],registry["artifacts"]) &&
        item["profile"] in ("science","full-state","both","local") && item["dependencies"] isa AbstractVector &&
        all(d->d isa String && !isempty(d),item["dependencies"]),"unsupported artifact role/media/schema/profile")
    _p04_path(root,item["path"])
    for path in item["dependencies"];_p04_path(root,path);end
    item
end
function _p04_pin(pin)
    _p04_keys(pin,("head","entries","records","scba_rows","outer_rows","witness_updates","last_record"))
    counts=Dict{String,UInt64}()
    for name in ("entries","records","scba_rows","outer_rows","witness_updates","last_record")
        counts[name]=_p04_u64(pin[name])
    end
    _p04_require(BigInt(counts["records"])==sum(BigInt(counts[k]) for k in ("scba_rows","outer_rows","witness_updates")) &&
        counts["records"]==counts["last_record"],"history totals differ")
    _p04_require(pin["head"]===nothing ? all(==(0),values(counts)) : counts["entries"]>0 && counts["records"]>0,"empty/nonempty history pin differs")
    pin["head"]===nothing || _p04_file_fields(pin["head"])
    counts
end
function _p04_verify_history(root,pin,identity,invocation,budget)
    _p04_pin(pin);current=deepcopy(pin);artifacts=Dict{String,Any}();records=Set{String}();pages=Set{String}();lastgeneration=nothing
    while current["head"]!==nothing
        ref=current["head"];_p04_require(ref["schema"]==_P04_SCHEMAS["catalog"] && !(ref["path"] in pages),"catalog cycle/format")
        push!(pages,ref["path"]);page=_p04_read_json_ref(root,ref,budget)
        _p04_envelope(page,"catalog",("schema","contract_set","identity","invocation","generation","entries","previous","artifacts","range","totals"))
        _p04_require(page["identity"]==identity && page["invocation"]==invocation,"catalog source differs")
        _p04_keys(page["totals"],("records","scba_rows","outer_rows","witness_updates","last_record"))
        _p04_require(merge(Dict("head"=>ref,"entries"=>page["entries"]),page["totals"])==current,"catalog pin/counters differ")
        generation=_p04_u64(page["generation"];positive=true)
        _p04_require(lastgeneration===nothing || generation<lastgeneration,"catalog generation order differs");lastgeneration=generation
        previous=page["previous"]===nothing ? _p04_empty_pin() : page["previous"]
        prior=_p04_pin(previous);now=_p04_pin(current)
        _p04_keys(page["range"],("first_record","last_record"))
        first=_p04_u64(page["range"]["first_record"];positive=true);_p04_u64(page["range"]["last_record"];positive=true)
        _p04_require(BigInt(first)==BigInt(prior["last_record"])+1 &&
            page["range"]["last_record"]==current["last_record"] && now["records"]>prior["records"] &&
            all(now[k]>=prior[k] for k in keys(now)) && length(page["artifacts"]) in (1,2) &&
            BigInt(now["entries"])==BigInt(prior["entries"])+length(page["artifacts"]),"catalog range/entry count differs")
        for item in page["artifacts"]
            _p04_artifact_fields(root,item)
            _p04_require(item["role"]=="science.history" && item["schema"]=="qcl-negf-scientific-history-v5" &&
                item["media_type"]=="application/x-hdf5" && !(item["path"] in keys(artifacts)) &&
                !(item["path"] in pages) && length(unique(item["dependencies"]))==length(item["dependencies"]),"duplicate/non-native history artifact")
            _p04_path(root,item["path"]);artifacts[item["path"]]=item
        end
        if length(page["artifacts"])==2
            _p04_require(page["artifacts"][1]["path"] in page["artifacts"][2]["dependencies"],"record leaf does not bind ordered array owner")
        end
        push!(records,page["artifacts"][end]["path"])
        current=previous
    end
    _p04_require(isempty(intersect(pages,Set(keys(artifacts)))) && length(artifacts)==parse(UInt64,pin["entries"]),"history inventory differs")
    (;artifacts,records)
end
function _p04_original_record(root,locator,key,verified)
    _p04_keys(locator,("source_identity","source_epoch","append_ordinal","leaf","row_offset"))
    _p04_identity(locator["source_identity"]);_p04_id(locator["source_epoch"])
    _p04_u64(locator["append_ordinal"];positive=true);offset=_p04_u64(locator["row_offset"])
    _p04_require(offset<=typemax(Int),"record offset exceeds reader index width")
    file=_p04_open_hdf(root,locator["leaf"],verified)
    meta=offsets=bytes=nothing
    try
        meta=file["metadata"]
        _p04_require(read_attribute(meta,"representation")=="record_leaf","original append is not record leaf")
        identity=read(meta,"identity_json");invocation=read(meta,"invocation_json")
        _p04_require(_p04_parse(String(identity))==locator["source_identity"] &&
            _p04_parse(String(invocation))["source_epoch"]==locator["source_epoch"],"original append leaf owner differs")
        offsets=file["records/offsets"];index=Int(offset)
        _p04_require(0<=index<length(offsets)-1,"original append offset out of range")
        a,b=Int(offsets[index+1]),Int(offsets[index+2]);bytes=file["records/json_utf8"]
        _p04_require(0<=a<b<=length(bytes),"record byte offsets differ")
        record=_p04_parse(String(bytes[a+1:b]))
        _p04_envelope(record,"record",("schema","contract_set","identity","invocation","stream_ordinal","row_key","target","core"))
        _p04_admit_row_key(record["row_key"],record["core"])
        _p04_require(record["identity"]==locator["source_identity"] && record["invocation"]["source_epoch"]==locator["source_epoch"] &&
            record["stream_ordinal"]==locator["append_ordinal"] && record["row_key"]==key && record["target"]===nothing &&
            record["core"]["fields"]["action"]==Dict("kind"=>"symbol","value"=>"append"),"target is not original append")
        record
    finally
        for object in (meta,offsets,bytes);object===nothing || close(object);end
        close(file)
    end
end

function _p04_manifest_checkpoint(root,reference,budget)
    _p04_keys(reference,("identity","state_id","state_sequence","manifest"));_p04_identity(reference["identity"])
    _p04_id(reference["state_id"]);_p04_u64(reference["state_sequence"];positive=true)
    _p04_require(reference["manifest"]["schema"]==_P04_SCHEMAS["manifest"],"unsupported manifest reference")
    manifest=_p04_read_json_ref(root,reference["manifest"],budget)
    _p04_envelope(manifest,"manifest",("schema","contract_set","identity","lineage","invocation","provenance","numerical_binding", "state_id","state_sequence","generation","closed","status","artifacts","history","checkpoint"))
    _p04_require(all(manifest[k]==reference[k] for k in ("identity","state_id","state_sequence")) &&
        manifest["checkpoint"]!==nothing && manifest["checkpoint"]["schema"]==_P04_SCHEMAS["checkpoint"],"selected manifest has no matching exact checkpoint")
    _p04_validate_status(manifest["status"]);_p04_validate_provenance(manifest["provenance"])
    _p04_require(manifest["closed"] isa Bool,"invalid manifest closed flag")
    _p04_keys(manifest["numerical_binding"],("identity","execution"))
    _p04_keys(manifest["lineage"],("parent_state",))
    manifest["lineage"]["parent_state"]===nothing || _p04_lineage(manifest["identity"],manifest["lineage"]["parent_state"])
    declaration=_p04_read_json_ref(root,manifest["checkpoint"],budget)
    _p04_envelope(declaration,"checkpoint",("schema","contract_set","identity","lineage","invocation","state_id","state_sequence","core_layout_sha256","numerical_binding","history","state","payloads","witness_targets"))
    _p04_keys(declaration["numerical_binding"],("identity","execution"))
    _p04_require(declaration["payloads"] isa AbstractVector && declaration["witness_targets"] isa AbstractVector &&
        length(declaration["witness_targets"])<=2 && manifest["artifacts"] isa AbstractVector,"invalid checkpoint inventory")
    _p04_require(declaration["core_layout_sha256"]==_P04_LAYOUT &&
        all(declaration[k]==manifest[k] for k in ("identity","lineage","invocation","state_id","state_sequence","history","numerical_binding")) &&
        declaration["state"]["fields"]["identity"]==declaration["numerical_binding"]["identity"],"checkpoint binding differs from pinned manifest")
    manifest,declaration
end

function _p04_verify_anchors(root,manifest,decl,budget,verified)
    history=_p04_verify_history(root,decl["history"],decl["identity"],decl["invocation"],budget)
    state=decl["state"]["fields"];eligible=Set{Int}()
    if state["boundary"]==Dict("kind"=>"symbol","value"=>"scba_accepted") && state["continuation"]!==nothing &&
            get(state["continuation"],"type",nothing)=="SCBAContinuation" && !state["continuation"]["fields"]["decision"]["fields"]["terminal"]
        for n in state["continuation"]["fields"]["witness_retention"][2:3]
            i=parse(Int,n["decimal"]);i>0 && push!(eligible,i)
        end
    end
    indices=Set{Int}();carried=Any[]
    for entry in decl["witness_targets"]
        _p04_keys(entry,("row_key","locator"));key=_p04_admit_row_key(entry["row_key"]);locator=entry["locator"]
        _p04_require(key["stage"]==Dict("kind"=>"symbol","value"=>"scba") &&
            key["outer_iteration"]==state["progress"]["fields"]["current_outer"] && key["inner_iteration"]!==nothing,"anchor stage differs")
        index=parse(Int,key["inner_iteration"]["decimal"]);_p04_require(!(index in indices),"duplicate witness anchor");push!(indices,index)
        _p04_require(locator["leaf"] in decl["payloads"] && all(locator["source_identity"][k]==decl["identity"][k] for k in
            ("run_id","execution_id","point_id","model_sha256","plan_sha256")),"witness leaf/scope dependency absent")
        if locator["source_identity"]==decl["identity"] && locator["source_epoch"]==decl["invocation"]["source_epoch"]
            _p04_require(locator["leaf"]["path"] in history.records &&
                all(history.artifacts[locator["leaf"]["path"]][k]==v for (k,v) in locator["leaf"]) &&
                0<parse(UInt64,locator["append_ordinal"])<=parse(UInt64,decl["history"]["last_record"]),"own anchor outside committed history")
        else;push!(carried,entry);end
        _p04_original_record(root,locator,key,verified)
    end
    _p04_require(indices==eligible,"anchors differ from public continuation receipt")
    if !isempty(carried)
        parent=manifest["lineage"]["parent_state"];_p04_require(parent!==nothing,"carried anchor without parent")
        pm,pd=_p04_manifest_checkpoint(root,parent,budget)
        _p04_require(all(entry in pd["witness_targets"] for entry in carried),"carried anchor not retained by immediate parent")
        _p04_verify_anchors(root,pm,pd,budget,verified)
    end
    history
end

"""Open a hash-pinned exact state and verify native datasets without materializing arrays."""
function open_exact_checkpoint(artifact_root::AbstractString,reference::AbstractDict;
    maximum_metadata_bytes::Integer)::VerifiedExactCheckpoint
    _p04_require(isdir(artifact_root) && !islink(artifact_root) && maximum_metadata_bytes>0,"invalid root/metadata budget")
    root=realpath(artifact_root);budget=Ref(Int(maximum_metadata_bytes))
    manifest,decl=_p04_manifest_checkpoint(root,reference,budget)
    references=Dict{String,Any}();verified=Dict{String,Any}()
    for p in decl["payloads"]
        _p04_file_fields(p)
        _p04_require(!haskey(references,p["path"]),"duplicate checkpoint payload path")
        references[p["path"]]=p
    end
    inventory=Dict{String,Any}()
    for a in manifest["artifacts"]
        _p04_artifact_fields(root,a)
        _p04_require(!haskey(inventory,a["path"]),"duplicate manifest artifact");inventory[a["path"]]=a
    end
    for a in values(inventory)
        _p04_require(length(unique(a["dependencies"]))==length(a["dependencies"]) && all(haskey(inventory,d) for d in a["dependencies"]),"artifact dependency closure absent")
    end
    _p04_require(haskey(inventory,manifest["checkpoint"]["path"]) &&
        all(inventory[manifest["checkpoint"]["path"]][k]==v for (k,v) in manifest["checkpoint"]),"checkpoint absent from manifest inventory")
    state_schema=manifest["closed"] ? "qcl-negf-physics-v5" : "qcl-negf-checkpoint-v5"
    _p04_require(count(p->p["schema"]==state_schema,values(references))==1 &&
        all(p->p["schema"] in (state_schema,"qcl-negf-scientific-history-v5"),values(references)),"checkpoint native ownership differs")
    for p in values(references)
        _p04_require(haskey(inventory,p["path"]) && all(inventory[p["path"]][k]==v for (k,v) in p),"payload absent from manifest inventory")
        file=p["schema"]==state_schema ? _p04_open_hdf(root,p,verified;identity=decl["identity"],invocation=decl["invocation"],representation="array_payload") :
            _p04_open_hdf(root,p,verified;representation="record_leaf")
        close(file)
    end
    _p04_verify_status(root,manifest["status"],verified)
    _p04_verify_anchors(root,manifest,decl,budget,verified)
    files=Dict{String,Any}();context=(;root,references,verified,files,validate_only=true)
    try
        _p04_decode(decl["state"],QCLNEGF.ExactSolverState,context)
        _p04_decode(decl["numerical_binding"]["execution"],QCLNEGF.ExactExecutionIdentity,context)
    finally;for file in values(files);close(file);end;end
    VerifiedExactCheckpoint(root,reference,manifest,decl,verified,Val(:verified))
end
"""Explicit full state materialization; call Core.restore_exact_state for numerical admission."""
function load_exact_solver_state(checkpoint::VerifiedExactCheckpoint)::QCLNEGF.ExactSolverState
    decl=_p04_parse(checkpoint.declaration_json);references=Dict(p["path"]=>p for p in decl["payloads"])
    files=Dict{String,Any}();context=(root=checkpoint.root,references=references,verified=checkpoint.verified,files=files,validate_only=false)
    try;_p04_decode(decl["state"],QCLNEGF.ExactSolverState,context)
    finally;for file in values(files);close(file);end;end
end

function _atomic_checkpoint(path::AbstractString, solution::NEGFSolution;
    resource_policy::Symbol = :standalone)
    _resident_writer_preflight(resource_policy, :atomic_checkpoint)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary, stream = mktemp(directory)
    close(stream)
    try
        save_checkpoint(temporary, solution; include_kernels = false)
        _atomic_replace_file(temporary, path)
        _sync_artifact_directory(directory)
    catch
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return path
end

function _read_restart_family(parent, name::AbstractString)
    group = parent[name]
    family = SelfEnergyFamily(
        _read_complex(group, "SR"),
        _read_complex(group, "SL"),
        _read_complex(group, "SG"),
    )
    all(component -> all(isfinite, component), (family.Σᴿ, family.Σˡ, family.Σᵍ)) ||
        throw(ArgumentError("restart self-energy family $name contains non-finite values"))
    return family
end

struct _ProductionRestartMismatch <: Exception
    message::String
end

Base.showerror(io::IO, error::_ProductionRestartMismatch) = print(io, error.message)

_restart_mismatch(message::AbstractString) =
    throw(_ProductionRestartMismatch(String(message)))

function _require_restart_equal(label::AbstractString, actual, expected)
    actual == expected ||
        _restart_mismatch("restart $label mismatch: stored=$actual, expected=$expected")
end

function _require_restart_close(label::AbstractString, actual::Real, expected::Real)
    a, b = Float64(actual), Float64(expected)
    isfinite(a) && isfinite(b) ||
        throw(ArgumentError("restart $label contains a non-finite value"))
    scale = max(abs(a), abs(b), floatmin(Float64))
    abs(a - b) ≤ 256eps(Float64) * scale ||
        _restart_mismatch("restart $label mismatch: stored=$actual, expected=$expected")
end

function _require_restart_fraction(numerical, dataset::AbstractString)
    haskey(numerical, dataset) ||
        throw(ArgumentError("restart is missing required numerical_inputs/$dataset"))
    stored = read(numerical[dataset])
    stored isa Real ||
        throw(ArgumentError("restart numerical_inputs/$dataset must be a real scalar"))
    value = Float64(stored)
    isfinite(value) || throw(
        ArgumentError("restart numerical_inputs/$dataset contains a non-finite value"),
    )
    0 < value < 1 ||
        throw(ArgumentError("restart numerical_inputs/$dataset must lie in (0,1)"))
    return value
end

function _require_restart_array_close(label::AbstractString, actual, expected)
    size(actual) == size(expected) || _restart_mismatch(
        "restart $label shape mismatch: stored=$(size(actual)), " *
        "expected=$(size(expected))",
    )
    all(isfinite, actual) ||
        throw(ArgumentError("restart $label contains non-finite values"))
    isempty(actual) && return nothing
    scale = max(maximum(abs, actual), maximum(abs, expected), floatmin(Float64))
    maximum(abs, actual .- expected) ≤ 512eps(Float64) * scale ||
        _restart_mismatch("restart $label values differ from problem")
    return nothing
end

function _require_restart_array_equal(label::AbstractString, actual, expected)
    size(actual) == size(expected) || _restart_mismatch("restart $label shape mismatch")
    actual == expected || _restart_mismatch("restart $label values differ from problem")
    return nothing
end

function _validate_restart_metadata(file, problem::NEGFProblem)
    identity = _checkpoint_identity(file)
    identity.package == _CHECKPOINT_PACKAGE || _restart_mismatch(
        "unsupported restart package $(identity.package) " *
        "(expected $(_CHECKPOINT_PACKAGE))",
    )
    identity.schema == _CHECKPOINT_SCHEMA_VERSION || _restart_mismatch(
        "unsupported restart schema $(identity.schema) " *
        "(expected $(_CHECKPOINT_SCHEMA_VERSION))",
    )
    _require_native_metadata(file, ("qcl-negf-checkpoint-v4", "qcl-negf-physics-v4"))
    haskey(file, "convergence") ||
        throw(ArgumentError("native v4 requires convergence history"))
    _require_native_scba_tables(file["convergence"])
    model_metadata=file["metadata"]
    haskey(model_metadata, "physical_models_identity_yaml") ||
        _restart_mismatch("native v4 checkpoint lacks required physical model identity")
    stored_models=YAML.load(
        String(read(model_metadata["physical_models_identity_yaml"]));
        dicttype = Dict{String,Any},
    )
    expected_models=YAML.load(
        YAML.write(
            Dict(String(k)=>v for (k, v) in pairs(physical_model_identity(problem.models))),
        );
        dicttype = Dict{String,Any},
    )
    _require_restart_equal("physical model identity", stored_models, expected_models)
    numerical = file["numerical_inputs"]
    haskey(attributes(numerical), "energy_shift_discretization") || _restart_mismatch(
        "checkpoint has no energy-shift discretization identity; start a new run",
    )
    _require_restart_equal(
        "energy-shift discretization",
        Symbol(String(read_attribute(numerical, "energy_shift_discretization"))),
        problem.energy_shift_discretization,
    )
    for dataset in ("energy_tail_window_fraction", "momentum_tail_window_fraction")
        _require_restart_fraction(numerical, dataset)
    end
    n = problem.numerical
    _require_restart_equal("N_z", Int(read(numerical["Nz"])), n.N_z)
    _require_restart_equal("N_E", Int(read(numerical["NE"])), n.N_E)
    _require_restart_equal("N_k", Int(read(numerical["Nk"])), n.N_k)
    _require_restart_equal("N_b", Int(read(numerical["Nb"])), n.N_b)
    _require_restart_equal("P_basis", Int(read(numerical["P_basis"])), n.P_basis)
    for (label, dataset, expected) in (
        ("E_min", "E_min_eV", _electronvolts(n.E_min)),
        ("E_max", "E_max_eV", _electronvolts(n.E_max)),
        ("M_E", "M_E_eV", _electronvolts(n.M_E)),
        ("k_max", "k_max_per_m", _inverse_metres(n.k_max)),
        ("qz_max", "qz_max_per_m", _inverse_metres(n.qz_max)),
        ("eta_seed", "eta_seed_eV", _electronvolts(n.η_seed)),
    )
        _require_restart_close(label, Float64(read(numerical[dataset])), expected)
    end
    for (label, dataset, expected) in (("N_phi", "Nphi", n.N_φ), ("N_qz", "Nqz", n.N_qz))
        _require_restart_equal(label, Int(read(numerical[dataset])), expected)
    end
    for name in fieldnames(ScatteringOptions)
        stored = Bool(read(numerical["scattering_$(String(name))"]))
        _require_restart_equal(
            "scattering $name",
            stored,
            getfield(problem.scattering, name),
        )
    end

    inputs = file["inputs"]
    p = problem.physical
    expected_voltage = Float64(ustrip(u"V", uconvert(u"V", p.F_bias * period_length(p))))
    _require_restart_close(
        "voltage per period",
        Float64(read(inputs["V_period_V"])),
        expected_voltage,
    )
    for (label, dataset, expected) in (
        ("field", "F_bias_V_per_m", _volts_per_metre(p.F_bias)),
        ("sheet doping", "N_dop_2D_per_m2", _per_square_metre(p.N_dop²ᴰ)),
        ("ionization", "f_ion", p.f_ion),
        ("coordinate origin", "z0_m", _metres(p.z₀)),
        ("energy reference", "E_ref_eV", _electronvolts(p.E_ref)),
        ("static permittivity", "epsilon_static_relative", p.ε_s),
        ("infinite-frequency permittivity", "epsilon_infinity_relative", p.ε_∞),
        ("LO energy", "hbar_omega_LO_eV", _electronvolts(p.ħωᴸᴼ)),
        ("screening", "q_screen_per_m", _inverse_metres(p.q_s)),
        ("LO screening", "q_LO_screen_per_m", _inverse_metres(p.qᴸᴼ_s)),
        ("IFR height", "Delta_IFR_m", _metres(p.Δᴵᶠᴿ)),
        ("IFR length", "Lambda_IFR_m", _metres(p.Λᴵᶠᴿ)),
        ("deformation potential", "Xi_eV", _electronvolts(p.Ξ)),
        ("mass density", "rho_m_kg_per_m3", Float64(ustrip(u"kg/m^3", p.ρ_m))),
        ("sound speed", "v_s_m_per_s", Float64(ustrip(u"m/s", p.v_s))),
    )
        _require_restart_close(label, Float64(read(inputs[dataset])), expected)
    end
    _require_restart_close(
        "lattice temperature",
        Float64(read(inputs["T_L_K"])),
        _kelvin(p.Tᴸ),
    )
    _require_restart_close(
        "LO temperature",
        Float64(read(inputs["T_LO_K"])),
        _kelvin(p.Tᴸᴼ),
    )
    _require_restart_equal("spin degeneracy", Int(read(inputs["spin_degeneracy"])), p.g_s)
    _require_restart_equal(
        "alloy switch",
        Bool(read_attribute(inputs, "alloy_enabled")),
        problem.scattering.alloy,
    )
    layer_arrays = (
        ("layer thickness", "layer_thickness_m", _metres.([x.d for x in p.layers])),
        ("layer Ec", "layer_Ec_eV", _electronvolts.([x.Eᶜ for x in p.layers])),
        ("layer mz", "layer_mz_relative", [x.mᶻᵣ for x in p.layers]),
        ("layer mparallel", "layer_mparallel_relative", [x.m_parallelᵣ for x in p.layers]),
        ("layer epsilon", "layer_epsilon_relative", [x.εᵣ for x in p.layers]),
        ("layer xAl", "layer_x_Al", [x.x_Al for x in p.layers]),
        ("interfaces", "interface_m", _metres.(p.interfaces)),
    )
    for (label, dataset, expected) in layer_arrays
        _require_restart_array_close(label, read(inputs[dataset]), expected)
    end
    _require_restart_array_equal(
        "layer doping flags",
        read(inputs["layer_doped"]),
        Int8[x.doped for x in p.layers],
    )
    if problem.scattering.alloy
        p.ΔV_alloy === nothing &&
            throw(ArgumentError("alloy restart requires DeltaV_alloy"))
        p.Ω₀ === nothing && throw(ArgumentError("alloy restart requires Omega0"))
        _require_restart_close(
            "alloy potential",
            Float64(read(inputs["DeltaV_alloy_eV"])),
            _electronvolts(p.ΔV_alloy),
        )
        _require_restart_close(
            "alloy volume",
            Float64(read(inputs["Omega0_m3"])),
            Float64(ustrip(u"m^3", p.Ω₀)),
        )
    end

    scales = file["scales"]
    _require_restart_close("E₀", Float64(read(scales["E0_eV"])), problem.scales.E₀_eV)
    _require_restart_close("L₀", Float64(read(scales["L0_m"])), problem.scales.L₀_m)
    _require_restart_close(
        "Poisson scale",
        Float64(read(scales["lambda_P"])),
        problem.scales.λ_P,
    )
    _require_restart_close(
        "current scale",
        Float64(read(scales["J0_A_per_m2"])),
        Float64(ustrip(u"A/m^2", problem.scales.J₀)),
    )
    _require_restart_close(
        "mass scale",
        Float64(read(scales["m_ref_kg"])),
        Float64(ustrip(u"kg", problem.scales.m_ref)),
    )

    grids = file["grids_dimensionless"]
    for (label, dataset, expected) in (
        ("x grid", "x", problem.grids.x),
        ("x weights", "wx", problem.grids.wˣ),
        ("energy grid", "energy", problem.grids.ε),
        ("energy weights", "wE", problem.grids.wᴱ),
        ("k grid", "k", problem.grids.κ),
        ("k weights", "wk", problem.grids.wᵏ),
        ("qz grid", "qz", problem.grids.qᶻ),
        ("qz weights", "wqz", problem.grids.wᑫᶻ),
    )
        _require_restart_array_close(label, read(grids[dataset]), expected)
    end
    _require_restart_array_equal(
        "trusted energy mask",
        read(grids["trusted_energy"]),
        Int8.(problem.grids.trusted_energy),
    )

    profiles = file["profiles_dimensionless"]
    for (label, dataset, expected) in (
        ("Ec profile", "Ec", problem.profiles.Eᶜ),
        ("mz profile", "mz_relative", problem.profiles.mᶻᵣ),
        ("mparallel profile", "mparallel_relative", problem.profiles.m_parallelᵣ),
        ("epsilon profile", "epsilon_relative", problem.profiles.εᵣ),
        ("donor profile", "ND", problem.profiles.Nᴰ),
        ("xAl profile", "x_Al", problem.profiles.x_Al),
    )
        _require_restart_array_close(label, read(profiles[dataset]), expected)
    end
    _require_restart_array_equal(
        "layer-index profile",
        read(profiles["layer_index"]),
        problem.profiles.layer_index,
    )

    basis = file["basis_dimensionless"]
    stored_localization = Symbol(String(read_attribute(basis, "localization")))
    _require_restart_equal(
        "basis localization",
        stored_localization,
        problem.basis.localization,
    )
    for (label, dataset, expected) in (
        ("basis H0", "H0", problem.basis.H₀),
        ("basis Z", "Z", problem.basis.Z),
        ("basis Tplus", "Tplus", problem.basis.T₊),
        ("basis Tminus", "Tminus", problem.basis.T₋),
    )
        _require_restart_array_close(label, _read_complex(basis, dataset), expected)
    end
    selfenergy = file["selfenergy_dimensionless"]
    stored_mechanisms = Set(
        Symbol(String(name)) for
        name in keys(selfenergy) if !startswith(String(name), "embedding_")
    )
    expected_mechanisms = Set(problem.kernels.enabled)
    stored_mechanisms == expected_mechanisms || _restart_mismatch(
        "restart mechanisms mismatch: stored=$(sort!(collect(stored_mechanisms); by=String)), " *
        "expected=$(sort!(collect(expected_mechanisms); by=String))",
    )
    return nothing
end

function _recorded_algorithm_options(contract)
    recorded=get(contract,"algorithms",nothing)
    recorded isa AbstractDict || throw(ArgumentError("restart has unknown algorithm provenance"))
    required=String.(fieldnames(AlgorithmOptions))
    Set(String.(keys(recorded)))==Set(required) || throw(ArgumentError("restart algorithm contract is incomplete"))
    options=Pair{Symbol,Any}[]
    for (index,name) in enumerate(fieldnames(AlgorithmOptions))
        value=recorded[String(name)]
        push!(options,name=>(fieldtype(AlgorithmOptions,index)===Symbol ? Symbol(value) : value))
    end
    return AlgorithmOptions(;options...)
end

function _load_production_restart(
    path::AbstractString,
    problem::NEGFProblem;
    algorithms::Union{Nothing,AlgorithmOptions} = nothing,
    solver_options::Union{Nothing,SolverOptions} = nothing,
)
    return h5open(path, "r") do file
        _validate_restart_metadata(file, problem)
        metadata = file["metadata"]
        String(read_attribute(metadata, "package_version")) == _software_version() ||
            _restart_mismatch("exact restart requires the same package version")
        haskey(metadata, "restart_contract_yaml") || _restart_mismatch(
            "checkpoint lacks the required exact numerical restart contract; start a new run",
        )
        contract = YAML.load(
            String(read(metadata["restart_contract_yaml"]));
            dicttype = Dict{String,Any},
        )
        contract isa Dict{String,Any} &&
        get(contract, "schema", nothing)=="qcl-negf-exact-restart-v1" ||
            throw(ArgumentError("invalid exact restart contract"))
        haskey(metadata, "kernel_identity_yaml") ||
            _restart_mismatch("checkpoint lacks the exact scattering-operator identity")
        kernel_identity = YAML.load(
            String(read(metadata["kernel_identity_yaml"]));
            dicttype = Dict{String,Any},
        )
        kernel_identity == _checkpoint_kernel_identity(problem.kernels) ||
            _restart_mismatch("restart scattering operators differ (Khat, qK, or F_LO)")
        if algorithms !== nothing
            get(contract, "algorithms", nothing) == _restart_contract_value(algorithms) ||
                _restart_mismatch(
                    "restart algorithm contract differs from requested algorithms",
                )
        end
        if solver_options !== nothing
            get(contract, "solver", nothing) == _solver_restart_contract(
                solver_options,
                algorithms === nothing ? _recorded_algorithm_options(contract) : algorithms,
            )["solver"] || _restart_mismatch(
                "restart mixing/quality policy differs from requested solver options",
            )
        end
        state = file["state_dimensionless"]
        shape = (
            problem.numerical.N_E,
            problem.numerical.N_k,
            problem.numerical.N_b,
            problem.numerical.N_b,
        )
        Gᴿ = _read_complex(state, "GR")
        Gˡ = _read_complex(state, "GL")
        Gᵍ = _read_complex(state, "GG")
        A = _read_complex(state, "A")
        all(size(X) == shape for X in (Gᴿ, Gˡ, Gᵍ, A)) ||
            throw(DimensionMismatch("restart Green arrays differ from problem"))
        all(X -> all(isfinite, X), (Gᴿ, Gˡ, Gᵍ, A)) ||
            throw(ArgumentError("restart Green arrays contain non-finite values"))
        condition_number = _read_array(state, "condition_number")
        dyson_scale = _read_array(state, "dyson_scale")
        size(condition_number) ==
        (problem.numerical.N_E, problem.numerical.N_k) ==
        size(dyson_scale) ||
            throw(DimensionMismatch("restart Dyson diagnostics differ from problem"))
        all(isfinite, condition_number) && all(isfinite, dyson_scale) ||
            throw(ArgumentError("restart Dyson diagnostics are non-finite"))
        green = GreenState(Gᴿ, Gˡ, Gᵍ, A, condition_number, dyson_scale)
        parent = file["selfenergy_dimensionless"]
        scattering = Dict{Symbol,SelfEnergyFamily}()
        for name in problem.kernels.enabled
            haskey(parent, String(name)) ||
                throw(ArgumentError("restart is missing mechanism $name"))
            scattering[name] = _read_restart_family(parent, String(name))
        end
        plus = _read_restart_family(parent, "embedding_plus")
        minus = _read_restart_family(parent, "embedding_minus")
        embedding = _read_restart_family(parent, "embedding_total")
        all(
            size(getfield(family, component)) == shape for
            family in (values(scattering)..., embedding, plus, minus) for
            component in (:Σᴿ, :Σˡ, :Σᵍ)
        ) || throw(DimensionMismatch("restart self-energy arrays differ"))
        # Checkpoint histories are logical progress, not the age of this process.
        convergence = file["convergence"]
        scba_rows = _read_array(convergence, "scba")
        size(scba_rows, 2) == 18 || throw(
            ArgumentError("native v4 SCBA checkpoint history requires exactly 18 columns"),
        )
        history = SCBAIteration[
            SCBAIteration(
                Int(row[1]),
                Float64.(row[2:13])...,
                Float64.(row[15:18])...,
                nothing,
                nothing,
            ) for row in eachrow(scba_rows)
        ]
        witnesses = _read_psd_history(convergence, length(history))
        physical_markers = _read_physical_markers(convergence, length(history))
        history = SCBAIteration[
            SCBAIteration(
                (getfield(row, field) for field in fieldnames(SCBAIteration)[1:17])...,
                witnesses[index],
                physical_markers[index],
            ) for (index, row) in enumerate(history)
        ]
        all(i -> history[i].ν == i, eachindex(history)) ||
            throw(ArgumentError("SCBA checkpoint history is not contiguous"))
        outer_rows = _read_array(convergence, "outer")
        populations = _read_array(convergence, "outer_populations")
        density = _read_array(convergence, "outer_density")
        outer_history = OuterIteration[
            OuterIteration(
                Int(row[1]),
                Float64.(row[2:10])...,
                Float64.(vec(populations[i, :])),
                Float64.(vec(density[i, :])),
            ) for (i, row) in enumerate(eachrow(outer_rows))
        ]
        all(i -> outer_history[i].μ == i, eachindex(outer_history)) ||
            throw(ArgumentError("Poisson checkpoint history is not contiguous"))
        stored_status = Symbol(String(read_attribute(file["metadata"], "status")))
        stored_quality = Symbol(String(read_attribute(file["metadata"], "scba_quality")))
        haskey(file, "algorithm_state") ||
            throw(ArgumentError("checkpoint lacks algorithm state"))
        algorithm = file["algorithm_state"]
        method = Symbol(String(read_attribute(algorithm, "method")))
        count = Int(read_attribute(algorithm, "history_count"))
        families_count = length(problem.kernels.enabled)+2
        expected_order = join(
            [String.(problem.kernels.enabled); "embedding_plus"; "embedding_minus"],
            ",",
        )
        String(read_attribute(algorithm, "family_order")) == expected_order ||
            throw(ArgumentError("checkpoint mixer family order differs"))
        read_history(kind) = [
            SelfEnergyFamily[
                _read_restart_family(algorithm[kind][string(i)], string(j)) for
                j = 1:families_count
            ] for i = 1:count
        ]
        mixer = SCBAMixerState(method, read_history("states"), read_history("residuals"))
        all(
            size(getfield(family, component)) == shape for
            rows in (mixer.states, mixer.residuals) for families in rows for
            family in families for component in (:Σᴿ, :Σˡ, :Σᵍ)
        ) || throw(DimensionMismatch("checkpoint mixer array shape differs"))
        scba = SCBAResult(
            green,
            scattering,
            embedding,
            plus,
            minus,
            history,
            false,
            :restart,
            stored_quality === :strictly_converged ? :unresolved : stored_quality,
            contract,
            mixer,
        )
        Uᴴ = Float64.(read(state["UH"]))
        length(Uᴴ) == problem.numerical.N_z ||
            throw(DimensionMismatch("restart Hartree field differs from problem"))
        all(isfinite, Uᴴ) ||
            throw(ArgumentError("restart Hartree field contains non-finite values"))
        metadata=file["metadata"]
        for name in ("warnings_json", "adaptation_checkpoint_json")
            haskey(metadata, name) ||
                throw(ArgumentError("native v4 recovery requires metadata/$name"))
        end
        warning_data=YAML.load(
            String(read(metadata["warnings_json"]));
            dicttype = Dict{String,Any},
        )
        warning_data isa AbstractVector ||
            throw(ArgumentError("checkpoint warnings must be an array"))
        warnings=Dict{String,Any}[Dict{String,Any}(warning) for warning in warning_data]
        adaptation = YAML.load(
            String(read(metadata["adaptation_checkpoint_json"]));
            dicttype = Dict{String,Any},
        )
        return (;
            Uᴴ,
            scba,
            outer_history,
            warnings,
            adaptation,
            status = stored_status,
            original_scba_status = Symbol(String(read_attribute(metadata, "scba_status"))),
            original_scba_converged = Bool(read_attribute(metadata, "scba_converged")),
            original_scba_quality = stored_quality,
            resume_scba = !(stored_status in (:running, :snapshot)),
            completed = stored_status in (:converged, :approximate),
        )
    end
end

function _quarantine_production_restart(path::AbstractString)
    absolute = abspath(path)
    stem, extension = splitext(absolute)
    token = "$(getpid()).$(time_ns())"
    suffix = 0
    while true
        discriminator = suffix == 0 ? token : "$token.$suffix"
        candidate = "$stem.incompatible.$discriminator$extension"
        try
            mv(absolute, candidate; force = false)
            return candidate
        catch error
            if ispath(candidate) && isfile(absolute)
                suffix += 1
                continue
            end
            rethrow(error)
        end
    end
end

"""
    load_production_restart(path, problem; incompatible=:error)

Load the full Green/self-energy state needed for a warm restart.  The caller
must provide the already rebuilt problem; exact array shapes and mechanism
names and saved histories are checked. Same-stage linear restart restores
logical iteration counts and consumes only the remaining budget. Anderson state and residual histories are serialized at the accepted boundary;
restart replays the next mixing step with the restored history.

`incompatible=:error` (the default) preserves strict loading and throws an
`ArgumentError` for a metadata-incompatible checkpoint.  `:ignore` emits a
warning and returns `nothing`.  `:quarantine` moves the incompatible file
beside the original under a collision-safe `.incompatible.*` name, emits
a warning containing both paths, and returns `nothing`.  Malformed HDF5,
missing datasets, non-finite state arrays, and all other errors remain fatal in
every mode; these indicate corruption or an implementation error rather than
a reusable checkpoint from a different discretization.

See [Production sweep and recovery](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md) and the
[HDF5 checkpoint schema](@ref native-result-formats).
"""
function load_production_restart(
    path::AbstractString,
    problem::NEGFProblem;
    incompatible::Symbol = :error,
    algorithms::Union{Nothing,AlgorithmOptions} = nothing,
    solver_options::Union{Nothing,SolverOptions} = nothing,
)
    incompatible in (:error, :ignore, :quarantine) ||
        throw(ArgumentError("incompatible must be :error, :ignore, or :quarantine"))
    try
        return _load_production_restart(path, problem; algorithms, solver_options)
    catch error
        error isa _ProductionRestartMismatch || rethrow(error)
        message = error.message
        incompatible === :error && throw(ArgumentError(message))
        if incompatible === :ignore
            @warn "ignoring metadata-incompatible production checkpoint; starting fresh" checkpoint=abspath(
                path,
            ) reason=message
        else
            quarantined = _quarantine_production_restart(path)
            @warn "quarantined metadata-incompatible production checkpoint; starting fresh" checkpoint=abspath(
                path,
            ) quarantined reason=message
        end
        return nothing
    end
end

function _csv_field(value)
    text = string(value)
    return occursin(r"[,\"\n\r]", text) ? "\"" * replace(text, "\"" => "\"\"") * "\"" : text
end

"""
Atomically write a language-neutral CSV sweep summary.

See [Production plots and saved data](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md).
"""
function save_production_summary(path::AbstractString, result::ProductionSweepResult)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary, stream = mktemp(directory)
    try
        metric_set = Set{Symbol}()
        for record in result.records
            union!(metric_set, keys(record.metrics))
        end
        metric_names = sort!(collect(metric_set); by = String)
        header = String[
            "temperature_K",
            "voltage_per_period_V",
            "field_V_per_m",
            "current_A_per_m2",
            "converged",
            "status",
            "scba_quality",
            "outer_iterations",
            "final_scba_iterations",
            "estimated_peak_bytes",
            "wall_seconds",
            "checkpoint",
            "quality",
            "warning_count",
            "warnings_json",
        ]
        append!(header, ["metric_$(String(name))" for name in metric_names])
        println(stream, join(header, ','))
        for record in result.records
            values = Any[
                record.temperature_K,
                record.voltage_per_period_V,
                record.field_V_per_m,
                record.current_A_per_m2,
                record.converged,
                record.status,
                record.scba_quality,
                record.outer_iterations,
                record.final_scba_iterations,
                record.estimated_peak_bytes,
                record.wall_seconds,
                record.checkpoint,
                record.converged ? "strict" :
                record.scba_quality === :invalid ? "invalid" :
                record.status === :approximate ? "approximate" : "unconverged",
                length(record.warnings),
                sprint(_light_json, record.warnings),
            ]
            append!(values, [get(record.metrics, name, "") for name in metric_names])
            println(stream, join(_csv_field.(values), ','))
        end
        close(stream)
        _atomic_replace_file(temporary, path)
    catch
        isopen(stream) && close(stream)
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return path
end
