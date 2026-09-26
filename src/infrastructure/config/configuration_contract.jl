"""
    default_configuration_schema()

Return the absolute path of the run-configuration schema in the currently loaded
package. Resolve this resource when called so a precompiled package can be moved
from its build directory to an installed prefix.
"""
default_configuration_schema() = _package_path("schema", "run.schema.json")

"""
Absolute path of the installed run-configuration schema, initialized when the
module is loaded. Retained as a String for existing callers; new code can use
[`default_configuration_schema`](@ref) to resolve the current package resource.
"""
DEFAULT_CONFIGURATION_SCHEMA::String = ""

"""
    ValidatedConfigurationDocument

Schema-validated, deeply merged input before conversion to solver types.
Keeping this boundary object separate allows a web configurator to inspect
the exact declarative document without reaching into numerical code.
"""
struct ValidatedConfigurationDocument
    data::Dict{String,Any}
    provenance::ConfigurationProvenance
    schema_id::String
    schema_path::String
end

function _load_configuration_schema(path::AbstractString)
    isfile(path) || _configuration_error(path, "configuration JSON Schema does not exist")
    schema = _load_yaml_mapping(path) # JSON is a strict YAML subset.
    get(schema, "\$schema", nothing) == "https://json-schema.org/draft/2020-12/schema" ||
        _configuration_error(path, "schema must declare JSON Schema draft 2020-12")
    try
        _check_supported_schema_keywords!(schema)
    catch error
        _configuration_error(path, sprint(showerror, error))
    end
    return schema
end

function _validate_schema_node(
    data,
    schema,
    root;
    instance_path::AbstractString = "root",
    schema_path::AbstractString = "\$",
)
    violations = _SchemaViolation[]
    try
        _validate_json_schema!(violations, data, schema, root, instance_path, schema_path)
    catch error
        error isa ConfigurationError && rethrow()
        _configuration_error(
            instance_path,
            "invalid schema contract: $(sprint(showerror, error))",
        )
    end
    if !isempty(violations)
        first_violation = first(violations)
        remainder = length(violations) - 1
        suffix = remainder == 0 ? "" : " (and $remainder additional schema violation(s))"
        _configuration_error(
            first_violation.instance_path,
            string(
                first_violation.message,
                " [schema: ",
                first_violation.schema_path,
                ']',
                suffix,
            ),
        )
    end
    return data
end

"""
    validate_configuration_schema(mapping; schema_path=default_configuration_schema())

Validate a fully merged YAML mapping against the sole language-independent
configuration contract. Unknown keys are rejected by
`additionalProperties: false`; no `version` or `schema_version` field exists.
Semantic checks that depend on Unitful conversion or on several physical
quantities are intentionally performed later by `_resolve_configuration`.
"""
function validate_configuration_schema(
    mapping::Dict{String,Any};
    schema_path::AbstractString = default_configuration_schema(),
)
    schema = _load_configuration_schema(schema_path)
    _validate_schema_node(mapping, schema, schema)
    return mapping
end
