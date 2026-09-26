function _resource_read(path::AbstractString)
    try
        return strip(read(path, String))
    catch
        return ""
    end
end

function _resource_integer(value::AbstractString)
    text = strip(value)
    text in ("", "max") && return typemax(Int)
    parsed = tryparse(BigInt, text)
    parsed === nothing && return typemax(Int)
    0 <= parsed <= typemax(Int) || return typemax(Int)
    return Int(parsed)
end

function _cpuset_count(value::AbstractString)
    text = strip(value)
    isempty(text) && return typemax(Int)
    total = 0
    seen = Set{Int}()
    for item in split(text, ',')
        bounds = split(strip(item), '-'; limit = 2)
        isempty(bounds) && return typemax(Int)
        first_cpu = tryparse(Int, bounds[1])
        first_cpu === nothing && return typemax(Int)
        last_cpu = length(bounds) == 1 ? first_cpu : tryparse(Int, bounds[2])
        last_cpu === nothing && return typemax(Int)
        0 <= first_cpu <= last_cpu || return typemax(Int)
        for cpu = first_cpu:last_cpu
            cpu in seen && continue
            push!(seen, cpu)
            total += 1
        end
    end
    return total > 0 ? total : typemax(Int)
end

function _process_cgroup_path(proc_root::AbstractString)
    contents = _resource_read(joinpath(proc_root, "self", "cgroup"))
    for line in split(contents, '\n')
        startswith(line, "0::") || continue
        requested = strip(line[4:end])
        relative = normpath(replace(requested, r"^/+" => ""))
        relative in ("", ".") && return "."
        first(splitpath(relative)) == ".." && return "."
        return relative
    end
    return "."
end

function _cgroup_ancestors(cgroup_root::AbstractString, relative::AbstractString)
    root = abspath(cgroup_root)
    current = abspath(joinpath(root, relative))
    first(splitpath(relpath(current, root))) == ".." && (current = root)
    result = String[]
    while true
        push!(result, current)
        current == root && break
        parent = dirname(current)
        parent == current && break
        current = parent
    end
    return result
end

function _minimum_cgroup_value(ancestors, name::AbstractString)
    values = [_resource_integer(_resource_read(joinpath(path, name))) for path in ancestors]
    return isempty(values) ? typemax(Int) : minimum(values)
end

function _cgroup_available_headroom(ancestors)
    headroom = typemax(Int)
    for path in ancestors
        current_text = _resource_read(joinpath(path, "memory.current"))
        current = _resource_integer(current_text)
        for name in ("memory.high", "memory.max")
            limit = _resource_integer(_resource_read(joinpath(path, name)))
            limit == typemax(Int) && continue
            # A finite limit without a readable current value cannot be used
            # safely as available capacity.
            current == typemax(Int) && return 0
            headroom = min(headroom, max(0, limit - current))
        end
    end
    return headroom
end

function _memory_available_from_proc(proc_root::AbstractString)
    contents = _resource_read(joinpath(proc_root, "meminfo"))
    matched = match(r"(?m)^MemAvailable:\s*([0-9]+)\s+kB\s*$", contents)
    matched === nothing && return 0
    value = tryparse(BigInt, matched.captures[1])
    value === nothing && return 0
    bytes = value * 1024
    0 <= bytes <= typemax(Int) || return 0
    return Int(bytes)
end

function _process_affinity_count(proc_root::AbstractString)
    contents = _resource_read(joinpath(proc_root, "self", "status"))
    matched = match(r"(?m)^Cpus_allowed_list:\s*(\S+)\s*$", contents)
    matched === nothing && return typemax(Int)
    return _cpuset_count(matched.captures[1])
end

function _cpu_quota_cores(ancestors)
    result = Inf
    for path in ancestors
        fields = split(_resource_read(joinpath(path, "cpu.max")))
        length(fields) == 2 || continue
        first(fields) == "max" && continue
        quota = tryparse(Float64, fields[1])
        period = tryparse(Float64, fields[2])
        if quota === nothing ||
           period === nothing ||
           !isfinite(quota) ||
           !isfinite(period) ||
           period <= 0 ||
           quota <= 0
            continue
        end
        result = min(result, quota / period)
    end
    return result
end

