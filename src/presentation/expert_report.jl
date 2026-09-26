const _METHOD_FAMILIES = (
    :direct_reference,
    :exact_optimized,
    :controlled_approximation,
    :reduced_model,
    :surrogate,
)

"""
    MethodDescriptor(; id, label, structure_id, physics_signature,
                     modifies_physics, algorithm_family, description="",
                     literature="")

Machine-readable identity of one solver mode in an expert comparison.
`modifies_physics=false` declares an unchanged physical model (either a
purely computational implementation or an explicitly controlled numerical
approximation) and therefore requires the same `physics_signature` as the
reference run.
`modifies_physics=true` marks a change to the equations, discretized
interaction, basis truncation, or another physical approximation; the report
never presents such a run as a speed-only optimization.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
struct MethodDescriptor
    id::Symbol
    label::String
    structure_id::String
    physics_signature::String
    modifies_physics::Bool
    algorithm_family::Symbol
    description::String
    literature::String
end

function MethodDescriptor(;
    id,
    label::AbstractString,
    structure_id::AbstractString,
    physics_signature::AbstractString,
    modifies_physics::Bool,
    algorithm_family,
    description::AbstractString = "",
    literature::AbstractString = "",
)
    method_id = Symbol(id)
    isempty(String(method_id)) && throw(ArgumentError("method id cannot be empty"))
    family = Symbol(algorithm_family)
    family in _METHOD_FAMILIES || throw(
        ArgumentError("algorithm_family must be one of $(join(_METHOD_FAMILIES, ", "))"),
    )
    isempty(strip(structure_id)) && throw(ArgumentError("structure_id cannot be empty"))
    isempty(strip(physics_signature)) &&
        throw(ArgumentError("physics_signature cannot be empty"))
    return MethodDescriptor(
        method_id,
        String(label),
        String(structure_id),
        String(physics_signature),
        modifies_physics,
        family,
        String(description),
        String(literature),
    )
end

"""One operating point retained by the
[expert comparison workflow](@ref expert-comparison-workflow), including its
independent `scba_quality` classification."""
struct MethodPoint
    temperature_K::Float64
    voltage_per_period_V::Float64
    field_V_per_m::Union{Missing,Float64}
    current_A_per_m2::Float64
    converged::Bool
    status::Symbol
    scba_quality::Symbol
    outer_iterations::Int
    final_scba_iterations::Int
    wall_seconds::Union{Missing,Float64}
    peak_bytes::Union{Missing,Int64}
    memory_kind::Symbol
    checkpoint::String
    metrics::Dict{Symbol,Float64}
    warnings::Vector{Dict{String,Any}}

    function MethodPoint(
        temperature_K::Float64,
        voltage_per_period_V::Float64,
        field_V_per_m::Union{Missing,Float64},
        current_A_per_m2::Float64,
        converged::Bool,
        status::Symbol,
        scba_quality::Symbol,
        outer_iterations::Int,
        final_scba_iterations::Int,
        wall_seconds::Union{Missing,Float64},
        peak_bytes::Union{Missing,Int64},
        memory_kind::Symbol,
        checkpoint::String,
        metrics::Dict{Symbol,Float64},
        warnings::Vector{Dict{String,Any}} = Dict{String,Any}[],
    )
        _check_scba_result_classification(converged, status, scba_quality)
        return new(
            temperature_K,
            voltage_per_period_V,
            field_V_per_m,
            current_A_per_m2,
            converged,
            status,
            scba_quality,
            outer_iterations,
            final_scba_iterations,
            wall_seconds,
            peak_bytes,
            memory_kind,
            checkpoint,
            metrics,
            warnings,
        )
    end
end

"""Descriptor, points, and provenance for the
[expert comparison workflow](@ref expert-comparison-workflow)."""
struct MethodRun
    descriptor::MethodDescriptor
    points::Vector{MethodPoint}
    summary_path::String
end

"""Long-form metric row from the
[expert comparison workflow](@ref expert-comparison-workflow)."""
struct MethodComparisonRow
    reference_id::Symbol
    candidate_id::Symbol
    modifies_physics::Bool
    temperature_K::Float64
    voltage_per_period_V::Float64
    metric::Symbol
    reference_value::Float64
    candidate_value::Float64
    absolute_error::Float64
    relative_error::Union{Missing,Float64}
    reference_converged::Bool
    candidate_converged::Bool
    reference_scba_quality::Symbol
    candidate_scba_quality::Symbol
    speedup::Union{Missing,Float64}
    memory_ratio::Union{Missing,Float64}
end

"""
Comparison of several stored runs on one declared physical structure.

