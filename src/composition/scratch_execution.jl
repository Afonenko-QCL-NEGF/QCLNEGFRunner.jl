const _CAPTURE_RESERVE_BYTES = 104 * 1024^2 # 32 performance +64 scalar +8 auxiliary.

# Mandatory native scientific origin is independent of optional capture. These
# bounded original bytes are assertions; trusted jobs_root/Code/caller and the
# actual creator remain owning AiiDA/Platform/Root joins.
function _native_origin_inputs(plan_path,graph_path,native_path,output,calcjob_uuid,execution_id;
    frozen_plan_bytes::Vector{UInt8})
    _p04_require(_native_origin_uuid(calcjob_uuid),"invalid native CalcJob UUID")
    _p04_id(execution_id)
    _p04_require(all(p->p isa AbstractString && !isempty(p) && normpath(p)==p && !occursin('\0',p),
        (plan_path,graph_path,native_path,output)),"noncanonical native input/output path")
    job=dirname(abspath(plan_path))
    _p04_require(isdir(job) && !islink(job) && realpath(job)==job,"native original workdir is not canonical")
    _p04_require(isabspath(output) && abspath(output)==output && output!=job &&
        !startswith(output,job*"/") && !startswith(job,output*"/"),"native output aliases original workdir")
    # The original plan follows the existing capture plan allowance. The two
    # other original roles retain their smaller metadata ceiling.
    plan_cap=1024^2
    _p04_require(length(frozen_plan_bytes)<=plan_cap,"native original plan exceeds byte limit")
    function original(path,name,cap)
        actual=abspath(path)
        _p04_require(actual==joinpath(job,name) && isfile(actual) && !islink(actual),"native original input path differs")
        file=Base.Filesystem.open(actual,Base.JL_O_RDONLY|Base.JL_O_NOFOLLOW|Base.JL_O_NONBLOCK)
        primary=nothing
        try
            before=stat(file)
            _p04_require(isfile(before) && before.nlink==1 && before.size<=cap,"native original input exceeds bound or is aliased")
            raw=read(file,cap+1)
            _p04_require(length(raw)<=cap && length(raw)==before.size &&
                _p04_stat(before)==_p04_stat(stat(file)) && !islink(actual) &&
                _p04_stat(before)==_p04_stat(stat(actual)) && realpath(job)==job,"native original input changed")
            raw
        catch error
            primary=error;rethrow()
        finally
            try
                close(file)
            catch secondary
                primary===nothing && rethrow()
                @warn "native original input close uncertain; original exception retained" exception=secondary
            end
        end
    end
    plan_raw=original(plan_path,"plan.json",plan_cap)
    _p04_require(plan_raw==frozen_plan_bytes,"native original frozen plan bytes differ")
    graph_raw=original(graph_path,"source-graph.json",65536);native_raw=original(native_path,"native-execution.json",65536)
    plan=_p04_parse(String(copy(plan_raw)));graph=_p04_parse(String(copy(graph_raw)));native=_p04_parse(String(native_raw))
    _p04_require(plan isa AbstractDict && get(plan,"executions",nothing) isa AbstractVector &&
        count(e->e isa AbstractDict && get(e,"id",nothing)==execution_id,plan["executions"])==1,
        "native original selected execution differs")
    _require_source_graph(graph)
    paths=[row["path"] for row in graph["components"]]
    _p04_require(length(paths)==length(unique(paths)),"duplicate native original source component")
    _p04_require(native isa AbstractDict,"native execution must be an object")
    _p04_keys(native,("schema","request_id","execution_id","storage","source_graph","code","input_plan","access_receipt_ref"))
    opaque(v)=v isa String && 1<=length(v)<=256 && !startswith(v,"/") && all(c->c>=' ' && c!='\x7f',v)
    _p04_require(native["schema"]=="qcl-negf.aiida-native-execution.v1" &&
        _native_origin_uuid(native["request_id"]) && native["execution_id"]==execution_id &&
        opaque(native["access_receipt_ref"]),"native original execution declaration differs")
    for (key,raw) in (("input_plan",plan_raw),("source_graph",graph_raw))
        claim=native[key];_p04_require(claim isa AbstractDict,"native original file claim must be an object")
        _p04_keys(claim,("node_uuid","bytes","sha256"))
        _p04_require(_native_origin_uuid(claim["node_uuid"]) && claim["bytes"]==string(length(raw)) &&
            claim["sha256"]==bytes2hex(sha256(raw)),"native original whole file claim differs")
    end
    storage=native["storage"];code=native["code"]
    _p04_require(storage isa AbstractDict && code isa AbstractDict,"native storage/code must be objects")
    _p04_keys(storage,("namespace_id","storage_identity","relative_execution_root","computer_uuid",
        "execution_binding_uuid","retention_policy_id","retention_owner_id","hold_ref","access_binding_ref"))
    _p04_id(storage["namespace_id"])
    _p04_require(_native_origin_uuid(storage["computer_uuid"]) && _native_origin_uuid(storage["execution_binding_uuid"]) &&
        all(k->opaque(storage[k]),("storage_identity","retention_policy_id","retention_owner_id","hold_ref","access_binding_ref")),
        "native original storage declaration differs")
    relative=storage["relative_execution_root"]
    _p04_require(relative isa String && !isempty(relative) && !isabspath(relative) &&
        !occursin('\\',relative) && !occursin('\0',relative) &&
        all(p->!(p in ("",".","..")),split(relative,'/')) && endswith(output,"/"*relative),
        "native original output suffix differs")
    _p04_keys(code,("code_uuid","computer_uuid","solver_executable","release_id","build_receipt_ref"))
    _p04_id(code["release_id"])
    _p04_require(_native_origin_uuid(code["code_uuid"]) && code["computer_uuid"]==storage["computer_uuid"] &&
        opaque(code["build_receipt_ref"]) && code["solver_executable"] isa String &&
        occursin(r"^/nix/store/[A-Za-z0-9][A-Za-z0-9+._?-]*/bin/qcl-negf\z",code["solver_executable"]),
        "native original Code declaration differs")
    _native_origin_ids((calcjob_uuid=String(calcjob_uuid),native_execution_uuid=String(storage["execution_binding_uuid"])))
