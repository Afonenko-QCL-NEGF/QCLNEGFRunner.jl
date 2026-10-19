function file_sha256(path::AbstractString)
    isfile(path) || throw(ArgumentError("file does not exist: $path"))
    return open(path, "r") do stream
        bytes2hex(SHA.sha256(stream))
    end
end

"""
Filesystem adapter for the application repository port. All mutable metadata
is replaced atomically; events and checkpoint generations are append-only.
One repository object is thread-safe. A given run directory remains a
single-writer resource across processes/machines.
"""
mutable struct FilesystemRunRepository <: AbstractRunRepository
    root::String
    lock::ReentrantLock
    event_sequences::Dict{String,Int}
    _checkpoint_active::Bool
    function FilesystemRunRepository(root::AbstractString)
        new(abspath(root), ReentrantLock(), Dict{String,Int}(), false)
    end
end

default_run_repository(root::AbstractString) = FilesystemRunRepository(root)

function run_directory(repository::FilesystemRunRepository, run_id::AbstractString)
    identifier = validate_content_identifier(run_id, "run id")
    return joinpath(repository.root, identifier)
end

run_workspace_directory(repository::FilesystemRunRepository, run_id::AbstractString) =
    run_directory(repository, run_id)

function _point_directory(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
)
    point = validate_content_identifier(point_id, "point id")
    return joinpath(run_directory(repository, run_id), "points", point)
end

point_workspace_directory(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
) = _point_directory(repository, run_id, point_id)

function _normalise_loaded_yaml(value)
    if value isa AbstractDict
        result = Dict{String,Any}()
        for (key, child) in value
            name = String(key)
            haskey(result, name) &&
                throw(ArgumentError("duplicate YAML key after string normalisation: $name"))
            result[name] = _normalise_loaded_yaml(child)
        end
        return result
    elseif value isa AbstractVector
        return Any[_normalise_loaded_yaml(child) for child in value]
    end
    return value
end

function _atomic_yaml(path::AbstractString, value)
    absolute = abspath(path)
    directory = dirname(absolute)
    mkpath(directory)
    temporary, stream = mktemp(directory)
    close(stream)
    try
        YAML.write_file(temporary, portable_metadata(value))
        _atomic_replace_file(temporary, absolute)
    catch
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return absolute
end

function _load_yaml(path::AbstractString)
    isfile(path) || return nothing
    return _normalise_loaded_yaml(YAML.load_file(path))
end

function _immutable_yaml(path::AbstractString, value)
    safe = portable_metadata(value)
    if isfile(path)
        existing = _load_yaml(path)
        canonical_bytes(existing) == canonical_bytes(safe) || throw(
            ArgumentError(
                "immutable YAML artifact already exists with different content: $path",
            ),
        )
        return abspath(path)
    end
    return _atomic_yaml(path, safe)
end

"""
Initialise or verify the content-addressed run directory. Returns `true` when
the run already existed. Existing identity metadata must match byte-for-byte
under canonical encoding.
"""
function initialize_run!(repository::FilesystemRunRepository, definition::RunDefinition)
    directory = run_directory(repository, definition.identity.run_id)
    path = joinpath(directory, "run.yaml")
    existed = isfile(path)
    mkpath(joinpath(directory, "points"))
    mkpath(joinpath(directory, "events"))
    mkpath(joinpath(directory, "timings"))
    _immutable_yaml(path, run_definition_dict(definition))
    # These two files are operational presentation/order choices excluded
    # from scientific identity and may change between resume sessions.
    _atomic_yaml(
        joinpath(directory, "execution_plan.yaml"),
        _sweep_plan_dict(definition.plan),
    )
    _atomic_yaml(joinpath(directory, "display_labels.yaml"), definition.labels)
    return existed
end

function write_run_status!(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    status,
)
    return _atomic_yaml(joinpath(run_directory(repository, run_id), "status.yaml"), status)
end

function read_point_status(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
)
    return _load_yaml(
        joinpath(_point_directory(repository, run_id, point_id), "status.yaml"),
    )
end

function write_point_status!(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
    status,
)
    return _atomic_yaml(
        joinpath(_point_directory(repository, run_id, point_id), "status.yaml"),
        status,
    )
end

function write_point_result!(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
    result,
)
    return _atomic_yaml(
        joinpath(_point_directory(repository, run_id, point_id), "result.yaml"),
        result,
    )
