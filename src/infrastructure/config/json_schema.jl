"""
One fail-closed JSON-Schema violation.  The public configuration API converts
this internal representation to `ConfigurationError` only after combinators
(`oneOf`, `anyOf`, `if`/`then`) have been evaluated.
"""
struct _SchemaViolation
    instance_path::String
    schema_path::String
    message::String
end

_schema_child(path::AbstractString, key::AbstractString) =
    isempty(path) ? String(key) : string(path, '.', key)

_schema_index(path::AbstractString, index::Integer) = string(path, '[', index, ']')

function _schema_type_matches(value, name::AbstractString)
    name == "null" && return value === nothing
    name == "boolean" && return value isa Bool
    name == "integer" && return value isa Integer && !(value isa Bool)
    name == "number" && return value isa Real && !(value isa Bool)
    name == "string" && return value isa AbstractString
    name == "array" && return value isa AbstractVector
    name == "object" && return value isa Dict{String,Any}
    return false
end

function _schema_value_equal(left, right)
    if left isa Real && right isa Real && !(left isa Bool) && !(right isa Bool)
        return left == right
    end
    return isequal(left, right)
end

function _decode_json_pointer_token(token::AbstractString)
    replace(String(token), "~1" => "/", "~0" => "~")
end

function _resolve_local_schema_reference(root::Dict{String,Any}, reference::AbstractString)
    reference == "#" && return root
    startswith(reference, "#/") || throw(
        ArgumentError("only local JSON-Schema references are supported, got $reference"),
    )
    node = root
    for raw_token in split(reference[3:end], '/')
        token = _decode_json_pointer_token(raw_token)
        node isa Dict{String,Any} && haskey(node, token) || throw(
            ArgumentError("unresolved JSON-Schema reference $reference at token $token"),
        )
        node = node[token]
    end
    return node
end

function _branch_is_valid(value, schema, root, instance_path, schema_path)
    branch_violations = _SchemaViolation[]
    _validate_json_schema!(
        branch_violations,
        value,
        schema,
        root,
        instance_path,
        schema_path,
    )
    return isempty(branch_violations), branch_violations
end

function _push_schema_violation!(violations, instance_path, schema_path, message)
    push!(
        violations,
        _SchemaViolation(String(instance_path), String(schema_path), String(message)),
    )
    return violations
end

