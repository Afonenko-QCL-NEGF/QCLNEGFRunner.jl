# Optional metadata at the actual public solve boundary. No model resolution,
# scientific arrays, origin inference or Core state introspection belongs here.
const _MODEL_HELP_SNAPSHOT_BYTES=64*1024
const _MODEL_HELP_TOTAL_BYTES=8*1024^2
struct _ModelHelpUnavailable <: Exception
    reason::String
end
Base.showerror(io::IO,e::_ModelHelpUnavailable)=print(io,e.reason)
mutable struct _ModelHelpBudget
    entries::Int
    bytes::Int
    work_bytes::Int
    function _ModelHelpBudget(points::Int;bytes::Int=_MODEL_HELP_TOTAL_BYTES,
        work_bytes::Int=6*_MODEL_HELP_TOTAL_BYTES)
        points>=0 && 0<=bytes<=_MODEL_HELP_TOTAL_BYTES && work_bytes>=0 ||
            throw(ArgumentError("invalid model help allowance"))
        new(min(points,10000),bytes,work_bytes)
    end
end
_model_help_unknown()=Dict{String,Any}("status"=>"unknown","atom"=>nothing)
function _model_help_atom(value,unit::String;integer=false)
    safe=integer ? value isa Integer && !(value isa Bool) && abs(big(value))<=9007199254740991 :
        value isa Float64 && isfinite(value)
    safe || return _model_help_unknown()
    Dict{String,Any}("status"=>"known","atom"=>Dict{String,Any}(
        "kind"=>integer ? "integer" : "quantity","value"=>value,"unit"=>unit))
end
function _model_help_inputs(problem::QCLNEGF.NEGFProblem,options::QCLNEGF.ProductionOptions)
    p=problem.physical
    # Deliberately explicit actual getters; their conversion oracle is independent.
    atoms=(
        ("production.energy_chunk",_model_help_atom(options.energy_chunk,"1";integer=true)),
        ("physical.lattice_temperature",_model_help_atom(ustrip(uconvert(u"K",p.Tᴸ)),"K")),
        ("physical.lo_temperature",_model_help_atom(ustrip(uconvert(u"K",p.Tᴸᴼ)),"K")),
        ("physical.interface_roughness_height",_model_help_atom(ustrip(uconvert(u"nm",p.Δᴵᶠᴿ)),"nm")),
        ("physical.interface_correlation_length",_model_help_atom(ustrip(uconvert(u"nm",p.Λᴵᶠᴿ)),"nm")),
        ("physical.impurity_screening_wavenumber",_model_help_atom(ustrip(uconvert(u"nm^-1",p.q_s)),"nm^-1")),
        ("physical.lo_screening_wavenumber",_model_help_atom(ustrip(uconvert(u"nm^-1",p.qᴸᴼ_s)),"nm^-1")),
        ("physical.lo_phonon_energy",_model_help_atom(ustrip(uconvert(u"meV",p.ħωᴸᴼ)),"meV")))
    [Dict{String,Any}("path"=>path,"declared"=>_model_help_unknown(),"used"=>used,
        "assigning"=>Dict("status"=>"unknown","kind"=>"unknown","source"=>nothing,"rule"=>nothing),
        "effective_origin"=>Dict("status"=>"unknown","steps"=>Any[])) for (path,used) in atoms]
end
function _model_help_context(capture::_P05PlanCapture,point::ScientificPoint,identity)
    capture.kind===:scientific_plan_v2 || throw(ArgumentError("help requires frozen scientific plan"))
    doc=capture.document
    ids=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z"; digest=r"^[0-9a-f]{64}\z"
    all(x->x isa String && occursin(digest,x),(doc["fingerprint"],doc["scientific_fingerprint"],capture.plan_sha256)) &&
        doc["model_revision"] isa String && 0<ncodeunits(doc["model_revision"])<=128 ||
        throw(ArgumentError("invalid frozen help context"))
    occursin(ids,point.id) && occursin(ids,point.execution_id) || throw(ArgumentError("invalid help point"))
    rows=filter(row->row["id"]==point.id,doc["points"])
    executions=filter(row->row["id"]==point.execution_id,doc["executions"])
    length(rows)==1 && length(executions)==1 && point.id in only(executions)["point_ids"] ||
        throw(ArgumentError("help point is not selected frozen membership"))
    row=only(rows); passport=row["effective_inputs"]
    all(get(row,k,nothing)==v for (k,v) in _point_dict(point)) &&
        passport["hash_encoding"]=="qcl-negf-canonical-bytes-v1" && passport["axes_applied"]===true &&
        passport["temperature_K"]==point.temperature_K && passport["voltage_per_period_V"]==point.voltage_per_period_V &&
        passport["configuration_hash"] isa String && occursin(digest,passport["configuration_hash"]) &&
        passport["model_sha256"]==identity["model_sha256"] && capture.plan_sha256==identity["plan_sha256"] &&
        point.id==identity["point_id"] && point.execution_id==identity["execution_id"] ||
        throw(ArgumentError("help passport/P05 binding differs"))
    attempt=tryparse(Int,String(identity["attempt"]))
    attempt!==nothing && 1<=attempt<=9007199254740991 || throw(ArgumentError("invalid local help attempt"))
    Dict{String,Any}("plan_fingerprint"=>doc["fingerprint"],"scientific_fingerprint"=>doc["scientific_fingerprint"],
        "model_revision"=>doc["model_revision"],"execution_id"=>point.execution_id,"point_id"=>point.id,
        "attempt"=>attempt,"configuration_hash"=>passport["configuration_hash"])
