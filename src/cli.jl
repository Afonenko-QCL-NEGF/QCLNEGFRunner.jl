function _cli_compare(arguments)
    length(arguments) >= 5 && isodd(length(arguments)) || throw(ArgumentError("compare expects CATALOG.csv OUTPUT --reference-id ID [--temperature-atol K] [--voltage-atol V] [--maximum-input-bytes BYTES]"))
    options = Dict{String,String}()
    for index in 4:2:length(arguments)
        flag = arguments[index]
        flag in ("--reference-id","--temperature-atol","--voltage-atol","--maximum-input-bytes") || throw(ArgumentError("unknown compare option $flag"))
        haskey(options,flag) && throw(ArgumentError("duplicate compare option $flag"))
        options[flag] = arguments[index+1]
    end
    haskey(options,"--reference-id") || throw(ArgumentError("compare requires --reference-id"))
    function tolerance(flag, default, unit)
        value = get(options,flag,default)
        parsed = tryparse(Float64,value)
        parsed === nothing && throw(ArgumentError("invalid_matching_tolerance: $flag ($unit): $value"))
        return parsed
    end
    result = compare_saved_results(arguments[2],arguments[3];reference_id=options["--reference-id"],
        temperature_atol=tolerance("--temperature-atol","1e-9","K"),
        voltage_atol=tolerance("--voltage-atol","1e-12","V"),
        maximum_input_bytes=parse(Int,get(options,"--maximum-input-bytes",string(16*1024^2))))
    for path in values(result.paths)
        println(path)
    end
    return 0
end

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

function _cli_configure(arguments)
    length(arguments) in (5,6) || throw(ArgumentError("configure expects --catalog-root ROOT --catalog-source-id ID [--catalog]"))
    arguments[2]=="--catalog-root" && arguments[4]=="--catalog-source-id" || throw(ArgumentError("invalid trusted configure arguments"))
    catalog=length(arguments)==6
    catalog && arguments[6]!="--catalog" && throw(ArgumentError("unknown configure option"))
    response=if catalog
        QCLScientificWorkflow.configurator_catalog(arguments[3],arguments[5])
    else
        bytes=read(stdin,QCLScientificWorkflow.CONFIGURATOR_REQUEST_BYTES+1)
        QCLScientificWorkflow.configurator_preview(String(bytes),arguments[3],arguments[5])
    end
    _light_json(stdout,response)
    println()
    return get(response,"status",nothing)=="available" ? 0 : 2
end

function _cli_resource_proposal(arguments)
    length(arguments) in (5,11) || throw(ArgumentError("resource-proposal expects --runner-source-id ID --core-source-id ID [--runtime-id ID --margin-policy-file FILE --margin-policy-sha256 SHA]"))
    arguments[2]=="--runner-source-id" && arguments[4]=="--core-source-id" ||
        throw(ArgumentError("invalid trusted resource-proposal arguments"))
    bytes=read(stdin,QCLScientificWorkflow.RESOURCE_PROPOSAL_REQUEST_BYTES+1)
    trusted_policy=nothing;runtime_id=nothing;policy_failure=nothing
    if length(arguments)==11
        arguments[6]=="--runtime-id" && arguments[8]=="--margin-policy-file" && arguments[10]=="--margin-policy-sha256" ||
            throw(ArgumentError("invalid trusted margin-policy arguments"))
        runtime_id=arguments[7]
        try
            trusted_policy=QCLScientificWorkflow._resource_load_policy(arguments[9],arguments[11],runtime_id,arguments[3],arguments[5])
        catch error
            error isa QCLScientificWorkflow.ResourceForecastUnavailable || rethrow()
            policy_failure=error.detail
        end
    end
    response=QCLScientificWorkflow.resource_proposal(String(bytes),arguments[3],arguments[5];trusted_policy,runtime_id,policy_failure)
    _light_json(stdout,response)
    println()
    return get(response,"status",nothing)=="available" ? 0 : 2
end

function _cli_quantum_preview(arguments)
    length(arguments) in (5,7) || throw(ArgumentError("quantum-preview expects --runner-source-id ID --core-source-id ID [--output FILE]"))
    arguments[2]=="--runner-source-id" && arguments[4]=="--core-source-id" ||
        throw(ArgumentError("invalid trusted quantum-preview arguments"))
    output=nothing
    if length(arguments)==7
        arguments[6]=="--output" || throw(ArgumentError("unknown quantum-preview option"))
        output=arguments[7]
    end
    bytes=read(stdin,QCLScientificWorkflow.QUANTUM_REQUEST_BYTES+1)
    response=QCLScientificWorkflow.quantum_preview(String(bytes),arguments[3],arguments[5])
    try
        QCLScientificWorkflow.write_quantum_preview(stdout,response;output)
    catch failure
        failure isa QCLScientificWorkflow.QuantumPreviewRefusal || rethrow()
        throw(ArgumentError("Quantum preview output refused: "*failure.code))
    end
    return get(response,"status",nothing)=="available" ? 0 : 2
end