Rows are long-form so current density, conservation residuals, gain, or any
future `metric_*` column can be assessed without changing the report schema.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
struct ExpertComparison
    structure_id::String
    reference_id::Symbol
    runs::Vector{MethodRun}
    rows::Vector{MethodComparisonRow}
end

# A CSV record can span several physical lines. Keep the quote state until the
# record separator outside a quoted field, preserving embedded LF/CRLF verbatim.
# This is shared by catalogs, point summaries, and comparison exports; no CSV
# repair or newline substitution is performed on scientific provenance.
function _read_report_csv_record(stream::IO, path::AbstractString, record_index::Int)
    fields = String[]
    buffer = IOBuffer()
    state = :field_start
    has_input = false
    nonblank = false
    while !eof(stream)
        char = read(stream, Char)
        has_input = true
        nonblank |= !isspace(char)
        if state === :quoted
            if char == '"'
                if !eof(stream) && peek(stream, UInt8) == UInt8('"')
                    read(stream, UInt8)
                    write(buffer, '"')
                else
                    state = :after_quote
                end
            else
                write(buffer, char)
            end
        elseif char == ','
            push!(fields, String(take!(buffer)))
            state = :field_start
        elseif char == '\n' || char == '\r'
            # A CRLF separator is one record boundary; CRLF inside quotes was
            # handled above and remains part of the field's original value.
            if char == '\r' && !eof(stream) && peek(stream, UInt8) == UInt8('\n')
                read(stream, UInt8)
            end
            push!(fields, String(take!(buffer)))
            return (fields = fields, blank = !nonblank)
        elseif state === :after_quote
            throw(
                ArgumentError(
                    "unexpected character after a closing quote in CSV record $record_index in $path",
                ),
            )
        elseif char == '"'
            state === :field_start || throw(
                ArgumentError(
                    "quote inside an unquoted field in CSV record $record_index in $path",
                ),
            )
            state = :quoted
        else
            write(buffer, char)
            state = :unquoted
        end
    end
    state === :quoted && throw(
        ArgumentError("unterminated quoted CSV field in record $record_index in $path"),
    )
    has_input || return nothing
    push!(fields, String(take!(buffer)))
    return (fields = fields, blank = !nonblank)
end

function _read_report_csv(path::AbstractString)
    return open(path, "r") do stream
        # A byte-order mark belongs to the file, including when its first
        # header field is quoted. It must not become part of that field.
        if !eof(stream) && read(stream, Char) != '\ufeff'
            seekstart(stream)
        end
        first_record = _read_report_csv_record(stream, path, 1)
        first_record === nothing && throw(ArgumentError("CSV file is empty: $path"))
        header = first_record.fields
        any(isempty, header) && throw(ArgumentError("empty CSV column in $path"))
        length(unique(header)) == length(header) ||
            throw(ArgumentError("duplicate CSV columns in $path"))
        rows = Dict{String,String}[]
        record_index = 2
        while true
            record = _read_report_csv_record(stream, path, record_index)
            record === nothing && break
            if !record.blank
                values = record.fields
                length(values) == length(header) || throw(
                    ArgumentError(
                        "CSV record $record_index in $path has $(length(values)) fields; " *
                        "expected $(length(header))",
                    ),
                )
                push!(rows, Dict(zip(header, values)))
            end
            record_index += 1
        end
        return header, rows
    end
end

function _required_report_field(row, name::AbstractString, path)
    haskey(row, name) ||
        throw(ArgumentError("required column '$name' is absent from $path"))
    isempty(strip(row[name])) &&
        throw(ArgumentError("required value '$name' is empty in $path"))
    return strip(row[name])
end

function _optional_report_field(row, name::AbstractString)
    haskey(row, name) || return nothing
    value = strip(row[name])
    return isempty(value) ? nothing : value
end

function _parse_report_bool(value::AbstractString, label::AbstractString)
    normal = lowercase(strip(value))
    normal in ("true", "1", "yes") && return true
    normal in ("false", "0", "no") && return false
    throw(ArgumentError("$label must be true or false; received '$value'"))