end

function _capture_context(plan, output, execution_id, attempt;
    spec_path=get(ENV,"QCL_NEGF_CAPTURE_SPEC",""),scratch_root=nothing,
    frozen_plan_bytes=nothing,source_plan_path=nothing,
    native_execution_path=nothing,source_graph_path=nothing,native_origin=nothing)
    isempty(spec_path) && return nothing
    try
        path=abspath(spec_path); job=dirname(path)
        basename(path)=="capture-spec.json" && isfile(path) && !islink(path) || return nothing
        native_mode=native_execution_path!==nothing
        if native_mode
            # Transport admission does not set the solver's native point counter.
            attempt===nothing && scratch_root===nothing && isabspath(output) && abspath(output)==output || return nothing
            native_origin===nothing || _native_origin_ids(native_origin)!==nothing || return nothing
        else
            abspath(output)==joinpath(job,"result") || return nothing
        end
        raw=open(io->read(io,16385),path); length(raw)<=16384 || return nothing
        spec=native_mode ? _p04_parse(String(raw)) : YAML.load(String(raw);dicttype=Dict{String,Any})
        spec isa AbstractDict || return nothing
        fields=["schema","selection","plan","capture_token","allocation_id","allocated_logical_cpus","scratch_root","credits"]
        if native_mode
            push!(fields,"native_performance")
            Set(keys(spec))==Set(fields) && spec["schema"]=="qcl-negf.capture-spec.v3" || return nothing
            performance=spec["native_performance"]
            performance isa AbstractDict && Set(keys(performance))==Set(["run_uuid"]) &&
                _native_origin_uuid(performance["run_uuid"]) || return nothing
            native_origin!==nothing || return nothing
        else
            Set(keys(spec))==Set(fields) && spec["schema"]=="qcl-negf.capture-spec.v1" || return nothing
        end
        selection=spec["selection"]
        Set(keys(selection))==Set(["calcjob_uuid","execution_id","attempt","plan_fingerprint"]) || return nothing
        selection["calcjob_uuid"] isa String && occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",selection["calcjob_uuid"]) || return nothing
        native_origin===nothing || selection["calcjob_uuid"]==native_origin.calcjob_uuid || return nothing
        transport_attempt=selection["attempt"]
        if native_mode
            transport_attempt isa Int && !(transport_attempt isa Bool) && 1<=transport_attempt<=9007199254740991 || return nothing
        else
            transport_attempt===attempt || return nothing
        end
        selection["execution_id"]==execution_id && selection["plan_fingerprint"]==plan.fingerprint || return nothing
        token=spec["capture_token"]; token isa String && occursin(r"^[0-9a-f]{32}$",token) || return nothing
        spec["allocated_logical_cpus"]===nothing && spec["scratch_root"]==scratch_root &&
            spec["allocation_id"]=="calcjob-process:$(selection["calcjob_uuid"]):$(transport_attempt)" || return nothing
        pin=spec["plan"]; pin["path"]=="plan.json" || return nothing
        expected_plan=joinpath(job,"plan.json")
        plan_raw=if frozen_plan_bytes !== nothing && source_plan_path !== nothing &&
                    isfile(expected_plan) && realpath(source_plan_path)==realpath(expected_plan)
            frozen_plan_bytes
        else
            open(io->read(io,1024^2+1),expected_plan)
        end
        length(plan_raw)<=1024^2 && length(plan_raw)==pin["bytes"] && bytes2hex(sha256(plan_raw))==pin["sha256"] || return nothing
        if native_mode
            # These bounded original INPUT claims are assertions. The controller
            # owns jobs_root authority, InstalledCode/release and writer lifetime.
            uuid(v)=v isa String && occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z",v)
            id(v)=v isa String && occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z",v)
            opaque(v)=v isa String && 1<=length(v)<=256 && !startswith(v,"/") && all(c->c>=' ' && c!='\x7f',v)
            file_claim(ref,bytes)=ref isa AbstractDict && Set(keys(ref))==Set(["node_uuid","bytes","sha256"]) &&
                uuid(ref["node_uuid"]) && ref["bytes"]==string(length(bytes)) && ref["sha256"]==bytes2hex(sha256(bytes))
            uuid(selection["calcjob_uuid"]) && occursin(r"^[0-9a-f]{32}\z",token) &&
                Set(keys(pin))==Set(["path","bytes","sha256"]) && pin["bytes"] isa Int && !(pin["bytes"] isa Bool) || return nothing
            source_plan_path!==nothing && source_graph_path!==nothing &&
                !islink(expected_plan) && !islink(source_plan_path) && realpath(source_plan_path)==realpath(expected_plan) || return nothing
            graph_path=joinpath(job,"source-graph.json")
            !islink(graph_path) && !islink(source_graph_path) && realpath(source_graph_path)==realpath(graph_path) || return nothing
            graph_raw=open(io->read(io,256*1024+1),graph_path);length(graph_raw)<=256*1024 || return nothing
            graph=_require_source_graph(_p04_parse(String(copy(graph_raw))))
            components=graph["components"];length(unique(c["path"] for c in components))==length(components) || return nothing
            original_plan=_p04_parse(String(copy(plan_raw)))
            original_plan["fingerprint"]==plan.fingerprint && any(e["id"]==execution_id for e in original_plan["executions"]) || return nothing
            native_path=abspath(native_execution_path)
            native_path==joinpath(job,"native-execution.json") && !islink(native_path) || return nothing
            native_raw=open(io->read(io,16385),native_path);length(native_raw)<=16384 || return nothing
            native=_p04_parse(String(native_raw))
            Set(keys(native))==Set(["schema","request_id","execution_id","storage","source_graph","code","input_plan","access_receipt_ref"]) &&
                native["schema"]=="qcl-negf.aiida-native-execution.v1" && uuid(native["request_id"]) &&
                id(native["execution_id"]) && native["execution_id"]==execution_id && opaque(native["access_receipt_ref"]) &&
                file_claim(native["input_plan"],plan_raw) && file_claim(native["source_graph"],graph_raw) || return nothing
            storage=native["storage"];code=native["code"]
            Set(keys(storage))==Set(["namespace_id","storage_identity","relative_execution_root","computer_uuid",
                "execution_binding_uuid","retention_policy_id","retention_owner_id","hold_ref","access_binding_ref"]) &&
                id(storage["namespace_id"]) && uuid(storage["computer_uuid"]) && uuid(storage["execution_binding_uuid"]) &&
                all(opaque(storage[k]) for k in ("storage_identity","retention_policy_id","retention_owner_id","hold_ref","access_binding_ref")) || return nothing
            relative=storage["relative_execution_root"]
            relative isa String && !isempty(relative) && !isabspath(relative) && !occursin('\\',relative) && !occursin('\0',relative) &&
                all(p->!(p in ("",".","..")),split(relative,'/')) && endswith(output,"/"*relative) || return nothing
            Set(keys(code))==Set(["code_uuid","computer_uuid","solver_executable","release_id","build_receipt_ref"]) &&
                uuid(code["code_uuid"]) && uuid(code["computer_uuid"]) && code["computer_uuid"]==storage["computer_uuid"] &&
                id(code["release_id"]) && opaque(code["build_receipt_ref"]) && code["solver_executable"] isa String &&
                occursin(r"^/nix/store/[A-Za-z0-9][A-Za-z0-9+._?-]*/bin/qcl-negf\z",code["solver_executable"]) || return nothing
        end
        credits=spec["credits"]
        Set(keys(credits))==Set(["performance_bytes","scalar_bytes","io_bytes","reserve_bytes"]) &&
            all(v isa Int && !(v isa Bool) for v in values(credits)) &&
            16384<=credits["io_bytes"]<=128*1024^2 && credits["reserve_bytes"]>=0 || return nothing
        credits["performance_bytes"]==32*1024^2 && credits["scalar_bytes"]==64*1024^2 || return nothing
        context=(path=joinpath(job,"capture-source.json"),token=token,execution_id=execution_id,fingerprint=plan.fingerprint)
        if native_mode
            # Repeat the mandatory bounded original-file validation for a caller
            # entering this private context directly; optional failure stays off.
            origin=_native_origin_inputs(expected_plan,source_graph_path,native_execution_path,output,
                native_origin.calcjob_uuid,execution_id;frozen_plan_bytes=Vector{UInt8}(plan_raw))
            origin==native_origin || return nothing
            relative=native["storage"]["relative_execution_root"]
            anchor=chop(String(output);tail=length(relative)+1)
            return merge(context,(native3=true,output=String(output),jobs_anchor=anchor,relative=String(relative),
                native_origin=origin,run_uuid=spec["native_performance"]["run_uuid"]))
        end
        return context
    catch error
        error isa InterruptException && rethrow()
        return nothing # Optional metadata failure never changes scientific status.
    end
