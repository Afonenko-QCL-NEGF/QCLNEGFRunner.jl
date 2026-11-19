"""
Одно скалярное значение в [`ProgressSnapshot`](@ref).

Число `value` должно быть выражено в указанных единицах `unit`. Единицы
хранятся отдельно от числа, а CSV сохраняет полное представление `Float64`.
При выводе в терминал число может округляться.

См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
struct ProgressMetric
    name::Symbol
    value::Union{Float64,Int64,Bool,String}
    unit::String
end

# The automatically generated constructor has the union-typed signature
# `(Symbol, Union{...}, String)`.  Exact forwarding methods remove dispatch
# ambiguities between that constructor and the convenient abstract adapters
# below (notably because `Bool <: Integer` in Julia).
for T in (Float64, Int64, Bool, String)
    @eval ProgressMetric(name::Symbol, value::$T, unit::String) = invoke(
        ProgressMetric,
        Tuple{Symbol,Union{Float64,Int64,Bool,String},String},
        name,
        value,
        unit,
    )
end

ProgressMetric(name::Symbol, value::AbstractFloat, unit::AbstractString = "") =
    ProgressMetric(name, Float64(value), String(unit))
ProgressMetric(name::Symbol, value::Integer, unit::AbstractString = "") =
    ProgressMetric(name, Int64(value), String(unit))
ProgressMetric(name::Symbol, value::Bool, unit::AbstractString = "") =
    ProgressMetric(name, value, String(unit))
ProgressMetric(name::Symbol, value::AbstractString, unit::AbstractString = "") =
    ProgressMetric(name, String(value), String(unit))

"""
Неизменяемое описание одного события о ходе расчёта.

`stage_path` и `labels` задают путь от корня исследования до текущей стадии.
Для неитерационной стадии `iteration`, `total` и `fraction` равны `nothing`.
Тип события принимает одно из значений `:begin`, `:progress` или `:end`.

См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
struct ProgressSnapshot
    sequence::Int
    event::Symbol
    stage_path::Vector{Symbol}
    labels::Vector{String}
    iteration::Union{Nothing,Int}
    total::Union{Nothing,Int}
    fraction::Union{Nothing,Float64}
    elapsed_seconds::Float64
    status::Symbol
    message::String
    metrics::Vector{ProgressMetric}
end

mutable struct _ProgressStageFrame
    stage::Symbol
    label::String
    started_ns::Int
    iteration::Union{Nothing,Int}
    total::Union{Nothing,Int}
end

const _PROGRESS_STAGE_PARENT = Dict{Symbol,Tuple{Vararg{Symbol}}}(
    :study => (),
    :sweep => (:study,),
    :point => (:sweep, :study),
    :poisson => (:point,),
    :scba => (:poisson,),
)

