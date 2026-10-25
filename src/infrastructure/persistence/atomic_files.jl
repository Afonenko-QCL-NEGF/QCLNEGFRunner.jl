"""
    _atomic_replace_file(source, destination)

Replace a regular file with one same-directory rename operation. Julia 1.12.7
`mv(...; force=true)` removes an existing destination first, so it is not a
valid commit primitive for status, result, progress, or checkpoint files.
"""
function _atomic_replace_file(source::AbstractString, destination::AbstractString;
    resource_policy::Symbol = :standalone, storage_context=nothing)
    if resource_policy === :campaign_strict && storage_context isa StorageWriteContext
        permit = storage_context.permit
        return lock(permit.ledger.guard) do
            owned_inflight = false
            try
                _resident_live_ancestry!(permit)
                if permit.ledger.inflight != 0
                    permit.ledger.interference = Base.checked_add(permit.ledger.interference, 1)
                    throw(ResidentGrowthRefusal(:atomic_replace, :needs_guard, :unknown))
                end
                storage_context.mutation_started || require_growth!(storage_context,
                    permit.descriptor.writer, destination; payload=source)
                _resident_live_ancestry!(permit)
                interference = permit.ledger.interference
                permit.ledger.inflight += 1
                owned_inflight = true
                validate_resident_writer!(permit.authority, permit.descriptor,
                    :atomic_replace, abspath(destination), source) === true ||
                    throw(ResidentGrowthRefusal(:atomic_replace, :needs_guard, :unknown))
                # Callback success cannot override parent invalidation or a
                # caught reentrant close attempt. Keep the same lock/inflight
                # interval through the actual chmod and native rename.
                _resident_live_ancestry!(permit)
                permit.ledger.interference == interference ||
                    throw(ResidentGrowthRefusal(:atomic_replace, :needs_guard, :unknown))
                return _atomic_replace_file_native(source, destination)
            catch primary
                canonical = _resident_failure!(storage_context, primary)
                canonical === nothing || canonical === primary || throw(canonical)
                rethrow()
            finally
                owned_inflight && (permit.ledger.inflight -= 1)
            end
        end
    else
        _resident_writer_preflight(resource_policy, :atomic_replace)
    end
    return _atomic_replace_file_native(source, destination)
end

# Existing same-directory chmod/native-rename sequence, entered by strict only
# while its live ancestry and inflight scope are held by the wrapper above.
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