end

function _capture_credit(paths,budget,reserve,forecast,free_root;
    storage_reader=_storage_bytes,free_reader=_storage_available)
    try
        additional=Base.checked_add(forecast,_CAPTURE_RESERVE_BYTES)
        _storage_budget_used(storage_reader(paths),budget,reserve,additional)
        _storage_free_permit(free_reader(free_root),Base.checked_add(additional,reserve))
        return _CAPTURE_RESERVE_BYTES
    catch error
        error isa InterruptException && rethrow()
        return 0 # Ordinary science retains its previous guards and full plan.
    end
end

function _capture_locator(context,mode,actual,epoch)
    context===nothing && return nothing
    _native_capture3(context) && throw(ArgumentError("native3 locator requires held birth"))
    try
        document=Dict("schema"=>"qcl-negf.capture-source.v1","capture_token"=>context.token,
            "execution_id"=>context.execution_id,"plan_fingerprint"=>context.fingerprint,
            "mode"=>String(mode),"actual_root"=>abspath(actual),"epoch"=>epoch)
        # One best-effort control publication, no observer acknowledgement/retry.
        io=IOBuffer(); _light_json(io,document); position(io)<=16384 || return nothing
        QCLScientificWorkflow._scientific_json(context.path,document)
    catch error
        error isa InterruptException && rethrow()
    end
    return nothing
