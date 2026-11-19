"""Интерфейс предоставления ресурсов. При самостоятельном запуске можно передать границы ресурсов явно."""
default_execution_envelope() = nothing

function _grant_integer(value, name; minimum = 1)
    value isa Integer && !(value isa Bool) && minimum <= value <= typemax(Int) || throw(
        ArgumentError(
            "execution envelope $name must be a representable integer >= $minimum",
        ),
    )
    return Int(value)
end

"""Раздельные ограничения численных операций и процесса, заданные вызывающей программой.

Пул потоков Julia выделяется при запуске. `cpu_ids` описывает процессоры,
доступные по настройкам привязки ОС. Их набор может увеличиваться в границах
пула при переходе между безопасными этапами.
"""
struct ExecutionEnvelope
    token::String
    numerical_memory_bytes::Int
    runtime_memory_bytes::Int
    allocator_memory_bytes::Int
    hard_memory_bytes::Int
    thread_pool_size::Int
    cpu_ids::Vector{Int}

    function ExecutionEnvelope(token, numerical, runtime, allocator, hard, threads, cpus)
        token isa AbstractString && !isempty(token) ||
            throw(ArgumentError("execution envelope requires a allocation identity"))
        numerical = _grant_integer(numerical, "numerical_memory_bytes")
        runtime = _grant_integer(runtime, "runtime_memory_bytes")
        allocator = _grant_integer(allocator, "allocator_memory_bytes")
        hard = _grant_integer(hard, "hard_memory_bytes")
        threads = _grant_integer(threads, "thread_pool_size")
        big(numerical) + runtime + allocator <= hard || throw(
            ArgumentError("numerical buffers and overhead exceed the hard memory grant"),
        )
        (cpus isa AbstractVector || cpus isa Tuple) && !isempty(cpus) ||
            throw(ArgumentError("execution CPU grant requires a nonempty sequence"))
        cpu_ids = [_grant_integer(cpu, "cpu_ids"; minimum = 0) for cpu in cpus]
        length(unique(cpu_ids)) == length(cpu_ids) && length(cpu_ids) <= threads ||
            throw(ArgumentError("invalid execution CPU grant"))
        return new(String(token), numerical, runtime, allocator, hard, threads, cpu_ids)
    end
end

function execution_budget(hardware, envelope::ExecutionEnvelope)
    hardware.cgroup_memory_max_bytes >= envelope.hard_memory_bytes ||
        throw(ArgumentError("observed memory.max is below the explicit resource grant"))
    hardware.julia_threads >= envelope.thread_pool_size ||
        throw(ArgumentError("Julia thread pool is smaller than the explicit resource grant"))
    # Current runtime pages and allocator headroom were charged by the authority.
    # They must never be subtracted a second time from the numerical allowance.
    return envelope.numerical_memory_bytes, 0
end