"""
    ProgressReporter(; human_io=stdout, csv_io=nothing,
                     significant_digits=4,
                     on_snapshot=identity, clock_ns=time_ns,
                     strict_hierarchy=true)

Создаёт явно настроенный приёмник событий о ходе расчёта. Компактный поток
предназначен для терминала. Нормализованный CSV содержит по строке на каждую
метрику и сохраняет полное представление `Float64`. Для панели наблюдения
можно опустить оба потока и использовать только `on_snapshot`.

Параметр `clock_ns` позволяет подменить источник времени в тестах и при
воспроизведении событий. Терминальный поток показывает начало и конец стадий.
Все итерации доступны в CSV и через обратные вызовы.

См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
mutable struct ProgressReporter
    human_io::Union{Nothing,IO}
    csv_io::Union{Nothing,IO}
    significant_digits::Int
    on_snapshot::Function
    clock_ns::Function
    strict_hierarchy::Bool
    stack::Vector{_ProgressStageFrame}
    sequence::Int
    last_snapshot::Union{Nothing,ProgressSnapshot}
    owns_csv_io::Bool
    machine_directory::Union{Nothing,String}
    session_id::String
    timing_samples::Dict{String,Vector{Float64}}
    timing_calls::Dict{String,Int}
    timing_summary::Bool
end

function ProgressReporter(;
    human_io::Union{Nothing,IO} = stdout,
    csv_io::Union{Nothing,IO} = nothing,
    significant_digits::Integer = 4,
    on_snapshot::Function = identity,
    clock_ns::Function = () -> Int(time_ns()),
    strict_hierarchy::Bool = true,
    machine_directory::Union{Nothing,AbstractString} = nothing,
    append::Bool = false,
    timing_summary::Bool = csv_io !== nothing,
    _owns_csv_io::Bool = false,
    _write_header::Bool = true,
)
    2 ≤ significant_digits ≤ 17 ||
        throw(ArgumentError("significant_digits must lie in 2:17"))
    reporter = ProgressReporter(
        human_io,
        csv_io,
        Int(significant_digits),
        on_snapshot,
        clock_ns,
        strict_hierarchy,
        _ProgressStageFrame[],
        0,
        nothing,
        _owns_csv_io,
        nothing,
        string(time_ns(), "-", getpid()),
        Dict{String,Vector{Float64}}(),
        Dict{String,Int}(),
        timing_summary,
    )
    if machine_directory!==nothing
        directory=abspath(machine_directory)
        islink(directory) &&
            throw(ArgumentError("machine telemetry directory cannot be a symlink"))
        ispath(directory) &&
            !isdir(directory) &&
            throw(ArgumentError("machine telemetry directory is not a directory"))
        mkpath(directory)
        for name in ("events.jsonl", "progress.yaml", "timings.csv", "timing_summary.yaml")
            companion=joinpath(directory, name)
            islink(companion) &&
                throw(ArgumentError("machine telemetry companion cannot be a symlink"))
            if !append && isfile(companion)
                rm(companion)
            end
        end
        latest=joinpath(directory, "progress.yaml")
        if append && isfile(latest)
            saved=YAML.load_file(latest; dicttype = Dict{String,Any})
            sequence=get(saved, "sequence", nothing)
            sequence isa Integer && sequence>=0 ||
                throw(ArgumentError("invalid machine telemetry sequence"))
            reporter.sequence=Int(sequence)
        end
        reporter.machine_directory=directory
    end
    if csv_io !== nothing && _write_header
        println(
            csv_io,
            join(
                (
                    "sequence",
                    "event",
                    "stage_path",
                    "stage",
                    "label",
                    "iteration",
                    "total",
                    "fraction",
                    "elapsed_seconds",
                    "status",
                    "metric",
                    "value",
                    "value_type",
                    "unit",
                    "message",
                ),
                ',',
            ),
        )
        flush(csv_io)
    end
    return reporter
end

"""
    ProgressReporter(csv_path; append=false, kwargs...)

Открывает машинный журнал событий, которым управляет объект `reporter`.
После завершения исследования вызовите `close(reporter)`, желательно в блоке
`try`/`finally`. В режиме добавления заголовок записывается только в новый
или пустой файл. Нумерация продолжается со следующего номера после последнего
сохранённого события, поэтому события возобновлённого расчёта различимы.
"""
function ProgressReporter(csv_path::AbstractString; append::Bool = false, kwargs...)
    path = abspath(csv_path)
    basename(path) in
    ("events.jsonl", "progress.yaml", "timings.csv", "timing_summary.yaml") &&
        throw(ArgumentError("reserved machine telemetry filename"))
    mkpath(dirname(path))
    write_header = !append || !isfile(path) || filesize(path) == 0
    initial_sequence = append && isfile(path) ? _last_progress_sequence(path) : 0
    stream = open(path, append ? "a" : "w")
    try
        reporter = ProgressReporter(;
            csv_io = stream,
            _owns_csv_io = true,
            _write_header = write_header,
            kwargs...,
        )
        reporter.sequence = initial_sequence
        reporter.machine_directory = dirname(path)
        if !append
            for name in
                ("events.jsonl", "progress.yaml", "timings.csv", "timing_summary.yaml")
                companion = joinpath(dirname(path), name)
                companion == path && throw(
                    ArgumentError(
                        "CSV path collides with reserved machine telemetry companion",
                    ),
                )
                islink(companion) &&
                    throw(ArgumentError("machine telemetry companion cannot be a symlink"))
                isfile(companion) && rm(companion)
            end
        end
        return reporter
    catch
        close(stream)
        rethrow()
    end
end

function _last_progress_sequence(path::AbstractString)
    maximum_sequence = 0
    for line in eachline(path)
        matched = match(r"^(\d+),", line)
        matched === nothing && continue
        sequence = tryparse(Int, only(matched.captures))
        sequence === nothing || (maximum_sequence = max(maximum_sequence, sequence))
    end
    return maximum_sequence
end

function Base.close(reporter::ProgressReporter)
    reporter.csv_io === nothing || !isopen(reporter.csv_io) || flush(reporter.csv_io)
    reporter.human_io === nothing || !isopen(reporter.human_io) || flush(reporter.human_io)
    if reporter.owns_csv_io && reporter.csv_io !== nothing && isopen(reporter.csv_io)
        close(reporter.csv_io)
    end
    return nothing
end

"""
Возвращает последний неизменяемый снимок события.
См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
latest_progress(reporter::ProgressReporter) = reporter.last_snapshot

