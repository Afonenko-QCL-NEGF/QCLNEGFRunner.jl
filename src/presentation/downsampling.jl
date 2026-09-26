"""Presentation-only downsampling; it never changes the durable iteration log."""
struct DisplayDownsamplingPolicy
    max_points::Int
    strategy::Symbol
    function DisplayDownsamplingPolicy(;
        max_points::Integer = 500,
        strategy::Symbol = :lttb,
    )
        max_points >= 3 || throw(ArgumentError("display max_points must be at least 3"))
        strategy in (:uniform, :lttb) ||
            throw(ArgumentError("display strategy must be uniform or lttb"))
        new(Int(max_points), strategy)
    end
end

function _uniform_indices(length::Int, target::Int)
    target >= length && return collect(1:length)
    raw = round.(Int, range(1, length; length = target))
    raw[1] = 1
    raw[end] = length
    unique!(raw)
    return raw
end

# Largest-Triangle-Three-Buckets. Endpoints are retained and extrema influence
# selection, making it suitable for residual/current histories in the web UI.
function _lttb_indices(x::AbstractVector, y::AbstractVector, threshold::Int)
    n = length(x)
    threshold >= n && return collect(1:n)
    threshold == 3 && return [1, argmax(abs.(y[2:(end-1)] .- y[1])) + 1, n]
    selected = Int[1]
    every = (n - 2) / (threshold - 2)
    a = 1
    for bucket = 0:(threshold-3)
        average_start = floor(Int, (bucket + 1) * every) + 2
        average_end = min(floor(Int, (bucket + 2) * every) + 1, n)
        average_start = min(average_start, n)
        average_end = max(average_end, average_start)
        avg_x =
            sum(Float64(x[index]) for index = average_start:average_end) /
            (average_end - average_start + 1)
        avg_y =
            sum(Float64(y[index]) for index = average_start:average_end) /
            (average_end - average_start + 1)

        range_start = floor(Int, bucket * every) + 2
        range_end = min(floor(Int, (bucket + 1) * every) + 1, n - 1)
        range_end = max(range_end, range_start)
        ax, ay = Float64(x[a]), Float64(y[a])
        best_area = -Inf
        best_index = range_start
        for index = range_start:range_end
            area = abs(
                (ax - avg_x) * (Float64(y[index]) - ay) -
                (ax - Float64(x[index])) * (avg_y - ay),
            )
            if area > best_area
                best_area = area
                best_index = index
            end
        end
        push!(selected, best_index)
        a = best_index
    end
    push!(selected, n)
    return selected
end

function downsample_series(
    x::AbstractVector,
    y::AbstractVector,
    policy::DisplayDownsamplingPolicy,
)
    length(x) == length(y) || throw(DimensionMismatch("x and y must have equal lengths"))
    isempty(x) && return (x = eltype(x)[], y = eltype(y)[], indices = Int[])
    all(isfinite, Float64.(x)) && all(isfinite, Float64.(y)) ||
        throw(ArgumentError("display series must contain finite numbers"))
    indices = if length(x) <= policy.max_points
        collect(eachindex(x))
    elseif policy.strategy === :uniform
        _uniform_indices(length(x), policy.max_points)
    else
        _lttb_indices(x, y, policy.max_points)
    end
    return (x = x[indices], y = y[indices], indices = indices)
end
