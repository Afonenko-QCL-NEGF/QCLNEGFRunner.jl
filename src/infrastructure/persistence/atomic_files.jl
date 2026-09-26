"""
    _atomic_replace_file(source, destination)

Replace a regular file with one same-directory rename operation. Julia 1.12.7
`mv(...; force=true)` removes an existing destination first, so it is not a
valid commit primitive for status, result, progress, or checkpoint files.
"""
function _atomic_replace_file(source::AbstractString, destination::AbstractString)
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
