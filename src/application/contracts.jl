const RUNTIME_CHECKPOINT_SCHEMA = "reference2019-runtime-checkpoint-v1"

"""Интерфейс сохранения данных, который реализуют хранилища запусков."""
abstract type AbstractRunRepository end

# Repository operations belong to the application boundary. Infrastructure
# adapters add methods without exposing their concrete type to the coordinator.
function initialize_run! end
function default_run_repository end
function run_workspace_directory end
function point_workspace_directory end
function write_run_status! end
function read_point_status end
function write_point_status! end
function write_point_result! end
function read_point_result end
function point_result_sha256 end
function write_run_result! end
function read_run_result end
function write_provenance! end
function write_disk_estimate! end
function append_event! end
function read_events end
function write_timing_session! end
function aggregate_timing_sessions! end
"""
    verify_result_artifacts!(repository, run_id, artifacts)

Перед повторным использованием завершённой точки проверить все файлы,
для которых обязательна проверка целостности. Хранилище отклоняет отсутствующие
файлы, символические ссылки, пути за пределами каталога запуска и файлы
с несовпадающими размером или контрольной суммой.
"""
function verify_result_artifacts! end

"""Интерфейс сериализации контрольных точек решателя."""
abstract type AbstractCheckpointCodec end

"""
Адаптер для пары функций записи и чтения контрольной точки. Хранилище
определяет формат фиксации данных и служебной записи.
"""
struct CallbackCheckpointCodec <: AbstractCheckpointCodec
    extension::String
    writer::Function
    reader::Function
    validator::Function
    function CallbackCheckpointCodec(
        extension::AbstractString,
        writer::Function,
        reader::Function;
        validator::Function = state -> true,
    )
        ext = lowercase(String(extension))
        occursin(r"^[a-z0-9]{1,12}$", ext) ||
            throw(ArgumentError("checkpoint extension must be portable and omit the dot"))
        new(ext, writer, reader, validator)
    end
end

"""
Неизменяемая ссылка на одно зафиксированное поколение контрольной точки.

Поля путей интерпретирует адаптер. Координатор передаёт их без преобразований.
"""
struct CheckpointReference
    run_id::String
    point_id::String
    generation::Int
    attempt::Int
    payload_path::String
    metadata_path::String
    sha256::String
    kind::String
    iteration::Union{Nothing,Int}
end

"""Состояние с проверенной контрольной суммой, полученное через интерфейс контрольных точек."""
struct LoadedCheckpoint
    reference::CheckpointReference
    state::Any
    metadata::Dict{String,Any}
end

"""Ошибка при отсутствии или повреждении поколения контрольной точки."""
struct CheckpointIntegrityError <: Exception
    path::String
    message::String
end

"""Ошибка нарушения целостности опубликованного файла результатов."""
struct ArtifactIntegrityError <: Exception
    path::String
    message::String
end

Base.showerror(io::IO, error::CheckpointIntegrityError) =
    print(io, "checkpoint integrity error at ", error.path, ": ", error.message)
Base.showerror(io::IO, error::ArtifactIntegrityError) =
    print(io, "artifact integrity error at ", error.path, ": ", error.message)

function default_checkpoint_codec end
function save_runtime_checkpoint! end
function load_latest_checkpoint end

const _PORTABLE_NAME = r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$"
const _CONTENT_ID = r"^[a-z][a-z0-9_-]*-[0-9a-f]{64}$"
const _SHA256_DIGEST = r"^[0-9a-f]{64}$"

function _portable_name(value::AbstractString, what::AbstractString)
    text = String(value)
    occursin(_PORTABLE_NAME, text) || throw(
        ArgumentError("$what must match $(_PORTABLE_NAME.pattern), got $(repr(text))"),
    )
    return text
end

