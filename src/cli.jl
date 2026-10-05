function _cli_self_check(arguments)
    length(arguments) in (1,3) || throw(ArgumentError("self-check expects [--directory DIRECTORY]"))
    directory=tempdir()
    if length(arguments)==3
        arguments[2]=="--directory" || throw(ArgumentError("unknown self-check option"))
        directory=arguments[3]
    end
    _light_json(stdout,runner_self_check(;directory))
    println()
    return 0
end

function _cli_pause_verify(arguments)
    command=first(arguments)
    length(arguments) in (6,8) || throw(ArgumentError("$command expects OUTPUT --execution-id ID --attempt N [--archive-byte-budget BYTES]"))
    options=Dict{String,String}()
    for index in 3:2:length(arguments)
        flag=arguments[index]
        (flag in ("--execution-id","--attempt") ||
            (command!="pause" && flag=="--archive-byte-budget")) || throw(ArgumentError("unknown $command option $flag"))
        haskey(options,flag) && throw(ArgumentError("duplicate $command option $flag"))
        options[flag]=arguments[index+1]
    end
    haskey(options,"--execution-id") && haskey(options,"--attempt") || throw(ArgumentError("execution id and attempt are required"))
    execution_id=options["--execution-id"]
    attempt=parse(Int,options["--attempt"])
    archive_byte_budget=parse(Int,get(options,"--archive-byte-budget",string(64*1024^3)))
    if command=="pause"
        println(request_pause(abspath(arguments[2]),execution_id,attempt))
    elseif command=="verify-pause"
        _light_json(stdout,verify_pause_receipt(abspath(arguments[2]),execution_id,attempt;archive_byte_budget))
    else
        _light_json(stdout,verify_stop_receipt(abspath(arguments[2]),execution_id,attempt;archive_byte_budget))
    end
    return 0
end

function _cli_heavy(arguments)
    command=first(arguments)
    if command == "plan"
        length(arguments) in (2, 4) || throw(ArgumentError("plan expects CONFIG [--max-runs N]"))
        maximum = 10000
        if length(arguments) == 4
            arguments[3] == "--max-runs" || throw(ArgumentError("expected --max-runs"))
            maximum = parse(Int, arguments[4])
        end
        write_scientific_plan(stdout, resolve_scientific_plan(arguments[2]; maximum_solver_runs=maximum))
    elseif command == "run-plan"
        length(arguments) >= 3 && isodd(length(arguments)) ||
            throw(ArgumentError("run-plan expects PLAN OUTPUT [--execution-id ID] [--scratch-root DIRECTORY]"))
        options = Dict{String,String}()
        for index in 4:2:length(arguments)
            flag = arguments[index]
            flag in ("--execution-id", "--scratch-root", "--attempt", "--recovery-bundle", "--archive-bundle", "--archive-byte-budget") || throw(ArgumentError("unknown run-plan option $flag"))
            haskey(options, flag) && throw(ArgumentError("duplicate option $flag"))
            options[flag] = arguments[index+1]
        end
        result = execute_scientific_plan_staged(load_scientific_plan(arguments[2]), arguments[3];
            execution_id=get(options, "--execution-id", nothing),
            scratch_root=get(options, "--scratch-root", nothing),
            attempt=haskey(options,"--attempt") ? parse(Int,options["--attempt"]) : nothing,
            recovery_bundle=get(options,"--recovery-bundle",nothing),
            telemetry_sink=haskey(ENV,"QCL_TELEMETRY_ENDPOINT") ? http_telemetry_sink(ENV["QCL_TELEMETRY_ENDPOINT"]) : nothing,
            archive_bundle=get(options,"--archive-bundle",nothing),
            archive_byte_budget=haskey(options,"--archive-byte-budget") ? parse(Int,options["--archive-byte-budget"]) : 64*1024^3)
        write_scientific_result(stdout, result)
    elseif command == "analyze"
        length(arguments) in (2, 3) || throw(ArgumentError("analyze expects RESULTS [OUTPUT]"))
        output = length(arguments) == 3 ? arguments[3] : joinpath(arguments[2], "analysis")
        postprocess_series(arguments[2]; output_directory=output)
        println(joinpath(abspath(output), "report.md"))
    else
        throw(ArgumentError("unknown command: $command"))
    end
    return 0
end

"""Run the public `qcl-negf` command and return its process exit status."""
function main(arguments::AbstractVector{<:AbstractString}=ARGS)
    try
        isempty(arguments) && throw(ArgumentError(
            "usage: qcl-negf self-check [--directory DIRECTORY] | pause OUTPUT --execution-id ID --attempt N | verify-pause|verify-stop OUTPUT --execution-id ID --attempt N [--archive-byte-budget BYTES] | plan CONFIG [--max-runs N] | run-plan PLAN OUTPUT [OPTIONS] | analyze RESULTS [OUTPUT]"))
        command=first(arguments)
        # Keep operational commands outside the solver handler's inference graph.
        # The process status remains independent of scientific gates in artifacts.
        handler=command=="self-check" ? _cli_self_check :
            command in ("pause","verify-pause","verify-stop") ? _cli_pause_verify : _cli_heavy
        return Base.invokelatest(handler,arguments)
    catch error
        if error isa Union{ArgumentError,ConfigurationError}
            println(stderr,sprint(showerror,error))
            return 2
        end
        rethrow()
    end
end