end

function read_point_result(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
)
    return _load_yaml(
        joinpath(_point_directory(repository, run_id, point_id), "result.yaml"),
    )
end

function verify_result_artifacts!(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    artifacts,
)
    artifacts isa AbstractDict || throw(
        ArtifactIntegrityError(
            run_directory(repository, run_id),
            "artifacts must be a mapping",
        ),
    )
    root = realpath(run_directory(repository, run_id))
    for (name, raw) in artifacts
        raw isa AbstractDict ||
            throw(ArtifactIntegrityError(root, "artifact $name must be a metadata mapping"))
        get(raw, "integrity_required", false) === true || continue
        relative = get(raw, "path", nothing)
        relative isa AbstractString ||
            throw(ArtifactIntegrityError(root, "artifact $name has no relative path"))
        isabspath(relative) && throw(
            ArtifactIntegrityError(String(relative), "artifact path must be relative"),
        )
        absolute = abspath(joinpath(root, String(relative)))
        relative_check = relpath(absolute, root)
        first(splitpath(relative_check)) == ".." && throw(
            ArtifactIntegrityError(
                absolute,
                "artifact path escapes its content-addressed run",
            ),
        )
        isfile(absolute) && !islink(absolute) || throw(
            ArtifactIntegrityError(
                absolute,
                "required regular artifact is missing or a symlink",
            ),
        )
        resolved = realpath(absolute)
        first(splitpath(relpath(resolved, root))) == ".." && throw(
            ArtifactIntegrityError(
                resolved,
                "artifact resolves outside its content-addressed run",
            ),
        )
        expected_bytes = get(raw, "bytes", nothing)
        expected_bytes isa Integer && !(expected_bytes isa Bool) ||
            throw(ArtifactIntegrityError(absolute, "artifact byte count is missing"))
        filesize(absolute) == Int(expected_bytes) || throw(
            ArtifactIntegrityError(
                absolute,
                "artifact byte count differs from result certificate",
            ),
        )
        expected_sha256 = get(raw, "sha256", nothing)
        expected_sha256 isa AbstractString &&
        occursin(r"^[0-9a-f]{64}$", expected_sha256) || throw(
            ArtifactIntegrityError(absolute, "artifact SHA-256 is missing or malformed"),
        )
        file_sha256(absolute) == expected_sha256 || throw(
            ArtifactIntegrityError(
                absolute,
                "artifact SHA-256 differs from result certificate",
            ),
        )
    end
    return true
end

function point_result_sha256(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
)
    path = joinpath(_point_directory(repository, run_id, point_id), "result.yaml")
    return isfile(path) ? file_sha256(path) : nothing
end

function write_run_result!(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    result,
)
    return _atomic_yaml(joinpath(run_directory(repository, run_id), "result.yaml"), result)
end

function read_run_result(repository::FilesystemRunRepository, run_id::AbstractString)
    return _load_yaml(joinpath(run_directory(repository, run_id), "result.yaml"))
end

function write_provenance!(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    provenance,
)
    return _immutable_yaml(
        joinpath(run_directory(repository, run_id), "provenance.yaml"),
        provenance,
    )
end

function write_disk_estimate!(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    estimate::DiskEstimate,
)
    return _atomic_yaml(
        joinpath(run_directory(repository, run_id), "disk_estimate.yaml"),
        disk_estimate_dict(estimate),
    )
end

function _existing_event_sequence(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
)
    directory = joinpath(run_directory(repository, run_id), "events")
    isdir(directory) || return 0
    maximum_sequence = 0
    for filename in readdir(directory)
        matched = match(r"^(\d{12})-", filename)
        matched === nothing && continue
        maximum_sequence =
            max(maximum_sequence, something(tryparse(Int, only(matched.captures)), 0))
    end
    return maximum_sequence
end

function _next_event_sequence!(repository::FilesystemRunRepository, run_id::String)
    return lock(repository.lock) do
        current = get!(repository.event_sequences, run_id) do
            _existing_event_sequence(repository, run_id)
        end
        next = Base.checked_add(current, 1)
        repository.event_sequences[run_id] = next
        next
    end
end

