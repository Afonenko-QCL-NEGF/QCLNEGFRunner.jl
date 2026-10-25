const _CAPTURE_RESERVE_BYTES = 104 * 1024^2 # 32 performance +64 scalar +8 auxiliary.

function _capture_context(plan, output, execution_id, attempt;
    spec_path=get(ENV,"QCL_NEGF_CAPTURE_SPEC",""),scratch_root=nothing)
    isempty(spec_path) && return nothing
    try
        path=abspath(spec_path); job=dirname(path)
        basename(path)=="capture-spec.json" && isfile(path) && !islink(path) || return nothing
        abspath(output)==joinpath(job,"result") || return nothing
        raw=open(io->read(io,16385),path); length(raw)<=16384 || return nothing
        spec=YAML.load(String(raw);dicttype=Dict{String,Any})
        Set(keys(spec))==Set(["schema","selection","plan","capture_token","allocation_id","allocated_logical_cpus","scratch_root","credits"]) &&
            spec["schema"]=="qcl-negf.capture-spec.v1" || return nothing
        selection=spec["selection"]
        Set(keys(selection))==Set(["calcjob_uuid","execution_id","attempt","plan_fingerprint"]) || return nothing
        selection["calcjob_uuid"] isa String && occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",selection["calcjob_uuid"]) || return nothing
        selection["execution_id"]==execution_id && selection["attempt"]===attempt &&
            selection["plan_fingerprint"]==plan.fingerprint || return nothing
        token=spec["capture_token"]; token isa String && occursin(r"^[0-9a-f]{32}$",token) || return nothing
        spec["allocated_logical_cpus"]===nothing && spec["scratch_root"]==scratch_root &&
            spec["allocation_id"]=="calcjob-process:$(selection["calcjob_uuid"]):$(attempt)" || return nothing
        pin=spec["plan"]; pin["path"]=="plan.json" || return nothing
        plan_raw=open(io->read(io,1024^2+1),joinpath(job,"plan.json"))
        length(plan_raw)<=1024^2 && length(plan_raw)==pin["bytes"] && bytes2hex(sha256(plan_raw))==pin["sha256"] || return nothing
        credits=spec["credits"]
        Set(keys(credits))==Set(["performance_bytes","scalar_bytes","io_bytes","reserve_bytes"]) &&
            all(v isa Int && !(v isa Bool) for v in values(credits)) &&
            16384<=credits["io_bytes"]<=128*1024^2 && credits["reserve_bytes"]>=0 || return nothing
        credits["performance_bytes"]==32*1024^2 && credits["scalar_bytes"]==64*1024^2 || return nothing
        return (path=joinpath(job,"capture-source.json"),token=token,execution_id=execution_id,fingerprint=plan.fingerprint)
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
    resource_policy::Symbol = :standalone, storage_context=nothing)
    temporary = nothing
    try
        _resident_writer_preflight(resource_policy, :stage, storage_context, destination; payload=source)
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
        resident_created!(storage_context, temporary)
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
        for (directory, _, _) in walkdir(staged; topdown=false)
            _sync_artifact_directory(directory)
        end
        # Staged and final directories are on the same filesystem; never merge trees.
        ispath(destination) && throw(ArgumentError("staged output was created concurrently"))
        if _resident_preserve(resource_policy, storage_context)
            lock(storage_context.permit.ledger.guard) do
                _resident_live_ancestry!(storage_context.permit)
                Base.Filesystem.rename(staged, destination)
                resident_renamed!(storage_context, staged, destination)
            end
        else
            Base.Filesystem.rename(staged, destination)
        end
        _sync_artifact_directory(dirname(destination))
        resident_acknowledged!(storage_context, destination)
        return destination
    catch failure
        canonical = _resident_failure!(storage_context, failure)
        canonical === nothing || canonical === failure || throw(canonical)
        rethrow()
    finally
        resource_policy === :standalone && temporary !== nothing && isdir(temporary) && rm(temporary; recursive=true, force=true)
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
    resource_policy::Symbol = :standalone,
    envelope::Union{Nothing,ExecutionEnvelope} = default_execution_envelope(),
)
    # Dominates scratch mkdir, workspace create, delivery and success deletion.
    # Strict must never create scratch and then fall back to standalone inside.
    _scientific_resource_preflight(resource_policy, envelope)
    selected=[e for e in plan.executions if execution_id===nothing || e.id==execution_id]
    if capture_context!==nothing && resource_policy===:standalone && !isempty(selected)
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
        _capture_locator(capture_context,:direct,output,0)
        return execute_scientific_plan(plan,output;execution_id,attempt,recovery_bundle,telemetry_sink,archive_bundle,archive_byte_budget,resource_policy,envelope,capture_reserve_bytes)
    end
    selected=[e for e in plan.executions if execution_id===nothing || e.id==execution_id]
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
        result = execute_scientific_plan(plan, local_result; execution_id, resume=false,attempt,recovery_bundle,telemetry_sink,archive_bundle,archive_byte_budget,resource_policy,envelope,capture_reserve_bytes)
        stage_result_tree(local_result, destination; byte_budget,reserve_bytes,resource_policy,capture_reserve_bytes)
        _capture_locator(capture_context,:staged,destination,1)
        _resident_writer_preflight(resource_policy, :scratch_success_cleanup)
        rm(workspace; recursive=true)
        return result
    catch
        @error "Scientific workspace retained after execution or delivery failure" workspace
        rethrow()
    end
end
