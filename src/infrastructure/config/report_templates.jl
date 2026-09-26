function _portable_report_output(value, path::AbstractString)
    output = _string(value, path)
    isabspath(output) &&
        _configuration_error(path, "must be relative to the result directory")
    normalized = normpath(output)
    first(splitpath(normalized)) == ".." &&
        _configuration_error(path, "must remain below the result directory")
    normalized == "." && _configuration_error(path, "must name a Markdown file")
    all(
        component -> occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", component),
        splitpath(normalized),
    ) || _configuration_error(path, "must contain only portable path components")
    lowercase(splitext(normalized)[2]) == ".md" ||
        _configuration_error(path, "must use the .md extension")
    return normalized
end

"""
    load_configured_report_template(path)

Load and strictly validate a versionless report-template YAML file.  Unknown
or duplicate sections fail closed; rendering and section ordering are driven
only by this object.
"""
function load_configured_report_template(path::AbstractString)
    absolute = abspath(path)
    mapping = _mapping(_load_yaml_mapping(absolute), "report_template")
    _expect_keys(
        mapping,
        "report_template";
        required = ("id", "label", "sections", "image_policy", "output"),
    )
    identifier = _string(mapping["id"], "report_template.id")
    occursin(r"^[a-z][a-z0-9_-]{0,63}$", identifier) || _configuration_error(
        "report_template.id",
        "must be a portable lowercase identifier",
    )
    label = _string(mapping["label"], "report_template.label")
    section_values = _array(mapping["sections"], "report_template.sections")
    isempty(section_values) &&
        _configuration_error("report_template.sections", "at least one section is required")
    sections = Symbol[]
    allowed = Set(CONFIGURED_REPORT_SECTIONS)
    for (index, value) in pairs(section_values)
        name = Symbol(_string(value, "report_template.sections[$index]"))
        name in allowed || _configuration_error(
            "report_template.sections[$index]",
            "unknown section $(repr(String(name)))",
        )
        name in sections && _configuration_error(
            "report_template.sections[$index]",
            "duplicate section $(repr(String(name)))",
        )
        push!(sections, name)
    end
    image_policy =
        _choice(mapping["image_policy"], "report_template.image_policy", (:links,))
    output = _portable_report_output(mapping["output"], "report_template.output")
    return ConfiguredReportTemplate(
        identifier,
        label,
        sections,
        image_policy,
        output,
        absolute,
        file_sha256(absolute),
    )
end