end

function _parse_report_float(value::AbstractString, label::AbstractString)
    result = tryparse(Float64, strip(value))
    result === nothing &&
        throw(ArgumentError("$label must be a Float64; received '$value'"))
    return result
end

function _parse_report_int(value::AbstractString, label::AbstractString)
    result = tryparse(Int64, strip(value))
    result === nothing &&
        throw(ArgumentError("$label must be an integer; received '$value'"))
    return result
end

"""
    load_method_run(descriptor, summary_path)

Load an existing `qcl-negf-report-v1` `sweep_summary.csv`. The required
`scba_quality` column
keeps strict convergence, a diagnostic approximate fixed point, and an
unresolved state distinct. Optional columns `wall_seconds`,
`measured_peak_bytes`, and any number of `metric_<name>` columns enrich the
comparison. If only `estimated_peak_bytes` exists, the report labels memory as
estimated rather than measured.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
function load_method_run(descriptor::MethodDescriptor, summary_path::AbstractString)
    path = abspath(summary_path)
    header, rows = _read_report_csv(path)
    required = (
        "temperature_K",
        "voltage_per_period_V",
        "current_A_per_m2",
        "converged",
        "status",
        "scba_quality",
        "outer_iterations",
        "final_scba_iterations",
    )
    for name in required
        name in header ||
            throw(ArgumentError("required column '$name' is absent from $path"))
    end
    metric_columns = sort(filter(name -> startswith(name, "metric_"), header))
    points = MethodPoint[]
    for row in rows
        temperature = _parse_report_float(
            _required_report_field(row, "temperature_K", path),
            "temperature_K",
        )
        voltage = _parse_report_float(
            _required_report_field(row, "voltage_per_period_V", path),
            "voltage_per_period_V",
        )
        current = _parse_report_float(
            _required_report_field(row, "current_A_per_m2", path),
            "current_A_per_m2",
        )
        field_text = _optional_report_field(row, "field_V_per_m")
        field =
            field_text === nothing ? missing :
            _parse_report_float(field_text, "field_V_per_m")
        converged =
            _parse_report_bool(_required_report_field(row, "converged", path), "converged")
        status = Symbol(_required_report_field(row, "status", path))
        scba_quality = Symbol(_required_report_field(row, "scba_quality", path))
        outer = Int(
            _parse_report_int(
                _required_report_field(row, "outer_iterations", path),
                "outer_iterations",
            ),
        )
        scba = Int(
            _parse_report_int(
                _required_report_field(row, "final_scba_iterations", path),
                "final_scba_iterations",
            ),
        )
        wall_text = _optional_report_field(row, "wall_seconds")
        wall =
            wall_text === nothing ? missing : _parse_report_float(wall_text, "wall_seconds")
        measured_text = _optional_report_field(row, "measured_peak_bytes")
        estimated_text = _optional_report_field(row, "estimated_peak_bytes")
        peak, memory_kind = if measured_text !== nothing
            (_parse_report_int(measured_text, "measured_peak_bytes"), :measured)
        elseif estimated_text !== nothing
            (_parse_report_int(estimated_text, "estimated_peak_bytes"), :estimated)
        else
            (missing, :missing)
        end
        checkpoint = String(something(_optional_report_field(row, "checkpoint"), ""))
        metrics = Dict{Symbol,Float64}(:current_A_per_m2 => current)
        for column in metric_columns
            value = _optional_report_field(row, column)
            value === nothing && continue
            metrics[Symbol(column[8:end])] = _parse_report_float(value, column)
        end
        warning_text = something(_optional_report_field(row, "warnings_json"), "[]")
        warning_data = YAML.load(warning_text; dicttype = Dict{String,Any})
        warning_data isa AbstractVector ||
            throw(ArgumentError("warnings_json must contain an array"))
        warnings = Dict{String,Any}[Dict{String,Any}(entry) for entry in warning_data]
        push!(
            points,
            MethodPoint(
                temperature,
                voltage,
                field,
                current,
                converged,
                status,
                scba_quality,
                outer,
                scba,
                wall,
                peak,
                memory_kind,
                checkpoint,
                metrics,
                warnings,
            ),
        )
    end
    sort!(points; by = point -> (point.temperature_K, point.voltage_per_period_V))
    return MethodRun(descriptor, points, path)
end

"""
    load_method_catalog(path)

