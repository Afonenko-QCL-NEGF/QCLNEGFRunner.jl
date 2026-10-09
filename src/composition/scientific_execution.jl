struct _ScientificPause <: Exception
    commit_path::Union{Nothing,String}
    reason::Symbol
end
_ScientificPause(path::String) = _ScientificPause(path, :paused)

# A paused execution may carry an older, already verified coherent commit.
# Keep its provenance separate from the current execution attempt; never stamp
# a historical payload with the newer attempt number.
function _scientific_pause_data(
    root,
    directory,
    commit_path,
    attempt;
    resource_pressure = false,
)
    data = Dict{String,Any}(
        "artifact_root" => replace(relpath(directory, root), '\\' => '/'),
        "resume_kind" => commit_path === nothing ? "cold_start" : "checkpoint",
    )
    resource_pressure && (data["pause_reason"] = "resource_pressure")
    commit_path === nothing && return data
    # This path comes only from a successful immutable commit or the verified
    # restart pointer. Read its small envelope; do not rehash gigabytes under
    # memory pressure merely to recover the already committed identity.
    commit = YAML.load_file(commit_path; dicttype = Dict{String,Any})
    get(commit, "schema", nothing) == "qcl-negf.artifact-commit.v2" &&
    get(commit, "contract_set", nothing) == "qcl-negf.results.v1" ||
        throw(ArgumentError("incompatible checkpoint commit envelope"))
    source_attempt = get(commit["identity"], "attempt", nothing)
    source_attempt isa Integer &&
    !(source_attempt isa Bool) &&
    0 < source_attempt <= attempt ||
        throw(ArgumentError("invalid checkpoint source attempt"))
    if source_attempt != attempt
        resource_pressure ||
            throw(ArgumentError("historical checkpoint requires resource-pause provenance"))
        data["checkpoint_source_attempt"] = source_attempt
        data["recovery_origin"] = "last_committed_before_resource_pause"
    end
    data["result_commit"] = replace(relpath(commit_path, root), '\\' => '/')
    data["full_state"] =
        replace(relpath(joinpath(dirname(commit_path), "physics.h5"), root), '\\' => '/')
    return data
end

function _scientific_validate_checkpoint_identity(commit, old, point, fingerprint; acknowledged_fallback=false)
    source_attempt = get(old.data, "checkpoint_source_attempt", old.attempt)
    if haskey(old.data, "checkpoint_source_attempt")
        old.status === :paused &&
        get(old.data, "pause_reason", nothing) == "resource_pressure" &&
        get(old.data, "resume_kind", nothing) == "checkpoint" &&
        get(old.data, "recovery_origin", nothing) ==
        "last_committed_before_resource_pause" &&
        source_attempt isa Integer &&
        !(source_attempt isa Bool) &&
        0 < source_attempt < old.attempt ||
            throw(ArgumentError("invalid historical checkpoint provenance"))
    end
    identity = commit["identity"]
    if acknowledged_fallback
        actual=get(identity,"attempt",nothing)
        actual isa Integer && !(actual isa Bool) && 0<actual<=old.attempt ||
            throw(ArgumentError("fallback checkpoint source attempt differs"))
        source_attempt=actual
    end
    expected = Dict(
        "point_id" => point.id,
        "execution_id" => point.execution_id,
        "plan_fingerprint" => fingerprint,
        "attempt" => source_attempt,
    )
    all(get(identity, key, nothing) == value for (key, value) in expected) ||
        throw(ArgumentError("checkpoint identity differs from the paused point"))
    return nothing
end

function _initialization(
    kind::String;
    source = nothing,
    checkpoint = nothing,
    reason = nothing,
)
    return (
        kind = kind,
        source_point_id = source,
        checkpoint = checkpoint,
        fallback_reason = reason,
    )
end
_coordinates(point::ScientificPoint) = (
    temperature_K = point.temperature_K,
    voltage_per_period_V = point.voltage_per_period_V,
    branch = point.branch,
    order = point.order,
)

function _point_result(
    point,
    attempt,
    initialization,
    status,
    quality,
    converged;
    warnings = Dict{String,Any}[],
    observables = Dict{String,Any}(),
    data = Dict{String,Any}(),
    postprocessing = Dict{String,Any}(),
)
    if status in (:skipped,:failed,:cancelled) && get(data,"full_state",nothing)===nothing
        data["full_state"]=nothing
        data["state_absence_reason"]=status===:skipped ? "solver_not_run" : "solver_did_not_publish_a_final_state"
    end
    return ScientificPointResult(
        point.id,
        point.execution_id,
        attempt,
        _coordinates(point),
        initialization,
        status,
        quality,
        converged,
        warnings,
        observables,
        data,
        postprocessing,
    )
end

function _scientific_resume_result(item)
    coordinates=item["coordinates"]
    init=item["initialization"]
    return ScientificPointResult(
        String(item["id"]),
        String(item["execution_id"]),
        Int(item["attempt"]),
        (
            temperature_K = Float64(coordinates["temperature_K"]),
            voltage_per_period_V = Float64(coordinates["voltage_per_period_V"]),
            branch = String(coordinates["branch"]),
            order = Int(coordinates["order"]),
        ),
        _initialization(
            String(init["kind"]);
            source = get(init, "source_point_id", nothing),
            checkpoint = get(init, "checkpoint", nothing),
            reason = get(init, "fallback_reason", nothing),
        ),
        Symbol(item["status"]),
        Symbol(item["quality"]),
        Bool(item["converged"]),
        Dict{String,Any}[_mapping_input(w, "warning") for w in item["warnings"]],
        _mapping_input(item["observables"], "observables"),
        _mapping_input(item["data"], "data"),
        _mapping_input(item["postprocessing"], "postprocessing"),
    )
end

# Reserve a new attempt directory, preserving files left by a killed process.
function _scientific_attempt_directory(parent::AbstractString, first_attempt::Int)
    mkpath(parent)
    attempt=first_attempt
    while true
        path=joinpath(parent, "attempt-$(attempt)")
        try
            mkdir(path)
            return attempt, path
        catch error
            ispath(path) || rethrow()
            attempt+=1
        end
    end
end

function _scientific_memory_reservation(config, resource_plan)
    required=scientific_memory_estimate(FilesystemScientificDefinitions(), config)
    hardware=resource_plan.hardware
    envelope=default_execution_envelope()
    budget=envelope === nothing ?
           min(
        resource_plan.memory_budget_bytes,
        hardware.total_memory_bytes,
        hardware.available_memory_bytes,
    ) : min(resource_plan.memory_budget_bytes, envelope.numerical_memory_bytes)
    required<=budget || throw(
        ArgumentError(
            "scientific execution requires $(required) bytes including declared adaptive domains and retained states; available budget is $(budget) bytes",
        ),
    )
    return Dict(
        "estimated_peak_bytes"=>required,
        "memory_budget_bytes"=>budget,
        "resource_authority"=>envelope === nothing ? "operating_system" : "explicit",
        "runtime_reserve_applied_again"=>false,
        "maximum_energy_nodes"=>config.domain_adaptation.mode===:none ?
                                config.numerical.N_E :
                                max(
            config.numerical.N_E,
            config.domain_adaptation.maximum_energy_nodes,
        ),
        "basis"=>"full estimator at declared node cap plus retained initial, voltage and domain residents",
    )
