#!/usr/bin/env julia
# Explicit local integration operations. No production campaign or automatic retry.
module LocalLabAcceptance
using SHA

const USAGE = """
Usage: julia --project=IMMUTABLE_ENV tools/local_lab_acceptance.jl MODE ARGS
  native OUTPUT                  seeded native storage fixture; no SCBA/Poisson
  prepare DIRECTORY              freeze the existing bounded two-point diagnostic
  pause DIRECTORY OUTPUT         request second-point pause; attempt 1
  resume DIRECTORY PRIOR OUTPUT  portable copied recovery + prior archive; attempt 2
  staging SOURCE DEST            verified atomic stage_result_tree copy
Every path must be absolute and canonical. Outputs must not already exist.
External operator budget: timeout1200, CPU1, RAM1792MiB for each physical phase.
Scientific acceptance is separate from driver exit status; no convergence claim.
"""
const SOURCE_ROOT = normpath(joinpath(@__DIR__, ".."))
const BASE_CONFIGURATION = joinpath(SOURCE_ROOT, "test", "fixtures", "configurations", "studies-smoke.yaml")

function canonical_path(path::AbstractString)
    isabspath(path) && normpath(path) == path && path != "/" ||
        throw(ArgumentError("require an absolute canonical non-root path"))
    current = ""
    for component in splitpath(path)
        current = joinpath(current, component)
        islink(current) && throw(ArgumentError("symbolic-link path component is not owned: $current"))
    end
    return String(path)
end
function fresh_output(path::AbstractString)
    canonical_path(path)
    (ispath(path) || islink(path)) && throw(ArgumentError("output already exists; refusing adoption: $path"))
    return String(path)
end
function checked_input(path::AbstractString)
    canonical_path(path)
    isdir(path) || throw(ArgumentError("input must be an existing owned directory: $path"))
    return String(path)
end
function contained_file(root::AbstractString, relative::AbstractString)
    checked_input(root)
    isabspath(relative) && throw(ArgumentError("artifact reference must be relative"))
    path = canonical_path(joinpath(root, relative))
    startswith(path, root * string(Base.Filesystem.path_separator)) ||
        throw(ArgumentError("artifact reference escapes its root"))
    isfile(path) || throw(ArgumentError("required artifact is missing: $path"))
    return path
end
function reserve_output(path)
    fresh_output(path)
    mkpath(dirname(path))
    mkdir(path; mode=0o700)
    return path
end
function validate_arguments(arguments)
    isempty(arguments) && throw(ArgumentError(USAGE))
    mode = first(arguments)
    count = get(Dict("native"=>1, "prepare"=>1, "pause"=>2, "resume"=>3, "staging"=>2), mode, -1)
    count >= 0 && length(arguments) == count + 1 || throw(ArgumentError(USAGE))
    for path in arguments[2:end]
        canonical_path(path)
    end
    return mode, arguments[2:end]
end
function preflight(mode, paths)
    if mode in ("native", "prepare")
        fresh_output(paths[1])
    elseif mode == "pause"
        checked_input(paths[1]); fresh_output(paths[2])
    elseif mode == "resume"
        checked_input(paths[1]); checked_input(paths[2]); fresh_output(paths[3])
        fresh_output(paths[3] * ".portable-input")
    else
        checked_input(paths[1]); fresh_output(paths[2])
        fresh_output(paths[2] * ".staging-evidence.json")
    end
    return nothing
end
function load_runtime()
    VERSION == v"1.13.0" || throw(ArgumentError("acceptance runtime requires Julia1.13.0 exactly"))
    @eval using QCLNEGFRunner
    @eval using YAML
    @eval import LinearAlgebra
    Base.invokelatest(LinearAlgebra.BLAS.set_num_threads, 1)
    Threads.nthreads() == 1 || throw(ArgumentError("physical acceptance requires exactly one Julia thread"))
    include(joinpath(SOURCE_ROOT, "test", "support", "native_physics_fixture.jl"))
    return nothing