Read a catalog with one row per method. Required columns are `method_id`,
`label`, `structure_id`, `physics_signature`, `modifies_physics`,
`algorithm_family`, and `summary_path`. Relative summary paths are resolved
against the catalog directory. Optional `description` and `literature`
columns are propagated into the expert report.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
function load_method_catalog(path::AbstractString)
    catalog = abspath(path)
    _, rows = _read_report_csv(catalog)
    runs = MethodRun[]
    ids = Symbol[]
    for row in rows
        descriptor = MethodDescriptor(
            id = _required_report_field(row, "method_id", catalog),
            label = _required_report_field(row, "label", catalog),
            structure_id = _required_report_field(row, "structure_id", catalog),
            physics_signature = _required_report_field(row, "physics_signature", catalog),
            modifies_physics = _parse_report_bool(
                _required_report_field(row, "modifies_physics", catalog),
                "modifies_physics",
            ),
            algorithm_family = Symbol(
                _required_report_field(row, "algorithm_family", catalog),
            ),
            description = something(_optional_report_field(row, "description"), ""),
            literature = something(_optional_report_field(row, "literature"), ""),
        )
        descriptor.id in ids &&
            throw(ArgumentError("duplicate method id :$(descriptor.id) in $catalog"))
        push!(ids, descriptor.id)
        summary = _required_report_field(row, "summary_path", catalog)
        summary_path =
            isabspath(summary) ? summary : normpath(joinpath(dirname(catalog), summary))
        push!(runs, load_method_run(descriptor, summary_path))
    end
    isempty(runs) && throw(ArgumentError("method catalog is empty: $catalog"))
    return runs
end

function _matching_method_point(
    points::Vector{MethodPoint},
    target::MethodPoint;
    temperature_atol::Float64,
    voltage_atol::Float64,
)
    matches = filter(points) do point
        abs(point.temperature_K - target.temperature_K) ≤ temperature_atol &&
            abs(point.voltage_per_period_V - target.voltage_per_period_V) ≤ voltage_atol
    end
    length(matches) ≤ 1 || throw(
        ArgumentError(
            "candidate has ambiguous operating points near " *
            "T=$(target.temperature_K) K, Vp=$(target.voltage_per_period_V) V",
        ),
    )
    return isempty(matches) ? nothing : only(matches)
end

function _comparison_ratio(numerator, denominator)
    numerator === missing && return missing
    denominator === missing && return missing
    isfinite(numerator) && isfinite(denominator) && denominator > 0 || return missing
    return numerator / denominator
end