end

# Native3 is deliberately separate from ordinary best-effort observation. A
# local birth assertion is conditional on the owning native writer domain; it
# does not authenticate AiiDA/Code or confer authority on an arbitrary pathname.
_native_capture3(context)=context!==nothing && hasproperty(context,:native3) && context.native3===true
_native_capture_stamp(s)=(s.device,s.inode,s.uid,s.gid,s.mode)
_native_capture_stat(fd::Cint)=stat(RawFD(fd))

mutable struct _NativeCaptureBirth
    # Each selected name is anchored to the preceding held parent (AT_FDCWD
    # only for /). Mutable directory timestamps/nlink are intentionally absent.
    directories::Vector{Any}
    identity::Dict{String,String}
    locator_raw::Union{Nothing,Vector{UInt8}}
    closed::Bool
end

function _native_capture_openat(parent::Cint,name)
    ccall(:openat,Cint,(Cint,Cstring,Cint),parent,name,
        Base.JL_O_RDONLY|Base.JL_O_DIRECTORY|Base.JL_O_NOFOLLOW|Base.JL_O_CLOEXEC)
end
function _native_capture_process()
    Sys.islinux() || throw(ArgumentError("native3 birth requires Linux identity"))
    boot=String(strip(open(io->read(io,129),"/proc/sys/kernel/random/boot_id") |> String))
    _p04_require(_native_origin_uuid(boot),"native3 boot identity unavailable")
    raw=open(io->read(io,4097),"/proc/self/stat")
    _p04_require(length(raw)<=4096,"native3 process identity exceeds bound")
    text=String(raw);last=findlast(')',text)
    _p04_require(last!==nothing,"native3 process generation unavailable")
    fields=split(text[nextind(text,last):end])
    _p04_require(length(fields)>=20,"native3 process generation unavailable")
    ticks=parse(UInt64,fields[20]);_p04_require(ticks>0,"native3 process generation unavailable")
    ns=stat("/proc/self/ns/mnt")
    Dict("boot_id"=>String(boot),"mount_namespace_device"=>string(ns.device),
        "mount_namespace_inode"=>string(ns.inode),"producer_pid"=>string(getpid()),
        "producer_start_ticks"=>string(ticks))
end
function _native_capture_close!(birth)
    birth.closed && return nothing
    birth.closed=true # Never retry a close with uncertain FD ownership.
    failure=nothing
    for entry in reverse(birth.directories)
        rc=ccall(:close,Cint,(Cint,),entry.fd)
        rc==0 || (failure===nothing && (failure=ArgumentError("native3 directory close uncertain")))
    end
    failure===nothing || throw(failure)
    nothing
end
function _native_capture_named_stamp(parent,name)
    named=_native_capture_openat(parent,name)
    named>=0 || throw(ArgumentError("native3 selected directory disappeared"))
    primary=nothing
    try
        _native_capture_stamp(_native_capture_stat(named))
    catch error
        primary=error;rethrow()
    finally
        if ccall(:close,Cint,(Cint,),named)!=0
            primary===nothing && throw(ArgumentError("native3 validation close uncertain"))
            @warn "native3 validation close uncertain; original exception retained"
        end
    end