"""Проверить, что интерфейс приложения вернул SHA-256 в нижнем регистре."""
function validate_sha256_digest(digest, kind::AbstractString)
    digest isa AbstractString || throw(
        ArgumentError("$kind must be a lowercase SHA-256 string, got $(typeof(digest))"),
    )
    value = String(digest)
    occursin(_SHA256_DIGEST, value) ||
        throw(ArgumentError("$kind is not a lowercase SHA-256 digest: $(repr(value))"))
    return value
end

"""Проверить полный идентификатор содержимого на границе приложения."""
function validate_content_identifier(identifier::AbstractString, kind::AbstractString)
    value = String(identifier)
    occursin(_CONTENT_ID, value) ||
        throw(ArgumentError("$kind is not a full content identifier: $(repr(value))"))
    return value
end

"""
    portable_metadata(value)

Преобразовать служебные сведения приложения в независимое от языка
дерево скаляров, векторов и отображений, которое принимает хранилище.
Адаптер может записать дерево в YAML, JSON или другом формате.
"""
function portable_metadata(value)
    if value isa AbstractDict || value isa NamedTuple
        mapping = _canonical_mapping(value)
        return Dict{String,Any}(key => portable_metadata(child) for (key, child) in mapping)
    elseif value isa AbstractVector || value isa Tuple
        return Any[portable_metadata(child) for child in value]
    elseif value isa Pair
        return Dict{String,Any}(
            "key" => portable_metadata(first(value)),
            "value" => portable_metadata(last(value)),
        )
    elseif value isa Symbol
        return String(value)
    elseif value isa AbstractFloat
        if !isfinite(value)
            representation =
                isnan(value) ? "nan" :
                (signbit(value) ? "negative_infinity" : "positive_infinity")
            return Dict{String,Any}("__reference2019_nonfinite_float__" => representation)
        end
        return value
    elseif value isa Union{Nothing,Bool,Integer,AbstractString}
        return value
    end
    throw(ArgumentError("unsupported portable metadata type $(typeof(value))"))
end

function _write_canonical_token(io::IO, tag::AbstractString, payload::AbstractString)
    print(io, tag, ncodeunits(payload), ':', payload)
    return nothing
end

"""
    canonical_bytes(value)

Вернуть независимое от языка представление в байтах для вычисления
идентификаторов содержимого. Ключи отображений сортируются как строки UTF-8.
Разрядность целых чисел не учитывается. Конечные вещественные числа
представляются битами в формате IEEE-754 binary64. Неподдерживаемый объект
вызывает ошибку.
"""
function canonical_bytes(value)
    io = IOBuffer()
    _write_canonical(io, value)
    return take!(io)
end

_write_canonical(io::IO, ::Nothing) = print(io, "n;")
_write_canonical(io::IO, value::Bool) = print(io, value ? "b1;" : "b0;")
_write_canonical(io::IO, value::Integer) = _write_canonical_token(io, "i", string(value))

function _write_canonical(io::IO, value::AbstractFloat)
    number = Float64(value)
    isfinite(number) ||
        throw(ArgumentError("non-finite numbers are not valid content-identity inputs"))
    payload = string(reinterpret(UInt64, number); base = 16, pad = 16)
    return _write_canonical_token(io, "f", payload)
end

_write_canonical(io::IO, value::AbstractString) =
    _write_canonical_token(io, "s", String(value))
_write_canonical(io::IO, value::Symbol) = _write_canonical_token(io, "s", String(value))

function _canonical_mapping(value)
    mapping = Dict{String,Any}()
    for (key, child) in pairs(value)
        key isa Union{AbstractString,Symbol} || throw(
            ArgumentError(
                "content-identity mapping keys must be strings, got $(typeof(key))",
            ),
        )
        name = String(key)
        haskey(mapping, name) &&
            throw(ArgumentError("duplicate canonical mapping key $(repr(name))"))
        mapping[name] = child
    end
    return mapping
end