"""
    compare_method_runs(runs; reference_id, temperature_atol=1e-9,
                        voltage_atol=1e-12)

Match stored methods at identical operating points and calculate long-form
metric errors, speedup, and peak-memory ratio. Methods declaring unchanged
physics are rejected if their `physics_signature` differs from the reference. This is
an important fail-closed guard: a physical approximation cannot be relabelled
as an implementation optimization by mistake.

See [Physics-first tests](https://github.com/AfonenkoA/QCLNEGF.jl/blob/main/docs/src/theory/12_validation.md) and
[Expert comparison workflow](@ref expert-comparison-workflow).
"""
function compare_method_runs(
    runs::AbstractVector{<:MethodRun};
    reference_id,
    temperature_atol::Real = 1e-9,
    voltage_atol::Real = 1e-12,
)
    isempty(runs) && throw(ArgumentError("at least one method run is required"))
    run_vector = collect(runs)
    structures = unique(run.descriptor.structure_id for run in run_vector)
    length(structures) == 1 ||
        throw(ArgumentError("all runs must declare the same structure_id"))
    reference_symbol = Symbol(reference_id)
    reference_matches = filter(run -> run.descriptor.id === reference_symbol, run_vector)
    length(reference_matches) == 1 ||
        throw(ArgumentError("reference_id must identify exactly one run"))
    reference = only(reference_matches)
    for run in run_vector
        if !run.descriptor.modifies_physics &&
           run.descriptor.physics_signature != reference.descriptor.physics_signature
            throw(
                ArgumentError(
                    "method :$(run.descriptor.id) declaring unchanged physics has a " *
                    "different physics_signature from the reference",
                ),
            )
        end
    end

    rows = MethodComparisonRow[]
    for candidate in sort(run_vector; by = run -> String(run.descriptor.id))
        candidate.descriptor.id === reference_symbol && continue
        for reference_point in reference.points
            candidate_point = _matching_method_point(
                candidate.points,
                reference_point;
                temperature_atol = Float64(temperature_atol),
                voltage_atol = Float64(voltage_atol),
            )
            candidate_point === nothing && continue
            common_metrics = sort!(
                collect(
                    intersect(keys(reference_point.metrics), keys(candidate_point.metrics)),
                );
                by = String,
            )
            speedup = _comparison_ratio(
                reference_point.wall_seconds,
                candidate_point.wall_seconds,
            )
            memory_ratio =
                _comparison_ratio(candidate_point.peak_bytes, reference_point.peak_bytes)
            for metric in common_metrics
                reference_value = reference_point.metrics[metric]
                candidate_value = candidate_point.metrics[metric]
                absolute_error = abs(candidate_value - reference_value)
                relative_error =
                    reference_value == 0 ||
                    !isfinite(reference_value) ||
                    !isfinite(candidate_value) ? missing :
                    absolute_error / abs(reference_value)
                push!(
                    rows,
                    MethodComparisonRow(
                        reference_symbol,
                        candidate.descriptor.id,
                        candidate.descriptor.modifies_physics,
                        reference_point.temperature_K,
                        reference_point.voltage_per_period_V,
                        metric,
                        reference_value,
                        candidate_value,
                        absolute_error,
                        relative_error,
                        reference_point.converged,
                        candidate_point.converged,
                        reference_point.scba_quality,
                        candidate_point.scba_quality,
                        speedup,
                        memory_ratio,
                    ),
                )
            end
        end
    end
    sort!(
        rows;
        by = row -> (
            String(row.candidate_id),
            row.temperature_K,
            row.voltage_per_period_V,
            String(row.metric),
        ),
    )
    return ExpertComparison(only(structures), reference_symbol, run_vector, rows)
end

_report_missing(value) = value === missing ? "" : repr(value)

function _report_csv_field(value)
    text = string(value)
    if occursin(',', text) ||
       occursin('"', text) ||
       occursin('\n', text) ||
       occursin('\r', text)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
    return text
end

function _write_comparison_csv(path::AbstractString, comparison::ExpertComparison)
    return _observability_atomic_text(path) do stream
        println(
            stream,
            join(
                (
                    "reference_id",
                    "candidate_id",
                    "modifies_physics",
                    "temperature_K",
                    "voltage_per_period_V",
                    "metric",
                    "reference_value",
                    "candidate_value",
                    "absolute_error",
                    "relative_error",
                    "reference_converged",
                    "candidate_converged",
                    "reference_scba_quality",
                    "candidate_scba_quality",
                    "speedup",
                    "memory_ratio",
                ),
                ',',
            ),
        )
        for row in comparison.rows
            values = (
                row.reference_id,
                row.candidate_id,
                row.modifies_physics,
                repr(row.temperature_K),
                repr(row.voltage_per_period_V),
                row.metric,
                repr(row.reference_value),
                repr(row.candidate_value),
                repr(row.absolute_error),
                _report_missing(row.relative_error),
                row.reference_converged,
                row.candidate_converged,
                row.reference_scba_quality,
                row.candidate_scba_quality,
                _report_missing(row.speedup),
                _report_missing(row.memory_ratio),
            )
            println(stream, join(_report_csv_field.(values), ','))
        end
    end
end