function _cli_parent_checkpoint(options::AbstractDict, artifact_root::AbstractString)
    flags=("--parent-pointer","--parent-identity","--parent-metadata-bytes")
    present=count(flag->haskey(options,flag),flags)
    present==0 && return nothing
    present==length(flags) || throw(ArgumentError("parent pointer, identity and metadata byte allowance must be supplied together"))
    allowance=tryparse(Int,options["--parent-metadata-bytes"])
    allowance !== nothing && allowance>0 || throw(ArgumentError("parent metadata byte allowance must be a positive integer"))
    path=options["--parent-identity"]
    islink(path) && throw(ArgumentError("invalid parent identity file"))
    bytes=open(io->read(io,256*1024+1),path)
    length(bytes)<=256*1024 || throw(ArgumentError("parent identity file exceeds byte limit"))
    text=String(bytes)
    isvalid(text) || throw(ArgumentError("invalid parent identity UTF-8"))
    identity=_p04_parse(text)
    identity isa AbstractDict || throw(ArgumentError("invalid parent identity"))
    _p04_identity(identity)
    return open_exact_checkpoint(artifact_root,options["--parent-pointer"];
        expected_identity=identity,maximum_metadata_bytes=allowance)
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
            flag in ("--execution-id", "--scratch-root", "--attempt", "--recovery-bundle", "--archive-bundle", "--archive-byte-budget", "--source-graph", "--parent-pointer", "--parent-identity", "--parent-metadata-bytes", "--native-execution", "--native-calcjob-uuid") || throw(ArgumentError("unknown run-plan option $flag"))
            haskey(options, flag) && throw(ArgumentError("duplicate option $flag"))
            options[flag] = arguments[index+1]
        end
        native_mode=haskey(options,"--native-execution")
        native_mode==haskey(options,"--native-calcjob-uuid") || throw(ArgumentError("native execution and CalcJob options must be paired"))
        native_options=Set(["--execution-id","--source-graph","--native-execution","--native-calcjob-uuid"])
        !native_mode || Set(keys(options))==native_options || throw(ArgumentError("unsupported native run-plan options"))
        parent_checkpoint=_cli_parent_checkpoint(options,arguments[3])
        loaded=QCLScientificWorkflow._load_scientific_plan_bytes(arguments[2])
        plan=loaded.plan
        native_origin=native_mode ? _native_origin_inputs(arguments[2],options["--source-graph"],
            options["--native-execution"],arguments[3],options["--native-calcjob-uuid"],options["--execution-id"];
            frozen_plan_bytes=loaded.bytes) : nothing
        native_capture_input=get(ENV,"QCL_NEGF_NATIVE_CAPTURE_INPUT","")
        # The fixed native protocol omits --attempt and does not enable scratch.
        capture_options=isempty(native_capture_input) || Set(keys(options))==(native_mode ? native_options : Set(["--execution-id","--source-graph"]))
        if native_mode && !isempty(native_capture_input)
            capture_options &= abspath(native_capture_input)==abspath(options["--native-execution"])
        end
        capture_context=capture_options ? _capture_context(plan,arguments[3],get(options,"--execution-id",nothing),
            haskey(options,"--attempt") ? parse(Int,options["--attempt"]) : nothing;
            scratch_root=get(options,"--scratch-root",nothing),
            frozen_plan_bytes=loaded.bytes,source_plan_path=arguments[2],
            native_execution_path=native_mode ? options["--native-execution"] : isempty(native_capture_input) ? nothing : native_capture_input,
            source_graph_path=get(options,"--source-graph",nothing),native_origin) : nothing
        result = execute_scientific_plan_staged(plan, arguments[3];
            capture_context,
            native_origin,
            frozen_plan_capture=loaded.capture,
            source_graph=haskey(options,"--source-graph") ? _load_source_graph_file(options["--source-graph"]) : nothing,
            parent_checkpoint,
            execution_id=get(options, "--execution-id", nothing),
            scratch_root=get(options, "--scratch-root", nothing),
            attempt=haskey(options,"--attempt") ? parse(Int,options["--attempt"]) : nothing,
            recovery_bundle=get(options,"--recovery-bundle",nothing),
            telemetry_sink=haskey(ENV,"QCL_TELEMETRY_ENDPOINT") ? http_telemetry_sink(ENV["QCL_TELEMETRY_ENDPOINT"]) : nothing,
            archive_bundle=get(options,"--archive-bundle",nothing),
            archive_byte_budget=haskey(options,"--archive-byte-budget") ? parse(Int,options["--archive-byte-budget"]) : 64*1024^3)
        # Typed DTO output is independent of Q1 transport-close. The stationary
        # entry gate remains until the same DTO readers/actor/close are qualified.
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
            "usage: qcl-negf self-check [--directory DIRECTORY] | pause OUTPUT --execution-id ID --attempt N | verify-pause|verify-stop OUTPUT --execution-id ID --attempt N [--archive-byte-budget BYTES] | plan CONFIG [--max-runs N] | run-plan PLAN OUTPUT [OPTIONS] | analyze RESULTS [OUTPUT] | compare CATALOG.csv OUTPUT --reference-id ID [OPTIONS]"))
        command=first(arguments)
        # Keep operational commands outside the solver handler's inference graph.
        # The process status remains independent of scientific gates in artifacts.
        handler=command=="configure" ? _cli_configure :
            command=="quantum-preview" ? _cli_quantum_preview :
            command=="resource-proposal" ? _cli_resource_proposal :
            command=="compare" ? _cli_compare :
            command=="self-check" ? _cli_self_check :
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
