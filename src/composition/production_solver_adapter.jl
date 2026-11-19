"""
    solve_production(problem; checkpoint_path=nothing, kwargs...)

Вызвать основной решатель, работающий в памяти. Обработка пути контрольной
точки и атомарная замена файла выполняются в адаптере. При
`checkpoint_path=nothing` контрольная точка HDF5 не записывается.

См. [совместный цикл Пуассона и SCBA](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/10_poisson.md),
[основной решатель](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md)
и [сохранение состояния](@ref native-result-formats).
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