end
hash_file(path) = bytes2hex(open(SHA.sha256, path))
function write_json_once(path, document)
    fresh_output(path)
    QCLNEGFRunner._observability_atomic_text(path) do io
        QCLNEGFRunner._light_json(io, document)
        println(io)
    end
    QCLNEGFRunner._sync_artifact_file(path)
    QCLNEGFRunner._sync_artifact_directory(dirname(path))
    return path
end
function metadata(mode; extra...)
    return Dict{String,Any}(
        "schema"=>"qcl-negf-local-lab-acceptance-v1", "mode"=>mode,
        "scope"=>"diagnostic integration; no production/experimental validation",
        "julia_version"=>string(VERSION), "julia_threads"=>Threads.nthreads(),
        "driver_sha256"=>hash_file(@__FILE__), "runner_source"=>SOURCE_ROOT,
        "iterative_converged"=>"not_measured", "discretization_verified"=>"not_measured",
        "experimental_validation"=>"not_measured", "scientific_accepted"=>false,
        (String(k)=>v for (k,v) in extra)...,
    )
end
function diagnostic_definition(; native=false, numerical=Dict{String,Any}())
    overrides = Dict{String,Any}(
        "numerical"=>native ? numerical : Dict("energy_min"=>"-0.5 eV", "energy_max"=>"1.5 eV"),
        "production"=>Dict("worker_count"=>1, "parallel_backend"=>"blas", "checkpoint_every_scba"=>0),
        "execution"=>Dict("strategy"=>"manual"),
    )
    if native
        overrides["scattering"] = Dict(k=>false for k in
            ("lo_phonon", "acoustic_phonon", "ionized_impurity", "interface_roughness", "alloy_disorder"))
        overrides["physical"] = Dict("lattice_temperature"=>"200 K", "lo_temperature"=>"200 K")
    else
        overrides["solver"] = Dict("maximum_scba_iterations"=>2, "maximum_poisson_iterations"=>1)
    end
    return Dict{String,Any}(
        "schema"=>"qcl-negf-study-v2", "kind"=>"study",
        "id"=>native ? "local-native-storage" : "portable-two-point", "purpose"=>"diagnostic",
        "configuration"=>Dict("sources"=>[BASE_CONFIGURATION], "overrides"=>overrides),
        "axes"=>Dict("temperatures"=>Dict("values"=>[native ? 200 : 70], "unit"=>"K"),
            "voltages"=>Dict("values"=>native ? [56] : [50,56], "unit"=>"mV")),
        "policies"=>Dict("voltage"=>Dict("mode"=>"strict", "invalid_predecessor"=>"cold_start")),
        "output"=>Dict("archive"=>Dict("full_final"=>true, "optical"=>false),
            "recovery"=>Dict("reserve_bytes"=>0)),
    )
end
function freeze_definition(root, definition)
    path = joinpath(root, "study.yaml")
    YAML.write_file(path, definition)
    plan = QCLNEGFRunner.resolve_scientific_plan(path)
    open(joinpath(root, "scientific_plan.json"), "w") do io
        QCLNEGFRunner.write_scientific_plan(io, plan)
    end
    write_json_once(joinpath(root, "plan-identity.json"), Dict(
        "plan_sha256"=>hash_file(joinpath(root, "scientific_plan.json")),
        "plan_fingerprint"=>plan.fingerprint, "execution_id"=>only(plan.executions).id,
        "definition_sha256"=>hash_file(path), "base_configuration_sha256"=>hash_file(BASE_CONFIGURATION)))
    return plan
