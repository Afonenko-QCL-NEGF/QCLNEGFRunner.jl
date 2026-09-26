"""Small metadata serialization, scientific diagnostic records, and SVG line output.

Native physical arrays are written exclusively by point_artifacts.jl; the
retired JSON/CSV snapshot writer is deliberately absent.
"""
_light_yaml(io::IO, data) = print(io, YAML.write(data))
_light_quality(solution::NEGFSolution) = String(solution_quality(solution))

function _light_json(io::IO, value)
    if value === nothing
        print(io, "null")
    elseif value isa Bool
        print(io, value ? "true" : "false")
    elseif value isa Real
        if isfinite(value)
            # JSON numbers and YAML's JSON-compatible reader must retain the
            # same scalar type. Julia's 1.0e9 needs an explicit exponent sign;
            # Float32's 1.0f0 is not a JSON numeric token.
            number=value isa Integer ? repr(value) :
                   replace(repr(Float64(value)), r"[eE](?=\d)"=>"e+")
            print(io, number)
        else
            print(io, "null")
        end
    elseif value isa AbstractDict || value isa NamedTuple
        print(io, '{')
        for (index, (key, item)) in enumerate(pairs(value))
            index == 1 || print(io, ',')
            _light_json(io, string(key))
            print(io, ':')
            _light_json(io, item)
        end
        print(io, '}')
    elseif value isa AbstractArray || value isa Tuple
        print(io, '[')
        for (index, item) in enumerate(value)
            index == 1 || print(io, ',')
            _light_json(io, item)
        end
        print(io, ']')
    else
        print(io, '"')
        for char in string(value)
            if char == '"'
                print(io, "\\\"")
            elseif char == '\\'
                print(io, "\\\\")
            elseif char == '\n'
                print(io, "\\n")
            elseif char == '\r'
                print(io, "\\r")
            elseif char == '\t'
                print(io, "\\t")
            elseif Int(char) < 0x20
                print(io, "\\u", string(Int(char); base = 16, pad = 4))
            else
                print(io, char)
            end
        end
        print(io, '"')
    end
end

function _light_svg_series(path, x, series; title = "", xlabel = "", ylabel = "")
    colors = ("#127c83", "#c66a21", "#724ca2", "#2c69af", "#d14559", "#617524")
    finite_x = filter(isfinite, x)
    all_y = [Float64(v) for (_, values) in series for v in values if isfinite(v)]
    isempty(finite_x) && return nothing
    isempty(all_y) && return nothing
    xmin, xmax = extrema(finite_x)
    ymin, ymax = extrema(all_y)
    xmax == xmin && (xmax=xmin+1)
    ymax == ymin && (ymax=ymin+1)
    _observability_atomic_text(path) do io
        println(
            io,
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1600\" height=\"900\" viewBox=\"0 0 1600 900\">",
        )
        println(
            io,
            "<rect width=\"1600\" height=\"900\" fill=\"white\"/><g font-family=\"sans-serif\" fill=\"#213047\">",
        )
        println(
            io,
            "<text x=\"90\" y=\"55\" font-size=\"28\">",
            _progress_html_escape(title),
            "</text>",
        )
        println(io, "<path d=\"M90 95V750H1510\" fill=\"none\" stroke=\"#607080\"/>")
        for tick = 0:5
            xv=xmin+(xmax-xmin)*tick/5
            yv=ymin+(ymax-ymin)*tick/5
            println(
                io,
                "<text x=\"",
                90+1420*tick/5,
                "\" y=\"782\" font-size=\"20\">",
                compact_number(xv),
                "</text>",
            )
            println(
                io,
                "<text x=\"5\" y=\"",
                750-655*tick/5,
                "\" font-size=\"18\">",
                compact_number(yv),
                "</text>",
            )
        end
        for (index, (name, values)) in enumerate(series)
            color=colors[mod1(index, length(colors))]
            segments=String[]
            for (xi, yi) in zip(x, values)
                if isfinite(xi) && isfinite(yi)
                    push!(
                        segments,
                        "$(90+1420*(xi-xmin)/(xmax-xmin)),$(750-655*(yi-ymin)/(ymax-ymin))",
                    )
                elseif !isempty(segments)
                    println(
                        io,
                        "<polyline fill=\"none\" stroke=\"$color\" stroke-width=\"2.5\" points=\"",
                        join(segments, ' '),
                        "\"/>",
                    )
                    empty!(segments)
                end
            end
            isempty(segments) || println(
                io,
                "<polyline fill=\"none\" stroke=\"$color\" stroke-width=\"2.5\" points=\"",
                join(segments, ' '),
                "\"/>",
            )
            println(
                io,
                "<text x=\"",
                90+mod(index-1, 4)*360,
                "\" y=\"",
                840+div(index-1, 4)*25,
                "\" fill=\"$color\" font-size=\"18\">",
                _progress_html_escape(name),
                "</text>",
            )
        end
        println(
            io,
            "<text x=\"740\" y=\"817\" font-size=\"22\">",
            _progress_html_escape(xlabel),
            "</text><text x=\"90\" y=\"85\" font-size=\"18\">",
            _progress_html_escape(ylabel),
            "</text></g></svg>",
        )
    end
    return path
