module QCLSchemaProvenance

using SHA
using YAML

struct SchemaProvenanceError <: Exception
    path::String
    message::String
end

Base.showerror(io::IO, error::SchemaProvenanceError) =
    print(io, "schema provenance error at ", error.path, ": ", error.message)

_fail(path, message) = throw(SchemaProvenanceError(String(path), String(message)))

function _string_keys(value, path)
    if value isa AbstractDict
        mapping = Dict{String,Any}()
        for (key, child) in value
            key isa AbstractString || _fail(path, "mapping keys must be strings")
            name = String(key)
            haskey(mapping, name) && _fail(path, "duplicate mapping key $(repr(name))")
            mapping[name] = _string_keys(child, path)
        end
        return mapping
    elseif value isa AbstractVector
        return Any[_string_keys(child, path) for child in value]
    end
    return value
end

# Metadata forbids YAML merge keys because YAML0.4.17's flatten_mapping skips
# duplicate checking for merged mappings. Custom schemas retain their semantics.
function _strict_mapping_from_bytes(bytes, path; metadata::Bool=false)
    strict_mapping = function (constructor, node)
        if metadata && any(pair -> first(pair).tag == "tag:yaml.org,2002:merge", node.value)
            _fail(path, "YAML merge keys are not allowed in provenance metadata")
        end
        YAML.construct_mapping(Dict{Any,Any}, constructor, node; strict_unique_keys=true)
    end
    parsed = try
        YAML.load(String(copy(bytes)), Dict("tag:yaml.org,2002:map" => strict_mapping))
    catch error
        error isa SchemaProvenanceError && rethrow()
        if error isa Union{YAML.ScannerError,YAML.ParserError,YAML.ComposerError,YAML.ConstructorError,ArgumentError}
            _fail(path, "invalid YAML: $(sprint(showerror, error))")
        end
        rethrow()
    end
    parsed isa AbstractDict || _fail(path, "top-level YAML value must be a mapping")
    return _string_keys(parsed, path)
end

function _directory(path)
    absolute = abspath(path)
    isdir(absolute) || _fail(absolute, "directory does not exist")
    try
        return realpath(absolute)
    catch error
        error isa Union{SystemError,Base.IOError} || rethrow()
        _fail(absolute, "cannot resolve directory: $(sprint(showerror, error))")
    end
end

function _capture_file(path; directory=nothing)
    isfile(path) || _fail(path, "regular file does not exist")
    try
        resolved = realpath(path)
        if directory !== nothing && dirname(resolved) != directory
            _fail(path, "file escapes its schema directory")
        end
        return read(resolved)
    catch error
        error isa Union{SystemError,Base.IOError,ArgumentError} || rethrow()
        _fail(path, "cannot read file: $(sprint(showerror, error))")
    end
end

function _schema_directory(root, parts...)
    path = joinpath(root, parts...)
    directory = _directory(path)
    # A schema-directory symlink must not redirect the selected package layout.
    directory == normpath(path) || _fail(path, "schema directory resolves outside its selected path")
    return directory
end

function _safe_name(name, path)
    name isa AbstractString || _fail(path, "declared file names must be strings")
    text = String(name)
    (isempty(text) || text in (".", "..") || isabspath(text) ||
     occursin('/', text) || occursin('\\', text) || occursin(':', text) || occursin('\0', text)) &&
        _fail(path, "unsafe declared file name $(repr(text))")
    return text
end