function _write_points_csv(path::AbstractString, comparison::ExpertComparison)
    metric_set = Set{Symbol}()
    for run in comparison.runs, point in run.points
        union!(metric_set, keys(point.metrics))
    end
    metric_names = sort!(collect(metric_set); by = String)
    return _observability_atomic_text(path) do stream
        header = String[
            "method_id",
            "modifies_physics",
            "algorithm_family",
            "temperature_K",
            "voltage_per_period_V",
            "field_V_per_m",
            "converged",
            "status",
            "scba_quality",
            "outer_iterations",
            "final_scba_iterations",
            "wall_seconds",
            "peak_bytes",
            "memory_kind",
            "checkpoint",
            "quality",
            "warning_count",
            "warnings_json",
        ]
        append!(header, "metric_" .* String.(metric_names))
        println(stream, join(_report_csv_field.(header), ','))
        for run in sort(comparison.runs; by = run -> String(run.descriptor.id))
            for point in run.points
                values = Any[
                    run.descriptor.id,
                    run.descriptor.modifies_physics,
                    run.descriptor.algorithm_family,
                    repr(point.temperature_K),
                    repr(point.voltage_per_period_V),
                    _report_missing(point.field_V_per_m),
                    point.converged,
                    point.status,
                    point.scba_quality,
                    point.outer_iterations,
                    point.final_scba_iterations,
                    _report_missing(point.wall_seconds),
                    _report_missing(point.peak_bytes),
                    point.memory_kind,
                    point.checkpoint,
                    point.converged ? "strict" :
                    point.scba_quality === :invalid ? "invalid" :
                    point.status === :approximate ? "approximate" : "unconverged",
                    length(point.warnings),
                    sprint(_light_json, point.warnings),
                ]
                append!(
                    values,
                    [
                        haskey(point.metrics, metric) ? repr(point.metrics[metric]) : "" for
                        metric in metric_names
                    ],
                )
                println(stream, join(_report_csv_field.(values), ','))
            end
        end
    end
end

function _markdown_escape(text::AbstractString)
    return replace(replace(text, "|" => "\\|"), '\n' => ' ')
end

function _human_identifier(
    value::AbstractString;
    head_chars::Integer = 24,
    tail_chars::Integer = 12,
)
    head_chars > 0 || throw(ArgumentError("head_chars must be positive"))
    tail_chars > 0 || throw(ArgumentError("tail_chars must be positive"))
    length(value) <= head_chars + tail_chars + 1 && return String(value)
    return string(first(value, head_chars), '…', last(value, tail_chars))
end

function _report_number(value; digits = 5)
    value === missing && return "—"
    return compact_number(value; significant_digits = digits)
end

# Failed operating points keep NaN in machine data. They have no physical
# current to convert; the human table must remain writable for other methods.
_report_current_density(value::Real) =
    isfinite(value) ? _report_number(current_density_A_per_cm2(value)) : "—"

function _report_median(values)
    selected =
        sort(Float64[value for value in values if value !== missing && isfinite(value)])
    isempty(selected) && return missing
    middle = length(selected) ÷ 2
    return isodd(length(selected)) ? selected[middle+1] :
           (selected[middle] + selected[middle+1]) / 2
end