function _write_canonical(io::IO, value::Union{AbstractDict,NamedTuple})
    mapping = _canonical_mapping(value)
    print(io, 'm', length(mapping), '{')
    for key in sort!(collect(keys(mapping)))
        _write_canonical(io, key)
        _write_canonical(io, mapping[key])
    end
    print(io, '}')
    return nothing
end

function _write_canonical(io::IO, value::Union{AbstractVector,Tuple})
    print(io, 'a', length(value), '[')
    for child in value
        _write_canonical(io, child)
    end
    print(io, ']')
    return nothing
end

function _write_canonical(io::IO, value)
    throw(
        ArgumentError(
            "unsupported content-identity type $(typeof(value)); " *
            "convert it to a YAML scalar, vector, or mapping",
        ),
    )
end

"""Вернуть полный идентификатор содержимого на основе SHA-256 с переносимым префиксом."""
function content_id(prefix::AbstractString, value)
    name = lowercase(_portable_name(prefix, "content-id prefix"))
    digest = bytes2hex(SHA.sha256(canonical_bytes(value)))
    return "$name-$digest"
end

"""Вычислить SHA-256 файла потоковым чтением, сохраняя ограниченный объём занятой памяти."""
function file_sha256 end

function _normalised_relative_path(path::AbstractString, root::AbstractString)
    relative = relpath(abspath(path), abspath(root))
    first(splitpath(relative)) == ".." &&
        throw(ArgumentError("source file escapes fingerprint root: $path"))
    return replace(relative, '\\' => '/')
end

"""
    fingerprint_sources(paths; root)

Составить детерминированный манифест источников из относительных путей,
размеров в байтах и контрольных сумм SHA-256. Содержимое файлов в манифест не входит.
"""
function fingerprint_sources(paths; root::AbstractString = pwd())
    records = Dict{String,Any}[]
    for path in paths
        absolute = abspath(String(path))
        push!(
            records,
            Dict{String,Any}(
                "path" => _normalised_relative_path(absolute, root),
                "bytes" => filesize(absolute),
                "sha256" => file_sha256(absolute),
            ),
        )
    end
    sort!(records; by = record -> record["path"])
    paths_only = getindex.(records, "path")
    allunique(paths_only) ||
        throw(ArgumentError("source fingerprint contains duplicate relative paths"))
    return records
end

"""Одна явно заданная ось на определённом уровне вложенного перебора."""
struct SweepAxis
    name::String
    values::Vector{Any}
    function SweepAxis(name::AbstractString, values)
        axis_name = _portable_name(name, "sweep axis name")
        materialised = Any[deepcopy(value) for value in values]
        isempty(materialised) && throw(ArgumentError("sweep axis $axis_name has no values"))
        digests = [bytes2hex(SHA.sha256(canonical_bytes(value))) for value in materialised]
        allunique(digests) || throw(
            ArgumentError("sweep axis $axis_name contains duplicate canonical values"),
        )
        new(axis_name, materialised)
    end
end

"""Рекурсивное описание перебора на уровне приложения, состоящее из уровней и листьев."""
abstract type AbstractSweepSpec end

"""Имя задачи в листе на последнем уровне перебора."""
struct SweepLeaf <: AbstractSweepSpec
    name::String
    SweepLeaf(name::AbstractString = "solve") = new(_portable_name(name, "sweep leaf name"))
end

"""
Один уровень вложенного перебора. Оси на этом уровне образуют декартово
произведение. Элемент `child` обрабатывается для каждой комбинации. Так
задаётся вложенный перебор без привязки к циклам конкретного решателя.
"""
struct SweepLevel <: AbstractSweepSpec
    name::String
    axes::Vector{SweepAxis}
    child::AbstractSweepSpec
    function SweepLevel(name::AbstractString, axes, child::AbstractSweepSpec = SweepLeaf())
        level_name = _portable_name(name, "sweep level name")
        axis_values = SweepAxis[axis for axis in axes]
        isempty(axis_values) && throw(ArgumentError("sweep level $level_name has no axes"))
        names = getfield.(axis_values, :name)
        allunique(names) ||
            throw(ArgumentError("sweep level $level_name has duplicate axis names"))
        new(level_name, axis_values, child)
    end
