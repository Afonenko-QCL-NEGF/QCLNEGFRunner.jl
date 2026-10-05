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
    byte_budget::Int=8*1024^3, reserve_bytes::Int=64*1024^2)
    source = abspath(source)
    destination = abspath(destination)
    isdir(source) || throw(ArgumentError("result source is not a directory"))
    byte_budget>0 && 0<=reserve_bytes<byte_budget ||
        throw(ArgumentError("invalid staging byte budget or reserve"))
    ispath(destination) || islink(destination) ?
        throw(ArgumentError("staged output must not already exist")) : nothing
    relative = relpath(destination, source)
    (relative == "." || !(relative == ".." || startswith(relative, ".." * string(Base.Filesystem.path_separator)))) &&
        throw(ArgumentError("staged output must be outside the source tree"))
    _validate_staging_tree(source)
    source_bytes = _storage_bytes([source])
    _check_storage_budget([source],byte_budget,reserve_bytes,source_bytes)
    storage_parent=dirname(destination)
    while !isdir(storage_parent)
        storage_parent=dirname(storage_parent)
    end
    _check_storage_free(storage_parent,Base.checked_add(source_bytes,reserve_bytes))
    before = _tree_digests(source)
    mkpath(dirname(destination))
    temporary = mktempdir(dirname(destination); prefix=".qcl-negf-stage-", cleanup=false)
    staged = joinpath(temporary, "result")
    try
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
                            Base.checked_add(projected,reserve_bytes)<=byte_budget ||
                                throw(ArgumentError("staging byte budget exhausted"))
                            _check_storage_free(temporary,Base.checked_add(additional,reserve_bytes))
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
        _check_storage_budget([source,staged],byte_budget,reserve_bytes,0)
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
        Base.Filesystem.rename(staged, destination)
        _sync_artifact_directory(dirname(destination))
        return destination
    finally
        isdir(temporary) && rm(temporary; recursive=true, force=true)
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
)
    if scratch_root===nothing || any(e.outputs.recovery.enabled for e in plan.executions if execution_id===nothing || e.id==execution_id)
        scratch_root===nothing || @warn "portable recovery publishes directly to output storage; scratch staging is disabled for this execution"
        return execute_scientific_plan(plan,output;execution_id,attempt,recovery_bundle,telemetry_sink,archive_bundle,archive_byte_budget)
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
        result = execute_scientific_plan(plan, local_result; execution_id, resume=false,attempt,recovery_bundle,telemetry_sink,archive_bundle,archive_byte_budget)
        stage_result_tree(local_result, destination; byte_budget,reserve_bytes)
        rm(workspace; recursive=true)
        return result
    catch
        @error "Scientific workspace retained after execution or delivery failure" workspace
        rethrow()
    end
end
