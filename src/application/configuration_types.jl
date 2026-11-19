"""
    ConfigurationError

Ошибка манифеста YAML, объединения, схемы, единиц или условия, связывающего
несколько полей. Неизвестный ключ вызывает ошибку.
"""
struct ConfigurationError <: Exception
    path::String
    message::String
end

function Base.showerror(io::IO, error::ConfigurationError)
    print(io, "configuration error at ", error.path, ": ", error.message)
end

_configuration_error(path, message) =
    throw(ConfigurationError(String(path), String(message)))

"""
Манифесты и файлы по порядку загрузки и полная история переопределений каждого
конечного поля итогового дерева YAML. Список `sources[path]` идёт от первого
определения к тому, которое вошло в итоговую конфигурацию.
"""
struct ConfigurationProvenance
    manifests::Vector{String}
    files::Vector{String}
    sources::Dict{String,Vector{String}}
end

"""Настройки планировщика расчёта уровня E1 в режиме `auto_exact`."""
struct AutomaticExecutionConfiguration
    memory_reserve_fraction::Float64
    minimum_memory_reserve_bytes::Int
    workspace_budget_fraction::Float64
    workspace_complex_arrays_per_energy_block::Int
    minimum_outer_parallel_threads::Int
    large_basis_threshold::Int
    minimum_energy_chunk::Int
    energy_chunk_alignment::Int
    blocks_per_worker::Int
    hilbert_columns_per_worker::Int
    energy_jobs_per_worker::Int
end

"""
Ресурсы запуска и выбор реализации решателя. Агрегирование данных в основном
решателе детерминировано по контракту и не задаётся отдельным режимом.

См. [конфигурации запуска YAML](@ref yaml-run-configurations).
"""
struct ExecutionConfiguration
    strategy::Symbol
    solver_backend::Symbol
    julia_threads::Int
    blas_threads::Int
    fail_on_thread_mismatch::Bool
    automatic::AutomaticExecutionConfiguration
end

"""
Настройки отображения хода расчёта и записи данных в машиночитаемом формате.

См. [результаты и возобновление](@ref native-result-formats).
"""
struct ProgressOutputConfiguration
    enabled::Bool
    terminal::Bool
    significant_digits::Int
    event_log_file::Union{Nothing,String}
    latest_snapshot_file::Union{Nothing,String}
    dashboard_file::Union{Nothing,String}
end

"""
Геометрия устройства, используемая для пересчёта тока в отчёте.

См. [конфигурации запуска YAML](@ref yaml-run-configurations).
"""
struct DeviceGeometryConfiguration
    periods::Int
    ridge_width::LengthQuantity
    cavity_length::LengthQuantity
end

"""
Настройки вывода, возобновления и визуализации хода расчёта.

См. [конфигурации запуска YAML](@ref yaml-run-configurations)
и [результаты и возобновление](@ref native-result-formats).
"""
struct OutputConfiguration
    directory::String
    checkpoint_prefix::String
    resume::Bool
    fail_fast::Bool
    save_full_state::Bool
    save_csv::Bool
    save_plots::Bool
    live_visualization::Bool
    snapshot_every_scba::Int
    snapshot_every_outer::Int
    progress::ProgressOutputConfiguration
    report_directory::String
    save_expert_markdown::Bool
    save_comparison_csv::Bool
    save_comparison_plots::Bool
    device_geometry::DeviceGeometryConfiguration
    debug_hdf5::Bool
    light_max_space_points::Int
    light_max_energy_points::Int
    light_max_momentum_points::Int
    light_max_snapshots::Int
end

"""
Явные размеры сеток, которые меняются при исследовании сходимости.

См. [подробное сравнение методов](@ref expert-comparison-workflow).
"""
struct ConvergenceStudyConfiguration
    spatial_nodes::Vector{Int}
    energy_nodes::Vector{Int}
    momentum_nodes::Vector{Int}
    angular_nodes::Vector{Int}
end