end

"""Именованное дерево вложенного перебора."""
struct NestedSweepPlan
    name::String
    root::AbstractSweepSpec
    function NestedSweepPlan(name::AbstractString, root::AbstractSweepSpec)
        _validate_coordinate_paths!(Set{String}(), root)
        new(_portable_name(name, "sweep plan name"), root)
    end
end

_validate_coordinate_paths!(seen::Set{String}, ::SweepLeaf) = seen

function _validate_coordinate_paths!(seen::Set{String}, level::SweepLevel)
    for axis in level.axes
        path = "$(level.name).$(axis.name)"
        path in seen &&
            throw(ArgumentError("nested sweep repeats fully-qualified coordinate $path"))
        push!(seen, path)
    end
    _validate_coordinate_paths!(seen, level.child)
    return seen
end

function _sweep_spec_dict(spec::SweepLeaf)
    return Dict{String,Any}("kind" => "leaf", "name" => spec.name)
end

function _sweep_spec_dict(spec::SweepLevel)
    return Dict{String,Any}(
        "kind" => "level",
        "name" => spec.name,
        "axes" => [
            Dict{String,Any}("name" => axis.name, "values" => deepcopy(axis.values)) for
            axis in spec.axes
        ],
        "child" => _sweep_spec_dict(spec.child),
    )
end

function _sweep_spec_identity_dict(spec::SweepLeaf)
    return _sweep_spec_dict(spec)
end

function _sweep_spec_identity_dict(spec::SweepLevel)
    axes = Dict{String,Any}[]
    for axis in sort(spec.axes; by = axis -> axis.name)
        ordered_values = sort(
            deepcopy(axis.values);
            by = value -> bytes2hex(SHA.sha256(canonical_bytes(value))),
        )
        push!(axes, Dict{String,Any}("name" => axis.name, "values" => ordered_values))
    end
    return Dict{String,Any}(
        "kind" => "level",
        "name" => spec.name,
        "axes" => axes,
        "child" => _sweep_spec_identity_dict(spec.child),
    )
end

_sweep_plan_dict(plan::NestedSweepPlan) =
    Dict{String,Any}("name" => plan.name, "root" => _sweep_spec_dict(plan.root))

_sweep_plan_identity_dict(plan::NestedSweepPlan) =
    Dict{String,Any}("name" => plan.name, "root" => _sweep_spec_identity_dict(plan.root))

"""Вернуть проверенное число конечных точек вложенного перебора."""
function point_count(spec::SweepLeaf)
    return 1
end

function point_count(spec::SweepLevel)
    count = point_count(spec.child)
    for axis in spec.axes
        count = Base.checked_mul(count, length(axis.values))
    end
    return count
end

point_count(plan::NestedSweepPlan) = point_count(plan.root)

"""Устойчивое описание листа. Идентификатор определяется координатами точки."""
struct SweepPoint
    point_id::String
    ordinal::Int
    leaf::String
    coordinates::Vector{Pair{String,Any}}
end

function _coordinate_mapping(coordinates::Vector{Pair{String,Any}})
    result = Dict{String,Any}()
    for (name, value) in coordinates
        haskey(result, name) &&
            throw(ArgumentError("duplicate fully-qualified sweep coordinate $name"))
        result[name] = deepcopy(value)
    end
    return result
end

function _visit_axis_product!(
    callback::Function,
    axes::Vector{SweepAxis},
    level::String,
    index::Int,
    coordinates::Vector{Pair{String,Any}},
)
    if index > length(axes)
        callback(coordinates)
        return nothing
    end
    axis = axes[index]
    key = "$level.$(axis.name)"
    for value in axis.values
        push!(coordinates, key => deepcopy(value))
        _visit_axis_product!(callback, axes, level, index + 1, coordinates)
        pop!(coordinates)
    end
    return nothing