"""
Minimal, deterministic Draft 2020-12 evaluator for the keywords used by the
QCLNEGFRunner configuration contract.  It deliberately rejects unsupported
schema keywords in `_check_supported_schema_keywords!`, instead of silently
pretending that a partial validator is complete.
"""
function _validate_json_schema!(
    violations::Vector{_SchemaViolation},
    value,
    schema,
    root::Dict{String,Any},
    instance_path::AbstractString,
    schema_path::AbstractString,
)
    schema === true && return violations
    if schema === false
        return _push_schema_violation!(
            violations,
            instance_path,
            schema_path,
            "value is forbidden by the schema",
        )
    end
    schema isa Dict{String,Any} ||
        throw(ArgumentError("JSON-Schema node $schema_path must be an object or Boolean"))

    if haskey(schema, "\$ref")
        reference = schema["\$ref"]
        reference isa AbstractString ||
            throw(ArgumentError("JSON-Schema \$ref at $schema_path must be a string"))
        target = _resolve_local_schema_reference(root, reference)
        _validate_json_schema!(
            violations,
            value,
            target,
            root,
            instance_path,
            string(schema_path, ".\$ref(", reference, ')'),
        )
    end

    if haskey(schema, "allOf")
        for (index, branch) in pairs(schema["allOf"])
            _validate_json_schema!(
                violations,
                value,
                branch,
                root,
                instance_path,
                _schema_index(string(schema_path, ".allOf"), index),
            )
        end
    end
    if haskey(schema, "anyOf")
        accepted = false
        branch_messages = String[]
        for (index, branch) in pairs(schema["anyOf"])
            valid, branch_violations = _branch_is_valid(
                value,
                branch,
                root,
                instance_path,
                _schema_index(string(schema_path, ".anyOf"), index),
            )
            accepted |= valid
            valid || push!(
                branch_messages,
                join((item.message for item in branch_violations), "; "),
            )
        end
        accepted || _push_schema_violation!(
            violations,
            instance_path,
            string(schema_path, ".anyOf"),
            "does not satisfy any allowed schema branch: " * join(branch_messages, " | "),
        )
    end
    if haskey(schema, "oneOf")
        accepted = 0
        for (index, branch) in pairs(schema["oneOf"])
            valid, _ = _branch_is_valid(
                value,
                branch,
                root,
                instance_path,
                _schema_index(string(schema_path, ".oneOf"), index),
            )
            accepted += valid
        end
        accepted == 1 || _push_schema_violation!(
            violations,
            instance_path,
            string(schema_path, ".oneOf"),
            "must satisfy exactly one schema branch, satisfied $accepted",
        )
    end
    if haskey(schema, "not")
        valid, _ = _branch_is_valid(
            value,
            schema["not"],
            root,
            instance_path,
            string(schema_path, ".not"),
        )
        valid && _push_schema_violation!(
            violations,
            instance_path,
            string(schema_path, ".not"),
            "matches a forbidden schema",
        )
    end
    if haskey(schema, "if")
        condition, _ = _branch_is_valid(
            value,
            schema["if"],
            root,
            instance_path,
            string(schema_path, ".if"),
        )
        selected = condition ? get(schema, "then", nothing) : get(schema, "else", nothing)
        if selected !== nothing
            selected_name = condition ? "then" : "else"
            _validate_json_schema!(
                violations,
                value,
                selected,
                root,
                instance_path,
                string(schema_path, '.', selected_name),
            )
        end
    end

    if haskey(schema, "type")
        requested =
            schema["type"] isa AbstractVector ? String.(schema["type"]) :
            [String(schema["type"])]
        any(name -> _schema_type_matches(value, name), requested) ||
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".type"),
                "expected type $(join(requested, " or ")), got $(typeof(value))",
            )
        # Type-specific keywords must not run on a value of another type.
        any(name -> _schema_type_matches(value, name), requested) || return violations
    end

    if haskey(schema, "const") && !_schema_value_equal(value, schema["const"])
        _push_schema_violation!(
            violations,
            instance_path,
            string(schema_path, ".const"),
            "expected constant value $(repr(schema["const"]))",
        )
    end
    if haskey(schema, "enum") &&
       !any(candidate -> _schema_value_equal(value, candidate), schema["enum"])
        _push_schema_violation!(
            violations,
            instance_path,
            string(schema_path, ".enum"),
            "must be one of $(join(repr.(schema["enum"]), ", "))",
        )
    end

    if value isa Dict{String,Any}
        properties = get(schema, "properties", Dict{String,Any}())
        required = Set{String}(String.(get(schema, "required", Any[])))
        missing = sort!(collect(setdiff(required, Set(keys(value)))))
        isempty(missing) || _push_schema_violation!(
            violations,
            instance_path,
            string(schema_path, ".required"),
            "missing required key(s): $(join(missing, ", "))",
        )
        if haskey(schema, "minProperties") && length(value) < schema["minProperties"]
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".minProperties"),
                "must contain at least $(schema["minProperties"]) properties",
            )
        end
        if haskey(schema, "maxProperties") && length(value) > schema["maxProperties"]
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".maxProperties"),
                "must contain at most $(schema["maxProperties"]) properties",
            )
        end
        for (key, child) in value
            if haskey(properties, key)
                _validate_json_schema!(
                    violations,
                    child,
                    properties[key],
                    root,
                    _schema_child(instance_path, key),
                    _schema_child(string(schema_path, ".properties"), key),
                )
            elseif get(schema, "additionalProperties", true) === false
                _push_schema_violation!(
                    violations,
                    _schema_child(instance_path, key),
                    string(schema_path, ".additionalProperties"),
                    "unknown key $(repr(key))",
                )
            elseif get(schema, "additionalProperties", true) isa Dict
                _validate_json_schema!(
                    violations,
                    child,
                    schema["additionalProperties"],
                    root,
                    _schema_child(instance_path, key),
                    string(schema_path, ".additionalProperties"),
                )
            end
        end
        for (key, dependencies) in get(schema, "dependentRequired", Dict{String,Any}())
            haskey(value, key) || continue
            absent = sort!(collect(setdiff(Set(String.(dependencies)), Set(keys(value)))))
            isempty(absent) || _push_schema_violation!(
                violations,
                _schema_child(instance_path, key),
                string(schema_path, ".dependentRequired.", key),
                "also requires key(s): $(join(absent, ", "))",
            )
        end
    elseif value isa AbstractVector
        if haskey(schema, "minItems") && length(value) < schema["minItems"]
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".minItems"),
                "must contain at least $(schema["minItems"]) items",
            )
        end
        if haskey(schema, "maxItems") && length(value) > schema["maxItems"]
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".maxItems"),
                "must contain at most $(schema["maxItems"]) items",
            )
        end
        if get(schema, "uniqueItems", false) === true
            for first_index in eachindex(value),
                second_index = (first_index+1):lastindex(value)

                if _schema_value_equal(value[first_index], value[second_index])
                    _push_schema_violation!(
                        violations,
                        instance_path,
                        string(schema_path, ".uniqueItems"),
                        "items $first_index and $second_index are duplicates",
                    )
                    break
                end
            end
        end
        if haskey(schema, "items")
            for (index, child) in pairs(value)
                _validate_json_schema!(
                    violations,
                    child,
                    schema["items"],
                    root,
                    _schema_index(instance_path, index),
                    string(schema_path, ".items"),
                )
            end
        end
    elseif value isa AbstractString
        if haskey(schema, "minLength") && length(value) < schema["minLength"]
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".minLength"),
                "must contain at least $(schema["minLength"]) characters",
            )
        end
        if haskey(schema, "maxLength") && length(value) > schema["maxLength"]
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".maxLength"),
                "must contain at most $(schema["maxLength"]) characters",
            )
        end
        if haskey(schema, "pattern")
            pattern = Regex(String(schema["pattern"]))
            occursin(pattern, value) || _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".pattern"),
                "does not match pattern $(repr(schema["pattern"]))",
            )
        end
    elseif value isa Real && !(value isa Bool)
        isfinite(value) || _push_schema_violation!(
            violations,
            instance_path,
            schema_path,
            "numeric value must be finite",
        )
        haskey(schema, "minimum") &&
            value < schema["minimum"] &&
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".minimum"),
                "must be at least $(schema["minimum"])",
            )
        haskey(schema, "maximum") &&
            value > schema["maximum"] &&
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".maximum"),
                "must not exceed $(schema["maximum"])",
            )
        haskey(schema, "exclusiveMinimum") &&
            value <= schema["exclusiveMinimum"] &&
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".exclusiveMinimum"),
                "must be greater than $(schema["exclusiveMinimum"])",
            )
        haskey(schema, "exclusiveMaximum") &&
            value >= schema["exclusiveMaximum"] &&
            _push_schema_violation!(
                violations,
                instance_path,
                string(schema_path, ".exclusiveMaximum"),
                "must be smaller than $(schema["exclusiveMaximum"])",
            )
    end
    return violations