function verify_schema_provenance(
    runner_root::AbstractString;
    mode::Symbol=:auto,
    workspace_root::Union{Nothing,AbstractString}=nothing,
)
    mode in (:auto, :workspace, :standalone) || _fail(runner_root, "unsupported mode $(repr(mode))")
    mode != :workspace && workspace_root !== nothing &&
        _fail(runner_root, "workspace_root is allowed only in workspace mode")
    mode == :workspace && workspace_root === nothing &&
        _fail(runner_root, "workspace mode requires workspace_root")
    root = _directory(runner_root)
    selected_workspace = nothing
    resolved_mode = mode
    if mode == :auto
        candidate = dirname(dirname(root))
        if basename(root) == "QCLNEGFRunner.jl" && basename(dirname(root)) == "components" &&
           isfile(joinpath(candidate, ".gitmodules"))
            resolved_mode = :workspace
            selected_workspace = candidate
        else
            resolved_mode = :standalone
        end
    elseif mode == :workspace
        selected_workspace = _directory(workspace_root)
    end
    canonical_directory = nothing
    if resolved_mode == :workspace
        selected_runner = joinpath(selected_workspace, "components", "QCLNEGFRunner.jl")
        _directory(selected_runner) == root ||
            _fail(selected_runner, "workspace Runner does not match runner_root")
        canonical_directory = _schema_directory(selected_workspace,
            "components", "qcl-negf-contracts", "src", "qcl_negf_contracts", "schemas")
    end
    directory = _schema_directory(root, "schema")
    provenance_path = joinpath(directory, "PROVENANCE.json")
    metadata = _strict_mapping_from_bytes(
        _capture_file(provenance_path; directory=directory), provenance_path; metadata=true)
    for field in ("source", "version")
        value = get(metadata, field, nothing)
        value isa AbstractString && !isempty(strip(value)) ||
            _fail(provenance_path, "$field must be a nonempty string")
    end
    declared = get(metadata, "sha256", nothing)
    declared isa AbstractDict && !isempty(declared) ||
        _fail(provenance_path, "sha256 must be a nonempty mapping")
    for required in ("run.schema.json", "results-contract-set.json")
        haskey(declared, required) || _fail(provenance_path, "sha256 is missing $required")
    end
    hashes = Dict{String,String}()
    files = Dict{String,Vector{UInt8}}()
    for name in sort!(collect(keys(declared)))
        safe_name = _safe_name(name, provenance_path)
        expected = declared[name]
        expected isa AbstractString && occursin(r"^[0-9a-f]{64}$", expected) ||
            _fail(provenance_path, "invalid SHA256 digest for $safe_name")
        packaged_path = joinpath(directory, safe_name)
        bytes = _capture_file(packaged_path; directory=directory)
        digest = bytes2hex(SHA.sha256(bytes))
        digest == expected ||
            _fail(packaged_path, "SHA256 mismatch (declared=$expected, actual=$digest)")
        if resolved_mode == :workspace
            canonical_path = joinpath(canonical_directory, safe_name)
            canonical_bytes = _capture_file(canonical_path; directory=canonical_directory)
            bytes == canonical_bytes || _fail(canonical_path,
                "canonical bytes differ (packaged=$digest, canonical=$(bytes2hex(SHA.sha256(canonical_bytes))))")
        end
        hashes[safe_name] = digest
        files[safe_name] = bytes
    end
    return (; mode=resolved_mode, runner_root=root, workspace_root=selected_workspace,
            provenance_path, hashes, files)
end

_one_line(message) = replace(String(message), '\n' => ' ', '\r' => ' ')

function main(arguments::AbstractVector{<:AbstractString}; output::IO=stdout, errors::IO=stderr)::Int
    options = Dict{String,String}()
    allowed = ("--mode", "--workspace-root", "--runner-root")
    index = 1
    usage_error = nothing
    while index <= length(arguments)
        option = arguments[index]
        if !(option in allowed)
            usage_error = "unknown option or positional argument $(repr(option))"
            break
        elseif haskey(options, option)
            usage_error = "duplicate option $option"
            break
        elseif index == length(arguments) || startswith(arguments[index + 1], "--")
            usage_error = "missing value for $option"
            break
        end
        options[option] = arguments[index + 1]
        index += 2
    end
    if usage_error === nothing
        requested = get(options, "--mode", "")
        if !(requested in ("workspace", "standalone"))
            usage_error = "--mode must be explicitly standalone or workspace"
        elseif requested == "workspace" && !haskey(options, "--workspace-root")
            usage_error = "workspace mode requires --workspace-root"
        elseif requested == "standalone" && haskey(options, "--workspace-root")
            usage_error = "standalone mode forbids --workspace-root"
        end
    end
    if usage_error !== nothing
        println(errors, "schema provenance usage error: ", _one_line(usage_error))
        return 2
    end
    root = get(options, "--runner-root", dirname(@__DIR__))
    snapshot = try
        verify_schema_provenance(root; mode=Symbol(options["--mode"]),
            workspace_root=get(options, "--workspace-root", nothing))
    catch error
        error isa SchemaProvenanceError || rethrow()
        println(errors, "schema provenance error at ", _one_line(error.path), ": ", _one_line(error.message))
        return 2
    end
    println(output, "schema provenance verified (mode=$(snapshot.mode), files=$(length(snapshot.files)))")
    return 0
end

end # module QCLSchemaProvenance

if abspath(PROGRAM_FILE) == @__FILE__
    exit(QCLSchemaProvenance.main(ARGS))
end