function _write_expert_markdown(
    path::AbstractString,
    comparison::ExpertComparison;
    title::AbstractString,
)
    reference =
        only(filter(run -> run.descriptor.id === comparison.reference_id, comparison.runs))
    return _observability_atomic_text(path) do stream
        println(stream, "# ", title, "\n")
        println(stream, "- Structure: `", _human_identifier(comparison.structure_id), "`")
        println(stream, "- Reference method: `", comparison.reference_id, "`")
        println(
            stream,
            "- Reference physics signature: `",
            _human_identifier(reference.descriptor.physics_signature),
            "`",
        )
        println(stream, "- Stored methods: ", length(comparison.runs))
        println(stream, "- Matched long-form metric rows: ", length(comparison.rows), "\n")
        println(
            stream,
            "> Long structure and physics identifiers are abbreviated " *
            "only in this human-readable report. Their complete exact values " *
            "remain in `method_catalog.csv` and the full-precision CSV outputs.\n",
        )
        println(
            stream,
            "> This report compares stored numerical results. It does not " *
            "by itself prove physical equivalence. Methods marked **physics changed** " *
            "must be validated against the reference with the physics-first test suite.\n",
        )

        println(stream, "## Method classification\n")
        println(stream, "| Method | Family | Classification | Physics signature | Source |")
        println(stream, "|---|---|---|---|---|")
        for run in sort(comparison.runs; by = run -> String(run.descriptor.id))
            descriptor = run.descriptor
            classification =
                descriptor.id === comparison.reference_id ? "reference equations" :
                descriptor.modifies_physics ? "**physics changed**" :
                descriptor.algorithm_family === :controlled_approximation ?
                "controlled numerical" : "computational only"
            source =
                isempty(descriptor.literature) ? "—" :
                _markdown_escape(descriptor.literature)
            println(
                stream,
                "| `",
                descriptor.id,
                "` — ",
                _markdown_escape(descriptor.label),
                " | `",
                descriptor.algorithm_family,
                "` | ",
                classification,
                " | `",
                _human_identifier(descriptor.physics_signature),
                "` | ",
                source,
                " |",
            )
        end

        println(stream, "\n## Coverage and convergence\n")
        println(
            stream,
            "| Method | Points | Strict overall | Approximate overall | Unconverged overall | Invalid overall |",
        )
        println(stream, "|---|---:|---:|---:|---:|---:|")
        for run in sort(comparison.runs; by = run -> String(run.descriptor.id))
            strict=count(point->point.converged, run.points)
            approximate=count(point->point.status === :approximate, run.points)
            invalid=count(point->point.scba_quality === :invalid, run.points)
            unresolved=length(run.points)-strict-approximate-invalid
            println(
                stream,
                "| `",
                run.descriptor.id,
                "` | ",
                length(run.points),
                " | ",
                strict,
                " | ",
                approximate,
                " | ",
                unresolved,
                " | ",
                invalid,
                " |",
            )
        end

        println(stream, "\n## Quality warnings\n")
        for run in comparison.runs, point in run.points, warning in point.warnings
            println(
                stream,
                "- `",
                run.descriptor.id,
                "` T=",
                point.temperature_K,
                " K, V=",
                point.voltage_per_period_V,
                " V: `",
                get(warning, "code", "warning"),
                "`; scope `",
                get(warning, "scope", "point"),
                "`. Details: `",
                _markdown_escape(sprint(_light_json, warning)),
                "`.",
            )
        end
        println(
            stream,
            "Approximate acceptance completes the workflow with warnings; it is not a strict accuracy certificate.",
        )

        println(stream, "\n## Current-density accuracy and resources\n")
        println(
            stream,
            "| Candidate | Classification | Converged J pairs | " *
            "Max relative current error | Median speedup | " *
            "Median peak-memory ratio |",
        )
        println(stream, "|---|---|---:|---:|---:|---:|")
        for run in sort(comparison.runs; by = run -> String(run.descriptor.id))
            run.descriptor.id === comparison.reference_id && continue
            rows = filter(
                row ->
                    row.candidate_id === run.descriptor.id &&
                    row.metric === :current_A_per_m2,
                comparison.rows,
            )
            valid_rows =
                filter(row -> row.reference_converged && row.candidate_converged, rows)
            relative =
                [row.relative_error for row in valid_rows if row.relative_error !== missing]
            maximum_relative = isempty(relative) ? missing : maximum(relative)
            speedup = _report_median(getfield.(valid_rows, :speedup))
            memory = _report_median(getfield.(valid_rows, :memory_ratio))
            classification =
                run.descriptor.modifies_physics ? "physics changed" :
                run.descriptor.algorithm_family === :controlled_approximation ?
                "controlled numerical" : "exact computational"
            println(
                stream,
                "| `",
                run.descriptor.id,
                "` | ",
                classification,
                " | ",
                length(valid_rows),
                " | ",
                _report_number(maximum_relative),
                " | ",
                _report_number(speedup),
                " | ",
                _report_number(memory),
                " |",
            )
        end

        println(stream, "\n## Physics-first metric envelope\n")
        println(
            stream,
            "The table includes only point pairs for which both " *
            "methods report convergence. A small I–V error cannot compensate " *
            "for a failed conservation, causality, sum-rule, population, or " *
            "gain test.\n",
        )
        println(
            stream,
            "| Candidate | Metric | Converged pairs | Max absolute " *
            "error | Max relative error |",
        )
        println(stream, "|---|---|---:|---:|---:|")
        candidate_metrics = sort!(
            unique((row.candidate_id, row.metric) for row in comparison.rows);
            by = item -> (String(item[1]), String(item[2])),
        )
        for (candidate_id, metric) in candidate_metrics
            rows = filter(
                row ->
                    row.candidate_id === candidate_id &&
                    row.metric === metric &&
                    row.reference_converged &&
                    row.candidate_converged,
                comparison.rows,
            )
            absolute = isempty(rows) ? missing : maximum(getfield.(rows, :absolute_error))
            relative_values =
                [row.relative_error for row in rows if row.relative_error !== missing]
            relative = isempty(relative_values) ? missing : maximum(relative_values)
            println(
                stream,
                "| `",
                candidate_id,
                "` | `",
                metric,
                "` | ",
                length(rows),
                " | ",
                _report_number(absolute),
                " | ",
                _report_number(relative),
                " |",
            )
        end

        println(stream, "\n## Operating-point comparison\n")
        println(
            stream,
            "Only converged current-density pairs should be used for " *
            "physical conclusions. Full-precision data are in " *
            "`method_comparison.csv`.\n",
        )
        println(
            stream,
            "| Candidate | T (K) | Vp (V) | " *
            "Reference J (A/cm²) | Candidate J (A/cm²) | Relative error | " *
            "SCBA quality (ref / candidate) | Pair converged |",
        )
        println(stream, "|---|---:|---:|---:|---:|---:|---|---|")
        current_rows = filter(row -> row.metric === :current_A_per_m2, comparison.rows)
        for row in current_rows
            pair_ok = row.reference_converged && row.candidate_converged
            println(
                stream,
                "| `",
                row.candidate_id,
                "` | ",
                _report_number(row.temperature_K),
                " | ",
                _report_number(row.voltage_per_period_V),
                " | ",
                _report_current_density(row.reference_value),
                " | ",
                _report_current_density(row.candidate_value),
                " | ",
                _report_number(row.relative_error),
                " | ",
                "`",
                row.reference_scba_quality,
                "` / `",
                row.candidate_scba_quality,
                "` | ",
                pair_ok ? "yes" : "**no**",
                " |",
            )
        end

        println(stream, "\n## Interpretation checklist\n")
        println(
            stream,
            "1. Confirm identical structure and physics signatures for " *
            "every method declaring unchanged physics; then keep controlled " *
            "numerical errors separate from round-off-equivalent implementations.",
        )
        println(
            stream,
            "2. Exclude unconverged point pairs before evaluating errors " * "or speedups.",
        )
        println(
            stream,
            "3. Inspect current continuity, causality, spectral sum rule, " *
            "charge neutrality, and power balance—not only I–V agreement.",
        )
        println(
            stream,
            "4. For physics-changing methods, repeat the comparison for " *
            "populations, gain peak, peak energy, and linewidth.",
        )
        println(stream, "5. Treat estimated memory separately from measured peak RSS.")

        println(stream, "\n## Provenance\n")
        for run in sort(comparison.runs; by = run -> String(run.descriptor.id))
            println(
                stream,
                "- `",
                run.descriptor.id,
                "`: `",
                replace(run.summary_path, '\\' => '/'),
                "`",
            )
            isempty(run.descriptor.description) ||
                println(stream, "  - ", _markdown_escape(run.descriptor.description))
        end
    end