end
function frozen_plan(root)
    checked_input(root)
    path = contained_file(root, "scientific_plan.json")
    identity = YAML.load_file(contained_file(root, "plan-identity.json"); dicttype=Dict{String,Any})
    hash_file(path) == identity["plan_sha256"] || throw(ArgumentError("frozen plan bytes changed"))
    hash_file(contained_file(root,"study.yaml")) == identity["definition_sha256"] ||
        throw(ArgumentError("frozen definition bytes changed"))
    plan = QCLNEGFRunner.load_scientific_plan(path)
    plan.fingerprint == identity["plan_fingerprint"] || throw(ArgumentError("frozen plan identity changed"))
    only(plan.executions).id == identity["execution_id"] || throw(ArgumentError("frozen execution identity changed"))
    identity["base_configuration_sha256"] == hash_file(BASE_CONFIGURATION) ||
        throw(ArgumentError("driver source fixture differs from the frozen input"))
    return plan, identity, path
end
function validate_physical_plan(plan)
    length(plan.executions) == 1 && length(plan.points) == 2 || error("require the frozen two-point fixture")
    configuration = only(plan.executions).configuration
    n = QCLNEGFRunner.numerical_parameters(configuration)
    (n.N_z,n.N_b,n.N_E,n.N_k) == (48,3,49,5) || error("portable fixture grid changed")
    raw = QCLNEGFRunner.resolved_configuration_dict(configuration)
    raw["numerical"]["energy_min"] == "-0.5 eV" && raw["numerical"]["energy_max"] == "1.5 eV" ||
        error("portable fixture energy window changed")
    scatter = QCLNEGFRunner.scattering_options(configuration)
    all(getfield(scatter, field) for field in (:LO,:acoustic,:impurity,:IFR)) && !scatter.alloy ||
        error("portable fixture scattering changed")
    options = QCLNEGFRunner.solver_options(configuration)
    (options.max_scba,options.max_poisson) == (2,1) || error("portable fixture budget changed")
    baseline = QCLNEGFRunner.load_run_configuration(BASE_CONFIGURATION).raw
    raw["solver"]["tolerances"] == baseline["solver"]["tolerances"] || error("portable tolerances changed")
    all(point.temperature_K == 70 for point in plan.points) &&
        [point.voltage_per_period_V for point in plan.points] == [0.05,0.056] || error("portable axes changed")
    return nothing
end
function prepare(root)
    reserve_output(root)
    plan = freeze_definition(root, diagnostic_definition())
    validate_physical_plan(plan)
    write_json_once(joinpath(root, "prepare-evidence.json"), metadata("prepare";
        plan_fingerprint=plan.fingerprint, maximum_scba_iterations=2, maximum_poisson_iterations=1,
        source_fixture="test/integration/portable_two_point_resume.jl", scattering_retained=true))
end
function native(root)
    reserve_output(root)
    # Existing seeded state: zero accepted iterations, all channels disabled by its owner.
    solution = native_physics_fixture(; energy_nodes=33)
    n = solution.problem.numerical
    fields = Dict("spatial_nodes"=>:N_z, "basis_states"=>:N_b, "basis_periods"=>:P_basis,
        "energy_nodes"=>:N_E, "momentum_nodes"=>:N_k, "angular_nodes"=>:N_φ,
        "longitudinal_momentum_nodes"=>:N_qz)
    numeric = Dict{String,Any}(key=>getfield(n, field) for (key,field) in fields)
    for (key,field) in (("energy_min",:E_min),("energy_max",:E_max),("energy_trust_margin",:M_E),
        ("momentum_max",:k_max),("longitudinal_momentum_max",:qz_max),("seed_broadening",:η_seed))
        numeric[key] = string(getfield(n, field))
    end
    plan = freeze_definition(root, diagnostic_definition(;native=true,numerical=numeric))
    execution, point = only(plan.executions), only(plan.points)
    identity = Dict{String,Any}("point_id"=>point.id, "execution_id"=>execution.id,
        "attempt"=>1, "plan_fingerprint"=>plan.fingerprint, "producer_kind"=>"native-storage-fixture",
        "scientific_validation"=>"not_performed")
    commit_path = QCLNEGFRunner.commit_point_artifacts(root, solution; identity,
        storage_class=:archive, archive_root=joinpath(root,"archive",execution.id,point.id),
        configuration=QCLNEGFRunner.resolved_configuration_dict(execution.configuration), reserve_bytes=0)
    commit = QCLNEGFRunner.verify_point_artifacts(commit_path)
    commit["scientific_accepted"] === false || error("storage fixture must not be scientifically accepted")
    workflow = QCLNEGFRunner.QCLScientificWorkflow
    record = workflow._point_result(point, 1, workflow._initialization("cold"), :failed, :unconverged, false;
        warnings=[Dict{String,Any}("kind"=>"STORAGE_FIXTURE_NO_SOLVE", "message"=>"Seeded native state; no SCBA or Poisson executed")],
        data=Dict{String,Any}("result_commit"=>relpath(commit_path,root),
            "full_state"=>relpath(joinpath(dirname(commit_path),"physics.h5"),root)))
    series = workflow._series_document(plan, [record], :failed)
    series["selected_execution_id"] = execution.id
    open(joinpath(root,"series_result.json"),"w") do io
        QCLNEGFRunner.write_scientific_result(io,series)
    end
    write_json_once(joinpath(root,"native-evidence.json"), metadata("native";
        storage_completed=true, solver_executed=false, scattering_enabled=false,
        plan_fingerprint=plan.fingerprint, plan_sha256=hash_file(joinpath(root,"scientific_plan.json")),
        commit_path=relpath(commit_path,root), commit_sha256=hash_file(commit_path),
        artifacts=commit["artifacts"], restart_coordinates=commit["restart_coordinates"]))