function _normalise_progress_metrics(metrics)
    result = ProgressMetric[]
    if metrics === nothing
        return result
    elseif metrics isa ProgressMetric
        push!(result, metrics)
    elseif metrics isa NamedTuple
        for name in propertynames(metrics)
            push!(result, ProgressMetric(name, getproperty(metrics, name)))
        end
    elseif metrics isa AbstractDict
        for (name, value) in metrics
            push!(result, ProgressMetric(Symbol(name), value))
        end
    else
        for metric in metrics
            metric isa ProgressMetric ||
                throw(ArgumentError("metrics must contain ProgressMetric values"))
            push!(result, metric)
        end
    end
    sort!(result; by = metric -> String(metric.name))
    names = getfield.(result, :name)
    allunique(names) || throw(ArgumentError("progress metric names must be unique"))
    return result
end

function _validate_progress_position(iteration, total)
    iteration === nothing && total === nothing && return nothing, nothing, nothing
    iteration === nothing &&
        throw(ArgumentError("iteration is required when total is supplied"))
    i = Int(iteration)
    i ≥ 0 || throw(ArgumentError("iteration cannot be negative"))
    if total === nothing
        return i, nothing, nothing
    end
    n = Int(total)
    n > 0 || throw(ArgumentError("total must be positive"))
    i ≤ n || throw(ArgumentError("iteration cannot exceed total"))
    return i, n, i / n
end

function _validate_stage_parent(reporter::ProgressReporter, stage::Symbol)
    reporter.strict_hierarchy || return nothing
    haskey(_PROGRESS_STAGE_PARENT, stage) ||
        throw(ArgumentError("unknown progress stage :$stage"))
    parents = _PROGRESS_STAGE_PARENT[stage]
    if isempty(reporter.stack)
        stage === :study || throw(ArgumentError("the root progress stage must be :study"))
    else
        parent = reporter.stack[end].stage
        parent in parents ||
            throw(ArgumentError("progress stage :$stage cannot be nested below :$parent"))
    end
    return nothing
end

_progress_value_type(value::Float64) = "float64"
_progress_value_type(value::Int64) = "int64"
_progress_value_type(value::Bool) = "bool"
_progress_value_type(value::String) = "string"

_progress_full(value::Float64) = repr(value)
_progress_full(value::Int64) = string(value)
_progress_full(value::Bool) = string(value)
_progress_full(value::String) = value