end

"""Record Hamiltonian coverage before allocating production iteration workspaces.

A diagnostic can deliberately expose an insufficient window; a stationary
research admission must cover the declared bare spectrum and shift margins.
This estimate is separate from the measured interacting tails in the final audit.
"""
function _scientific_representation_preflight(problem)
    c=representation_coverage(problem)
    return Dict{String,Any}(
        "schema"=>"qcl-negf-representation-preflight-v1",
        "discretization_id"=>c.discretization_id,
        "basis_id"=>c.basis_id,
        "hartree_id"=>c.hartree_id,
        "covered"=>c.covered,
        "source"=>String(c.source),
        "energy_unit"=>"E0",
        "energy_min"=>c.energy_min,
        "energy_max"=>c.energy_max,
        "required_min"=>c.required_min,
        "required_max"=>c.required_max,
        "shift_margin"=>c.shift_margin,
        "hilbert_margin"=>c.hilbert_margin,
        "effective_seed"=>Dict(
            String(k)=>v for (k, v) in pairs(effective_seed_parameters(problem))
        ),
    )
end

"""Publish comparable charge diagnostics without renormalizing any physical array."""
function _scientific_charge_observables(solution)
    charge=get(solution.observables, :charge_constraint, Dict())
    fields=Dict{String,Any}()
    raw=get(charge, "raw_charge", nothing)
    factor=get(charge, "lambda", nothing)
    raw isa Real &&
        isfinite(raw) &&
        (fields["raw_sheet_density_per_m2"]=raw/solution.problem.scales.L₀_m^2)
    factor isa Real && isfinite(factor) && (fields["normalization_factor"]=factor)
    # A common 64-position sampling grid gives grid-comparable profiles. The
    # physical z/n arrays remain in the native result; this is an L2 diagnostic.
    x=solution.problem.grids.x
    density=solution.n
    if length(x)==length(density) && length(x)>1 && all(isfinite, density)
        coordinates=collect(range(first(x), last(x); length = 64))
        values=Float64[]
        for coordinate in coordinates
            index=clamp(searchsortedlast(x, coordinate), 1, length(x)-1)
            fraction=(coordinate-x[index])/(x[index+1]-x[index])
            push!(
                values,
                Float64((1-fraction)*density[index]+fraction*density[index+1])/solution.problem.scales.L₀_m^3,
            )
        end
        fields["density_profile_per_m3"]=values
        fields["density_profile_grid"]="64_uniform_positions_in_declared_period_including_endpoints"
    end
    # Occupied spectral positions use the same native weights and spin factor
    # as the sheet-density functional. They do not modify the stored Green state.
    problem=solution.problem
    green=solution.scba.green.Gˡ
    occupied=zeros(length(problem.grids.ε))
    for e in axes(green, 1), k in axes(green, 2), a in axes(green, 3)
        occupied[e]+=real(-im*green[e, k, a, a])*problem.grids.wᵏ[k]*problem.physical.g_s/(
            2π
        )
    end
    try
        isdefined(@__MODULE__,:_occupied_energy_quantiles) ||
            throw(ArgumentError("occupied spectral quantile estimator is unavailable in this release"))
        quantiles=_occupied_energy_quantiles(
            problem.grids.ε,
            problem.grids.wᴱ,
            occupied;
            energy_scale_eV = problem.scales.E₀_eV,
            energy_reference_eV = Float64(ustrip(u"eV", problem.physical.E_ref)),
        )
        for (name, value) in zip(
            ("occupied_energy_q10_eV", "occupied_energy_q50_eV", "occupied_energy_q90_eV"),
            quantiles.values_eV,
        )
            fields[name]=value
        end
        fields["occupied_spectral_quantiles"]=Dict{String,Any}(
            "available"=>true,
            "units"=>"eV",
            "probabilities"=>quantiles.probabilities,
            "energy_window_eV"=>quantiles.energy_window_eV,
            "occupied_sheet_density_per_m2"=>quantiles.total_mass/problem.scales.L₀_m^2,
            "reconstruction"=>"piecewise_constant_control_volume",
            "formula"=>"mass(E)=wE(E)*gs/(2*pi)*sum_k wk(k)*real(-i*Tr(Gless(E,k)))",
            "scope"=>"finite represented window; no infinite-window moment claim",
        )
    catch error
        error isa ArgumentError || rethrow()
        fields["occupied_spectral_quantiles"]=Dict(
            "available"=>false,
            "status"=>"not_measured",
            "reason"=>sprint(showerror, error),
            "units"=>"eV",
        )
    end
    fields["effective_seed"]=Dict(
        String(k)=>v for (k, v) in pairs(effective_seed_parameters(solution.problem))
    )
    return fields
end

function _scientific_progress(root, point, attempt, status, artifact_root; event = nothing)
    # Producer phases have their own append-only timeline. They must not replace
    # the last physical residual row in the current-point progress projection.
    event !== nothing && event.action in (:phase_begin, :phase_end) && return nothing
    data=Dict{String,Any}(
        "schema"=>"qcl-negf-current-point-v1",
        "point_id"=>point.id,
        "execution_id"=>point.execution_id,
        "attempt"=>attempt,
        "status"=>String(status),
        "updated_unix"=>time(),
        "artifact_root"=>replace(relpath(artifact_root, root), '\\'=>'/'),
    )
    if event!==nothing
        data["stage"]=String(event.stage)
        data["iteration"]=event.iteration
        data["total"]=event.total
        data["metrics"]=[
            Dict("name"=>String(m.name), "value"=>m.value, "unit"=>m.unit) for
            m in event.metrics
        ]
        data["message"]=event.message
    end
    try
        pointer=joinpath(root, "current_point.json")
        if isfile(pointer) && (event===nothing || isempty(event.metrics))
            previous=YAML.load_file(pointer; dicttype = Dict{String,Any})
            if get(previous, "point_id", nothing)==point.id &&
               get(previous, "attempt", nothing)==attempt
                keys_to_keep=event===nothing ?
                             ("stage", "iteration", "total", "metrics", "message") :
                             ("metrics",)
                for key in keys_to_keep
                    haskey(previous, key) && (data[key]=previous[key])
                end
            end
        end
        _scientific_json(pointer, data)
    catch error
        error isa InterruptException && rethrow()
        @warn "optional progress publication failed" exception=(error, catch_backtrace())
    end
end