end
function _native_capture_hold!(birth,parent::Cint,name;create=false,fresh=false)
    fd=Cint(-1);created=false
    if fresh
        # EEXIST is a refusal, including our own empty directory from any prior
        # invocation. Never chmod, adopt, remove or repair that object.
        ccall(:mkdirat,Cint,(Cint,Cstring,Cuint),parent,name,0o700)==0 ||
            throw(ArgumentError("native3 fresh root birth refused"))
        created=true
    end
    fd=_native_capture_openat(parent,name)
    if fd<0 && create && !fresh && Base.Libc.errno()==2 # ENOENT only, not ELOOP/EACCES.
        ccall(:mkdirat,Cint,(Cint,Cstring,Cuint),parent,name,0o700)==0 ||
            throw(ArgumentError("native3 parent birth uncertain"))
        created=true;fd=_native_capture_openat(parent,name)
    end
    fd>=0 || throw(ArgumentError("native3 nofollow directory open refused"))
    # Transfer ownership immediately so failures below unwind this FD too.
    push!(birth.directories,(;fd,parent,name=String(name),stamp=nothing))
    s=_native_capture_stat(fd)
    birth.directories[end]=(;fd,parent,name=String(name),stamp=_native_capture_stamp(s))
    uid=ccall(:geteuid,Cuint,());gid=ccall(:getegid,Cuint,())
    _p04_require(isdir(s) && (s.uid==uid || s.uid==0) && s.mode & 0o022==0,
        "native3 directory owner/mode refused")
    if created
        _p04_require(s.uid==uid && s.gid==gid && s.mode & 0o7777==0o700,"native3 born directory credentials differ")
        ccall(:fsync,Cint,(Cint,),fd)==0 && ccall(:fsync,Cint,(Cint,),parent)==0 ||
            throw(ArgumentError("native3 directory durability uncertain"))
    end
    _p04_require(_native_capture_named_stamp(parent,name)==_native_capture_stamp(s),
        "native3 selected directory rebound")
    fd
end
function _native_capture_chain!(birth,path)
    _p04_require(isabspath(path) && normpath(path)==path && ncodeunits(path)<=4096,
        "native3 anchor path is not canonical")
    fd=_native_capture_hold!(birth,Cint(-100),"/") # AT_FDCWD, explicit absolute root.
    for part in split(path,'/';keepempty=false)
        fd=_native_capture_hold!(birth,fd,part)
    end
    fd
end
function _native_capture_validate(birth)
    _p04_require(!birth.closed,"native3 birth handle is closed")
    process=_native_capture_process()
    _p04_require(all(process[k]==birth.identity[k] for k in keys(process)),"native3 producer namespace/generation changed")
    for entry in birth.directories
        _p04_require(_native_capture_stamp(_native_capture_stat(entry.fd))==entry.stamp,
            "native3 held directory credentials changed")
        _p04_require(_native_capture_named_stamp(entry.parent,entry.name)==entry.stamp,
            "native3 selected directory rebound")
    end
    nothing
end
function _native_capture_birth(context,output)
    _p04_require(_native_capture3(context) && output==context.output,"native3 literal output differs")
    _p04_require(ccall(:geteuid,Cuint,())!=0,"native3 requires original nonroot worker")
    birth=_NativeCaptureBirth(Any[],_native_capture_process(),nothing,false)
    try
        # The original workdir remains a separate held namespace for the fixed
        # locator. It does not become the technical/scientific result root.
        _native_capture_chain!(birth,dirname(context.path))
        anchor=_native_capture_chain!(birth,context.jobs_anchor)
        device=_native_capture_stat(anchor).device
        parts=split(context.relative,'/')
        parent=anchor
        for (i,part) in enumerate(parts)
            parent=_native_capture_hold!(birth,parent,part;create=true,fresh=i==length(parts))
            _p04_require(_native_capture_stat(parent).device==device,"native3 result mount mapping differs")
        end
        root=_native_capture_stat(parent)
        birth.identity["device"]=string(root.device);birth.identity["inode"]=string(root.inode)
        _native_capture_validate(birth)
        birth
    catch
        try _native_capture_close!(birth) catch secondary
            @warn "native3 birth cleanup uncertain; original exception retained" exception=secondary
        end
        rethrow()
    end