"""
Форматирует одно числовое значение для терминала.
См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
function compact_number(value::Real; significant_digits::Integer = 4)
    2 ≤ significant_digits ≤ 17 ||
        throw(ArgumentError("significant_digits must lie in 2:17"))
    value isa Integer && return string(value)
    x = Float64(value)
    isnan(x) && return "NaN"
    isinf(x) && return signbit(x) ? "-Inf" : "Inf"
    x == 0 && return "0"
    rounded = round(x; sigdigits = Int(significant_digits))
    rounded == 0 && return "0"
    return string(rounded)
end

function _observability_csv_field(value)
    text = string(value)
    if occursin(',', text) ||
       occursin('"', text) ||
       occursin('\n', text) ||
       occursin('\r', text)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
    return text
end

function _emit_progress_csv!(reporter::ProgressReporter, snapshot::ProgressSnapshot)
    io = reporter.csv_io
    io === nothing && return nothing
    rows =
        isempty(snapshot.metrics) ? Union{Nothing,ProgressMetric}[nothing] :
        Union{Nothing,ProgressMetric}[snapshot.metrics...]
    for metric in rows
        values = (
            snapshot.sequence,
            snapshot.event,
            join(String.(snapshot.stage_path), '/'),
            snapshot.stage_path[end],
            snapshot.labels[end],
            snapshot.iteration === nothing ? "" : snapshot.iteration,
            snapshot.total === nothing ? "" : snapshot.total,
            snapshot.fraction === nothing ? "" : repr(snapshot.fraction),
            repr(snapshot.elapsed_seconds),
            snapshot.status,
            metric === nothing ? "" : metric.name,
            metric === nothing ? "" : _progress_full(metric.value),
            metric === nothing ? "" : _progress_value_type(metric.value),
            metric === nothing ? "" : metric.unit,
            snapshot.message,
        )
        println(io, join(_observability_csv_field.(values), ','))
    end
    flush(io)
    return nothing
end

_progress_stage_title(stage::Symbol) =
    stage === :poisson ? "Poisson" :
    stage === :scba ? "SCBA" : uppercasefirst(String(stage))

_progress_has_warning(snapshot::ProgressSnapshot) =
    any(metric->metric.name === :warning_code, snapshot.metrics)

function _emit_progress_human!(reporter::ProgressReporter, snapshot::ProgressSnapshot)
    io = reporter.human_io
    io === nothing && return nothing
    # Human journal contains lifecycle only. Every iteration remains in the machine stream.
    snapshot.event === :progress && !_progress_has_warning(snapshot) && return nothing
    indent = repeat("  ", length(snapshot.stage_path) - 1)
    marker =
        snapshot.event === :begin ? "▶" :
        snapshot.event === :end ? (snapshot.status === :completed ? "✓" : "■") : "⚠"
    position = if snapshot.iteration === nothing
        ""
    elseif snapshot.total === nothing
        " $(snapshot.iteration)"
    else
        percent = compact_number(
            100 * something(snapshot.fraction, 0.0);
            significant_digits = min(reporter.significant_digits, 5),
        )
        " $(snapshot.iteration)/$(snapshot.total) ($(percent)%)"
    end
    title = _progress_stage_title(snapshot.stage_path[end])
    label = isempty(snapshot.labels[end]) ? "" : " — $(snapshot.labels[end])"
    strings = String["$indent$marker $title$position$label"]
    isempty(snapshot.message) || push!(strings, snapshot.message)
    if snapshot.event === :end
        snapshot.status === :completed || push!(strings, "status=$(snapshot.status)")
        push!(
            strings,
            "elapsed=" *
            compact_number(
                snapshot.elapsed_seconds;
                significant_digits = reporter.significant_digits,
            ) *
            " s",
        )
    end
    println(io, join(strings, " | "))
    flush(io)
    return nothing
end

function _make_progress_snapshot!(
    reporter::ProgressReporter,
    event::Symbol,
    frame::_ProgressStageFrame;
    iteration = frame.iteration,
    total = frame.total,
    metrics = nothing,
    status::Symbol = :running,
    message::AbstractString = "",
)
    i, n, fraction = _validate_progress_position(iteration, total)
    now = Int(reporter.clock_ns())
    now ≥ frame.started_ns || throw(ArgumentError("progress clock must be monotone"))
    reporter.sequence += 1
    snapshot = ProgressSnapshot(
        reporter.sequence,
        event,
        [item.stage for item in reporter.stack],
        [item.label for item in reporter.stack],
        i,
        n,
        fraction,
        (now - frame.started_ns) * 1e-9,
        status,
        String(message),
        _normalise_progress_metrics(metrics),
    )
    reporter.last_snapshot = snapshot
    _emit_progress_csv!(reporter, snapshot)
    _emit_progress_human!(reporter, snapshot)
    _emit_machine_progress!(reporter, snapshot)
    reporter.on_snapshot(snapshot)
    return snapshot
end

"""
    begin_progress_stage!(reporter, stage; label="", iteration=nothing,
                          total=nothing, metrics=nothing, message="")