end
# Count closed JSON bytes without creating an encoded buffer or payload copy.
_model_help_size(::Nothing)=4
_model_help_size(x::Bool)=x ? 4 : 5
_model_help_size(x::Integer)=ncodeunits(repr(x))
_model_help_size(x::Float64)=ncodeunits(replace(repr(x),r"[eE](?=\d)"=>"e+"))
_model_help_size(x::AbstractString)=2+sum(c->c in ('"','\\','\n','\r','\t') ? 2 :
    Int(c)<0x20 ? 6 : ncodeunits(string(c)),x;init=0)
_model_help_size(x::AbstractVector)=2+max(length(x)-1,0)+sum(_model_help_size,x;init=0)
_model_help_size(x::AbstractDict)=2+max(length(x)-1,0)+sum(kv->_model_help_size(kv.first)+1+
    _model_help_size(kv.second),pairs(x);init=0)
function _model_help_admit!(budget::_ModelHelpBudget,n::Int,mirror::Bool)
    work=Base.checked_mul(n,mirror ? 6 : 4) # encode + byte-vector + temporary + durable, plus mirror pair.
    n<=_MODEL_HELP_SNAPSHOT_BYTES && budget.entries>0 && n<=budget.bytes && work<=budget.work_bytes ||
        throw(_ModelHelpUnavailable("model_help_budget_exhausted"))
    budget.entries-=1;budget.bytes-=n;budget.work_bytes-=work # Terminal credit: failures never refund.
    nothing
end
_model_help_expected(e)=e isa _ModelHelpUnavailable || e isa SystemError || e isa Base.IOError
function _model_help_close_birth(birth,primary)
    try
        QCLNEGFRunner._native_capture_close!(birth)
    catch secondary
        if primary===nothing
            # This owning helper reports a failed close as ArgumentError. It is
            # optional I/O uncertainty, not a scientific invariant failure.
            secondary isa ArgumentError && throw(_ModelHelpUnavailable("model_help_directory_close_uncertain"))
            rethrow()
        end
        @warn "model help close failed; original error retained" exception=secondary
    end
end
function _model_help_close_io(io,primary,hook)
    secondary=nothing
    try hook(:close) catch e;secondary=e;end
    try close(io) catch e;secondary===nothing && (secondary=e);end
    if secondary!==nothing
        primary===nothing && throw(secondary)
        @warn "model help file close failed; original error retained" exception=secondary
    end
end
function _model_help_hold_directory(path;children=())
    birth=QCLNEGFRunner._NativeCaptureBirth(Any[],QCLNEGFRunner._native_capture_process(),nothing,false)
    primary=nothing
    try
        directory=QCLNEGFRunner._native_capture_chain!(birth,abspath(path))
        for name in children
            directory=QCLNEGFRunner._native_capture_hold!(birth,directory,name;create=true)
        end
        return birth,directory
    catch e
        primary=e
        e isa ArgumentError && throw(_ModelHelpUnavailable("model_help_directory_unavailable: "*sprint(showerror,e)))
        rethrow()
    finally
        primary===nothing || _model_help_close_birth(birth,primary)
    end