"""Append one crash-independent YAML event and return its stored mapping."""
function append_event!(repository::FilesystemRunRepository, run_id::AbstractString, event)
    identifier = validate_content_identifier(run_id, "run id")
    mapping = _canonical_mapping(event)
    sequence = _next_event_sequence!(repository, identifier)
    mapping["sequence"] = sequence
    mapping["run_id"] = identifier
    event_id = content_id(
        "event",
        Dict{String,Any}(
            "run_id" => identifier,
            "sequence" => sequence,
            "event" => mapping,
        ),
    )
    mapping["event_id"] = event_id
    filename = lpad(string(sequence), 12, '0') * "-$event_id.yaml"
    path = joinpath(run_directory(repository, identifier), "events", filename)
    _immutable_yaml(path, mapping)
    return portable_metadata(mapping)
end

function read_events(repository::FilesystemRunRepository, run_id::AbstractString)
    directory = joinpath(run_directory(repository, run_id), "events")
    isdir(directory) || return Dict{String,Any}[]
    paths = sort!(filter(path -> endswith(path, ".yaml"), readdir(directory; join = true)))
    return Dict{String,Any}[_load_yaml(path) for path in paths]
end

"""Small portable codec used by tests and lightweight solver states."""
struct YamlCheckpointCodec <: AbstractCheckpointCodec end

default_checkpoint_codec() = YamlCheckpointCodec()

_checkpoint_extension(::YamlCheckpointCodec) = "yaml"
_checkpoint_extension(codec::CallbackCheckpointCodec) = codec.extension

function _write_checkpoint_payload(::YamlCheckpointCodec, path::AbstractString, state)
    YAML.write_file(path, portable_metadata(state))
    return path
end

function _read_checkpoint_payload(::YamlCheckpointCodec, path::AbstractString)
    return _load_yaml(path)
end

function _write_checkpoint_payload(
    codec::CallbackCheckpointCodec,
    path::AbstractString,
    state,
)
    codec.writer(path, state)
    isfile(path) || throw(ArgumentError("checkpoint writer did not create $path"))
    return path
end

function _read_checkpoint_payload(codec::CallbackCheckpointCodec, path::AbstractString)
    state = codec.reader(path)
    codec.validator(state) === true ||
        throw(ArgumentError("checkpoint validator rejected $path"))
    return state
end

_checkpoint_integrity(path, message) =
    throw(CheckpointIntegrityError(String(path), String(message)))

function _checkpoint_directory(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
)
    return joinpath(_point_directory(repository, run_id, point_id), "checkpoints")
end

function _checkpoint_metadata_paths(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
)
    directory = _checkpoint_directory(repository, run_id, point_id)
    isdir(directory) || return String[]
    return sort!(
        filter(path -> endswith(path, ".metadata.yaml"), readdir(directory; join = true)),
    )
end

function _next_checkpoint_generation(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    point_id::AbstractString,
)
    directory = _checkpoint_directory(repository, run_id, point_id)
    isdir(directory) || return 1
    paths = readdir(directory; join = true)
    generations = Int[]
    for path in paths
        matched =
            match(r"^(\d{12})\.(?:metadata\.yaml|payload\.[a-z0-9]+)$", basename(path))
        matched === nothing ||
            push!(generations, something(tryparse(Int, only(matched.captures)), 0))
    end
    isempty(generations) && return 1
    return Base.checked_add(maximum(generations), 1)
end

function _checkpoint_reference(metadata::Dict{String,Any}, metadata_path::AbstractString)
    iteration_value = get(metadata, "iteration", nothing)
    return CheckpointReference(
        String(metadata["run_id"]),
        String(metadata["point_id"]),
        Int(metadata["generation"]),
        Int(metadata["attempt"]),
        joinpath(dirname(metadata_path), String(metadata["payload_file"])),
        abspath(metadata_path),
        String(metadata["sha256"]),
        String(metadata["kind"]),
        iteration_value === nothing ? nothing : Int(iteration_value),
    )
end