function _scientific_execution_progress(records,active,root,fingerprint)
    completed=Any[]
    for record in records
        record.execution_id==active.execution_id && record.id!=active.id && record.status===:completed || continue
        commit_path=get(record.data,"result_commit",nothing)
        commit_path===nothing && throw(ArgumentError("completed predecessor has no archive receipt"))
        absolute=joinpath(root,commit_path)
        receipt=verify_recovery_receipt(absolute)
        commit=verify_point_artifacts(absolute)
        get(commit,"storage_class",nothing)=="archive" || throw(ArgumentError("completed predecessor has no immutable archive"))
        point=YAML.load(sprint(_light_json,_scientific_result_dict(record));dicttype=Dict{String,Any})
        point["data"]=Dict(key=>deepcopy(value) for (key,value) in point["data"] if key in
            ("result_commit","full_state","analysis_physics","optical"))
        point["data"]["artifact_root"]=replace(relpath(dirname(absolute),root),'\\'=>'/')
        files=Any[]
        names=String["commit.json","receipt.json"]
        append!(names,String[a["path"] for a in commit["artifacts"]])
        optical=get(record.data,"optical",nothing)
        optical===nothing || push!(names,"optical.h5")
        for name in unique(names)
            path=joinpath(dirname(absolute),name)
            push!(files,Dict("path"=>name,"bytes"=>filesize(path),"sha256"=>bytes2hex(open(sha256,path))))
        end
        push!(completed,Dict("point"=>point,
            "final_commit"=>replace(relpath(absolute,joinpath(root,"archive")),'\\'=>'/'),
            "receipt"=>Dict(key=>receipt[key] for key in ("identity","state_id","state_sequence","commit_sha256")),
            "files"=>files))
    end
    return Dict{String,Any}("schema"=>"qcl-negf-execution-progress-v1","contract_set"=>"qcl-negf.results.v1",
        "plan_fingerprint"=>fingerprint,"execution_id"=>active.execution_id,"active_point_id"=>active.id,
        "completed_points"=>completed)
end
function _import_completed_archives!(progress,archive_bundle,root,policy;archive_byte_budget::Int=64*1024^3)
    entries=get(progress,"completed_points",nothing)
    entries isa AbstractVector || throw(ArgumentError("execution progress has no completed-point index"))
    if isempty(entries)
        _verify_prior_final_dependencies(progress,joinpath(root,"archive");byte_budget=archive_byte_budget,reserve_bytes=policy.reserve_bytes)
        return ScientificPointResult[]
    end
    archive_bundle===nothing && throw(ArgumentError("recovery requires --archive-bundle for completed prior finals"))
    source_root=joinpath(abspath(archive_bundle),"archive")
    closure=_verify_prior_final_dependencies(progress,source_root;byte_budget=archive_byte_budget,reserve_bytes=policy.reserve_bytes)
    validated=Tuple{String,String,Any}[]
    records=ScientificPointResult[]
    for dependency in closure.dependencies
        target=joinpath(root,"archive",dirname(dependency.relative))
        ispath(target) && throw(ArgumentError("prior archive destination already exists"))
        push!(validated,(dependency.source,target,dependency.entry))
        push!(records,_scientific_resume_result(dependency.entry["point"]))
    end
    mkpath(root)
    _check_storage_free(root,closure.bytes+policy.reserve_bytes)
    for (source,target,entry) in validated
        mkpath(dirname(target))
        temporary=mktempdir(dirname(target);prefix="pending-import-")
        try
            for file in entry["files"]
                cp(joinpath(source,file["path"]),joinpath(temporary,file["path"]);follow_symlinks=false)
            end
            verify_recovery_receipt(joinpath(temporary,"commit.json"))
            for (_,_,files) in walkdir(temporary), name in files
                _sync_artifact_file(joinpath(temporary,name))
            end
            _sync_artifact_directory(temporary)
            mv(temporary,target;force=false)
            _sync_artifact_directory(dirname(target))
        finally
            isdir(temporary) && rm(temporary;recursive=true,force=true)
        end
    end
    return records
end