Проверяет стадию, добавляет её в иерархию и публикует снимок `:begin`.

См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
function begin_progress_stage!(
    reporter::ProgressReporter,
    stage::Symbol;
    label::AbstractString = "",
    iteration = nothing,
    total = nothing,
    metrics = nothing,
    message::AbstractString = "",
)
    _validate_stage_parent(reporter, stage)
    i, n, _ = _validate_progress_position(iteration, total)
    frame = _ProgressStageFrame(stage, String(label), Int(reporter.clock_ns()), i, n)
    push!(reporter.stack, frame)
    try
        return _make_progress_snapshot!(
            reporter,
            :begin,
            frame;
            iteration = i,
            total = n,
            metrics,
            message,
        )
    catch
        pop!(reporter.stack)
        rethrow()
    end
end

"""
    update_progress!(reporter; iteration=nothing, total=nothing,
                     metrics=nothing, message="")

Обновляет текущую стадию. Без `total` используется общее число итераций,
заданное в начале стадии. Частота записи машинных событий не ограничивается.

См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
function update_progress!(
    reporter::ProgressReporter;
    iteration = nothing,
    total = nothing,
    metrics = nothing,
    message::AbstractString = "",
)
    isempty(reporter.stack) &&
        throw(ArgumentError("cannot update progress without an active stage"))
    frame = reporter.stack[end]
    use_iteration = iteration === nothing ? frame.iteration : iteration
    use_total = total === nothing ? frame.total : total
    i, n, _ = _validate_progress_position(use_iteration, use_total)
    if frame.iteration !== nothing && i !== nothing && i < frame.iteration
        throw(ArgumentError("stage iteration must be monotone"))
    end
    frame.iteration = i
    frame.total = n
    return _make_progress_snapshot!(
        reporter,
        :progress,
        frame;
        iteration = i,
        total = n,
        metrics,
        message,
    )
end

"""
    end_progress_stage!(reporter, stage; status=:completed, ...)

Публикует итоговый снимок и закрывает указанную текущую стадию. Стадии
закрываются в порядке, обратном открытию. Этот порядок защищает сводку серии
от ошибочной регистрации сбойной точки SCBA как успешного завершения серии.

См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
function end_progress_stage!(
    reporter::ProgressReporter,
    stage::Symbol;
    status::Symbol = :completed,
    iteration = nothing,
    total = nothing,
    metrics = nothing,
    message::AbstractString = "",
)
    isempty(reporter.stack) &&
        throw(ArgumentError("cannot end progress without an active stage"))
    frame = reporter.stack[end]
    frame.stage === stage ||
        throw(ArgumentError("cannot end :$stage while :$(frame.stage) is active"))
    use_iteration = iteration === nothing ? frame.iteration : iteration
    use_total = total === nothing ? frame.total : total
    snapshot = _make_progress_snapshot!(
        reporter,
        :end,
        frame;
        iteration = use_iteration,
        total = use_total,
        metrics,
        status,
        message,
    )
    pop!(reporter.stack)
    return snapshot
end

function _observability_atomic_text(path::AbstractString, writer::Function)
    target = abspath(path)
    mkpath(dirname(target))
    temporary, stream = mktemp(dirname(target))
    try
        writer(stream)
        close(stream)
        _atomic_replace_file(temporary, target)
    catch
        isopen(stream) && close(stream)
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return target
end

# Julia's `do` syntax passes the anonymous function as the first positional
# argument. Keep the path-first method useful for explicit calls and provide
# the natural `f(path) do ... end` order used by snapshot/report writers.
_observability_atomic_text(writer::Function, path::AbstractString) =
    _observability_atomic_text(path, writer)