function _validate_checkpoint_envelope(
    raw,
    metadata_path::AbstractString,
    codec::AbstractCheckpointCodec,
    run_id::AbstractString,
    point_id::AbstractString,
)
    raw isa Dict{String,Any} ||
        _checkpoint_integrity(metadata_path, "envelope must be a YAML mapping")
    required = (
        "schema",
        "run_id",
        "point_id",
        "generation",
        "attempt",
        "kind",
        "iteration",
        "payload_file",
        "payload_extension",
        "payload_bytes",
        "sha256",
        "metadata",
    )
    missing = [key for key in required if !haskey(raw, key)]
    isempty(missing) || _checkpoint_integrity(
        metadata_path,
        "missing envelope fields: $(join(missing, ", "))",
    )
    raw["schema"] == RUNTIME_CHECKPOINT_SCHEMA ||
        _checkpoint_integrity(metadata_path, "unsupported checkpoint schema")
    raw["run_id"] == run_id || _checkpoint_integrity(metadata_path, "run id mismatch")
    raw["point_id"] == point_id || _checkpoint_integrity(metadata_path, "point id mismatch")
    raw["generation"] isa Integer && !(raw["generation"] isa Bool) ||
        _checkpoint_integrity(metadata_path, "generation must be an integer")
    raw["attempt"] isa Integer && !(raw["attempt"] isa Bool) ||
        _checkpoint_integrity(metadata_path, "attempt must be an integer")
    generation = Int(raw["generation"])
    generation >= 1 || _checkpoint_integrity(metadata_path, "generation must be positive")
    occursin(r"^[0-9]{12}\.metadata\.yaml$", basename(metadata_path)) &&
    basename(metadata_path) == lpad(string(generation), 12, '0') * ".metadata.yaml" ||
        _checkpoint_integrity(metadata_path, "metadata filename does not match generation")
    Int(raw["attempt"]) >= 1 ||
        _checkpoint_integrity(metadata_path, "attempt must be positive")
    iteration = raw["iteration"]
    iteration === nothing ||
        (iteration isa Integer && !(iteration isa Bool) && iteration >= 1) ||
        _checkpoint_integrity(metadata_path, "iteration must be null or a positive integer")
    raw["kind"] isa AbstractString ||
        _checkpoint_integrity(metadata_path, "kind must be a string")
    raw["payload_extension"] == _checkpoint_extension(codec) ||
        _checkpoint_integrity(metadata_path, "checkpoint codec/extension mismatch")
    payload_file = raw["payload_file"]
    payload_file isa AbstractString ||
        _checkpoint_integrity(metadata_path, "payload_file must be a string")
    basename(payload_file) == payload_file ||
        _checkpoint_integrity(metadata_path, "payload_file must be a basename")
    expected_payload =
        lpad(string(generation), 12, '0') * ".payload." * _checkpoint_extension(codec)
    payload_file == expected_payload || _checkpoint_integrity(
        metadata_path,
        "payload filename does not match generation and codec",
    )
    raw["payload_bytes"] isa Integer && !(raw["payload_bytes"] isa Bool) ||
        _checkpoint_integrity(metadata_path, "payload_bytes must be an integer")
    Int(raw["payload_bytes"]) >= 0 ||
        _checkpoint_integrity(metadata_path, "payload_bytes cannot be negative")
    checksum = raw["sha256"]
    checksum isa AbstractString && occursin(r"^[0-9a-f]{64}$", checksum) ||
        _checkpoint_integrity(
            metadata_path,
            "sha256 must be 64 lowercase hexadecimal digits",
        )
    raw["metadata"] isa Dict{String,Any} ||
        _checkpoint_integrity(metadata_path, "metadata must be a YAML mapping")
    return raw
end

# These barriers belong only to generic runtime checkpoints. A successful
# sequence is conditional on the local POSIX filesystem honouring fsync.
function _sync_runtime_checkpoint_file(path::String)::Nothing
    Sys.isunix() || throw(ArgumentError("runtime checkpoint fsync requires Unix"))
    open(path, "r") do stream
        ccall(:fsync, Cint, (Cint,), fd(stream)) == 0 ||
            throw(SystemError("fsync $path", Libc.errno()))
    end
    return nothing
end

function _sync_runtime_checkpoint_directory(path::String)::Nothing
    Sys.isunix() || throw(ArgumentError("runtime checkpoint directory fsync requires Unix"))
    isdir(path) && !islink(path) || throw(ArgumentError("not a real directory: $path"))
    descriptor = ccall(:open, Cint, (Cstring, Cint), path, 0)
    descriptor >= 0 || throw(SystemError("open directory $path", Libc.errno()))
    result = ccall(:fsync, Cint, (Cint,), descriptor)
    sync_errno = result == 0 ? 0 : Libc.errno()
    close_result = ccall(:close, Cint, (Cint,), descriptor)
    close_errno = close_result == 0 ? 0 : Libc.errno()
    # Preserve the first error even if closing the descriptor also failed.
    result == 0 || throw(SystemError("fsync directory $path", sync_errno))
    close_result == 0 || throw(SystemError("close directory $path", close_errno))
    return nothing