"""
    probe_hardware(; ...)

Observe the resource envelope visible to the current Julia process. On Linux
the probe follows `/proc/self/cgroup` to the process' cgroup-v2 directory and
combines every ancestor's memory and CPU bounds with process affinity. Keyword
paths and capacity overrides exist so the parser can be tested without reading
the test runner's real machine.
"""
function probe_hardware(;
    proc_root::AbstractString = "/proc",
    cgroup_root::AbstractString = "/sys/fs/cgroup",
    physical_memory_override::Union{Nothing,Integer} = nothing,
    available_memory_override::Union{Nothing,Integer} = nothing,
    host_logical_cpus::Integer = Sys.CPU_THREADS,
    julia_threads::Integer = Base.Threads.nthreads(:default),
    blas_vendor_override::Union{Nothing,AbstractString} = nothing,
)
    physical_memory = if physical_memory_override === nothing
        try
            Int(Sys.total_memory())
        catch
            0
        end
    else
        Int(physical_memory_override)
    end
    physical_memory >= 0 ||
        throw(ArgumentError("physical memory override cannot be negative"))
    host_logical_cpus > 0 || throw(ArgumentError("host logical CPU count must be positive"))
    julia_threads > 0 || throw(ArgumentError("Julia thread count must be positive"))

    relative_cgroup = _process_cgroup_path(proc_root)
    ancestors = _cgroup_ancestors(cgroup_root, relative_cgroup)
    current_cgroup = first(ancestors)
    memory_max = _minimum_cgroup_value(ancestors, "memory.max")
    memory_high = _minimum_cgroup_value(ancestors, "memory.high")
    current_memory =
        _resource_integer(_resource_read(joinpath(current_cgroup, "memory.current")))
    current_memory == typemax(Int) && (current_memory = 0)
    effective_memory = min(physical_memory, memory_max, memory_high)

    system_available =
        available_memory_override === nothing ? _memory_available_from_proc(proc_root) :
        Int(available_memory_override)
    system_available < 0 &&
        throw(ArgumentError("available memory override cannot be negative"))
    if system_available == 0 && available_memory_override === nothing
        system_available = try
            Int(Sys.free_memory())
        catch
            0
        end
    end
    cgroup_headroom = _cgroup_available_headroom(ancestors)
    effective_available = min(system_available, effective_memory, cgroup_headroom)

    affinity_count = _process_affinity_count(proc_root)
    cpuset_count =
        _cpuset_count(_resource_read(joinpath(current_cgroup, "cpuset.cpus.effective")))
    quota_cores = _cpu_quota_cores(ancestors)
    # A fractional quota is a time allowance, not an extra continuously
    # available core.  Rounding up would let a 1.5-core cgroup schedule two
    # fully occupied workers and create avoidable throttling.  One worker is
    # the irreducible execution unit when the quota is below one core.
    quota_workers = isfinite(quota_cores) ? max(1, floor(Int, quota_cores)) : typemax(Int)
    effective_cpus =
        min(Int(host_logical_cpus), affinity_count, cpuset_count, quota_workers)
    effective_cpus > 0 ||
        throw(ArgumentError("detected process CPU envelope contains no usable CPUs"))

    vendor = if blas_vendor_override === nothing
        try
            string(BLAS.vendor())
        catch
            "unknown"
        end
    else
        String(blas_vendor_override)
    end
    cpu_constraints = String[]
    affinity_count < host_logical_cpus && push!(cpu_constraints, "affinity")
    cpuset_count < host_logical_cpus && push!(cpu_constraints, "cpuset")
    isfinite(quota_cores) && push!(cpu_constraints, "cpu.max")
    cpu_source = isempty(cpu_constraints) ? "process CPU set" : join(cpu_constraints, "+")
    memory_constraints = String[]
    memory_high < physical_memory && push!(memory_constraints, "memory.high")
    memory_max < physical_memory && push!(memory_constraints, "memory.max")
    effective_available < effective_memory &&
        push!(memory_constraints, "available headroom")
    memory_source =
        isempty(memory_constraints) ? "physical memory" : join(memory_constraints, "+")

    return HardwareProfile(
        Int(julia_threads),
        effective_cpus,
        effective_memory,
        effective_available,
        vendor,
        physical_memory,
        memory_max,
        memory_high,
        current_memory,
        affinity_count,
        quota_cores,
        relative_cgroup,
        cpu_source,
        memory_source,
    )
end

# Explicit adapter for the application resource port.
default_hardware_profile() = probe_hardware()
