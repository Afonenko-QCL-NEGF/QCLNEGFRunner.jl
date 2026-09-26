function _tree_digests(root::AbstractString)
    result = Dict{String,String}()
    islink(root) && throw(ArgumentError("result tree must not be a symbolic link"))
    for (directory, directories, files) in walkdir(root; follow_symlinks=false)
        for name in vcat(directories, files)
            islink(joinpath(directory, name)) &&
                throw(ArgumentError("result staging rejects symbolic links"))
        end
        for name in files
            path = joinpath(directory, name)
            result[relpath(path, root)] = bytes2hex(open(SHA.sha256, path))
        end
    end
    return result
end

"""Copy a closed result tree, verify its bytes and native commits, then publish one directory."""
function stage_result_tree(source::AbstractString, destination::AbstractString)
    source = abspath(source)
    destination = abspath(destination)
    isdir(source) || throw(ArgumentError("result source is not a directory"))
    ispath(destination) || islink(destination) ?
        throw(ArgumentError("staged output must not already exist")) : nothing
    relative = relpath(destination, source)
    (relative == "." || !(relative == ".." || startswith(relative, ".." * string(Base.Filesystem.path_separator)))) &&
        throw(ArgumentError("staged output must be outside the source tree"))
    before = _tree_digests(source)
    mkpath(dirname(destination))
    temporary = mktempdir(dirname(destination); prefix=".qcl-negf-stage-", cleanup=false)
    staged = joinpath(temporary, "result")
    try
        cp(source, staged; follow_symlinks=false)
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
)
    scratch_root === nothing && return execute_scientific_plan(plan, output; execution_id)
    isabspath(scratch_root) || throw(ArgumentError("scratch root must be absolute"))
    destination = abspath(output)
    (ispath(destination) || islink(destination)) &&
        throw(ArgumentError("scratch execution requires a fresh output directory"))
    mkpath(scratch_root)
    workspace = mktempdir(scratch_root; prefix="qcl-negf-", cleanup=false)
    local_result = joinpath(workspace, "result")
    try
        result = execute_scientific_plan(plan, local_result; execution_id, resume=false)
        stage_result_tree(local_result, destination)
        rm(workspace; recursive=true)
        return result
    catch
        @error "Scientific workspace retained after execution or delivery failure" workspace
        rethrow()
    end
end