end

function _publish_runtime_checkpoint_file(
    source::AbstractString,
    destination::AbstractString,
)::String
    source_absolute, destination_absolute = abspath(source), abspath(destination)
    dirname(source_absolute) == dirname(destination_absolute) ||
        throw(ArgumentError("checkpoint publication requires the same directory"))
    isfile(source_absolute) && !islink(source_absolute) ||
        throw(ArgumentError("checkpoint publication source is not regular: $source_absolute"))
    (ispath(destination_absolute) || islink(destination_absolute)) &&
        throw(ArgumentError("immutable checkpoint destination exists: $destination_absolute"))
    # No chmod after fsync, overwrite, copy/delete fallback, or retry. The
    # single-writer precondition and object lock exclude concurrent publishers.
    error_code = ccall(:jl_fs_rename, Int32, (Cstring, Cstring),
        source_absolute, destination_absolute)
    error_code < 0 && Base.uv_error(
        "checkpoint publish $(repr(source_absolute)) -> $(repr(destination_absolute))",
        error_code,
    )
    return destination_absolute
end

function _write_runtime_checkpoint_metadata(path::String, envelope::Dict{String,Any})::Nothing
    YAML.write_file(path, envelope)
    return nothing
end

struct _RuntimeCheckpointIO
    sync_file::Function
    sync_directory::Function
    publish_file::Function
    write_metadata::Function
    cut::Function
end

_runtime_checkpoint_io()::_RuntimeCheckpointIO = _RuntimeCheckpointIO(
    _sync_runtime_checkpoint_file,
    _sync_runtime_checkpoint_directory,
    _publish_runtime_checkpoint_file,
    _write_runtime_checkpoint_metadata,
    (stage, context) -> nothing,
)

function _runtime_checkpoint_integer(value, name::AbstractString)
    value isa Integer && !(value isa Bool) && value >= 1 ||
        throw(ArgumentError("$name must be a positive non-Bool integer"))
    return try
        Int(value)
    catch error
        error isa InterruptException && rethrow()
        throw(ArgumentError("$name must be representable as Int"))
    end
end

function _runtime_checkpoint_anchor(repository::FilesystemRunRepository)
    # Compute before mkpath: existence of newly-created ancestors is not an
    # assertion that their entries have already reached stable storage.
    anchor = dirname(repository.root)
    while !isdir(anchor)
        (ispath(anchor) || islink(anchor)) &&
            throw(ArgumentError("checkpoint ancestor is not a directory: $anchor"))
        parent = dirname(anchor)
        parent == anchor && throw(ArgumentError("checkpoint directory has no existing anchor"))
        anchor = parent
    end
    islink(anchor) && throw(ArgumentError("checkpoint anchor is a symlink: $anchor"))
    return anchor
end

function _runtime_checkpoint_read(f, path::AbstractString; preserve_error::Bool = false)
    try
        return f()
    catch error
        error isa InterruptException && rethrow()
        error isa CheckpointIntegrityError && rethrow()
        preserve_error && rethrow()
        _checkpoint_integrity(path, sprint(showerror, error))
    end
end

function _read_runtime_checkpoint_envelope(
    codec::AbstractCheckpointCodec,
    metadata_path::String,
    run_id::AbstractString,
    point_id::AbstractString;
    expected_attempt = nothing,
    preserve_read_errors::Bool = false,
)
    return _runtime_checkpoint_read(metadata_path; preserve_error = preserve_read_errors) do
        isfile(metadata_path) && !islink(metadata_path) ||
            _checkpoint_integrity(metadata_path, "metadata must be a regular non-symlink file")
        envelope = _validate_checkpoint_envelope(
            _load_yaml(metadata_path), metadata_path, codec, run_id, point_id,
        )
        expected_attempt === nothing || envelope["attempt"] == expected_attempt ||
            _checkpoint_integrity(metadata_path, "attempt mismatch")
        envelope
    end
end