"""
    save_progress_snapshot(path, snapshot)

Атомарно заменяет CSV со снимком одного события в длинном формате. Файл
пригоден для наблюдения за обновлениями или простой панели. Числа сохраняют
полную точность.

См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
function save_progress_snapshot(path::AbstractString, snapshot::ProgressSnapshot)
    return _observability_atomic_text(path) do stream
        temporary_reporter = ProgressReporter(;
            human_io = nothing,
            csv_io = stream,
            on_snapshot = identity,
            clock_ns = () -> 0,
            strict_hierarchy = false,
        )
        _emit_progress_csv!(temporary_reporter, snapshot)
    end
end

_progress_html_escape(value) =
    replace(string(value), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

function _progress_metric(snapshot::ProgressSnapshot, name::Symbol)
    match = findfirst(metric -> metric.name === name, snapshot.metrics)
    return match === nothing ? nothing : snapshot.metrics[match]
end

function _progress_svg_series(snapshots, name::Symbol; width = 760, height = 190)
    points = Tuple{Float64,Float64}[]
    for snapshot in snapshots
        snapshot.event === :progress || continue
        snapshot.iteration === nothing && continue
        metric = _progress_metric(snapshot, name)
        metric === nothing && continue
        metric.value isa Real || continue
        value = Float64(metric.value)
        isfinite(value) && value > 0 || continue
        push!(points, (Float64(snapshot.iteration), log10(value)))
    end
    isempty(points) && return ""
    xmin, xmax = extrema(first.(points))
    ymin, ymax = extrema(last.(points))
    xmax == xmin && (xmax = xmin + 1)
    ymax == ymin && (ymax = ymin + 1)
    coordinates = String[]
    for (x, y) in points
        px = 12 + (width - 24) * (x - xmin) / (xmax - xmin)
        py = 10 + (height - 26) * (ymax - y) / (ymax - ymin)
        push!(coordinates, "$(round(px; digits=2)),$(round(py; digits=2))")
    end
    return "<polyline class=\"series $(String(name))\" points=\"" *
           join(coordinates, ' ') *
           "\"/>"
end

function _latest_scba_trace(snapshots)
    anchor = findlast(snapshots) do snapshot
        !isempty(snapshot.stage_path) &&
            snapshot.stage_path[end] === :scba &&
            any(metric -> metric.name in (:r_D, :r_K, :r_Σ, :r_λ), snapshot.metrics)
    end
    anchor === nothing && return ProgressSnapshot[]
    target = snapshots[anchor]
    return ProgressSnapshot[
        snapshot for snapshot in snapshots if
        snapshot.stage_path == target.stage_path && snapshot.labels == target.labels
    ]
end

"""
    save_progress_dashboard(path, snapshots)

Атомарно обновляет автономную панель HTML по событиям о ходе расчёта.
Она показывает иерархию стадий, долю выполненной работы, компактные карточки
метрик и логарифмические графики невязок SCBA. Браузер обновляет страницу
каждые две секунды. Сопутствующий CSV хранит события с полной точностью.

См. [Наблюдаемость производственного расчёта](@ref native-result-formats).
"""
function save_progress_dashboard(
    path::AbstractString,
    snapshots::AbstractVector{<:ProgressSnapshot},
)
    isempty(snapshots) && throw(ArgumentError("dashboard history is empty"))
    latest = last(snapshots)
    fraction = something(latest.fraction, 0.0)
    percentage = clamp(100fraction, 0.0, 100.0)
    breadcrumb = join(
        (
            begin
                stage_text = String(stage)
                isempty(label) ? _progress_html_escape(stage_text) :
                _progress_html_escape("$stage_text — $label")
            end for (stage, label) in zip(latest.stage_path, latest.labels)
        ),
        " › ",
    )
    cards = join(
        (
            "<div class=\"card\"><span>" *
            _progress_html_escape(metric.name) *
            "</span><strong>" *
            _progress_html_escape(
                metric.value isa Real ? compact_number(metric.value) : metric.value,
            ) *
            "</strong><small>" *
            _progress_html_escape(metric.unit) *
            "</small></div>" for metric in latest.metrics
        ),
        "\n",
    )
    scba_trace = _latest_scba_trace(snapshots)
    series = join(
        (_progress_svg_series(scba_trace, name) for name in (:r_D, :r_K, :r_Σ, :r_λ)),
        "\n",
    )
    legend = join(
        (
            "<span class=\"legend $(String(name))\">$(String(name))</span>" for
            name in (:r_D, :r_K, :r_Σ, :r_λ)
        ),
        " ",
    )
    return _observability_atomic_text(path) do stream
        print(
            stream,
            """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="2">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>QCLNEGFRunner live</title>
