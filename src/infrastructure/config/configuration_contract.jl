"""
    default_configuration_schema()

Возвращает абсолютный путь к схеме конфигурации запуска в загруженном пакете.
Путь вычисляется при вызове и соответствует текущему месту установки пакета.
"""
default_configuration_schema() = _package_path("schema", "run.schema.json")

"""
    ValidatedConfigurationDocument

Входные данные после рекурсивного объединения и проверки по схеме.
Отдельный объект позволяет приложению конфигурации читать декларативный
документ до преобразования данных в типы решателя.
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

Проверяет полностью объединённое отображение YAML по схеме конфигурации.
Правило `additionalProperties: false` отклоняет неизвестные ключи.
Проверки, требующие преобразования единиц через Unitful или сопоставления
нескольких физических величин, выполняются в `_resolve_configuration`.
"""
function validate_configuration_schema(
    mapping::Dict{String,Any};
    schema_path::AbstractString = default_configuration_schema(),
)
    schema = _load_configuration_schema(schema_path)
    _validate_schema_node(mapping, schema, schema)
    return mapping
end