end
function _model_help_publish!(path,raw;children=(),hook=stage->nothing)
    birth,directory=_model_help_hold_directory(path;children)
    temporary=".model-help-"*basename(tempname())
    primary=nothing;created=false
    try
        QCLNEGFRunner._native_capture_validate(birth)
        # Linux no-follow/exclusive open, anchored to the held actual directory.
        descriptor=ccall(:openat,Cint,(Cint,Cstring,Cint,Cuint),directory,temporary,0xa00c1,0o640)
        descriptor>=0 || throw(SystemError("model help openat",Libc.errno()))
        created=true;io=Base.fdio(descriptor,true);file_primary=nothing
        try
            write(io,raw)==length(raw) || throw(_ModelHelpUnavailable("model_help_short_write"))
            flush(io);hook(:sync)
            ccall(:fsync,Cint,(Cint,),fd(io))==0 || throw(SystemError("model help fsync",Libc.errno()))
        catch e
            file_primary=e;rethrow()
        finally
            _model_help_close_io(io,file_primary,hook)
        end
        QCLNEGFRunner._native_capture_validate(birth);hook(:link)
        ccall(:linkat,Cint,(Cint,Cstring,Cint,Cstring,Cint),directory,temporary,directory,"model-help-inputs.json",0)==0 ||
            throw(SystemError("model help exclusive link",Libc.errno()))
        ccall(:fsync,Cint,(Cint,),directory)==0 || throw(SystemError("model help directory fsync",Libc.errno()))
        QCLNEGFRunner._native_capture_validate(birth)
    catch e
        primary=e;rethrow()
    finally
        # Only our exclusive temporary name is removed. A published name is immutable.
        cleanup_error=nothing
        try
            if created
                ccall(:unlinkat,Cint,(Cint,Cstring,Cint),directory,temporary,0)==0 ||
                    throw(SystemError("model help temporary unlink",Libc.errno()))
                hook(:cleanup_sync)
                ccall(:fsync,Cint,(Cint,),directory)==0 ||
                    throw(SystemError("model help cleanup directory fsync",Libc.errno()))
            end
        catch e
            cleanup_error=e
        end
        try
            _model_help_close_birth(birth,primary===nothing ? cleanup_error : primary)
        catch e
            cleanup_error===nothing && (cleanup_error=e)
        end
        if cleanup_error!==nothing
            primary===nothing && throw(cleanup_error)
            @warn "model help cleanup failed; original error retained" exception=cleanup_error
        end
    end
    nothing
end
function _model_help_capture!(budget::_ModelHelpBudget,directory,problem::QCLNEGF.NEGFProblem,
    options::QCLNEGF.ProductionOptions,capture::_P05PlanCapture,point::ScientificPoint,identity;
    mirror=nothing,hook=stage->nothing)
    context=_model_help_context(capture,point,identity)
    expected=joinpath("executions",point.execution_id,point.id,"attempt-"*string(context["attempt"]))
    endswith(abspath(directory),"/"*expected) || throw(ArgumentError("help capture directory identity differs"))
    document=Dict{String,Any}("format"=>"qcl-negf.model-help-inputs.v1","context"=>context,
        "phase"=>"solver_input","inputs"=>_model_help_inputs(problem,options),"origin_bindings"=>Any[])
    try
        n=_model_help_size(document)
        _model_help_admit!(budget,n,mirror!==nothing)
        hook(:before_encode)
        raw=Vector{UInt8}(codeunits(sprint(_light_json,document)))
        length(raw)==n || error("model help byte forecast invariant")
        any(x->x["used"]["status"]=="unknown",document["inputs"]) && @warn "model help unsupported scalar remains unknown"
        try _check_storage_free(directory,2*n) catch e
            e isa ArgumentError || rethrow()
            throw(_ModelHelpUnavailable("model_help_source_space_unavailable"))
        end
        _model_help_publish!(directory,raw;hook)
        mirrored=false
        if mirror!==nothing
            try
                QCLNEGFRunner._native_capture_validate(mirror.birth)
                _check_storage_free(mirror.root,2*n)
                hook(:mirror_copy)
                _model_help_publish!(mirror.root,raw;children=(point.execution_id,point.id,"attempt-"*string(context["attempt"])),hook)
                QCLNEGFRunner._native_capture_validate(mirror.birth)
                mirrored=true
            catch e
                # Mirror namespace validation/free-space refusal is optional I/O.
                (e isa ArgumentError || _model_help_expected(e)) || rethrow()
                @warn "optional native model help mirror unavailable" exception=e
            end
        end
        (;path=joinpath(directory,"model-help-inputs.json"),sha256=bytes2hex(sha256(raw)),bytes=n,mirrored)
    catch e
        _model_help_expected(e) || rethrow()
        @warn "optional solver input help unavailable" exception=e
        nothing
    end
end
