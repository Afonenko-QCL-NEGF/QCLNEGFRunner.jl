# Argument compatibility only: removed policies/contexts never enter an IO path.
# This file is included independently by Runner and QCLApplicationRuntime.
function _resource_policy(policy::Symbol; storage_context=nothing)
    policy === :standalone || throw(ArgumentError(
        policy === :campaign_strict ?
        "unsupported_resource_policy: campaign_strict has been removed" :
        "unsupported_resource_policy: $(repr(policy))"))
    storage_context === nothing || throw(ArgumentError(
        "unsupported_storage_context: resident authority has been removed"))
    return policy
end

"""
    _atomic_replace_file(source, destination)

Replace a regular file with one same-directory rename operation. Julia 1.12.7
`mv(...; force=true)` removes an existing destination first, so it is not a
valid commit primitive for status, result, progress, or checkpoint files.
"""
function _atomic_replace_file(source::AbstractString, destination::AbstractString;
    resource_policy::Symbol = :standalone, storage_context=nothing)
    _resource_policy(resource_policy; storage_context)
    return _atomic_replace_file_native(source, destination)
end

function _atomic_replace_file_native(source::AbstractString, destination::AbstractString)
    source_absolute = abspath(source)
    destination_absolute = abspath(destination)
    dirname(source_absolute) == dirname(destination_absolute) || throw(
        ArgumentError(
            "atomic replacement requires source and destination in the same directory",
        ),
    )
    isfile(source_absolute) && !islink(source_absolute) || throw(
        ArgumentError(
            "atomic replacement source must be a regular non-symlink file: " *
            source_absolute,
        ),
    )

    # mktemp is deliberately owner-only. Published scientific artifacts must
    # also be readable by a caller-configured collaboration group. The
    # adapter assigns no user/group names; ownership follows the parent directory.
    chmod(source_absolute, 0o640)

    # jl_fs_rename is Julia's libuv-backed single-filesystem rename. It does
    # not fall back to copy/delete and atomically replaces an existing regular
    # destination on the supported deployment platforms.
    error_code = ccall(
        :jl_fs_rename,
        Int32,
        (Cstring, Cstring),
        source_absolute,
        destination_absolute,
    )
    error_code < 0 && Base.uv_error(
        "atomic replace $(repr(source_absolute)) -> " * repr(destination_absolute),
        error_code,
    )
    return destination_absolute
end

"""
    _copy_regular_tree_buffered(source, destination)

Copy a closed regular directory tree to a fresh destination using bounded byte
buffers. Reject symbolic links and special files before creating the target.
This assumes a single writer and a stable source; it is not atomic publication
or protection against concurrent filesystem replacement. Errors leave any
partial fresh destination for the caller to treat as unvalidated.
"""
function _copy_regular_tree_buffered(source::AbstractString, destination::AbstractString)
    isdir(source) && !islink(source) ||
        throw(ArgumentError("buffered copy requires a regular non-symlink directory"))
    source = realpath(source)
    destination = abspath(destination)
    (ispath(destination) || islink(destination)) &&
        throw(ArgumentError("buffered copy requires a fresh destination"))
    isdir(dirname(destination)) ||
        throw(ArgumentError("buffered copy requires an existing destination parent"))
    # Resolve parent aliases as well as lexical paths before checking ancestry.
    resolved_destination = joinpath(realpath(dirname(destination)), basename(destination))
    first(splitpath(relpath(resolved_destination, source))) == ".." ||
        throw(ArgumentError("buffered copy destination must be outside the source"))
    for (directory, directories, files) in walkdir(source; follow_symlinks=false)
        for name in vcat(directories, files)
            islink(joinpath(directory, name)) &&
                throw(ArgumentError("buffered copy rejects symbolic links"))
        end
        for name in files
            isfile(joinpath(directory, name)) ||
                throw(ArgumentError("buffered copy requires regular files"))
        end
    end

    mkdir(destination)
    for (directory, directories, files) in walkdir(source; follow_symlinks=false)
        target_directory = joinpath(destination, relpath(directory, source))
        for name in directories
            mkdir(joinpath(target_directory, name))
        end
        for name in files
            path = joinpath(directory, name)
            target = joinpath(target_directory, name)
            open(path, "r") do input
                open(target, "w") do output
                    while !eof(input)
                        block = read(input, 1024^2)
                        write(output, block) == length(block) ||
                            throw(ArgumentError("incomplete buffered copy write"))
                    end
                end
            end
            chmod(target, stat(path).mode & 0o7777)
        end
    end
    for (directory, _, _) in walkdir(source; topdown=false, follow_symlinks=false)
        chmod(joinpath(destination, relpath(directory, source)), stat(directory).mode & 0o7777)
    end
    return destination
end