end
function _native_capture_locator!(birth,context)
    _native_capture_validate(birth)
    document=Dict("schema"=>"qcl-negf.capture-source.v3","capture_token"=>context.token,
        "execution_id"=>context.execution_id,"plan_fingerprint"=>context.fingerprint,
        "mode"=>"direct","actual_root"=>context.output,"epoch"=>0,"root_birth"=>birth.identity)
    io=IOBuffer();_light_json(io,document);println(io);raw=take!(io)
    _p04_require(length(raw)<=16384,"native3 locator exceeds byte limit")
    first=birth.locator_raw===nothing
    if first
        _p04_require(!ispath(context.path) && !islink(context.path),"native3 existing locator is uncertain")
        birth.locator_raw=copy(raw)
    else
        _p04_require(raw==birth.locator_raw,"native3 retry changed locator bytes")
    end
    # A retry can only publish/read back these exact bytes for this held birth;
    # it cannot call mkdir again or reconstruct a handle from a pathname/token.
    if !ispath(context.path) && !islink(context.path)
        QCLScientificWorkflow._scientific_json(context.path,document)
    end
    _native_capture_validate(birth)
    file=Base.Filesystem.open(context.path,Base.JL_O_RDONLY|Base.JL_O_NOFOLLOW|Base.JL_O_NONBLOCK)
    primary=nothing
    try
        before=stat(file)
        _p04_require(isfile(before) && before.nlink==1 && before.size==length(raw),"native3 locator shape differs")
        observed=read(file,16385)
        _p04_require(observed==raw && _p04_stat(before)==_p04_stat(stat(file)) &&
            !islink(context.path) && _p04_stat(before)==_p04_stat(stat(context.path)),
            "native3 locator readback uncertain")
    catch error
        primary=error;rethrow()
    finally
        try
            close(file)
        catch secondary
            primary===nothing && rethrow()
            @warn "native3 locator close uncertain; original exception retained" exception=secondary
        end
    end
    _native_capture_validate(birth)
    nothing
end
function _with_native_capture_birth(effect,context,output)
    birth=_native_capture_birth(context,output)
    primary=nothing
    try
        _native_capture_locator!(birth,context)
        _native_capture_validate(birth)
        result=effect()
        _native_capture_validate(birth)
        result
    catch error
        primary=error;rethrow()
    finally
        try
            try
                _native_capture_validate(birth)
            finally
                _native_capture_close!(birth)
            end
        catch secondary
            primary===nothing && rethrow()
            @warn "native3 final validation/close uncertain; original exception retained" exception=secondary
        end
    end
end

function _validate_staging_tree(root::AbstractString)
    islink(root) && throw(ArgumentError("result tree must not be a symbolic link"))
    for (directory, directories, files) in walkdir(root; follow_symlinks=false)
        for name in vcat(directories, files)
            islink(joinpath(directory, name)) &&
                throw(ArgumentError("result staging rejects symbolic links"))
        end
        for name in files
            path = joinpath(directory, name)
            isfile(path) || throw(ArgumentError("result staging requires regular files"))
        end
    end
    return nothing
end

function _tree_digests(root::AbstractString)
    _validate_staging_tree(root)
    result = Dict{String,String}()
    for (directory,_,files) in walkdir(root;follow_symlinks=false), name in files
        path=joinpath(directory,name)
        isfile(path) || throw(ArgumentError("result staging requires regular files"))
        result[relpath(path,root)]=bytes2hex(open(SHA.sha256,path))
    end
    return result
end