end

function _light_positivity_data(solution::NEGFSolution; witnesses = nothing)
    finite_or_null(x) = isfinite(x) ? x : nothing
    problem = solution.problem
    witnesses === nothing &&
        (witnesses = _scba_positivity_witnesses(solution.scba, problem.kernels.enabled))
    rows = [
        begin
            is_broadening = witness.matrix_kind === :broadening
            factor = is_broadening ? problem.scales.E₀_eV : inv(problem.scales.E₀_eV)
            Dict{String,Any}(
                "matrix_kind"=>String(witness.matrix_kind),
                "energy_index"=>witness.energy_index,
                "momentum_index"=>witness.momentum_index,
                "energy_eV"=>problem.grids.ε[witness.energy_index]*problem.scales.E₀_eV +
                             _electronvolts(problem.physical.E_ref),
                "momentum_per_nm"=>problem.grids.κ[witness.momentum_index]/problem.scales.L₀_m*1e-9,
                "minimum_eigenvalue_scaled"=>finite_or_null(witness.minimum_eigenvalue),
                "block_norm_scaled"=>finite_or_null(witness.block_norm),
                "floor_scaled"=>witness.floor,
                "minimum_eigenvalue"=>finite_or_null(witness.minimum_eigenvalue*factor),
                "block_norm"=>finite_or_null(witness.block_norm*factor),
                "unit"=>(is_broadening ? "eV" : "1/eV"),
                "absolute_defect"=>finite_or_null(witness.absolute_defect*factor),
                "relative_defect"=>finite_or_null(witness.relative_defect),
                "backward_error"=>finite_or_null(witness.backward_error*factor),
                "hermiticity_defect"=>finite_or_null(witness.hermiticity_defect),
                "construction_scale"=>finite_or_null(witness.construction_scale*factor),
                "strict_absolute_threshold"=>finite_or_null(
                    (
                        witness.backward_error+solution.options.tolerances.r_PSD*witness.block_norm
                    )*factor,
                ),
                "ratio"=>finite_or_null(witness.ratio),
                "strict_threshold"=>solution.options.tolerances.r_PSD,
                "strict_passed"=>witness.ratio < solution.options.tolerances.r_PSD,
            )
        end for witness in witnesses
    ]
    return Dict{String,Any}(
        "schema"=>"qcl-negf-positivity-diagnostics-v3",
        "status"=>String(solution.scba.status),
        "quality"=>String(solution.scba.quality),
        "sampling"=>"full energy-momentum grid; worst normalized defect per matrix kind",
        "definition"=>"max(0,-lambda_min(H)-backward_error)/norm; near-zero blocks use absolute backward-error acceptance; H=(X+X')/2",
        "matrix_definitions"=>Dict(
            "spectral"=>"A",
            "occupied"=>"-i G<",
            "unoccupied"=>"i G>",
            "broadening"=>"i (Sigma> - Sigma<)",
            "raw_occupied"=>"GR (-i Sigma<) GA before the particle-number constraint",
            "raw_unoccupied"=>"GR (i Sigma>) GA before the particle-number constraint",
        ),
        "matrices"=>rows,
    )
end

"""All final gates are retained, including failures omitted by summary metrics."""
function _light_validation_data(solution::NEGFSolution)
    metrics = solution.report.metrics
    strict_limits = _solution_validation_limits(solution.options.tolerances, metrics)
    enabled = solution.options.convergence.diagnostic_quality.enabled
    approximate_limits =
        enabled ?
        _solution_validation_limits(
            _approximate_options(solution.options).tolerances,
            metrics,
        ) : nothing
    rows = [
        Dict{String,Any}(
            "metric"=>String(name),
            "value"=>isfinite(value) ? value : nothing,
            "strict_threshold"=>get(strict_limits, name, nothing),
            "approximate_threshold"=>enabled ? get(approximate_limits, name, nothing) :
                                     nothing,
            "strict_passed"=>haskey(strict_limits, name) &&
                             isfinite(value) &&
                             value <= strict_limits[name],
            "approximate_passed"=>enabled ?
                                  haskey(approximate_limits, name) &&
                                  isfinite(value) &&
                                  value <= approximate_limits[name] : nothing,
        ) for (name, value) in sort!(collect(metrics); by = item->String(first(item)))
    ]
    return Dict{String,Any}(
        "schema"=>"qcl-negf-validation-diagnostics-v1",
        "status"=>String(solution.status),
        "quality"=>String(solution_quality(solution)),
        "evaluated"=>!isempty(metrics),
        "strict_passed"=>solution.converged,
        "approximate_enabled"=>enabled,
        "approximate_passed"=>solution.status === :approximate,
        "messages"=>copy(solution.report.messages),
        "metrics"=>rows,
    )
end