<style>
body{font:15px system-ui,sans-serif;margin:2rem;background:#f4f7fa;color:#17324d}
main{max-width:900px;margin:auto}.path{font-weight:650;color:#40627e}.bar{height:14px;background:#dbe5ed;border-radius:9px;overflow:hidden}.fill{height:100%;background:#278a72}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:.7rem;margin:1rem 0}.card{background:white;border:1px solid #d6e0e8;border-radius:9px;padding:.75rem}.card span,.card small{display:block;color:#60798d}.card strong{font-size:1.25rem}.plot{background:white;border:1px solid #d6e0e8;border-radius:9px;padding:.5rem}.series{fill:none;stroke-width:2}.r_D{stroke:#1677b8;color:#1677b8}.r_K{stroke:#d56622;color:#d56622}.r_Σ{stroke:#278a72;color:#278a72}.r_λ{stroke:#9b59b6;color:#9b59b6}.legend{margin-right:1rem;font-weight:650}.message{white-space:pre-wrap}
</style></head><body><main><div class="path">$breadcrumb</div>
<h1>$(_progress_html_escape(latest.event)) · $(_progress_html_escape(latest.status))</h1>
<div class="bar"><div class="fill" style="width:$(round(percentage;digits=2))%"></div></div>
<p>iteration $(_progress_html_escape(something(latest.iteration,"—"))) / $(_progress_html_escape(something(latest.total,"—"))) · elapsed $(compact_number(latest.elapsed_seconds)) s</p>
<div class="cards">$cards</div><div class="plot"><svg viewBox="0 0 760 190" width="100%" role="img" aria-label="log10 SCBA residual history">$series</svg><div>$legend</div></div>
<p class="message">$(_progress_html_escape(latest.message))</p></main></body></html>""",
        )
    end
end


function _timing_quantile(values::AbstractVector, probability::Real)
    isempty(values) && return nothing
    ordered = sort(values)
    position = 1 + (length(ordered)-1)*probability
    lower, upper = floor(Int, position), ceil(Int, position)
    return ordered[lower] + (position-lower)*(ordered[upper]-ordered[lower])
end

function _machine_progress_mapping(reporter::ProgressReporter, snapshot::ProgressSnapshot)
    point_frame=findfirst(frame->frame.stage===:point, reporter.stack)
    poisson_frame=findfirst(frame->frame.stage===:poisson, reporter.stack)
    point_ordinal=point_frame===nothing ? nothing : reporter.stack[point_frame].iteration
    outer_iteration=poisson_frame===nothing ? nothing :
                    reporter.stack[poisson_frame].iteration
    outer_metric=findfirst(metric->metric.name===:outer_iteration, snapshot.metrics)
    outer_metric===nothing || (outer_iteration=snapshot.metrics[outer_metric].value)
    return Dict{String,Any}(
        "schema"=>"qcl-negf-progress-v1",
        "session_id"=>reporter.session_id,
        "sequence"=>snapshot.sequence,
        "event"=>String(snapshot.event),
        "point_ordinal"=>point_ordinal,
        "outer_iteration"=>outer_iteration,
        "stage_path"=>String.(snapshot.stage_path),
        "labels"=>snapshot.labels,
        "stage"=>String(last(snapshot.stage_path)),
        "iteration"=>snapshot.iteration,
        "total"=>snapshot.total,
        "remaining"=>snapshot.total === nothing || snapshot.iteration === nothing ?
                     nothing : max(0, snapshot.total-snapshot.iteration),
        "fraction"=>snapshot.fraction,
        "elapsed_seconds"=>snapshot.elapsed_seconds,
        "status"=>String(snapshot.status),
        "message"=>snapshot.message,
        "metrics"=>Dict(
            # Preserve nonfinite diagnostics as explicit text in scalar metadata.
            # Configuration-safe readers reject YAML numeric .inf/.nan; the
            # original numerical values remain in callbacks, CSV and HDF5.
            String(m.name) => Dict(
                "value"=>m.value isa Real && !isfinite(m.value) ? string(m.value) : m.value,
                "unit"=>m.unit,
            ) for m in snapshot.metrics
        ),
    )
end

function _emit_machine_progress!(reporter::ProgressReporter, snapshot::ProgressSnapshot)
    directory=reporter.machine_directory
    directory === nothing && return nothing
    mapping=_machine_progress_mapping(reporter, snapshot)
    _observability_atomic_text(joinpath(directory, "progress.yaml")) do io
        _light_yaml(io, mapping)
    end
    if snapshot.event !== :progress || _progress_has_warning(snapshot)
        event=copy(mapping)
        delete!(event, "metrics")
        event["schema"]="qcl-negf-lifecycle-event-v1"
        if _progress_has_warning(snapshot)
            event["warning_codes"]=[
                metric.value for metric in snapshot.metrics if metric.name===:warning_code
            ]
            snapshot.event===:progress && (event["event"]="warning")
        end
        open(joinpath(directory, "events.jsonl"), "a") do io
            _light_json(io, event)
            println(io)
        end
    end
    # Exact scalar samples are separate from lifecycle. Inclusive spans are not additive.
    for metric in snapshot.metrics
        snapshot.event === :progress || continue
        startswith(String(metric.name), "t_") || continue
        metric.value isa Real && isfinite(metric.value) && metric.value >= 0 || continue
        name=String(metric.name)[3:end]
        count=get(reporter.timing_calls, name, 0)+1
        reporter.timing_calls[name]=count
        # First observed call is shown separately; it may include JIT but is not labelled a measured compilation phase.
        if reporter.timing_summary
            samples=get!(reporter.timing_samples, name, Float64[])
            count>1 && push!(samples, Float64(metric.value))
            length(samples)>100000 && deleteat!(samples, 1)
        end
        path=joinpath(directory, "timings.csv")
        header=!isfile(path) || filesize(path)==0
        open(path, "a") do io
            header && println(
                io,
                "session_id,sequence,stage_path,iteration,core,seconds,warmup,exclusive",
            )
            println(
                io,
                join(
                    _observability_csv_field.((
                        reporter.session_id,
                        snapshot.sequence,
                        join(snapshot.stage_path, '/'),
                        something(snapshot.iteration, ""),
                        name,
                        repr(metric.value),
                        count==1,
                        false,
                    )),
                    ',',
                ),
            )
        end
    end
    if reporter.timing_summary &&
       !isempty(reporter.timing_samples) &&
       (snapshot.event === :end || snapshot.sequence % 10 == 0)
        cores=Dict(
            name=>Dict(
                "count"=>get(reporter.timing_calls, name, 0),
                "retained_steady_samples"=>length(samples),
                "minimum"=>isempty(samples) ? nothing : minimum(samples),
                "maximum"=>isempty(samples) ? nothing : maximum(samples),
                "q05"=>_timing_quantile(samples, 0.05),
                "q25"=>_timing_quantile(samples, 0.25),
                "median"=>_timing_quantile(samples, 0.5),
                "q75"=>_timing_quantile(samples, 0.75),
                "q95"=>_timing_quantile(samples, 0.95),
            ) for (name, samples) in reporter.timing_samples
        )
        _observability_atomic_text(joinpath(directory, "timing_summary.yaml")) do io
            _light_yaml(
                io,
                Dict(
                    "schema"=>"qcl-negf-timing-summary-v1",
                    "session_id"=>reporter.session_id,
                    "unit"=>"s",
                    "exclusive"=>false,
                    "warmup_policy"=>"first observed call per kernel/session excluded from steady statistics; not a measured JIT boundary",
                    "sample_window"=>100000,
                    "cores"=>cores,
                ),
            )
        end
    end
    return nothing
end