end
function pause(root, output)
    plan, identity, path = frozen_plan(root)
    validate_physical_plan(plan)
    reserve_output(output)
    # Preserve exact bytes; execute_scientific_plan checks the fingerprint instead of rewriting.
    cp(path, joinpath(output,"scientific_plan.json"))
    execution = only(plan.executions)
    QCLNEGFRunner.request_pause(output, execution.id, 1;point_id=last(plan.points).id)
    QCLNEGFRunner.execute_scientific_plan(plan, output;execution_id=execution.id,attempt=1)
    result = YAML.load_file(joinpath(output,"series_result.json");dicttype=Dict{String,Any})
    result["status"] == "paused" && first(result["points"])["status"] == "completed" &&
        last(result["points"])["status"] == "paused" || error("expected first final and second pause")
    receipt = QCLNEGFRunner.verify_pause_receipt(output,execution.id,1)
    first_state = contained_file(output,first(result["points"])["data"]["full_state"])
    hash_file(joinpath(output,"scientific_plan.json")) == identity["plan_sha256"] || error("plan bytes changed")
    write_json_once(joinpath(output,"pause-evidence.json"),metadata("pause";
        plan_sha256=identity["plan_sha256"], plan_fingerprint=plan.fingerprint, receipt=receipt,
        first_state_sha256=hash_file(first_state), first_point_id=first(result["points"])["id"],
        maximum_scba_iterations=2, maximum_poisson_iterations=1))
