"""
Declarative report template selected by an outer run template.  Report
selection is an application/presentation concern and deliberately does not
enter the scientific `ResolvedRunConfiguration` or the content identity.
"""
struct ConfiguredReportTemplate
    id::String
    label::String
    sections::Vector{Symbol}
    image_policy::Symbol
    output::String
    source::String
    source_sha256::String
end

"""One existing artifact that a configured report may link to."""
struct ConfiguredReportArtifact
    label::String
    path::String
    media_type::String
end

"""Material supplied by an application result for one report section."""
struct ConfiguredReportSection
    notes::Vector{String}
    artifacts::Vector{ConfiguredReportArtifact}
end

"""
Renderer-neutral result projection.  Numerical arrays remain in YAML/HDF5/CSV;
the report carries human-readable facts and links rather than copying them.
"""
struct ConfiguredReportContext
    title::String
    result_kind::Symbol
    status::String
    output_directory::String
    facts::Vector{Pair{String,String}}
    sections::Dict{Symbol,ConfiguredReportSection}
end

"""Application output port implemented by presentation adapters."""
abstract type AbstractConfiguredReportRenderer end

"""Build the renderer-neutral report projection for a completed use case."""
function configured_report_context end

"""Render a configured report through an `AbstractConfiguredReportRenderer`."""
function render_configured_report end

"""Closed vocabulary accepted by versionless configured report templates."""
const CONFIGURED_REPORT_SECTIONS = (
    :configuration,
    :provenance,
    :convergence,
    :current_density,
    :hartree_potential,
    :wavefunctions,
    :performance,
    :method_classification,
    :physical_equivalence,
    :discretization_convergence,
    :current_and_gain,
    :matrix_diagnostics,
    :incomplete_points,
)

"""
    configured_report_arguments(arguments)

Separate ordered configuration sources from the optional orchestration-only
`--report-template PATH` pair.  The marker may occur only once and must be the
last option pair, so configuration overrides remain unambiguous.
"""
function configured_report_arguments(arguments)
    values = String[String(value) for value in arguments]
    marker_indices = findall(==("--report-template"), values)
    length(marker_indices) <= 1 ||
        throw(ArgumentError("--report-template may be supplied only once"))
    if isempty(marker_indices)
        isempty(values) &&
            throw(ArgumentError("at least one configuration source is required"))
        return (configuration_sources = values, report_template = nothing)
    end
    marker = only(marker_indices)
    marker == length(values) - 1 ||
        throw(ArgumentError("--report-template PATH must be the final argument pair"))
    marker > 1 || throw(
        ArgumentError("at least one configuration source must precede --report-template"),
    )
    isempty(values[end]) && throw(ArgumentError("report template path cannot be empty"))
    return (configuration_sources = values[1:(marker-1)], report_template = values[end])
end