"""Execute exactly the frozen Julia plan; one execution uses the shared machine budget.

Every returned stationary state owns one final archive before optional optical
analysis. A pause owns a verified recovery bundle. Retries preserve cumulative
coordinates and completed-point receipts; display projections never seed a
physical operating point.
"""
function execute_scientific_plan(
    plan::ScientificPlan,
    output_directory::AbstractString;
    resume::Bool = true,
    execution_id::Union{Nothing,AbstractString} = nothing,
    attempt::Union{Nothing,Int} = nothing,
    recovery_bundle::Union{Nothing,AbstractString} = nothing,
    telemetry_sink::Union{Nothing,Function} = nothing,
    archive_bundle::Union{Nothing,AbstractString} = nothing,
    archive_byte_budget::Int = 64*1024^3,
)
    archive_byte_budget>0 || throw(ArgumentError("archive byte budget must be positive"))
    # Re-decode the frozen raw contract, rejecting mutation and stale typed aliases.
    plan=load_scientific_plan(scientific_plan_dict(plan))
    selected_executions=execution_id===nothing ? plan.executions :
                        [e for e in plan.executions if e.id==execution_id]
    isempty(selected_executions) && throw(ArgumentError("unknown selected execution"))
    selected_ids=Set(e.id for e in selected_executions)
    selected_points=[p for p in plan.points if p.execution_id in selected_ids]
    root=abspath(output_directory)
    mkpath(root)
    attempt===nothing || attempt>0 || throw(ArgumentError("attempt must be positive"))
    requested_attempt=attempt
    _check_storage_free(root,_minimum_scientific_output_bytes(plan)+maximum(e.outputs.recovery.reserve_bytes for e in selected_executions))
    plan_path=joinpath(root, "scientific_plan.json")
    if isfile(plan_path)
        stored=load_scientific_plan(plan_path)
        stored.fingerprint==plan.fingerprint ||
            throw(ArgumentError("output directory belongs to a different scientific plan"))
    else
        _scientific_json(plan_path, scientific_plan_dict(plan))
    end
    results=ScientificPointResult[]
    history=ScientificPointResult[]
    existing=Dict{String,ScientificPointResult}()
    result_path=joinpath(root, "series_result.json")
    if isfile(result_path)
        document, _=_read_series(root)
        document["plan_fingerprint"]==plan.fingerprint ||
            throw(ArgumentError("result/plan fingerprint mismatch"))
        for item in document["points"]
            record=_scientific_resume_result(item)
            existing[record.id]=record
        end
        for item in get(document, "attempt_history", document["points"])
            record=_scientific_resume_result(item)
            push!(history, record)
            latest=get(existing, record.id, nothing)
            (latest===nothing || record.attempt>latest.attempt) &&
                (existing[record.id]=record)
        end
    end
    inherited_history=Dict{String,String}()
    if recovery_bundle!==nothing
        requested_attempt===nothing && throw(ArgumentError("recovery import requires an explicit new attempt"))
        source=abspath(recovery_bundle)
        receipt=verify_recovery_receipt(joinpath(source,"commit.json"))
        identity=receipt["identity"]
        get(identity,"plan_fingerprint",nothing)==plan.fingerprint || throw(ArgumentError("recovery scientific plan differs"))
        point=only(filter(p->p.id==get(identity,"point_id",nothing),selected_points))
        point.execution_id==get(identity,"execution_id",nothing) || throw(ArgumentError("recovery execution identity differs"))
        source_attempt=Int(identity["attempt"])
        requested_attempt>source_attempt || throw(ArgumentError("new attempt must exceed recovery source attempt"))
        target=joinpath(root,"recovery",point.execution_id,point.id,"imported-$(source_attempt)")
        ispath(target) && throw(ArgumentError("recovery import destination already exists"))
        policy=only(e.outputs.recovery for e in selected_executions if e.id==point.execution_id)
        progress_path=joinpath(source,"execution_progress.json")
        isfile(progress_path) || throw(ArgumentError("portable recovery lacks execution_progress.json"))
        progress=YAML.load_file(progress_path;dicttype=Dict{String,Any})
        get(progress,"identity",nothing)==identity && get(progress,"active_point_id",nothing)==point.id &&
        get(progress,"plan_fingerprint",nothing)==plan.fingerprint || throw(ArgumentError("portable recovery progress identity differs"))
        imported_records=_import_completed_archives!(progress,archive_bundle,root,policy;archive_byte_budget)
        for record in imported_records
            haskey(existing,record.id) && throw(ArgumentError("imported completed point already exists"))
            existing[record.id]=record
            push!(history,record)
        end
        _check_storage_budget([joinpath(root,"executions"),joinpath(root,"recovery")],policy.byte_budget,policy.reserve_bytes,_storage_bytes([source]))
        mkpath(dirname(target))
        cp(source,target;follow_symlinks=false)
        verify_recovery_receipt(joinpath(target,"commit.json"))
        commit_relative=replace(relpath(joinpath(target,"commit.json"),root),'\\'=>'/')
        data=Dict{String,Any}("result_commit"=>commit_relative,"full_state"=>replace(relpath(joinpath(target,"physics.h5"),root),'\\'=>'/'))
        existing[point.id]=_point_result(point,source_attempt,_initialization("checkpoint"),:paused,:unconverged,false;data)
        isfile(joinpath(target,"history.h5")) && (inherited_history[point.id]=joinpath(target,"history.h5"))
    end
    points=Dict(p.id=>p for p in plan.points)
    function result_document(status)
        document=_series_document(plan, results, status)
        document["executions"]=[
            e for e in document["executions"] if e["id"] in selected_ids
        ]
        document["expected_point_count"]=length(selected_points)
        document["selected_execution_id"]=execution_id
        document["attempt_history"]=_scientific_result_dict.(history)
        return document
    end
    function publish(status = :running)
        _scientific_json(result_path, result_document(status))
    end
    function publish_cancelled()
        present=Set(record.id for record in results)
        for point in selected_points
            point.id in present && continue
            old=get(existing, point.id, nothing)
            attempt=requested_attempt===nothing ? (old===nothing ? 1 : old.attempt+1) : requested_attempt
            record=_point_result(
                point,
                attempt,
                _initialization("interrupted"),
                :cancelled,
                :unconverged,
                false;
                warnings = [
                    Dict{String,Any}(
                        "code"=>"CANCELLED",
                        "scope"=>"point",
                        "message"=>"cooperative cancellation; only already published snapshots are durable",
                    ),
                ],
            )
            push!(results, record)
            push!(history, record)
        end
        publish(:cancelled)
    end
    publish()
    stop_campaign=false
    for execution in selected_executions
        if stop_campaign
            for point_id in execution.point_ids
                point=points[point_id]
                old=get(existing, point_id, nothing)
                record=_point_result(
                    point,
                    old===nothing ? 1 : old.attempt+1,
                    _initialization("not_started"),
                    :skipped,
                    :unconverged,
                    false;
                    warnings = [
                        Dict{String,Any}(
                            "code"=>"CAMPAIGN_STOPPED",
                            "scope"=>"execution",
                            "message"=>"campaign stopped by explicit child failure policy",
                        ),
                    ],
                )
                push!(results, record)
                push!(history, record)
            end
            publish()
            continue
        end
        if execution.operation!==:stationary
            for point_id in execution.point_ids
                point=points[point_id]
                old=get(existing, point_id, nothing)
                attempt=requested_attempt===nothing ? (old===nothing ? 1 : old.attempt+1) : requested_attempt
                if resume && old!==nothing && old.status===:completed
                    all(
                        pair->first(pair)=="artifact_root" ?
                              isdir(joinpath(root, last(pair))) :
                              last(pair)===nothing || isfile(joinpath(root, last(pair))),
                        pairs(old.data),
                    ) || throw(ArgumentError("saved final artifacts missing for $point_id"))
                    commit=get(old.data, "result_commit", nothing)
                    commit===nothing && throw(
                        ArgumentError(
                            "saved final point $point_id lacks its native commit",
                        ),
                    )
                    verify_point_artifacts(joinpath(root, commit))
                    push!(results, old)
                    publish()
                    continue
                end
                attempt, directory=_scientific_attempt_directory(
                    joinpath(root, "executions", execution.id, point_id),
                    attempt,
                )
                _scientific_progress(root, point, attempt, :running, directory)
                checks=run_operator_diagnostics(
                    execution.operation,
                    execution.configuration;
                    point,
                )
                accepted=all(row["passed"] for row in checks)
                identity=Dict{String,Any}(
                    "point_id"=>point.id,
                    "execution_id"=>execution.id,
                    "attempt"=>attempt,
                    "plan_fingerprint"=>plan.fingerprint,
                )
                commit=commit_operator_artifacts(
                    directory,
                    checks;
                    identity,
                    operation = String(execution.operation),
                    accepted,
                )
                ledger=joinpath(dirname(commit), "operator_checks.json")
                record=_point_result(
                    point,
                    attempt,
                    _initialization("analytic_fixture"),
                    :completed,
                    accepted ? :strict : :unconverged,
                    accepted;
                    observables = Dict{String,Any}("operator_checks_passed"=>accepted),
                    data = Dict{String,Any}(
                        "artifact_root"=>replace(relpath(directory, root), '\\'=>'/'),
                        "operator_checks"=>replace(relpath(ledger, root), '\\'=>'/'),
                        "result_commit"=>replace(relpath(commit, root), '\\'=>'/'),
                    ),
                )
                record.data["result_commit"]=replace(relpath(commit, root), '\\'=>'/')
                push!(results, record)
                push!(history, record)
                publish()
                _scientific_progress(root, point, attempt, :completed, directory)
            end
            continue
        end
        config=execution.configuration
        execution_dir=joinpath(root, "executions", execution.id)
        mkpath(execution_dir)
        configured=nothing
        base_cache=nothing
        preparation_error=nothing
        try
            config, resource_plan=resolve_execution_strategy(config)
            configure_execution!(config)
            BLAS.set_num_threads(1)
            save_execution_plan(
                joinpath(execution_dir, "execution_plan.yaml"),
                resource_plan,
            )
            reservation=_scientific_memory_reservation(config, resource_plan)
            _scientific_json(
                joinpath(execution_dir, "scientific_memory_reservation.json"),
                reservation,
            )
            config.execution.solver_backend!==:production &&
                config.domain_adaptation.mode!==:none &&
                throw(ArgumentError("domain adaptation requires the production backend"))
            configured=build_configured_problem(config)
            coverage=_scientific_representation_preflight(configured.problem)
            _scientific_json(
                joinpath(execution_dir, "representation_preflight.json"),
                coverage,
            )
            base_cache=config.execution.solver_backend===:production ?
                       build_production_cache(
                configured.problem;
                options = config.production,
            ) : nothing
        catch error
            error isa InterruptException && rethrow()
            preparation_error=sprint(showerror, error)
        end
        previous=nothing
        previous_id=nothing
        stored_scba, stored_outer=preparation_error===nothing ?
                                  scientific_history_counts(execution_dir) : (0, 0)
        archive_history=joinpath(root,"archive",execution.id)
        if isdir(archive_history)
            for (directory,_,files) in walkdir(archive_history)
                "history.h5" in files || continue
                h5open(joinpath(directory,"history.h5"),"r") do file
                    for (kind,previous_count) in (("scba",stored_scba),("outer",stored_outer))
                        column=file[kind*"/sequence"]
                        value=length(column)==0 ? 0 : Int(column[length(column)])
                        kind=="scba" ? (stored_scba=max(stored_scba,value)) : (stored_outer=max(stored_outer,value))
                    end
                end
            end
        end
        scba_count=Ref(stored_scba)
        outer_count=Ref(stored_outer)
        for point_id in execution.point_ids
            point=points[point_id]
            old=get(existing, point_id, nothing)
            attempt=requested_attempt===nothing ? (old===nothing ? 1 : old.attempt+1) : requested_attempt
            initialization=_initialization("cold")
            if resume &&
               old!==nothing &&
               old.status===:completed &&
               point.predecessor_id===nothing &&
               execution.policies.voltage.mode===:independent
                # Completed independent points can be resumed without a solver state.
                all(
                    pair->first(pair)=="artifact_root" ? isdir(joinpath(root, last(pair))) :
                          first(pair) in ("state_absence_reason","resume_kind","pause_reason","recovery_origin","checkpoint_source_attempt") || last(pair)===nothing || isfile(joinpath(root, last(pair))),
                    pairs(old.data),
                ) || throw(ArgumentError("saved final artifacts missing for $point_id"))
                commit=get(old.data, "result_commit", nothing)
                commit===nothing && throw(
                    ArgumentError("saved final point $point_id lacks its native commit"),
                )
                verify_point_artifacts(joinpath(root, commit))
                push!(results, old)
                publish()
                continue
            end
            if resume &&
               old!==nothing &&
               old.status===:completed &&
               get(old.data, "full_state", nothing)!==nothing
                verified_commit=verify_point_artifacts(joinpath(root, old.data["result_commit"]))
                recovery=joinpath(root, old.data["full_state"])
                raw=load_resolved_configuration_envelope(
                    joinpath(dirname(recovery), "resolved_configuration.json"),
                )
                restored_config=_resolve_configuration(
                    raw,
                    ConfigurationProvenance(
                        String[],
                        String[],
                        Dict{String,Vector{String}}(),
                    ),
                )
                saved_problem=build_configured_problem(restored_config).problem
                saved=load_production_restart(
                    recovery,
                    saved_problem;
                    algorithms = config.algorithms,
                    solver_options = config.solver,
                )
                seed_summary=_restored_voltage_seed_summary(verified_commit, saved, old)
                previous=nothing
                if _usable_voltage_state(seed_summary, execution.policies.voltage.mode)
                    state=saved.scba
                    restored_scba=SCBAResult(
                        state.green,
                        state.scattering,
                        state.embedding,
                        state.embedding_plus,
                        state.embedding_minus,
                        state.history,
                        saved.original_scba_converged,
                        saved.original_scba_status,
                        saved.original_scba_quality,
                        state.restart_contract,
                        state.mixer_state,
                    )
                    previous=(; Uᴴ=saved.Uᴴ, scba=restored_scba)
                end
                previous_id=point_id
                push!(results, old)
                publish()
                continue
            end
            restoring=resume &&
                      old!==nothing &&
                      old.status in (:paused, :running, :failed) &&
                      get(old.data, "full_state", nothing)!==nothing
            if resume && old!==nothing && old.status in (:paused,:running) && !restoring
                throw(ArgumentError("unfinished point has no validated recovery; explicit fresh execution is required"))
            end
            if restoring
                initialization=_initialization(
                    "checkpoint";
                    checkpoint = old.data["full_state"],
                )
            elseif point.predecessor_id===nothing
                previous=nothing
                previous_id=nothing
            elseif previous_id==point.predecessor_id && previous!==nothing
                initialization=_initialization("predecessor"; source = previous_id)
            else
                policy=execution.policies.voltage.invalid_predecessor
                if policy===:cold_start
                    initialization=_initialization(
                        "cold_fallback";
                        source = point.predecessor_id,
                        reason = "predecessor is not permitted by voltage continuation policy",
                    )
                    previous=nothing
                else
                    record=_point_result(
                        point,
                        attempt,
                        _initialization(
                            "unavailable_predecessor";
                            source = point.predecessor_id,
                        ),
                        :skipped,
                        :unconverged,
                        false;
                        warnings = [
                            Dict{String,Any}(
                                "code"=>"DEPENDENCY_UNAVAILABLE",
                                "scope"=>"branch",
                                "message"=>"predecessor did not provide an allowed state; policy=$policy",
                            ),
                        ],
                    )
                    push!(results, record)
                    push!(history, record)
                    publish()
                    continue
                end
            end
            if stop_campaign || preparation_error!==nothing
                reason=stop_campaign ? "campaign stopped by explicit child failure policy" :
                       preparation_error
                record=_point_result(
                    point,
                    attempt,
                    initialization,
                    stop_campaign ? :skipped : :failed,
                    :invalid,
                    false;
                    warnings = [
                        Dict{String,Any}(
                            "code"=>stop_campaign ? "CAMPAIGN_STOPPED" :
                                    "PREPARATION_FAILED",
                            "scope"=>"execution",
                            "message"=>reason,
                        ),
                    ],
                )
                push!(results, record)
                push!(history, record)
                publish()
                preparation_error!==nothing &&
                    execution.policies.on_child_failure===:stop &&
                    (stop_campaign=true)
                continue
            end
            attempt, directory=_scientific_attempt_directory(
                joinpath(execution_dir, point_id),
                attempt,
            )
            solution=nothing
            reporter=nothing
            telemetry_sender=nothing
            history_recorder=nothing
            latest_commit=Ref{Union{Nothing,String}}(
                restoring &&
                old !== nothing &&
                get(old.data, "result_commit", nothing) !== nothing ?
                joinpath(root, old.data["result_commit"]) : nothing,
            )
            terminal_status=:failed
            _scientific_progress(root, point, attempt, :running, directory)
            try
                reporter=ProgressReporter(;
                    machine_directory = joinpath(directory, "progress"),
                    human_io = nothing,
                    strict_hierarchy = false,
                )
                begin_progress_stage!(
                    reporter,
                    :point;
                    label = point.id,
                    iteration = 0,
                    total = 1,
                )
                if execution.outputs.telemetry.enabled && telemetry_sink!==nothing
                    telemetry_sender=ScalarTelemetrySender(telemetry_sink;capacity=execution.outputs.telemetry.buffer_events)
                end
                function observe_solver_event(event)
                    if telemetry_sender!==nothing
                        attributes=Dict{String,Any}("point_id"=>point.id,"execution_id"=>execution.id,
                            "attempt"=>attempt,"stage"=>String(event.stage),"iteration"=>event.iteration,
                            "total"=>event.total,"message"=>event.message,
                            "metrics"=>Dict(String(m.name)=>Dict("value"=>m.value,"unit"=>m.unit) for m in event.metrics))
                        emit_telemetry!(telemetry_sender,Dict("schema"=>"qcl-runtime-event-v1",
                            "event"=>String(event.action),"name"=>event.label,"status"=>String(event.status),
                            "timestamp_unix_seconds"=>time(),"attributes"=>attributes))
                    end
                    _scientific_progress(root,point,attempt,:running,directory;event)
                end
                event_sink=_progress_event_sink(reporter;solver_event_observer=observe_solver_event)
                runtime_options=with_production_options(
                    config.production;
                    event_sink,
                    phase_request = _native_phase_request(reporter.machine_directory),
                )
                problem=retarget_problem(
                    configured.problem;
                    V_period = point.voltage_per_period_V*u"V",
                    Tᴸ = point.temperature_K*u"K",
                    Tᴸᴼ = point.temperature_K*u"K",
                    energy_shift = config.algorithms.energy_shift,
                )
                cache=base_cache===nothing ? nothing :
                      retarget_production_cache(base_cache, problem)
                restart=nothing
                if restoring
                    source_path=joinpath(root,old.data["result_commit"])
                    recovery_directory=joinpath(root,"recovery",execution.id,point.id)
                    if isfile(joinpath(recovery_directory,"current.json"))
                        source_path=load_recovery_commit(directory;recovery_root=recovery_directory)
                    else
                        verify_recovery_receipt(source_path)
                    end
                    recovery=joinpath(dirname(source_path),"physics.h5")
                    source_commit=verify_point_artifacts(source_path)
                    initialization=_initialization("checkpoint";checkpoint=replace(relpath(recovery,root),'\\'=>'/'))
                    isfile(joinpath(dirname(source_path),"history.h5")) &&
                        (inherited_history[point.id]=joinpath(dirname(source_path),"history.h5"))
                    _scientific_validate_checkpoint_identity(
                        source_commit,
                        old,
                        point,
                        plan.fingerprint;
                        acknowledged_fallback=source_path!=joinpath(root,old.data["result_commit"]),
                    )
                    saved_inputs=joinpath(dirname(recovery), "resolved_configuration.json")
                    isfile(saved_inputs) || throw(
                        ArgumentError("checkpoint has no immutable resolved configuration"),
                    )
                    inputs=load_resolved_configuration_envelope(saved_inputs)
                    restored_config=_resolve_configuration(
                        inputs,
                        ConfigurationProvenance(
                            String[],
                            String[],
                            Dict{String,Vector{String}}(),
                        ),
                    )
                    problem=build_configured_problem(restored_config).problem
                    cache=build_production_cache(problem; options = runtime_options)
                    restart=load_production_restart(
                        recovery,
                        problem;
                        incompatible = :error,
                        algorithms = config.algorithms,
                        solver_options = config.solver,
                    )
                    if restart.status in (:running, :snapshot)
                        candidate, _, _, _=solve_periodic_poisson(
                            problem,
                            _electron_density_bar(problem, restart.scba.green.Gˡ),
                        )
                        updated=(1-config.solver.α_P) .* restart.Uᴴ .+
                                config.solver.α_P .* candidate
                        restart=merge(restart, (Uᴴ = updated,))
                    end
                end
                coverage=_scientific_representation_preflight(problem)
                coverage["voltage_per_period_V"]=point.voltage_per_period_V
                coverage["temperature_K"]=point.temperature_K
                _scientific_json(
                    joinpath(directory, "representation_preflight.json"),
                    coverage,
                )
                if !coverage["covered"] &&
                   execution.purpose!==:diagnostic &&
                   config.domain_adaptation.mode===:none
                    throw(
                        ArgumentError(
                            "representation_coverage_failed: frozen energy window does not cover the actual point Hamiltonian and shift margins; a new declared diagnostic identity is required",
                        ),
                    )
                end
                identity=Dict{String,Any}(
                    "point_id"=>point.id,
                    "execution_id"=>execution.id,
                    "attempt"=>attempt,
                    "plan_fingerprint"=>plan.fingerprint,
                )
                if haskey(inherited_history,point.id)
                    inherited=joinpath(directory,"inherited-history.h5")
                    cp(inherited_history[point.id],inherited;force=false)
                    inherited_history[point.id]=inherited
                    h5open(inherited,"r") do file
                        for (kind,counter) in (("scba",scba_count),("outer",outer_count))
                            sequences=read(file[kind*"/sequence"])
                            isempty(sequences) || (counter[]=max(counter[],maximum(sequences)))
                        end
                    end
                end
                history_recorder=ScientificHistoryRecorder(
                    directory,
                    identity,
                    scba_count,
                    outer_count,
                )
                history_observer=(kind, outer, row, source)->record_scientific_history!(
                    history_recorder,
                    kind,
                    outer,
                    row,
                    source,
                )
                recovery_policy=execution.outputs.recovery
                recovery_directory=joinpath(root,"recovery",execution.id,point.id)
                archive_directory=joinpath(root,"archive",execution.id,point.id)
                operational_directories=[joinpath(root,"executions"),joinpath(root,"recovery")]
                checkpoint_clock=CheckpointDeadline(;interval_seconds=recovery_policy.interval_seconds)
                function durable_state(state; analysis = true)
                    state.observables[:representation_preflight]=coverage
                    state.observables[:model_capabilities]=model_capabilities(
                        state.problem,
                        config.algorithms,
                    )
                    flush_scientific_history!(history_recorder)
                    history_paths=scientific_history_sources(haskey(inherited_history,point.id) ? directory : dirname(directory))
                    haskey(inherited_history,point.id) && pushfirst!(history_paths,inherited_history[point.id])
                    commit=commit_point_artifacts(
                        directory,
                        state;
                        identity,
                        algorithms = config.algorithms,
                        configuration = _point_resolved_raw(config, point),
                        history_paths,
                        analysis,
                        terminal_status = state.status in
                                          (:running, :running_scba, :snapshot) ? "running" :
                                          "completed",
                        checkpoint_metadata = checkpoint_policy(checkpoint_clock),
                        storage_class = :recovery,
                        recovery_root = recovery_directory,
                        retain_generations = recovery_policy.retain_generations,
                        byte_budget = recovery_policy.byte_budget,
                        reserve_bytes = recovery_policy.reserve_bytes,
                        operational_roots = operational_directories,
                        state_sequence = _scientific_next_state_sequence(recovery_directory),
                        execution_progress = _scientific_execution_progress(results,point,root,plan.fingerprint),
                    )
                    checkpoint_completed!(checkpoint_clock)
                    latest_commit[]=commit
                    for name in readdir(recovery_directory)
                        startswith(name,"imported-") && rm(joinpath(recovery_directory,name);recursive=true)
                    end
                    current_data=Dict{String,Any}(
                        "artifact_root"=>replace(relpath(directory, root), '\\'=>'/'),
                        "result_commit"=>replace(relpath(commit, root), '\\'=>'/'),
                        "full_state"=>replace(
                            relpath(joinpath(dirname(commit), "physics.h5"), root),
                            '\\'=>'/',
                        ),
                    )
                    running_record=_point_result(
                        point,
                        attempt,
                        initialization,
                        :running,
                        Symbol(solution_quality(state)),
                        false;
                        data = current_data,
                    )
                    index=findfirst(r->r.id==point.id, results)
                    index===nothing ? push!(results, running_record) :
                    (results[index]=running_record)
                    publish()
                    if pause_requested(root,identity)
                        write_pause_receipt(root,commit,identity;archive_byte_budget)
                        throw(_ScientificPause(commit))
                    end
                    return nothing
                end
                function observer(state)
                    state.status===:snapshot || return
                    outer=length(state.outer_history)
                    cadence=config.output.snapshot_every_outer
                    cadence>0 && (outer==1 || outer%cadence==0) || return
                    recovery_policy.enabled && durable_state(state)
                end
                function checkpoint_request(context)
                    pause_requested(root,identity) && return true
                    recovery_policy.enabled || return false
                    checkpoint_due(checkpoint_clock) && return true
                    cadence =
                        context.stage === :scba ? config.production.checkpoint_every_scba :
                        config.production.checkpoint_every_outer
                    return cadence > 0 && context.iteration % cadence == 0
                end
                runtime_options =
                    with_production_options(runtime_options; checkpoint_request)
                function checkpoint_sink(state)
                    state.status in (:running, :running_scba) || return nothing
                    durable_state(state; analysis = false)
                end
                started=time_ns()
                solution=if config.execution.solver_backend===:production
                    solve_adaptive_production(
                        problem;
                        domain_adaptation = config.domain_adaptation,
                        kernel_options = config.kernels,
                        options = config.solver,
                        production_options = runtime_options,
                        cache,
                        initial_Uᴴ = restart===nothing ?
                                     (previous===nothing ? nothing : previous.Uᴴ) :
                                     restart.Uᴴ,
                        initial_scba = restart===nothing ?
                                       (previous===nothing ? nothing : previous.scba) :
                                       restart.scba,
                        initial_outer_history = restart===nothing ? OuterIteration[] :
                                                restart.outer_history,
                        initial_warnings = restart===nothing ? Dict{String,Any}[] :
                                           restart.warnings,
                        resume_scba = restart!==nothing && restart.resume_scba,
                        # A loaded checkpoint belongs exclusively to this
                        # attempt. Transfer its arrays and release this outer
                        # owner before solving; voltage warm starts stay shared
                        # and use the normal copying contract.
                        consume_initial = restoring,
                        initial_adaptation = let adaptation=restart===nothing ? nothing :
                                                            restart.adaptation
                            restart=nothing
                            adaptation
                        end,
                        state_observer = observer,
                        checkpoint_sink,
                        history_observer,
                    )
                else
                    previous===nothing || throw(
                        ArgumentError(
                            "educational backend has no voltage warm-start port; select independent points",
                        ),
                    )
                    solve(problem; options = config.solver, history_observer)
                end
                observables=Dict{String,Any}(
                    "current_density_A_per_m2"=>Float64(
                        ustrip(u"A/m^2", solution.observables[:electron_flow_current]),
                    ),
                    "wall_seconds"=>(time_ns()-started)*1e-9,
                    "outer_iterations"=>length(solution.outer_history),
                    "scba_iterations"=>length(solution.scba.history),
                )
                merge!(observables, _scientific_charge_observables(solution))
                observables["representation_preflight"]=coverage
                solution.observables[:representation_preflight]=coverage
                observables["scientific_assessment"]=solution_scientific_assessment(
                    solution,
                )
                warnings=Dict{String,Any}[
                    deepcopy(w) for
                    w in get(solution.observables, :warnings, Dict{String,Any}[])
                ]
                data=Dict{String,Any}(
                    "artifact_root"=>replace(relpath(directory, root), '\\'=>'/'),
                    "full_state"=>nothing,
                    "optical"=>nothing,
                    "progress_events"=>replace(
                        relpath(joinpath(directory, "progress", "events.jsonl"), root),
                        '\\'=>'/',
                    ),
                    "progress_latest"=>replace(
                        relpath(joinpath(directory, "progress", "progress.yaml"), root),
                        '\\'=>'/',
                    ),
                )
                derived=Dict{String,Any}(
                    "optical"=>Dict{String,Any}(
                        "status"=>execution.outputs.optical ? "pending" : "not_requested",
                        "error"=>nothing,
                    ),
                )
                record=_point_result(
                    point,
                    attempt,
                    initialization,
                    :saving,
                    Symbol(solution_quality(solution)),
                    solution.converged;
                    warnings,
                    observables,
                    data,
                    postprocessing = derived,
                )
                index=findfirst(r->r.id==point.id, results)
                index===nothing ? push!(results, record) : (results[index]=record)
                publish()
                # Required stationary data are durable before optional work starts.
                solution.observables[:model_capabilities]=model_capabilities(
                    solution.problem,
                    config.algorithms,
                )
                flush_scientific_history!(history_recorder)
                history_paths=scientific_history_sources(haskey(inherited_history,point.id) ? directory : dirname(directory))
                haskey(inherited_history,point.id) && pushfirst!(history_paths,inherited_history[point.id])
                commit=commit_point_artifacts(
                    directory,
                    solution;
                    identity,
                    algorithms = config.algorithms,
                    configuration = _point_resolved_raw(config, point),
                    history_paths,
                    checkpoint_metadata = checkpoint_policy(checkpoint_clock),
                    storage_class = :archive,
                    archive_root = archive_directory,
                    recovery_root = recovery_directory,
                    state_sequence = _scientific_next_state_sequence(recovery_directory),
                    reserve_bytes = recovery_policy.reserve_bytes,
                    execution_progress = _scientific_execution_progress(results,point,root,plan.fingerprint),
                )
                checkpoint_completed!(checkpoint_clock)
                data["result_commit"]=replace(relpath(commit, root), '\\'=>'/')
                data["analysis_physics"]=replace(
                    relpath(joinpath(dirname(commit), "analysis.h5"), root),
                    '\\'=>'/',
                )
                data["full_state"]=replace(
                    relpath(joinpath(dirname(commit), "physics.h5"), root),
                    '\\'=>'/',
                )
                observables["sheet_density_per_m2"]=real(
                    tr(_sheet_density_matrix_bar(solution.problem, solution.scba.green.Gˡ)),
                )/solution.problem.scales.L₀_m^2
                record=_point_result(
                    point,
                    attempt,
                    initialization,
                    :completed,
                    Symbol(solution_quality(solution)),
                    solution.converged;
                    warnings,
                    observables,
                    data,
                    postprocessing = derived,
                )
                results[end]=record
                publish()
                if execution.outputs.optical
                    try
                        photon_energies=[
                            config.study.photon_energy_min+(i-1)/(
                                config.study.photon_energy_points-1
                            )*(
                                config.study.photon_energy_max-config.study.photon_energy_min
                            ) for i = 1:config.study.photon_energy_points
                        ]
                        metrics=Dict{Symbol,Float64}()
                        response=_configured_optical_response!(
                            metrics,
                            solution,
                            photon_energies,
                            nothing;
                            edge_tolerance = config.study.optical_edge_tolerance,
                            threaded = config.production.parallel_backend===:threads,
                        )
                        optical_path=joinpath(dirname(commit),"optical.h5")
                        temporary_optical=optical_path*".pending"
                        source_receipt=verify_recovery_receipt(commit)
                        try
                            save_optical_physics(temporary_optical,response;
                                source_sha256=bytes2hex(open(sha256,joinpath(dirname(commit),"physics.h5"))),
                                stationary_quality=String(solution_quality(solution)),
                                stationary_assessment=solution_scientific_assessment(solution),
                                source_receipt,identity=source_receipt["identity"])
                            _sync_artifact_file(temporary_optical)
                            mv(temporary_optical,optical_path;force=false)
                            _sync_artifact_directory(dirname(commit))
                        finally
                            isfile(temporary_optical) && rm(temporary_optical)
                        end
                        data["optical"]=replace(relpath(optical_path,root),'\\'=>'/')
                        merge!(observables, Dict(String(k)=>v for (k, v) in metrics))
                        derived["optical"]["status"]="completed"
                    catch error
                        error isa InterruptException && rethrow()
                        derived["optical"]["status"]="failed"
                        derived["optical"]["error"]=sprint(showerror, error)
                        push!(
                            warnings,
                            Dict{String,Any}(
                                "code"=>"OPTIONAL_OPTICS_FAILED",
                                "scope"=>"postprocessing",
                                "message"=>sprint(showerror, error),
                            ),
                        )
                    end
                end
                push!(history, record)
                publish()
                terminal_status=:completed
                _scientific_progress(root, point, attempt, :completed, directory)
                seed_summary=_live_voltage_seed_summary(
                    solution, solution_quality(solution), observables["scientific_assessment"],
                )
                previous=_usable_voltage_state(seed_summary, execution.policies.voltage.mode) ?
                         solution : nothing
                previous_id=point_id
                if execution.policies.on_child_failure===:stop && !solution.converged
                    stop_campaign=true
                end
            catch error
                resource_pressure = error isa _NativePhasePressure
                pressure_message = resource_pressure ? sprint(showerror, error) : ""
                if resource_pressure
                    # Current G and mixed Σ may refer to different iterations.
                    # Only a previously committed accepted boundary is resumable.
                    error = _ScientificPause(latest_commit[], :paused)
                end
                if error isa _ScientificPause
                    terminal_status=error.reason
                    data = _scientific_pause_data(
                        root,
                        directory,
                        error.commit_path,
                        attempt;
                        resource_pressure,
                    )
                    record=_point_result(
                        point,
                        attempt,
                        initialization,
                        error.reason,
                        :unconverged,
                        false;
                        data,
                        warnings = resource_pressure ?
                                   [
                            Dict{String,Any}(
                                "code"=>"RESOURCE_PRESSURE",
                                "scope"=>"point",
                                "message"=>pressure_message,
                            ),
                        ] : Dict{String,Any}[],
                    )
                    index=findfirst(r->r.id==point.id, results)
                    index===nothing ? push!(results, record) : (results[index]=record)
                    push!(history, record)
                    publish(error.reason)
                    _scientific_progress(root, point, attempt, error.reason, directory)
                    return result_document(error.reason)
                end
                error isa InterruptException && (
                    terminal_status = :cancelled;
                    publish_cancelled();
                    _scientific_progress(root, point, attempt, :cancelled, directory);
                    rethrow()
                )
                # Preserve a computed current if the mandatory artifact sink failed.
                prior=!isempty(results) && last(results).id==point_id ? pop!(results) :
                      nothing
                warnings=prior===nothing ? Dict{String,Any}[] : prior.warnings
                push!(
                    warnings,
                    Dict{String,Any}(
                        "code"=>solution===nothing ? "POINT_FAILED" :
                                "MANDATORY_STORAGE_FAILED",
                        "scope"=>"point",
                        "message"=>sprint(showerror, error),
                    ),
                )
                record=_point_result(
                    point,
                    attempt,
                    initialization,
                    :failed,
                    solution===nothing ? :invalid : Symbol(solution_quality(solution)),
                    solution===nothing ? false : solution.converged;
                    warnings,
                    observables = prior===nothing ? Dict{String,Any}() : prior.observables,
                    data = prior===nothing ? Dict{String,Any}() : prior.data,
                    postprocessing = prior===nothing ? Dict{String,Any}() :
                                     prior.postprocessing,
                )
                push!(results, record)
                push!(history, record)
                publish()
                _scientific_progress(root, point, attempt, :failed, directory)
                previous=nothing
                previous_id=point_id
                execution.policies.on_child_failure===:stop && (stop_campaign=true)
            finally
                telemetry_sender===nothing || close(telemetry_sender)
                history_recorder===nothing || flush_scientific_history!(history_recorder)
                if reporter!==nothing
                    try
                        while !isempty(reporter.stack)
                            stage=last(reporter.stack).stage
                            if stage===:point && terminal_status===:completed
                                end_progress_stage!(
                                    reporter,
                                    stage;
                                    status = terminal_status,
                                    iteration = 1,
                                    total = 1,
                                )
                            else
                                end_progress_stage!(
                                    reporter,
                                    stage;
                                    status = terminal_status,
                                )
                            end
                        end
                    catch telemetry_error
                        @warn "terminal telemetry publication failed" exception=(
                            telemetry_error,
                            catch_backtrace(),
                        )
                    finally
                        close(reporter)
                    end
                end
            end
        end
        GC.gc()
    end
    final_status=stop_campaign ? :failed :
                 all(r->r.status===:completed, results) ?
                 (
        all(
            r->r.converged &&
               all(get(op, "status", "")!="failed" for op in values(r.postprocessing)),
            results,
        ) ? :completed : :completed_with_warnings
    ) : :failed
    publish(final_status)
    document=result_document(final_status)
    for execution in selected_executions
        records=filter(r->r.execution_id==execution.id,results)
        isempty(records) || write_stop_receipt(root,execution.id,maximum(r.attempt for r in records),document;archive_byte_budget)
    end
    return document
end

function _scientific_next_state_sequence(directory)
    isdir(directory) || return 1
    sequences=Int[]
    for name in readdir(directory)
        if occursin(r"^generation-\d+$",name)
            push!(sequences,parse(Int,match(r"^generation-(\d+)$",name).captures[1]))
        elseif startswith(name,"imported-") && isfile(joinpath(directory,name,"receipt.json"))
            receipt=verify_recovery_receipt(joinpath(directory,name,"commit.json"))
            push!(sequences,Int(receipt["state_sequence"]))
        end
    end
    return isempty(sequences) ? 1 : maximum(sequences)+1
end