end
function resume(root, prior, output)
    plan, identity, path = frozen_plan(root)
    validate_physical_plan(plan)
    checked_input(prior)
    fresh_output(output)
    hash_file(contained_file(prior,"scientific_plan.json")) == identity["plan_sha256"] ||
        throw(ArgumentError("prior output belongs to different frozen plan bytes"))
    receipt = QCLNEGFRunner.verify_pause_receipt(prior,only(plan.executions).id,1)
    prior_result = YAML.load_file(contained_file(prior,"series_result.json");dicttype=Dict{String,Any})
    first_state = contained_file(prior,first(prior_result["points"])["data"]["full_state"])
    original_hash = hash_file(first_state)
    copied = output * ".portable-input"
    reserve_output(copied)
    bundle = dirname(contained_file(prior,receipt["commit_path"]))
    QCLNEGFRunner.stage_result_tree(bundle,joinpath(copied,"recovery"))
    QCLNEGFRunner.stage_result_tree(checked_input(joinpath(prior,"archive")),joinpath(copied,"archive"))
    reserve_output(output)
    cp(path,joinpath(output,"scientific_plan.json"))
    QCLNEGFRunner.execute_scientific_plan(plan,output;execution_id=only(plan.executions).id,attempt=2,
        recovery_bundle=joinpath(copied,"recovery"),archive_bundle=copied,archive_byte_budget=64*1024^2)
    result = YAML.load_file(joinpath(output,"series_result.json");dicttype=Dict{String,Any})
    first_point, second = first(result["points"]),last(result["points"])
    first_point["attempt"] == 1 && first_point["status"] == "completed" || error("prior final was recalculated")
    hash_file(contained_file(output,first_point["data"]["full_state"])) == original_hash || error("prior final bytes changed")
    second["attempt"] == 2 && second["status"] == "completed" &&
        second["initialization"]["kind"] == "checkpoint" || error("portable checkpoint resume was not used")
    commit = QCLNEGFRunner.verify_point_artifacts(contained_file(output,second["data"]["result_commit"]))
    coordinates = commit["restart_coordinates"]
    coordinates["last_inner"] <= 2 && coordinates["last_completed_outer"] <= 1 || error("original cumulative budget exceeded")
    commit["scientific_accepted"] === false || error("bounded diagnostic unexpectedly accepted")
    stop = QCLNEGFRunner.verify_stop_receipt(output,only(plan.executions).id,2)
    hash_file(joinpath(output,"scientific_plan.json")) == identity["plan_sha256"] || error("plan bytes changed")
    write_json_once(joinpath(output,"resume-evidence.json"),metadata("resume";
        plan_sha256=identity["plan_sha256"], plan_fingerprint=plan.fingerprint, receipt=stop,
        original_first_state_sha256=original_hash, first_final_preserved=true,
        first_attempt=first_point["attempt"], second_attempt=second["attempt"],
        initialization=second["initialization"], restart_coordinates=coordinates,
        copied_portable_input=copied, archive_byte_budget=64*1024^2))
end
function staging(source,destination)
    checked_input(source)
    fresh_output(destination)
    evidence = fresh_output(destination * ".staging-evidence.json")
    marker = YAML.load_file(contained_file(source,"native-evidence.json");dicttype=Dict{String,Any})
    get(marker,"schema",nothing) == "qcl-negf-local-lab-acceptance-v1" &&
        get(marker,"mode",nothing) == "native" && get(marker,"storage_completed",nothing) === true &&
        get(marker,"solver_executed",nothing) === false ||
        throw(ArgumentError("staging requires an owned completed native storage fixture"))
    hash_file(contained_file(source,"scientific_plan.json")) == marker["plan_sha256"] ||
        throw(ArgumentError("native frozen plan changed before staging"))
    hash_file(contained_file(source,marker["commit_path"])) == marker["commit_sha256"] ||
        throw(ArgumentError("native commit changed before staging"))
    before = QCLNEGFRunner._tree_digests(source)
    QCLNEGFRunner.stage_result_tree(source,destination)
    after = QCLNEGFRunner._tree_digests(destination)
    before == after || error("staged tree differs")
    write_json_once(evidence,metadata("staging";source=source,destination=destination,
        implementation="QCLNEGFRunner.stage_result_tree", source_sha256=before,
        destination_sha256=after, byte_identical=true,
        publication="hash verification + owning fsync/rename implementation; syscall tracing not measured"))
end
function main(arguments=ARGS)
    arguments == ["--help"] && (print(USAGE); return 0)
    mode, paths = validate_arguments(arguments)
    preflight(mode, paths)
    load_runtime()
    operation = mode == "native" ? native : mode == "prepare" ? prepare :
        mode == "pause" ? pause : mode == "resume" ? resume : staging
    # Runtime/fixture methods were loaded explicitly only after inexpensive admission.
    Base.invokelatest(operation, paths...)
    return 0
end
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        exit(LocalLabAcceptance.main())
    catch exception
        showerror(stderr, exception)
        println(stderr)
        exit(2)
    end
end