"""
Copy a closed result tree, verify its bytes and native commits, then publish one directory.

`byte_budget` counts simultaneous logical source and pending-copy bytes plus
`reserve_bytes`. Controlled copy writes also check observed destination free space.
This guard is not an OS quota and does not reserve space against other writers.
"""
function stage_result_tree(source::AbstractString, destination::AbstractString;
    byte_budget::Int=8*1024^3, reserve_bytes::Int=64*1024^2,
    capture_reserve_bytes::Int=0,
    resource_policy::Symbol = :standalone, storage_context=nothing,
    maximum_metadata_bytes::Union{Nothing,Int}=nothing,
    native_result::Union{Nothing,AbstractDict}=nothing)
    temporary = nothing
    try
        _resource_policy(resource_policy; storage_context)
        native_result===nothing || maximum_metadata_bytes!==nothing || throw(ArgumentError("native staging requires explicit metadata cap"))
        maximum_metadata_bytes===nothing || _p05_cap(maximum_metadata_bytes)
        native_result===nothing || _p05_native_result_profile(native_result,maximum_metadata_bytes)
        source = abspath(source)
        destination = abspath(destination)
        isdir(source) || throw(ArgumentError("result source is not a directory"))
        byte_budget>0 && 0<=reserve_bytes<byte_budget ||
            throw(ArgumentError("invalid staging byte budget or reserve"))
        capture_reserve_bytes>=0 || throw(ArgumentError("capture reserve must be nonnegative"))
        ispath(destination) || islink(destination) ?
            throw(ArgumentError("staged output must not already exist")) : nothing
        relative = relpath(destination, source)
        (relative == "." || !(relative == ".." || startswith(relative, ".." * string(Base.Filesystem.path_separator)))) &&
            throw(ArgumentError("staged output must be outside the source tree"))
        _validate_staging_tree(source)
        source_bytes = _storage_bytes([source])
        _check_storage_budget([source],byte_budget,reserve_bytes,Base.checked_add(source_bytes,capture_reserve_bytes))
        storage_parent=dirname(destination)
        while !isdir(storage_parent)
            storage_parent=dirname(storage_parent)
        end
        _check_storage_free(storage_parent,Base.checked_add(Base.checked_add(source_bytes,reserve_bytes),capture_reserve_bytes))
        before = _tree_digests(source)
        mkpath(dirname(destination))
        temporary = mktempdir(dirname(destination); prefix=".qcl-negf-stage-", cleanup=false)
        staged = joinpath(temporary, "result")
        mkpath(staged)
        copied_bytes=0
        for (directory,directories,files) in walkdir(source;follow_symlinks=false)
            target_directory=joinpath(staged,relpath(directory,source))
            mkpath(target_directory)
            for name in vcat(directories,files)
                islink(joinpath(directory,name)) &&
                    throw(ArgumentError("result staging rejects symbolic links"))
            end
            for name in files
                path=joinpath(directory,name)
                isfile(path) || throw(ArgumentError("result staging requires regular files"))
                open(path,"r") do input
                    open(joinpath(target_directory,name),"w") do output
                        while !eof(input)
                            block=read(input,1024^2)
                            additional=length(block)
                            projected=Base.checked_add(source_bytes,Base.checked_add(copied_bytes,additional))
                            Base.checked_add(Base.checked_add(projected,reserve_bytes),capture_reserve_bytes)<=byte_budget ||
                                throw(ArgumentError("staging byte budget exhausted"))
                            _check_storage_free(temporary,Base.checked_add(Base.checked_add(additional,reserve_bytes),capture_reserve_bytes))
                            write(output,block)==additional || throw(ArgumentError("incomplete staging write"))
                            copied_bytes=Base.checked_add(copied_bytes,additional)
                        end
                    end
                end
                chmod(joinpath(target_directory,name),stat(path).mode & 0o7777)
            end
        end
        for (directory,_,_) in walkdir(source;topdown=false,follow_symlinks=false)
            chmod(joinpath(staged,relpath(directory,source)),stat(directory).mode & 0o7777)
        end
        _check_storage_budget([source,staged],byte_budget,reserve_bytes,capture_reserve_bytes)
        before == _tree_digests(source) == _tree_digests(staged) ||
            throw(ArgumentError("result changed or bytes differ during staging"))
        for path in keys(before)
            if basename(path) == "commit.json"
                document = YAML.load_file(joinpath(staged, path))
                get(document, "schema", nothing) == POINT_COMMIT_SCHEMA &&
                    verify_point_artifacts(joinpath(staged, path))
            end
            _sync_artifact_file(joinpath(staged, path))
        end
        # Selection is the exact execute return, never inferred from a filename,
        # role inventory, mutable pointer or directory scan.
        native_result===nothing || _p05_verify_native_result(staged,native_result,maximum_metadata_bytes)
        for (directory, _, _) in walkdir(staged; topdown=false)
            _sync_artifact_directory(directory)
        end
        # Staged and final directories are on the same filesystem; never merge trees.
        ispath(destination) && throw(ArgumentError("staged output was created concurrently"))
        Base.Filesystem.rename(staged, destination)
        _sync_artifact_directory(dirname(destination))
        return destination
    finally
        temporary !== nothing && isdir(temporary) && rm(temporary; recursive=true, force=true)
    end
end