end

"""
    save_expert_report(output_directory, comparison; title=...)

Write an auditable Markdown report plus full-precision long-form comparison
and point CSV files. Existing targets are atomically replaced only after each
new file is complete.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
function save_expert_report(
    output_directory::AbstractString,
    comparison::ExpertComparison;
    title::AbstractString = "reference design NEGF method comparison",
)
    directory = abspath(output_directory)
    mkpath(directory)
    markdown =
        _write_expert_markdown(joinpath(directory, "expert_report.md"), comparison; title)
    comparison_csv =
        _write_comparison_csv(joinpath(directory, "method_comparison.csv"), comparison)
    points_csv = _write_points_csv(joinpath(directory, "method_points.csv"), comparison)
    return (markdown = markdown, comparison_csv = comparison_csv, points_csv = points_csv)
end

"""
    generate_expert_report(catalog_path, output_directory; reference_id, ...)

One-call loader, comparator, and report writer used by the production wrapper.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
function generate_expert_report(
    catalog_path::AbstractString,
    output_directory::AbstractString;
    reference_id,
    title::AbstractString = "reference design NEGF method comparison",
)
    runs = load_method_catalog(catalog_path)
    comparison = compare_method_runs(runs; reference_id)
    paths = save_expert_report(output_directory, comparison; title)
    return (comparison = comparison, paths = paths)
end

"""Optional CairoMakie extension point described by the
[expert comparison workflow](@ref expert-comparison-workflow)."""
function plot_method_comparison end