end

function _visit_sweep_leaves!(
    callback::Function,
    spec::SweepLeaf,
    coordinates::Vector{Pair{String,Any}},
)
    callback(spec.name, coordinates)
    return nothing
end

function _visit_sweep_leaves!(
    callback::Function,
    spec::SweepLevel,
    coordinates::Vector{Pair{String,Any}},
)
    _visit_axis_product!(spec.axes, spec.name, 1, coordinates) do current
        _visit_sweep_leaves!(callback, spec.child, current)
    end
    return nothing
end

"""Последовательно обойти точки, не размещая в памяти полное декартово произведение."""
function foreach_sweep_point(
    callback::Function,
    plan::NestedSweepPlan,
    run_id::AbstractString,
)
    occursin(_CONTENT_ID, run_id) ||
        throw(ArgumentError("run_id is not a content identifier: $run_id"))
    ordinal = Ref(0)
    _visit_sweep_leaves!(plan.root, Pair{String,Any}[]) do leaf, coordinates
        ordinal[] += 1
        copied = Pair{String,Any}[name => deepcopy(value) for (name, value) in coordinates]
        identity = Dict{String,Any}(
            "run_id" => String(run_id),
            "plan" => plan.name,
            "leaf" => leaf,
            "coordinates" => _coordinate_mapping(copied),
        )
        callback(SweepPoint(content_id("point", identity), ordinal[], leaf, copied))
    end
    return nothing
end

"""Разместить в памяти план ограниченного размера. Большие планы обходятся через `foreach_sweep_point`."""
function planned_points(
    plan::NestedSweepPlan,
    run_id::AbstractString;
    maximum_points::Integer = 1_000_000,
)
    total = point_count(plan)
    total <= maximum_points || throw(
        ArgumentError("refusing to materialise $total points; use foreach_sweep_point"),
    )
    result = SweepPoint[]
    sizehint!(result, total)
    foreach_sweep_point(plan, run_id) do point
        push!(result, point)
    end
    return result
end

"""Полный идентификатор содержимого вместе с кратким идентификатором запуска."""
struct RunIdentity
    run_id::String
    digest::String
    schema::String
    canonical_bytes_count::Int
end

"""Вычислить устойчивый идентификатор SHA-256 по научной постановке, программному окружению и набору точек."""
function derive_run_identity(
    scientific_identity,
    software_identity,
    plan::NestedSweepPlan;
    schema::AbstractString = "reference2019-run-identity-v1",
)
    payload = Dict{String,Any}(
        "schema" => String(schema),
        "scientific" => deepcopy(scientific_identity),
        "software" => deepcopy(software_identity),
        # Axis/value iteration order is operational. The identity encodes the
        # same Cartesian set in canonical order so a reordered resume keeps
        # the same run and point ids.
        "sweep" => _sweep_plan_identity_dict(plan),
    )
    bytes = canonical_bytes(payload)
    digest = bytes2hex(SHA.sha256(bytes))
    return RunIdentity("run-$digest", digest, String(schema), length(bytes))
end

"""
Неизменяемый запрос приложения. В `scientific_identity` и `software_identity`
входят физика, численные настройки, алгоритмы, контрольные данные источников
и дерево перебора. Названия и подписи в идентификатор содержимого не входят.
"""
struct RunDefinition
    plan::NestedSweepPlan
    scientific_identity::Dict{String,Any}
    software_identity::Dict{String,Any}
    labels::Dict{String,Any}
    identity::RunIdentity
end

function RunDefinition(
    plan::NestedSweepPlan;
    scientific_identity,
    software_identity,
    labels = Dict{String,Any}(),
    identity_schema::AbstractString = "reference2019-run-identity-v1",
)
    scientific = _canonical_mapping(scientific_identity)
    software = _canonical_mapping(software_identity)
    label_mapping = _canonical_mapping(labels)
    identity = derive_run_identity(scientific, software, plan; schema = identity_schema)
    return RunDefinition(
        plan,
        deepcopy(scientific),
        deepcopy(software),
        deepcopy(label_mapping),
        identity,
    )