"""
    execute_scientific_plan_staged(plan, output; execution_id=nothing, scratch_root=nothing)

Run in a unique local workspace when `scratch_root` is supplied, then verify and
atomically publish the complete result tree to a fresh output directory. A failed
compute or transfer retains its local workspace and reports its path on stderr.
Without scratch, normal execution and explicit resume semantics apply.
"""
function execute_scientific_plan_staged(
    plan::ScientificPlan,
    output::AbstractString;
    execution_id::Union{Nothing,AbstractString}=nothing,
    scratch_root::Union{Nothing,AbstractString}=nothing,
    attempt::Union{Nothing,Int}=nothing,
    recovery_bundle::Union{Nothing,AbstractString}=nothing,
    telemetry_sink::Union{Nothing,Function}=nothing,
    archive_bundle::Union{Nothing,AbstractString}=nothing,
    archive_byte_budget::Int=64*1024^3,
    capture_reserve_bytes::Int=0,
    capture_context=nothing,
    frozen_plan_bytes::Union{Nothing,Vector{UInt8}}=nothing,
    frozen_plan_capture::Union{Nothing,_P05PlanCapture}=nothing,
    run_id::Union{Nothing,AbstractString}=nothing,
    source_graph::Union{Nothing,AbstractDict}=nothing,
    parent_checkpoint::Union{Nothing,VerifiedExactCheckpoint}=nothing,
    phase_observation_policy::Union{Nothing,PhaseObservationPolicy}=nothing,
    native_origin=nothing,
    resource_policy::Symbol = :standalone,
    envelope::Union{Nothing,ExecutionEnvelope} = default_execution_envelope(),
)
    native_origin=_native_origin_ids(native_origin)
    native_origin===nothing || scratch_root===nothing || throw(ArgumentError("native_scratch_binding_unavailable"))
    _scientific_resource_preflight(resource_policy, envelope)
    frozen_plan_bytes===nothing || frozen_plan_capture===nothing || throw(ArgumentError("choose one frozen plan source"))
    source_graph=_require_source_graph(source_graph)
    recovery_bundle === nothing || throw(ArgumentError("unsupported_format: legacy recovery bundle"))
    parent_checkpoint === nothing || _p05_parent_root_check(parent_checkpoint,output)
    native3=_native_capture3(capture_context)
    if native3
        _p04_require(native_origin!==nothing && native_origin==capture_context.native_origin &&
            output==capture_context.output && attempt===nothing && scratch_root===nothing &&
            parent_checkpoint===nothing && recovery_bundle===nothing && archive_bundle===nothing,
            "native3 requires original direct execution without imports")
    end
    selected=[e for e in plan.executions if execution_id===nothing || e.id==execution_id]
    if capture_context!==nothing && !isempty(selected)
        try
            parent=abspath(output)
            while !isdir(parent); parent=dirname(parent); end
            imports=_storage_bytes([p for p in (recovery_bundle,archive_bundle) if p!==nothing])
            forecast=Base.checked_add(QCLScientificWorkflow._minimum_scientific_output_bytes(plan),imports)
            capture_reserve_bytes=_capture_credit([joinpath(abspath(output),"executions"),joinpath(abspath(output),"recovery")],
                minimum(e.outputs.recovery.byte_budget for e in selected),maximum(e.outputs.recovery.reserve_bytes for e in selected),forecast,parent)
        catch error
            error isa InterruptException && rethrow()
            capture_reserve_bytes=0
        end
    else
        capture_reserve_bytes=0
    end
    capture_reserve_bytes==0 && (capture_context=nothing)
    if scratch_root===nothing || any(e.outputs.recovery.enabled for e in plan.executions if execution_id===nothing || e.id==execution_id)
        scratch_root===nothing || @warn "portable recovery publishes directly to output storage; scratch staging is disabled for this execution"
        if _native_capture3(capture_context)
            return _with_native_capture_birth(capture_context,output) do
                execute_scientific_plan(plan,output;execution_id,attempt,recovery_bundle,telemetry_sink,archive_bundle,archive_byte_budget,resource_policy,envelope,capture_reserve_bytes,frozen_plan_bytes,frozen_plan_capture,run_id,source_graph,parent_checkpoint,phase_observation_policy,native_origin)
            end
        end
        _capture_locator(capture_context,:direct,output,0)
        return execute_scientific_plan(plan,output;execution_id,attempt,recovery_bundle,telemetry_sink,archive_bundle,archive_byte_budget,resource_policy,envelope,capture_reserve_bytes,frozen_plan_bytes,frozen_plan_capture,run_id,source_graph,parent_checkpoint,phase_observation_policy,native_origin)
    end
    selected=[e for e in plan.executions if execution_id===nothing || e.id==execution_id]
    parent_checkpoint === nothing || throw(ArgumentError("native5_recovery_import_unavailable: scratch closure import requires P07"))
    isempty(selected) && throw(ArgumentError("unknown selected execution"))
    # Scratch and publication use the existing operational policy, even when
    # recovery checkpoints themselves are disabled. Shared staging obeys the
    # tightest selected budget and largest requested publication reserve.
    byte_budget=minimum(e.outputs.recovery.byte_budget for e in selected)
    reserve_bytes=maximum(e.outputs.recovery.reserve_bytes for e in selected)
    reserve_bytes<byte_budget || throw(ArgumentError("selected staging reserve exceeds its byte budget"))
    isabspath(scratch_root) || throw(ArgumentError("scratch root must be absolute"))
    destination = abspath(output)
    (ispath(destination) || islink(destination)) &&
        throw(ArgumentError("scratch execution requires a fresh output directory"))
    mkpath(scratch_root)
    workspace = mktempdir(scratch_root; prefix="qcl-negf-", cleanup=false)
    local_result = joinpath(workspace, "result")
    try
        _capture_locator(capture_context,:scratch,local_result,0)
        result = execute_scientific_plan(plan, local_result; execution_id, resume=false,attempt,recovery_bundle,telemetry_sink,archive_bundle,archive_byte_budget,resource_policy,envelope,capture_reserve_bytes,frozen_plan_bytes,frozen_plan_capture,run_id,source_graph,phase_observation_policy,native_origin)
        declared=minimum(e.configuration.production.memory_budget_bytes for e in selected)
        metadata_roots=(;entry=(plan,selected,source_graph,result),resources=(envelope,),construction=(),continuation=(),history=(),
            observers=(telemetry_sink,),inputs_publication=(workspace,local_result,destination,byte_budget,reserve_bytes,
                capture_reserve_bytes,capture_context,frozen_plan_bytes,frozen_plan_capture,run_id))
        maximum_metadata_bytes=_p05_closed_metadata_limit(declared,metadata_roots;envelope)
        stage_result_tree(local_result,destination;byte_budget,reserve_bytes,resource_policy,capture_reserve_bytes,
            maximum_metadata_bytes,native_result=result)
        _capture_locator(capture_context,:staged,destination,1)
        rm(workspace; recursive=true)
        return result
    catch
        @error "Scientific workspace retained after execution or delivery failure" workspace
        rethrow()
    end
end
