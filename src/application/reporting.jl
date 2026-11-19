"""
Шаблон отчёта, выбранный внешним шаблоном запуска. Он определяет представление
результатов. Научная конфигурация `ResolvedRunConfiguration` и идентификатор
содержимого от него не зависят.
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

"""Готовый файл, на который может ссылаться отчёт по шаблону."""
struct ConfiguredReportArtifact
    label::String
    path::String
    media_type::String
end

"""Материал из результата расчёта для одного раздела отчёта."""
struct ConfiguredReportSection
    notes::Vector{String}
    artifacts::Vector{ConfiguredReportArtifact}
end

"""
Данные для отчёта, независимые от способа его представления. Массивы хранятся
в YAML, HDF5 или CSV. Отчёт содержит текстовые сведения и ссылки на файлы.
"""
struct ConfiguredReportContext
    title::String
    result_kind::Symbol
    status::String
    output_directory::String
    facts::Vector{Pair{String,String}}
    sections::Dict{Symbol,ConfiguredReportSection}
end

"""Интерфейс вывода приложения, который реализуют средства представления результатов."""
abstract type AbstractConfiguredReportRenderer end

"""Подготовить данные о завершённой операции в формате, независимом от средства представления."""
function configured_report_context end

"""Сформировать отчёт по заданному шаблону с помощью `AbstractConfiguredReportRenderer`."""
function render_configured_report end

"""Закрытый перечень названий разделов, которые принимает шаблон отчёта."""
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

Отделить упорядоченные источники конфигурации от необязательной пары
`--report-template PATH`, которая задаёт только отчёт. Пара допускается один
раз в конце списка аргументов. Это сохраняет однозначный порядок переопределений.
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