"""
Сведения для отчёта по одному из сравниваемых вариантов конфигурации.

См. [подробное сравнение методов](@ref expert-comparison-workflow).
"""
struct StudyMethodConfiguration
    profile::String
    label::String
    modifies_physics::Bool
    algorithm_family::Symbol
    description::String
    literature::Vector{String}
end

"""
Рабочие точки и настройки сравнения и отчёта для одного воспроизводимого запуска.

См. [подробное сравнение методов](@ref expert-comparison-workflow).
"""
struct StudyConfiguration
    mode::Symbol
    voltages_per_period::Vector{typeof(1.0u"V")}
    temperatures::Vector{TemperatureQuantity}
    comparison_profiles::Vector{String}
    reference_profile::Union{Nothing,String}
    methods::Vector{StudyMethodConfiguration}
    repetitions::Int
    calculate_optical_response::Bool
    photon_energy_min::EnergyQuantity
    photon_energy_max::EnergyQuantity
    photon_energy_points::Int
    optical_edge_tolerance::Float64
    convergence::ConvergenceStudyConfiguration
end

"""
    ResolvedRunConfiguration

Итоговое описание запуска с проверенными единицами. Физические и численные
параметры преобразованы в типизированные объекты учебного и основного решателей.
`algorithms` содержит проверенный объект
[`AlgorithmOptions`](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/api/public.md),
который также доступен через `production.algorithms`.
Поле `raw` предназначено для отчёта и воспроизведения конфигурации.

См. [конфигурации запуска YAML](@ref yaml-run-configurations).
"""
struct ResolvedRunConfiguration
    name::String
    description::String
    classification::Symbol
    physical::PhysicalParameters
    numerical::NumericalParameters
    scales::ScaleSystem
    scattering::ScatteringOptions
    solver::SolverOptions
    production::ProductionOptions
    kernels::ProductionKernelOptions
    algorithms::AlgorithmOptions
    execution::ExecutionConfiguration
    output::OutputConfiguration
    study::StudyConfiguration
    provenance::ConfigurationProvenance
    raw::Dict{String,Any}
    physical_models::PhysicalModelOptions
    domain_adaptation::DomainAdaptationPolicy
end

"""
    configuration_source(configuration, dotted_path)

Вернуть файл YAML, из которого взято итоговое значение `dotted_path`.
Если путь не указывает на конечное поле, вернуть `nothing`.

См. [конфигурации запуска YAML](@ref yaml-run-configurations).
"""
function configuration_source(
    configuration::ResolvedRunConfiguration,
    dotted_path::AbstractString,
)
    history = get(configuration.provenance.sources, String(dotted_path), nothing)
    return history === nothing || isempty(history) ? nothing : last(history)
end

"""Вернуть независимую копию проверенной [конфигурации YAML](@ref yaml-run-configurations)
после объединения всех вложенных полей."""
resolved_configuration_dict(configuration::ResolvedRunConfiguration) =
    deepcopy(configuration.raw)

"""Вернуть физические параметры из [конфигурации запуска YAML](@ref yaml-run-configurations)."""
physical_parameters(configuration::ResolvedRunConfiguration) = configuration.physical
"""Вернуть параметры сетки из [конфигурации запуска YAML](@ref yaml-run-configurations)."""
numerical_parameters(configuration::ResolvedRunConfiguration) = configuration.numerical
"""Вернуть каналы рассеяния из [конфигурации запуска YAML](@ref yaml-run-configurations)."""
scattering_options(configuration::ResolvedRunConfiguration) = configuration.scattering
"""Вернуть настройки SCBA и Пуассона из [конфигурации запуска YAML](@ref yaml-run-configurations)."""
solver_options(configuration::ResolvedRunConfiguration) = configuration.solver
"""Вернуть настройки основного решателя из [конфигурации запуска YAML](@ref yaml-run-configurations)."""
production_options(configuration::ResolvedRunConfiguration) = configuration.production
"""Вернуть выбранные параметры алгоритма. См.
[схему выбора оптимизаций](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/20_optimization_decision_tree.md)."""
algorithm_options(configuration::ResolvedRunConfiguration) = configuration.algorithms
