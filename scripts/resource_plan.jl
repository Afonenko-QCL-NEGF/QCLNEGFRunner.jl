#!/usr/bin/env julia

using QCLNEGFRunner

function usage(io::IO = stdout)
    println(io, "usage: julia --project=. scripts/resource_plan.jl \\")
    println(io, "  --configuration PATH --output FILE [--benchmark] \\")
    println(io, "  [--maximum-seconds SECONDS] [--repetitions COUNT]")
end

function argument_value(arguments, index, option)
    index < length(arguments) || error("$option requires a value")
    return arguments[index+1]
end

function parse_arguments(arguments)
    configuration = nothing
    output = nothing
    benchmark = false
    maximum_seconds = 5.0
    repetitions = 3
    index = 1
    while index <= length(arguments)
        argument = arguments[index]
        if argument == "--configuration"
            configuration = argument_value(arguments, index, argument)
            index += 2
        elseif argument == "--output"
            output = argument_value(arguments, index, argument)
            index += 2
        elseif argument == "--benchmark"
            benchmark = true
            index += 1
        elseif argument == "--maximum-seconds"
            maximum_seconds = parse(Float64, argument_value(arguments, index, argument))
            index += 2
        elseif argument == "--repetitions"
            repetitions = parse(Int, argument_value(arguments, index, argument))
            index += 2
        elseif argument in ("--help", "-h")
            usage()
            exit(0)
        else
            error("unknown argument: $argument")
        end
    end
    configuration === nothing && error("--configuration is required")
    output === nothing && error("--output is required")
    return (;
        configuration = String(configuration),
        output = String(output),
        benchmark,
        maximum_seconds,
        repetitions,
    )
end

function main(arguments)
    options = parse_arguments(arguments)
    configuration = load_run_configuration(options.configuration)
    hardware = probe_hardware()
    plan, calibration = calibrate_execution_plan(
        configuration;
        hardware,
        run_benchmark = options.benchmark,
        maximum_seconds = options.maximum_seconds,
        repetitions = options.repetitions,
    )
    destination = save_resource_diagnostics(options.output, plan; calibration)
    println("Resource diagnostics: ", destination)
    println(
        "CPU: ",
        hardware.logical_cpus,
        " effective / ",
        hardware.julia_threads,
        " Julia threads",
    )
    println(
        "Memory budget: ",
        plan.memory_budget_bytes,
        " bytes; ",
        "estimated peak: ",
        plan.estimated_peak_bytes,
        " bytes",
    )
    println(
        "Schedule: ",
        plan.parallel_backend,
        ", workers=",
        plan.worker_count,
        ", BLAS threads=",
        plan.blas_threads,
        ", energy chunk=",
        plan.energy_chunk,
    )
    return nothing
end

try
    main(ARGS)
catch error
    usage(stderr)
    showerror(stderr, error)
    println(stderr)
    exit(2)
end