end

function run_definition_dict(definition::RunDefinition)
    return Dict{String,Any}(
        "schema" => "reference2019-application-run-v1",
        "run_id" => definition.identity.run_id,
        "identity" => Dict{String,Any}(
            "algorithm" => "sha256",
            "digest" => definition.identity.digest,
            "schema" => definition.identity.schema,
            "canonical_bytes" => definition.identity.canonical_bytes_count,
        ),
        "scientific_identity" => deepcopy(definition.scientific_identity),
        "software_identity" => deepcopy(definition.software_identity),
        "sweep_identity" => _sweep_plan_identity_dict(definition.plan),
        "execution_plan_file" => "execution_plan.yaml",
        "display_labels_file" => "display_labels.yaml",
        "point_count" => point_count(definition.plan),
    )
end

"""
Политика долговременного хранения данных итераций. Скалярные события
сохраняются всегда. Политика задаёт отбор объёмных снимков состояния
и ограничивает объём данных для отображения.
"""
struct IterationRetentionPolicy
    snapshot_mode::Symbol
    snapshot_stride::Int
    keep_first::Int
    keep_last::Int
    function IterationRetentionPolicy(;
        snapshot_mode::Symbol = :stride,
        snapshot_stride::Integer = 25,
        keep_first::Integer = 2,
        keep_last::Integer = 2,
    )
        snapshot_mode in (:all, :stride, :logarithmic, :none) ||
            throw(ArgumentError("snapshot_mode must be all, stride, logarithmic, or none"))
        snapshot_stride > 0 || throw(ArgumentError("snapshot_stride must be positive"))
        keep_first >= 0 && keep_last >= 0 ||
            throw(ArgumentError("keep_first and keep_last cannot be negative"))
        new(snapshot_mode, Int(snapshot_stride), Int(keep_first), Int(keep_last))
    end
end

function _is_logarithmic_milestone(iteration::Int)
    iteration <= 0 && return false
    magnitude = 1
    while magnitude <= iteration
        for multiplier in (1, 2, 5)
            multiplier * magnitude == iteration && return true
        end
        magnitude > typemax(Int) ÷ 10 && break
        magnitude *= 10
    end
    return false
end

function should_retain_snapshot(
    policy::IterationRetentionPolicy,
    iteration::Integer;
    total::Union{Nothing,Integer} = nothing,
    terminal::Bool = false,
)
    i = Int(iteration)
    i >= 1 || throw(ArgumentError("iteration must be positive"))
    n = total === nothing ? nothing : Int(total)
    n === nothing || (n >= i || throw(ArgumentError("iteration cannot exceed total")))
    terminal && return policy.snapshot_mode !== :none
    i <= policy.keep_first && return policy.snapshot_mode !== :none
    if n !== nothing && i > max(0, n - policy.keep_last)
        return policy.snapshot_mode !== :none
    end
    policy.snapshot_mode === :all && return true
    policy.snapshot_mode === :none && return false
    policy.snapshot_mode === :stride && return i % policy.snapshot_stride == 0
    return _is_logarithmic_milestone(i)
end

function retained_snapshot_count(policy::IterationRetentionPolicy, total::Integer)
    count = Int(total)
    count >= 0 || throw(ArgumentError("total cannot be negative"))
    return sum(
        should_retain_snapshot(policy, i; total = count, terminal = i == count) for
        i = 1:count
    )
end

