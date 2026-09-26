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
    function FilesystemRunRepository(root::AbstractString)
        new(abspath(root), ReentrantLock(), Dict{String,Int}())
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

"""
Write payload first and its immutable envelope last. A crash before the
envelope leaves an ignored orphan, never a falsely valid restart.
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
    attempt >= 1 || throw(ArgumentError("checkpoint attempt must be positive"))
    iteration === nothing ||
        iteration >= 1 ||
        throw(ArgumentError("checkpoint iteration must be positive"))
    _portable_name(kind, "checkpoint kind")
    directory = _checkpoint_directory(repository, run_id, point_id)
    mkpath(directory)
    generation = _next_checkpoint_generation(repository, run_id, point_id)
    stem = lpad(string(generation), 12, '0')
    extension = _checkpoint_extension(codec)
    payload_path = joinpath(directory, "$stem.payload.$extension")
    metadata_path = joinpath(directory, "$stem.metadata.yaml")
    temporary, stream = mktemp(directory)
    close(stream)
    try
        _write_checkpoint_payload(codec, temporary, state)
        checksum = file_sha256(temporary)
        bytes = filesize(temporary)
        chmod(temporary, 0o640)
        mv(temporary, payload_path; force = false)
        envelope = Dict{String,Any}(
            "schema" => RUNTIME_CHECKPOINT_SCHEMA,
            "run_id" => String(run_id),
            "point_id" => String(point_id),
            "generation" => generation,
            "attempt" => Int(attempt),
            "kind" => String(kind),
            "iteration" => iteration === nothing ? nothing : Int(iteration),
            "payload_file" => basename(payload_path),
            "payload_extension" => extension,
            "payload_bytes" => bytes,
            "sha256" => checksum,
            "metadata" => portable_metadata(metadata),
        )
        _immutable_yaml(metadata_path, envelope)
        return _checkpoint_reference(envelope, metadata_path)
    catch
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
end

"""Load and checksum the newest committed checkpoint envelope."""
function load_latest_checkpoint(
    repository::FilesystemRunRepository,
    codec::AbstractCheckpointCodec,
    run_id::AbstractString,
    point_id::AbstractString,
)
    paths = _checkpoint_metadata_paths(repository, run_id, point_id)
    isempty(paths) && return nothing
    metadata_path = last(paths)
    metadata = _validate_checkpoint_envelope(
        _load_yaml(metadata_path),
        metadata_path,
        codec,
        run_id,
        point_id,
    )
    reference = _checkpoint_reference(metadata, metadata_path)
    isfile(reference.payload_path) ||
        throw(CheckpointIntegrityError(reference.payload_path, "payload is missing"))
    filesize(reference.payload_path) == Int(metadata["payload_bytes"]) || throw(
        CheckpointIntegrityError(
            reference.payload_path,
            "payload byte count does not match envelope",
        ),
    )
    actual = file_sha256(reference.payload_path)
    actual == reference.sha256 || throw(
        CheckpointIntegrityError(
            reference.payload_path,
            "SHA-256 digest does not match envelope",
        ),
    )
    state = _read_checkpoint_payload(codec, reference.payload_path)
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
