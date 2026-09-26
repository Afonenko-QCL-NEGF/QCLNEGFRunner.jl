function _figure_edges(values)
    length(values)>=2 ||
        throw(ArgumentError("heatmap needs at least two coordinates on each axis"))
    x=Float64.(values)
    all(diff(x) .> 0) || throw(ArgumentError("heatmap coordinates must increase"))
    return vcat(
        x[1]-(x[2]-x[1])/2,
        (x[1:(end-1)] .+ x[2:end]) ./ 2,
        x[end]+(x[end]-x[end-1])/2,
    )
end

"""Render declared FigureData coordinates and values without scientific transformations."""
function _scientific_heatmap_svg(path, spec)
    data=spec["heatmap"]
    x=_figure_edges(data["x"])
    y=_figure_edges(data["y"])
    values=data["values"]
    length(values)==length(y)-1 && all(length(row)==length(x)-1 for row in values) ||
        throw(DimensionMismatch("heatmap values/axes mismatch"))
    finite=Float64[
        value for row in values for value in row if value isa Real && isfinite(value)
    ]
    isempty(finite) && throw(ArgumentError("heatmap has no finite values"))
    lo, hi=extrema(finite)
    hi==lo && (hi=lo+1)
    xp(v) = 90+1000*(v-first(x))/(last(x)-first(x))
    yp(v) = 690-560*(v-first(y))/(last(y)-first(y))
    _observability_atomic_text(path) do io
        println(
            io,
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"800\" viewBox=\"0 0 1200 800\"><rect width=\"1200\" height=\"800\" fill=\"white\"/><g font-family=\"sans-serif\">",
        )
        println(io, "<text x=\"90\" y=\"60\" font-size=\"26\">", spec["title"], "</text>")
        for j in eachindex(values), i in eachindex(values[j])
            value=values[j][i]
            valid=value isa Real && isfinite(value)
            t=valid ? clamp((value-lo)/(hi-lo), 0, 1) : 0.0
            color=valid ?
                  "rgb($(round(Int,240-220t)),$(round(Int,246-125t)),$(round(Int,249-110t)))" :
                  "#ddd"
            println(
                io,
                "<rect x=\"",
                xp(x[i]),
                "\" y=\"",
                yp(y[j+1]),
                "\" width=\"",
                xp(x[i+1])-xp(x[i]),
                "\" height=\"",
                yp(y[j])-yp(y[j+1]),
                "\" fill=\"",
                color,
                "\"/>",
            )
        end
        println(
            io,
            "<text x=\"90\" y=\"735\" font-size=\"18\">",
            spec["x"]["label"],
            " [",
            spec["x"]["unit"],
            "] ",
            first(data["x"]),
            " … ",
            last(data["x"]),
            "; ",
            spec["y"]["label"],
            " [",
            spec["y"]["unit"],
            "] ",
            first(data["y"]),
            " … ",
            last(data["y"]),
            "</text>",
        )
        println(
            io,
            "<text x=\"90\" y=\"770\" font-size=\"18\">Linear colour [",
            data["unit"],
            "] ",
            lo,
            " … ",
            hi,
            "; ",
            data["quality"],
            "</text></g></svg>",
        )
    end
    return path
end