"""Модель затрат дискового пространства в байтах до начала записи результатов."""
struct DiskBudgetModel
    fixed_run_bytes::Int
    result_metadata_bytes_per_point::Int
    event_bytes::Int
    events_per_iteration::Int
    checkpoint_payload_bytes::Int
    checkpoint_metadata_bytes::Int
    additional_artifacts_bytes_per_point::Int
    safety_factor::Float64
    function DiskBudgetModel(;
        fixed_run_bytes::Integer = 1_000_000,
        result_metadata_bytes_per_point::Integer = 16_000,
        event_bytes::Integer = 2_000,
        events_per_iteration::Integer = 1,
        checkpoint_payload_bytes::Integer,
        checkpoint_metadata_bytes::Integer = 4_000,
        additional_artifacts_bytes_per_point::Integer = 0,
        safety_factor::Real = 1.25,
    )
        values = (
            fixed_run_bytes,
            result_metadata_bytes_per_point,
            event_bytes,
            events_per_iteration,
            checkpoint_payload_bytes,
            checkpoint_metadata_bytes,
            additional_artifacts_bytes_per_point,
        )
        all(value >= 0 for value in values) ||
            throw(ArgumentError("disk budget byte/count values cannot be negative"))
        safety_factor >= 1 ||
            throw(ArgumentError("disk budget safety_factor must be at least one"))
        new(
            Int(fixed_run_bytes),
            Int(result_metadata_bytes_per_point),
            Int(event_bytes),
            Int(events_per_iteration),
            Int(checkpoint_payload_bytes),
            Int(checkpoint_metadata_bytes),
            Int(additional_artifacts_bytes_per_point),
            Float64(safety_factor),
        )
    end
end

"""Проверяемая оценка по составляющим, которую возвращает [`estimate_disk`](@ref)."""
struct DiskEstimate
    point_count::Int
    iterations_per_point::Int
    snapshots_per_point::Int
    components::Dict{String,Int}
    subtotal_bytes::Int
    estimated_bytes::Int
    safety_factor::Float64
end

"""Оценить требуемый объём хранения до записи результатов перебора."""
function estimate_disk(
    plan::NestedSweepPlan,
    model::DiskBudgetModel,
    retention::IterationRetentionPolicy;
    iterations_per_point::Integer,
)
    iterations = Int(iterations_per_point)
    iterations >= 0 || throw(ArgumentError("iterations_per_point cannot be negative"))
    points = point_count(plan)
    snapshots = retained_snapshot_count(retention, iterations)
    checkpoint_bytes =
        Base.checked_add(model.checkpoint_payload_bytes, model.checkpoint_metadata_bytes)
    components = Dict{String,Int}(
        "fixed_run" => model.fixed_run_bytes,
        "point_results" =>
            Base.checked_mul(points, model.result_metadata_bytes_per_point),
        "iteration_events" => Base.checked_mul(
            Base.checked_mul(points, iterations),
            Base.checked_mul(model.events_per_iteration, model.event_bytes),
        ),
        "state_snapshots" =>
            Base.checked_mul(Base.checked_mul(points, snapshots), checkpoint_bytes),
        "additional_artifacts" =>
            Base.checked_mul(points, model.additional_artifacts_bytes_per_point),
    )
    subtotal = foldl(Base.checked_add, values(components); init = 0)
    estimated = ceil(Int, subtotal * model.safety_factor)
    return DiskEstimate(
        points,
        iterations,
        snapshots,
        components,
        subtotal,
        estimated,
        model.safety_factor,
    )
end

function disk_estimate_dict(estimate::DiskEstimate)
    return Dict{String,Any}(
        "schema" => "reference2019-disk-estimate-v1",
        "point_count" => estimate.point_count,
        "iterations_per_point" => estimate.iterations_per_point,
        "snapshots_per_point" => estimate.snapshots_per_point,
        "components_bytes" => deepcopy(estimate.components),
        "subtotal_bytes" => estimate.subtotal_bytes,
        "safety_factor" => estimate.safety_factor,
        "estimated_bytes" => estimate.estimated_bytes,
        "estimated_gib" => estimate.estimated_bytes / 1024.0^3,
    )
end