function _verify_runtime_checkpoint_payload(
    envelope::Dict{String,Any}, metadata_path::String;
    preserve_read_errors::Bool = false,
)
    reference = _runtime_checkpoint_read(metadata_path; preserve_error = preserve_read_errors) do
        _checkpoint_reference(envelope, metadata_path)
    end
    _runtime_checkpoint_read(reference.payload_path; preserve_error = preserve_read_errors) do
        isfile(reference.payload_path) && !islink(reference.payload_path) ||
            _checkpoint_integrity(reference.payload_path, "payload must be a regular non-symlink file")
        filesize(reference.payload_path) == Int(envelope["payload_bytes"]) ||
            _checkpoint_integrity(reference.payload_path, "payload byte count does not match envelope")
        file_sha256(reference.payload_path) == reference.sha256 ||
            _checkpoint_integrity(reference.payload_path, "SHA-256 digest does not match envelope")
    end
    return reference
end

"""
Publish and verify an immutable runtime checkpoint. Return acknowledges the
checkpoint-scoped local POSIX barriers; it is not a native NFS/power-loss receipt.
"""
function save_runtime_checkpoint!(
    repository::FilesystemRunRepository,
    codec::AbstractCheckpointCodec,
    run_id::AbstractString,
    point_id::AbstractString,
    attempt::Integer,
    state;
    kind::AbstractString = "iteration",
    iteration = nothing,
    metadata = Dict{String,Any}(),
)
    return _save_runtime_checkpoint!(repository, codec, run_id, point_id,
        attempt, state, _runtime_checkpoint_io(); kind = kind,
        iteration = iteration, metadata = metadata)
end

function _save_runtime_checkpoint!(
    repository::FilesystemRunRepository,
    codec::AbstractCheckpointCodec,
    run_id::AbstractString,
    point_id::AbstractString,
    attempt::Integer,
    state,
    io::_RuntimeCheckpointIO;
    kind::AbstractString = "iteration",
    iteration = nothing,
    metadata = Dict{String,Any}(),
)
    Sys.isunix() || throw(ArgumentError("runtime checkpoint persistence requires Unix"))
    directory = _checkpoint_directory(repository, run_id, point_id)
    attempt_value = _runtime_checkpoint_integer(attempt, "checkpoint attempt")
    iteration_value = iteration === nothing ? nothing :
        _runtime_checkpoint_integer(iteration, "checkpoint iteration")
    kind_value = _portable_name(kind, "checkpoint kind")
    safe_metadata = portable_metadata(metadata)
    safe_metadata isa Dict{String,Any} ||
        throw(ArgumentError("checkpoint metadata must be a mapping"))
    return lock(repository.lock) do
        repository._checkpoint_active &&
            throw(ArgumentError("nested checkpoint save on the same repository is not allowed"))
        repository._checkpoint_active = true
        try
            anchor = _runtime_checkpoint_anchor(repository)
            mkpath(directory)
            generation = _next_checkpoint_generation(repository, run_id, point_id)
            stem = lpad(string(generation), 12, '0')
            extension = _checkpoint_extension(codec)
            payload_path = joinpath(directory, "$stem.payload.$extension")
            metadata_path = joinpath(directory, "$stem.metadata.yaml")
            payload_temporary, stream = mktemp(directory)
            close(stream)
            metadata_temporary = nothing
            context() = (run_id = String(run_id), point_id = String(point_id),
                attempt = attempt_value, generation = generation, directory = directory,
                payload_temporary = payload_temporary, payload_path = payload_path,
                metadata_temporary = metadata_temporary, metadata_path = metadata_path)

            _write_checkpoint_payload(codec, payload_temporary, state)
            isfile(payload_temporary) && !islink(payload_temporary) ||
                throw(ArgumentError("checkpoint writer did not leave a regular payload"))
            chmod(payload_temporary, 0o640)
            io.cut(:payload_closed, context())
            checksum = file_sha256(payload_temporary)
            bytes = filesize(payload_temporary)
            envelope = Dict{String,Any}(
                "schema" => RUNTIME_CHECKPOINT_SCHEMA, "run_id" => String(run_id),
                "point_id" => String(point_id), "generation" => generation,
                "attempt" => attempt_value, "kind" => kind_value,
                "iteration" => iteration_value, "payload_file" => basename(payload_path),
                "payload_extension" => extension, "payload_bytes" => bytes,
                "sha256" => checksum, "metadata" => safe_metadata,
            )
            io.cut(:payload_hashed, context())
            io.sync_file(payload_temporary)
            io.cut(:payload_synced, context())
            io.publish_file(payload_temporary, payload_path)
            io.cut(:payload_published, context())
            current = directory
            while true
                io.sync_directory(current)
                current == anchor && break
                current = dirname(current)
            end
            io.cut(:payload_ancestry_synced, context())

            metadata_temporary, metadata_stream = mktemp(directory)
            close(metadata_stream)
            io.write_metadata(metadata_temporary, envelope)
            isfile(metadata_temporary) && !islink(metadata_temporary) ||
                throw(ArgumentError("checkpoint metadata writer did not leave a regular file"))
            chmod(metadata_temporary, 0o640)
            io.cut(:metadata_closed, context())
            io.sync_file(metadata_temporary)
            io.cut(:metadata_synced, context())
            io.publish_file(metadata_temporary, metadata_path)
            io.cut(:metadata_published, context())
            io.sync_directory(directory)
            io.cut(:metadata_directory_synced, context())

            published = _read_runtime_checkpoint_envelope(codec, metadata_path,
                run_id, point_id; expected_attempt = attempt_value, preserve_read_errors = true)
            canonical_bytes(published) == canonical_bytes(envelope) ||
                _checkpoint_integrity(metadata_path, "published envelope differs from expected")
            reference = _verify_runtime_checkpoint_payload(published, metadata_path;
                preserve_read_errors = true)
            io.cut(:publication_verified, context())
            return reference
        finally
            # Raw temporary/orphan/published files survive every failure. No
            # cleanup operation may mask the original write/sync/rename error.
            repository._checkpoint_active = false
        end
    end
