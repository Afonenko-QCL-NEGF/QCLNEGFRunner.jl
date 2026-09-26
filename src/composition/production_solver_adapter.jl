"""
    solve_production(problem; checkpoint_path=nothing, kwargs...)

Public composition adapter around the in-memory production solver. Checkpoint
paths and atomic file replacement remain outside numerical equations. With no
checkpoint path this entry point requires neither HDF5 nor a writable install.

See [the closed Poisson–SCBA loop](https://github.com/AfonenkoA/QCLNEGF.jl/blob/main/docs/src/theory/10_poisson.md),
[Production backend](https://github.com/AfonenkoA/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md), and the
[state persistence contract](@ref native-result-formats).
"""
function solve_production(
    problem::NEGFProblem;
    checkpoint_path::Union{Nothing,AbstractString} = nothing,
    checkpoint_sink::Union{Nothing,Function} = nothing,
    kwargs...,
)
    sink = if checkpoint_path===nothing
        checkpoint_sink
    else
        function (solution)
            checkpoint_sink===nothing || checkpoint_sink(solution)
            _atomic_checkpoint(checkpoint_path, solution)
        end
    end
    return QCLNEGF.solve_production(problem; checkpoint_sink = sink, kwargs...)
end