end

const _SUPPORTED_SCHEMA_KEYWORDS = Set([
    "\$schema",
    "\$id",
    "\$comment",
    "\$defs",
    "\$ref",
    "title",
    "description",
    "default",
    "examples",
    "type",
    "const",
    "enum",
    "allOf",
    "anyOf",
    "oneOf",
    "not",
    "if",
    "then",
    "else",
    "properties",
    "required",
    "additionalProperties",
    "dependentRequired",
    "minProperties",
    "maxProperties",
    "items",
    "minItems",
    "maxItems",
    "uniqueItems",
    "minLength",
    "maxLength",
    "pattern",
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
])

function _check_supported_schema_keywords!(schema, path::AbstractString = "\$")
    schema isa Bool && return schema
    schema isa Dict{String,Any} ||
        throw(ArgumentError("JSON-Schema node $path must be an object or Boolean"))
    unknown = sort!(collect(setdiff(Set(keys(schema)), _SUPPORTED_SCHEMA_KEYWORDS)))
    isempty(unknown) || throw(
        ArgumentError(
            "unsupported JSON-Schema keyword(s) at $path: $(join(unknown, ", "))",
        ),
    )
    for key in ("properties", "\$defs")
        for (name, child) in get(schema, key, Dict{String,Any}())
            _check_supported_schema_keywords!(child, string(path, '.', key, '.', name))
        end
    end
    if haskey(schema, "additionalProperties") && schema["additionalProperties"] isa Dict
        _check_supported_schema_keywords!(
            schema["additionalProperties"],
            string(path, ".additionalProperties"),
        )
    end
    haskey(schema, "items") &&
        _check_supported_schema_keywords!(schema["items"], string(path, ".items"))
    for key in ("allOf", "anyOf", "oneOf")
        for (index, child) in pairs(get(schema, key, Any[]))
            _check_supported_schema_keywords!(
                child,
                _schema_index(string(path, '.', key), index),
            )
        end
    end
    for key in ("not", "if", "then", "else")
        haskey(schema, key) &&
            _check_supported_schema_keywords!(schema[key], string(path, '.', key))
    end
    return schema
end