end

"""Load the latest immutable envelope, failing closed without fallback or repair."""
function load_latest_checkpoint(
    repository::FilesystemRunRepository,
    codec::AbstractCheckpointCodec,
    run_id::AbstractString,
    point_id::AbstractString;
    expected_attempt::Union{Nothing,Integer} = nothing,
)
    attempt_value = expected_attempt === nothing ? nothing :
        _runtime_checkpoint_integer(expected_attempt, "expected checkpoint attempt")
    directory = _checkpoint_directory(repository, run_id, point_id)
    paths = _runtime_checkpoint_read(directory) do
        _checkpoint_metadata_paths(repository, run_id, point_id)
    end
    isempty(paths) && return nothing
    metadata_path = last(paths)
    metadata = _read_runtime_checkpoint_envelope(codec, metadata_path, run_id,
        point_id; expected_attempt = attempt_value)
    reference = _verify_runtime_checkpoint_payload(metadata, metadata_path)
    state = _runtime_checkpoint_read(reference.payload_path) do
        _read_checkpoint_payload(codec, reference.payload_path)
    end
    return LoadedCheckpoint(reference, state, metadata)
end

function write_timing_session!(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
    session_id::AbstractString,
    summary,
)
    validate_content_identifier(session_id, "timing session id")
    path = joinpath(run_directory(repository, run_id), "timings", "$session_id.yaml")
    _immutable_yaml(path, summary)
    return path
end

function aggregate_timing_sessions!(
    repository::FilesystemRunRepository,
    run_id::AbstractString,
)
    directory = joinpath(run_directory(repository, run_id), "timings")
    paths =
        isdir(directory) ?
        sort!(filter(path -> endswith(path, ".yaml"), readdir(directory; join = true))) :
        String[]
    cores = Dict{String,Dict{String,Any}}()
    for path in paths
        session = _load_yaml(path)
        for (name, timing) in get(session, "cores", Dict{String,Any}())
            target = get!(cores, name) do
                Dict{String,Any}(
                    "calls" => 0,
                    "total_wall_seconds" => 0.0,
                    "maximum_wall_seconds" => 0.0,
                )
            end
            target["calls"] += Int(timing["calls"])
            target["total_wall_seconds"] += Float64(timing["total_wall_seconds"])
            target["maximum_wall_seconds"] = max(
                Float64(target["maximum_wall_seconds"]),
                Float64(timing["maximum_wall_seconds"]),
            )
        end
    end
    summary = Dict{String,Any}(
        "schema" => "reference2019-core-timing-summary-v1",
        "run_id" => String(run_id),
        "session_count" => length(paths),
        "cores" => cores,
    )
    _atomic_yaml(joinpath(run_directory(repository, run_id), "core_timing.yaml"), summary)
    return summary
end
