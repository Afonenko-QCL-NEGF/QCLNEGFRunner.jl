"""Run the public `qcl-negf` command and return its process exit status."""
function main(arguments::AbstractVector{<:AbstractString}=ARGS)
    try
        isempty(arguments) && throw(ArgumentError(
            "usage: qcl-negf plan CONFIG [--max-runs N] | run-plan PLAN OUTPUT [--execution-id ID] [--scratch-root DIRECTORY] | analyze RESULTS [OUTPUT]"))
        command = first(arguments)
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
                flag in ("--execution-id", "--scratch-root") || throw(ArgumentError("unknown run-plan option $flag"))
                haskey(options, flag) && throw(ArgumentError("duplicate option $flag"))
                options[flag] = arguments[index+1]
            end
            result = execute_scientific_plan_staged(load_scientific_plan(arguments[2]), arguments[3];
                execution_id=get(options, "--execution-id", nothing),
                scratch_root=get(options, "--scratch-root", nothing))
            write_scientific_result(stdout, result)
        elseif command == "analyze"
            length(arguments) in (2, 3) || throw(ArgumentError("analyze expects RESULTS [OUTPUT]"))
            output = length(arguments) == 3 ? arguments[3] : joinpath(arguments[2], "analysis")
            postprocess_series(arguments[2]; output_directory=output)
            println(joinpath(abspath(output), "report.md"))
        else
            throw(ArgumentError("unknown command: $command"))
        end
        # Scientific gates are recorded in the result independently of process success.
        return 0
    catch error
        if error isa Union{ArgumentError,ConfigurationError}
            println(stderr, sprint(showerror, error))
            return 2
        end
        rethrow()
    end
end
