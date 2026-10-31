struct _ScientificPause <: Exception
    commit_path::Union{Nothing,String}
    reason::Symbol
end

import ..QCLNEGFRunner: publish_native_selection!, _p07_retain_input_pair!, _p05_closed_metadata_limit,
    _native_origin_ids, _native_source_epoch, _p30_begin_performance_anchor,
    _p30_anchor_phase_source, _p30_borrowed_anchor!

function _p05_prepare_scientific_request!(recorder::ScientificHistoryRecorder,
    capture::_P05PlanCapture,configuration,point::ScientificPoint;
    grant_bytes::Int,live_roots::NamedTuple,observer_admission::_P05ObserverAdmission)
    capture.kind===:scientific_plan_v2 || throw(ArgumentError("scientific request requires scientific plan"))
    resolved=_point_resolved_configuration(configuration,point)
    model_preimage=_snapshot_model(resolved)
    bytes2hex(sha256(canonical_bytes(model_preimage)))==recorder.identity["model_sha256"] ||
        throw(ArgumentError("actual point model differs from native identity"))
    roots=merge(live_roots,(;inputs_publication=(live_roots.inputs_publication...,capture,resolved,model_preimage)))
    limit=_p05_input_metadata_limit(grant_bytes,roots;observer_admission)
    request=publish_final_point_request!(recorder;plan_bytes=capture.bytes,model_preimage,
        temperature_K=point.temperature_K,voltage_per_period_V=point.voltage_per_period_V,
        scattering_requested=resolved.scattering,kind=capture.kind,maximum_metadata_bytes=limit)
    return (;request,model_preimage,resolved_configuration=resolved)
end
function _p05_emit_scalar!(sender,event::QCLNEGF.SolverEvent,header::NamedTuple)::Bool
    _scalar_try_producer!(sender) || return false
    try
        keys(header)==(:point_id,:execution_id,:attempt) || throw(ArgumentError("unknown scalar event header"))
        length(event.metrics)<=128 || throw(ArgumentError("too many scalar metrics"))
        # Symbol conversion itself must be bounded, before building attribute dictionaries.
        for symbol in (event.action,event.stage,event.status)
            sizeof(symbol)<=sender.maximum_event_bytes÷6 || throw(ArgumentError("oversized scalar symbol"))
        end
        remaining=Ref(sender.maximum_event_bytes)
        attributes=Dict{String,Any}("point_id"=>header.point_id,"execution_id"=>header.execution_id,
            "attempt"=>header.attempt,"stage"=>String(event.stage),"iteration"=>event.iteration,
            "total"=>event.total,"message"=>event.message,"metrics"=>Dict{String,Any}())
        copied=_telemetry_scalar_copy(Dict{String,Any}("schema"=>"qcl-runtime-event-v1",
            "event"=>String(event.action),"name"=>event.label,"status"=>String(event.status),
            "timestamp_unix_seconds"=>time(),"attributes"=>attributes),0,remaining)
        metrics=copied["attributes"]["metrics"]
        for m in event.metrics
            for symbol in (m.name,m.measurement_status,m.reason)
                symbol===nothing || sizeof(symbol)<=remaining[]÷6 || throw(ArgumentError("oversized scalar metric symbol"))
            end
            name=String(m.name)
            _telemetry_charge!(remaining,Base.checked_add(Base.checked_mul(6,ncodeunits(name)),4))
            metrics[name]=_telemetry_scalar_copy(Dict{String,Any}("value"=>m.value,"unit"=>m.unit,
                "measurement_status"=>String(m.measurement_status),"reason"=>m.reason===nothing ? nothing : String(m.reason)),3,remaining)
        end
        _enqueue_scalar_copy!(sender,copied)
    catch error
        error isa InterruptException && rethrow()
        Threads.atomic_add!(sender.dropped,1);false
    finally
        _scalar_release_producer!(sender)
    end
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
    phase_source = nothing,
)
    data["phase_source"] = _phase_source_projection(phase_source)
    get!(data,"native_source") do
        _p05_native_source(".";reason=status===:skipped ? "solver_not_run" : "no_selected_native_state")
    end
    get!(data,"optical_attachment",nothing)
    if isempty(postprocessing)
        postprocessing=Dict{String,Any}("optical"=>Dict{String,Any}("status"=>"not_requested","error"=>nothing))
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

function _scientific_memory_reservation(config, resource_plan,
    envelope=default_execution_envelope();margin_context=nothing)
    hardware=resource_plan.hardware
    capacity=envelope===nothing ? max(min(hardware.julia_threads,hardware.logical_cpus),1) : envelope.thread_pool_size
    required=scientific_memory_estimate(FilesystemScientificDefinitions(), config;worker_capacity=capacity)
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
    result=Dict{String,Any}(
        "estimated_peak_bytes"=>required,
        "worker_capacity"=>capacity,
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
    if margin_context!==nothing
        policy=_resource_entry_policy(margin_context)
        result["margin"]=_resource_margin_budget(config,resource_plan,hardware,policy;envelope,numerical_required_bytes=required)
    end
    return result
end

# SOURCE admission before allocating a configured grid/basis/kernel or base cache.
# The caller selected config/P/plan once; this gate consumes that same authority.
function _p05_scientific_build_admission!(config,resource_plan,reservation,live_roots;
    observer_admission::_P05ObserverAdmission)
    grant=min(resource_plan.memory_budget_bytes,reservation["memory_budget_bytes"],config.production.memory_budget_bytes)
    available=_p05_input_metadata_limit(grant,live_roots;observer_admission)
    reservation["estimated_peak_bytes"]<=available ||
        throw(ArgumentError("observer payload exceeds scientific build grant"))
    available
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

function _scientific_run_id(plan::ScientificPlan,sources::AbstractDict,requested::Union{Nothing,AbstractString})
    if requested === nothing
        records=get(sources,"solver_source_files",nothing)
        records isa AbstractVector && !isempty(records) || throw(ArgumentError("exact_execution_runtime_unavailable:source_files"))
        return content_id("run",Dict("plan_fingerprint"=>plan.fingerprint,"source_files"=>records))
    end
    run=String(requested)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z",run) || throw(ArgumentError("invalid run identity"))
    return run
end

function _scientific_point_identity(plan::ScientificPlan,execution::ScientificExecution,
    point::ScientificPoint,attempt::Integer;run_id::AbstractString,plan_sha256::AbstractString)
    attempt isa Bool && throw(ArgumentError("attempt must be a positive integer"))
    0 < attempt <= typemax(UInt64) || throw(ArgumentError("attempt must be a positive UInt64"))
    run=String(run_id)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z",run) || throw(ArgumentError("invalid run identity"))
    occursin(r"^[0-9a-f]{64}\z",plan_sha256) || throw(ArgumentError("invalid plan SHA256"))
    selected_executions=filter(e->e.id==execution.id,plan.executions)
    length(selected_executions)==1 && only(selected_executions) === execution ||
        throw(ArgumentError("execution is not the selected plan execution"))
    selected_points=filter(p->p.id==point.id,plan.points)
    length(selected_points)==1 && _point_dict(only(selected_points))==_point_dict(point) &&
        point.execution_id==execution.id && point.id in execution.point_ids ||
        throw(ArgumentError("point is not the selected plan point"))
    passport=_point_passport(execution.configuration,point)
    return Dict{String,Any}("run_id"=>run,"execution_id"=>execution.id,"point_id"=>point.id,
        "attempt"=>string(attempt),
        "branch_id"=>content_id("branch",Dict("execution_id"=>point.execution_id,"branch"=>point.branch)),
        "model_sha256"=>passport["model_sha256"],"plan_sha256"=>String(plan_sha256))
end

function _phase_source_projection(source)
    source === nothing && return Dict{String,Any}(
        "status"=>"unavailable", "session_id"=>nothing, "current_path"=>nothing,
        "reason"=>"phase_source_not_initialized")
    status = source.status
    status in (:available, :disabled, :unavailable) || throw(ArgumentError("invalid phase source status"))
    if status === :available
        source.session_id isa AbstractString && !isempty(source.session_id) &&
            source.current_path isa AbstractString && !isempty(source.current_path) &&
            source.reason === nothing || throw(ArgumentError("invalid available phase source"))
    else
        source.session_id === nothing && source.current_path === nothing &&
            source.reason isa Union{AbstractString,Symbol} && !isempty(String(source.reason)) ||
            throw(ArgumentError("invalid unavailable phase source"))
    end
    return Dict{String,Any}("status"=>String(status), "session_id"=>source.session_id,
        "current_path"=>source.current_path, "reason"=>source.reason === nothing ? nothing : String(source.reason))
end

function _scientific_progress(root, point, attempt, status, artifact_root; event = nothing, phase_source = nothing,native_source=nothing)
    # Producer phases have their own append-only timeline. They must not replace
    # the last physical residual row in the current-point progress projection.
    event !== nothing && event.action in (:phase_begin, :phase_end) && return nothing
    data=Dict{String,Any}(
        "schema"=>"qcl-negf-current-point-v2",
        "point_id"=>point.id,
        "execution_id"=>point.execution_id,
        "attempt"=>attempt,
        "status"=>String(status),
        "updated_unix"=>time(),
        "artifact_root"=>replace(relpath(artifact_root, root), '\\'=>'/'),
        "phase_source"=>_phase_source_projection(phase_source),
        "native_source"=>native_source===nothing ? _p05_native_source(".";reason="no_selected_native_state") : deepcopy(native_source),
    )
    if event!==nothing
        data["stage"]=String(event.stage)
        data["iteration"]=event.iteration
        data["total"]=event.total
        data["metrics"]=[
            Dict("name"=>String(m.name), "value"=>m.value isa AbstractFloat && !isfinite(m.value) ? nothing : m.value,
                "unit"=>m.unit,"measurement_status"=>m.value isa AbstractFloat && !isfinite(m.value) ? "error" : String(m.measurement_status),
                "reason"=>m.value isa AbstractFloat && !isfinite(m.value) ? "nonfinite_display_value" : m.reason===nothing ? nothing : String(m.reason)) for
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
function _import_completed_archives!(progress,archive_bundle,root,policy;
    archive_byte_budget::Int=64*1024^3, resource_policy::Symbol = :standalone,capture_reserve_bytes::Int=0)
    _resource_policy(resource_policy)
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
    _check_storage_free(root,Base.checked_add(Base.checked_add(closure.bytes,policy.reserve_bytes),capture_reserve_bytes))
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
    capture_reserve_bytes::Int = 0,
    resource_policy::Symbol = :standalone,
    envelope::Union{Nothing,ExecutionEnvelope} = default_execution_envelope(),
    margin_context=nothing,
    frozen_plan_bytes::Union{Nothing,Vector{UInt8}}=nothing,
    frozen_plan_capture::Union{Nothing,_P05PlanCapture}=nothing,
    run_id::Union{Nothing,AbstractString}=nothing,
    source_graph::Union{Nothing,AbstractDict}=nothing,
    parent_checkpoint::Union{Nothing,VerifiedExactCheckpoint}=nothing,
    phase_observation_policy::Union{Nothing,PhaseObservationPolicy}=nothing,
    native_origin=nothing,
    model_help_mirror=nothing,
)
    native_origin=_native_origin_ids(native_origin)
    _scientific_resource_preflight(resource_policy,envelope)
    frozen_plan_bytes===nothing || frozen_plan_capture===nothing || throw(ArgumentError("choose one frozen plan source"))
    source_graph=_require_source_graph(source_graph)
    recovery_bundle === nothing || throw(ArgumentError("unsupported_format: legacy recovery bundle"))
    if parent_checkpoint !== nothing
        _p05_parent_root_check(parent_checkpoint,output_directory)
        attempt === nothing && throw(ArgumentError("native5 parent requires an explicit child attempt"))
    end
    capture_reserve_bytes>=0 || throw(ArgumentError("capture reserve must be nonnegative"))
    archive_byte_budget>0 || throw(ArgumentError("archive byte budget must be positive"))
    # Re-decode the frozen raw contract, rejecting mutation and stale typed aliases.
    plan=_resource_execution_plan(plan,margin_context)
    selected_executions=execution_id===nothing ? plan.executions :
                        [e for e in plan.executions if e.id==execution_id]
    margin_context!==nothing && any(e->e.operation!==:stationary,selected_executions) &&
        _resource_unavailable("runtime_margin_operation_unsupported")
    isempty(selected_executions) && throw(ArgumentError("unknown selected execution"))
    help_budget=_ModelHelpBudget(sum(length(e.point_ids) for e in selected_executions if e.operation===:stationary))
    selected_ids=Set(e.id for e in selected_executions)
    selected_points=[p for p in plan.points if p.execution_id in selected_ids]
    if parent_checkpoint !== nothing
        length(selected_points)==1 || throw(ArgumentError("native5 parent requires exactly one selected point"))
        source_identity=checkpoint_reference(parent_checkpoint)["identity"]
        source_identity["point_id"]==only(selected_points).id &&
            source_identity["execution_id"]==only(selected_points).execution_id ||
            throw(ArgumentError("native5 parent does not match selected point"))
        frozen_plan_bytes===nothing && frozen_plan_capture===nothing &&
            throw(ArgumentError("native5_parent_plan_bytes_required"))
        original=frozen_plan_capture===nothing ? frozen_plan_bytes : frozen_plan_capture.bytes
        frozen_plan_capture===nothing || frozen_plan_capture.kind===:scientific_plan_v2 ||
            throw(ArgumentError("native5 parent scientific plan kind differs"))
        length(original)<=CONFIGURATOR_PLAN_BYTES || throw(ArgumentError("scientific plan exceeds byte limit"))
        bytes2hex(sha256(original))==source_identity["plan_sha256"] ||
            throw(ArgumentError("native5 parent original plan bytes differ"))
    end
    # The mandatory final native5 writer is owned by the concurrent persistence
    # integration. Refuse before output creation or compute until it is joined.
    any(e->e.operation===:stationary,selected_executions) &&
        throw(ArgumentError("native5_final_writer_unavailable: typed Results/AiiDA/Q1 transport qualification pending"))
    root=abspath(output_directory)
    mkpath(root)
    attempt===nothing || attempt>0 || throw(ArgumentError("attempt must be positive"))
    requested_attempt=attempt
    _check_storage_free(root,Base.checked_add(_minimum_scientific_output_bytes(plan)+maximum(e.outputs.recovery.reserve_bytes for e in selected_executions),capture_reserve_bytes))
    if margin_context !== nothing
        margin_bytes=Vector{UInt8}(codeunits(margin_context.raw_plan))
        frozen_plan_bytes === nothing || frozen_plan_bytes == margin_bytes ||
            throw(ArgumentError("frozen plan differs from admitted resource entry"))
        frozen_plan_capture===nothing || frozen_plan_capture.bytes==margin_bytes ||
            throw(ArgumentError("frozen plan differs from admitted resource entry"))
        frozen_plan_capture===nothing && (frozen_plan_bytes=margin_bytes)
    end
    plan_binding=_freeze_scientific_plan(plan,root;frozen_plan_bytes,frozen_plan_capture)
    solver_sources=_capture_solver_sources()
    selected_run_id = run_id===nothing && parent_checkpoint!==nothing ?
        checkpoint_reference(parent_checkpoint)["identity"]["run_id"] : run_id
    scientific_run_id=_scientific_run_id(plan,solver_sources,selected_run_id)
    results=ScientificPointResult[]
    history=ScientificPointResult[]
    existing=Dict{String,ScientificPointResult}()
    result_path=joinpath(root, "series_result.json")
    if isfile(result_path)
        document, _=_read_series(root)
        document["schema"]=="qcl-negf-series-result-v4" || throw(ArgumentError("native5_legacy_series_requires_explicit_migration"))
        document["plan_fingerprint"]==plan.fingerprint ||
            throw(ArgumentError("result/plan fingerprint mismatch"))
        _scientific_validate_raw_source_rows(plan, document)
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
    inherited_history=Dict{String,String}() # removed when final native5 persistence is joined
    native_selected_inputs=Dict{String,Any}[]
    point_order=[p.id for p in selected_points]
    for point in selected_points
        haskey(existing,point.id) && _upsert_scientific_point!(results,existing[point.id],point_order)
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
    # Preserve durable rows; only declared, absent descendants receive unrun rows.
    function publish_unrun_descendants(active, reason, status)
        blocked=Set([active.id])
        for point in selected_points
            point.execution_id==active.execution_id || continue
            point.predecessor_id in blocked || continue
            push!(blocked,point.id)
            any(r->r.id==point.id,results) && continue
            warnings=[_continuation_reason_record("DEPENDENCY_UNAVAILABLE",reason,active,
                "declared predecessor interrupted before an eligible final state")]
            record=_point_result(point,active.attempt,
                _initialization("unavailable_predecessor";source=point.predecessor_id),
                :skipped,:not_evaluated,false;warnings)
            _upsert_scientific_point!(results,record,point_order)
            _continuation_record_history!(history,record)
        end
        publish(status)
    end
    publish()
    stop_campaign=false
    branch_failed=false
    for execution in selected_executions
        if stop_campaign
            for point_id in execution.point_ids
                point=points[point_id]
                old=get(existing, point_id, nothing)
                if old!==nothing && old.status===:completed
                    _upsert_scientific_point!(results,old,point_order)
                    continue
                end
                record=_point_result(
                    point,
                    old===nothing ? 1 : old.attempt+1,
                    _initialization("not_started"),
                    :skipped,
                    :not_evaluated,
                    false;
                    warnings = [
                        Dict{String,Any}(
                            "code"=>"CAMPAIGN_STOPPED",
                            "scope"=>"execution",
                            "message"=>"campaign stopped by explicit child failure policy",
                        ),
                    ],
                )
                _upsert_scientific_point!(results,record,point_order)
                _continuation_record_history!(history,record)
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
                    _upsert_scientific_point!(results,old,point_order)
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
                    resource_policy,
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
                _upsert_scientific_point!(results,record,point_order,false)
                _continuation_record_history!(history,record)
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
        build_admission=nothing
        build_roots=nothing
        try
            if margin_context===nothing
                config, resource_plan=resolve_execution_strategy(config;envelope)
            else
                policy=_resource_entry_policy(margin_context)
                candidate=_resource_candidate(config,default_hardware_profile(),policy;envelope)
                config=candidate.configuration;resource_plan=candidate.resource_plan
            end
            configure_execution!(config)
            BLAS.set_num_threads(1)
            save_execution_plan(
                joinpath(execution_dir, "execution_plan.yaml"),
                resource_plan,
            )
            reservation=_scientific_memory_reservation(config, resource_plan, envelope;margin_context)
            _scientific_json(
                joinpath(execution_dir, "scientific_memory_reservation.json"),
                reservation,
            )
            config.execution.solver_backend!==:production &&
                config.domain_adaptation.mode!==:none &&
                throw(ArgumentError("domain adaptation requires the production backend"))
            # Reserve existing busy/draining entries before any numerical build.
            # No producer starts in this temporary epoch. The point epoch later
            # rechecks the actual built residents before starting its producers.
            build_admission=_p05_begin_observers!(;phase_request=nothing,scalar_request=nothing)
            build_roots=(;entry=(plan,selected_executions,selected_points,points,execution,config,source_graph),
                resources=(resource_plan,reservation,envelope,margin_context,solver_sources,config.production),
                construction=(),continuation=(parent_checkpoint,),
                history=(results,history,existing,point_order,inherited_history,native_selected_inputs),
                observers=(telemetry_sink,),inputs_publication=(plan_binding,))
            _p05_scientific_build_admission!(config,resource_plan,reservation,build_roots;
                observer_admission=build_admission)
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
        finally
            build_roots=nothing
            build_admission===nothing || _p05_end_observers!(build_admission)
        end
        previous=nothing
        previous_id=nothing
        branch_cause=nothing
        function remember_failure(record,summary=nothing,terminal=nothing;decorate=true,
                                  interruption=nothing,artifact_error=nothing)
            reasons=_continuation_failure_reasons(record,summary,terminal;interruption,artifact_error)
            if execution.policies.voltage.mode===:strict
                branch_failed=true
                branch_cause=(source=record,reasons=reasons)
                if decorate
                    for (kind,message) in reasons
                        push!(record.warnings,_continuation_reason_record("BRANCH_STOPPED",kind,record,message))
                    end
                end
            end
            return nothing
        end

        for point_id in execution.point_ids
            point=points[point_id]
            old=get(existing, point_id, nothing)
            resume && old !== nothing && parent_checkpoint===nothing &&
                throw(ArgumentError("native5_explicit_parent_selection_required"))
            attempt=requested_attempt===nothing ? (old===nothing ? 1 : old.attempt+1) : requested_attempt
            initialization=_initialization("cold")
            restoring=parent_checkpoint!==nothing
            if restoring
                initialization=_initialization("checkpoint";
                    checkpoint=checkpoint_reference(parent_checkpoint)["manifest"]["path"])
            elseif point.predecessor_id===nothing
                previous=nothing
                previous_id=nothing
            elseif previous_id==point.predecessor_id && previous!==nothing
                initialization=_initialization("predecessor"; source = previous_id)
            else
                policy=execution.policies.voltage.invalid_predecessor
                action=_continuation_branch_action(execution.policies.voltage,branch_cause,false)
                if action===:cold_fallback_declared
                    initialization=_initialization(
                        "cold_fallback";
                        source = point.predecessor_id,
                        reason = branch_cause===nothing || isempty(branch_cause.reasons) ?
                            "predecessor evidence unavailable" :
                            join((message for (_,message) in branch_cause.reasons),"; "),
                    )
                    previous=nothing
                else
                    attempt=_continuation_unrun_attempt(attempt,
                        branch_cause===nothing ? nothing : branch_cause.source,requested_attempt)
                    record=_point_result(
                        point,
                        attempt,
                        _initialization(
                            "unavailable_predecessor";
                            source = point.predecessor_id,
                        ),
                        :skipped,
                        :not_evaluated,
                        false;
                        warnings = [
                            Dict{String,Any}(
                                "code"=>"DEPENDENCY_UNAVAILABLE",
                                "scope"=>"branch",
                                "message"=>"predecessor did not provide an allowed state; policy=$policy",
                            ),
                        ],
                    )
                    if branch_cause!==nothing
                        for (kind,message) in branch_cause.reasons
                            push!(record.warnings,_continuation_reason_record("DEPENDENCY_UNAVAILABLE",kind,branch_cause.source,message))
                        end
                    end
                    branch_failed |= execution.policies.voltage.mode===:strict
                    _upsert_scientific_point!(results,record,point_order)
                    _continuation_record_history!(history,record)
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
                preparation_error===nothing || remember_failure(record)
                _upsert_scientific_point!(results,record,point_order)
                _continuation_record_history!(history,record)
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
            phase_observer=nothing
            observer_admission=nothing
            phase_source=(status=:disabled,session_id=nothing,current_path=nothing,reason="telemetry_disabled")
            history_recorder=nothing
            performance_anchor_path=nothing
            callbacks=nothing;committed=nothing;recorded=nothing;terminal=nothing;prepared_final_request=nothing;final_phase=false
            latest_commit=Ref{Union{Nothing,String}}(
                restoring &&
                old !== nothing &&
                get(old.data, "result_commit", nothing) !== nothing ?
                joinpath(root, old.data["result_commit"]) : nothing,
            )
            terminal_status=:failed
            point_primary=nothing
            try
                phase_identity=execution.outputs.telemetry.enabled ?
                    _scientific_point_identity(plan,execution,point,attempt;
                        run_id=scientific_run_id,plan_sha256=plan_binding.plan_sha256) : nothing
                session="phase-"*string(time_ns())
                phase_policy=phase_observation_policy===nothing ?
                    _normal_phase_policy(execution.outputs.telemetry.buffer_events) : phase_observation_policy
                phase_request=execution.outputs.telemetry.enabled ?
                    (;directory=joinpath(directory,"progress","phases",session),artifact_root=root,
                        identity=phase_identity,source_session=session,policy=phase_policy,
                        capacity_events=execution.outputs.telemetry.buffer_events) : nothing
                scalar_request=execution.outputs.telemetry.enabled && telemetry_sink!==nothing ?
                    (;sink=telemetry_sink,capacity=execution.outputs.telemetry.buffer_events,
                        maximum_event_bytes=16384,poll_seconds=.01) : nothing
                observer_admission=_p05_begin_observers!(;phase_request,scalar_request)
                pre_roots=(;entry=(plan,selected_executions,selected_points,points,execution,point,config,source_graph),
                    resources=(resource_plan,reservation,envelope,margin_context,solver_sources,config.production,observer_admission),
                    construction=(configured,base_cache),continuation=(previous,previous_id,parent_checkpoint,branch_cause,initialization),
                    history=(results,history,existing,old,latest_commit,point_order,inherited_history,native_selected_inputs),
                    observers=(telemetry_sink,),inputs_publication=(plan_binding,phase_source,phase_identity))
                admitted_grant=min(reservation["memory_budget_bytes"],config.production.memory_budget_bytes)
                available=_p05_input_metadata_limit(admitted_grant,pre_roots;observer_admission)
                planned=QCLNEGF.estimate_production_memory(config.numerical,config.scattering;options=config.production)
                planned.peak_bytes<=available || throw(ArgumentError("observer payload exceeds scientific grant"))
                if execution.outputs.telemetry.enabled
                    try
                        observer_admission.start_phase || throw(_PhaseObserverUnavailable(:previous_phase_writer_pending))
                        phase_observer=_start_phase_observer(joinpath(directory,"progress","phases",session);
                            artifact_root=root,identity=phase_identity,source_session=session,
                            policy=phase_policy,capacity_events=execution.outputs.telemetry.buffer_events,admission=observer_admission)
                        phase_source=_phase_source_descriptor(phase_observer)
                    catch phase_error
                        phase_error isa InterruptException && rethrow()
                        reason=phase_error isa _PhaseObserverUnavailable ? phase_error.reason : :phase_source_initialization_failed
                        phase_source=(status=:unavailable,session_id=nothing,current_path=nothing,reason=reason)
                    end
                end
                if execution.outputs.telemetry.enabled
                    performance_anchor_path=joinpath(root,"performance-anchor-current.json")
                    phase_anchor=_p30_begin_performance_anchor(root,performance_anchor_path,phase_identity,phase_source,native_origin)
                    if phase_anchor.failed
                        phase_source=(status=:unavailable,session_id=nothing,current_path=nothing,
                            reason=:performance_anchor_publication_failed)
                        performance_anchor_path=nothing
                    end
                end
                _scientific_progress(root, point, attempt, :running, directory;phase_source)
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
                    if observer_admission.start_scalar
                        telemetry_sender=_start_scalar_sender(telemetry_sink;capacity=execution.outputs.telemetry.buffer_events,
                            maximum_event_bytes=16384,poll_seconds=.01,admission=observer_admission)
                    else
                        @warn "scalar telemetry unavailable" reason=:previous_scalar_sender_pending
                    end
                end
                function observe_solver_event(event)
                    phase_source=_p30_anchor_phase_source(history_recorder,phase_source)
                    event.action in (:phase_begin,:phase_end) && return nothing
                    if telemetry_sender!==nothing
                        _p05_emit_scalar!(telemetry_sender,event,(;point_id=point.id,execution_id=execution.id,attempt))
                    end
                    _scientific_progress(root,point,attempt,:running,directory;event,phase_source)
                end
                event_sink=_progress_event_sink(reporter;solver_event_observer=observe_solver_event,phase_observer)
                runtime_options=with_production_options(
                    config.production;
                    event_sink=nothing,
                    phase_request = _native_phase_request(reporter.machine_directory;resource_policy),
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
                identity=_scientific_point_identity(plan,execution,point,attempt;
                    run_id=scientific_run_id,plan_sha256=plan_binding.plan_sha256)
                unmeasured()=Dict{String,Any}("state"=>"not_measured","reason"=>"pending_scientific_assessment","evidence"=>nothing)
                running_status=Dict{String,Any}("process"=>Dict{String,Any}("state"=>"running","exit_code"=>nothing,"reason"=>nothing),
                    (name=>unmeasured() for name in ("convergence","physics","discretization","experimental"))...)
                history_recorder=ScientificHistoryRecorder(directory;artifact_root=root,identity,
                    source_epoch=_native_source_epoch(native_origin),provenance=source_graph,status=running_status,
                    maximum_scba_rows=config.solver.max_scba,parent_checkpoint,resource_policy,performance_anchor_path)
                phase_source=_p30_anchor_phase_source(history_recorder,phase_source)
                recovery_policy=execution.outputs.recovery
                recovery_directory=joinpath(root,"recovery",execution.id,point.id)
                archive_directory=joinpath(root,"archive",execution.id,point.id)
                operational_directories=[joinpath(root,"executions"),joinpath(root,"recovery")]
                checkpoint_clock=CheckpointDeadline(;interval_seconds=recovery_policy.interval_seconds)
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
                input_roots=(;
                    entry=(plan,selected_executions,selected_points,points,execution,point,config,source_graph,native_origin),
                    resources=(resource_plan,reservation,envelope,margin_context,solver_sources,runtime_options,observer_admission),
                    construction=(configured,base_cache,problem,cache),
                    continuation=(previous,previous_id,parent_checkpoint,branch_cause,initialization),
                    history=(results,history,existing,old,history_recorder,latest_commit,point_order,inherited_history,native_selected_inputs),
                    observers=(phase_observer,telemetry_sender,reporter,event_sink,observe_solver_event,
                        publish,result_document,publish_unrun_descendants,remember_failure),
                    inputs_publication=(plan_binding,running_status,coverage,checkpoint_clock,phase_source,identity))
                admitted_grant=min(reservation["memory_budget_bytes"],runtime_options.memory_budget_bytes)
                prepared_final_request=_p05_prepare_scientific_request!(history_recorder,plan_binding,config,point;
                    grant_bytes=admitted_grant,live_roots=input_roots,observer_admission)
                exact_capture=_capture_exact_execution(runtime_options,solver_sources)
                kernel_binding=config.domain_adaptation.mode===:none ? nothing : config.kernels
                callback_roots=merge(input_roots,(;inputs_publication=(input_roots.inputs_publication...,prepared_final_request,exact_capture)))
                intermediate_cap=Base.checked_sub(_p05_input_metadata_limit(admitted_grant,callback_roots;observer_admission),reservation["estimated_peak_bytes"])
                intermediate_cap>0 || throw(ArgumentError("intermediate input IO exceeds scientific grant"))
                callbacks=_p05_science_callbacks(history_recorder,problem;options=config.solver,
                    production_options=runtime_options,execution=exact_capture.execution,
                    domain_adaptation=config.domain_adaptation,kernel_options=kernel_binding,
                    status=()->running_status,request=prepared_final_request.request,
                    maximum_metadata_bytes=intermediate_cap)
                parent_state=parent_checkpoint===nothing ? nothing : load_exact_solver_state(parent_checkpoint)
                restored=parent_state===nothing ? nothing : QCLNEGF.restore_exact_state(problem,parent_state;
                    options=config.solver,production_options=runtime_options,execution=exact_capture.execution,
                    domain_adaptation=config.domain_adaptation,kernel_options=kernel_binding)
                started=time_ns()
                solution=if restored !== nothing && parent_state.boundary===:final
                    QCLNEGF.restore_completed_solution(restored;revalidation=:selected_map,
                        independent_oracle=:if_supported)
                elseif restored !== nothing
                    _model_help_capture!(help_budget,directory,problem,runtime_options,plan_binding,point,identity;mirror=model_help_mirror)
                    solve_adaptive_production(problem;restart=restored,
                        observation_sink=event_sink,checkpoint_context_sink=callbacks.checkpoint_context_sink,
                        history_observer=callbacks.history_observer)
                elseif config.execution.solver_backend===:production
                    _model_help_capture!(help_budget,directory,problem,runtime_options,plan_binding,point,identity;mirror=model_help_mirror)
                    solve_adaptive_production(problem;domain_adaptation=config.domain_adaptation,
                        kernel_options=config.kernels,options=config.solver,
                        production_options=runtime_options,execution=exact_capture.execution,
                        cache,initial_Uᴴ=previous===nothing ? nothing : previous.Uᴴ,
                        initial_scba=previous===nothing ? nothing : previous.scba,
                        observation_sink=event_sink,checkpoint_context_sink=callbacks.checkpoint_context_sink,
                        history_observer=callbacks.history_observer)
                else
                    throw(ArgumentError("native5_educational_consumer_unavailable"))
                end
                final_phase=true
                terminal=parent_state!==nothing && parent_state.boundary===:final ? parent_state : callbacks.terminal[]
                terminal===nothing && throw(ArgumentError("global final checkpoint missing"))
                final_status=_p05_final_status_input(Dict("state"=>"succeeded","exit_code"=>0,"reason"=>nothing),running_status)
                final_roots=merge(input_roots,(;construction=(configured,base_cache,problem,cache,solution,terminal),
                    continuation=(previous,previous_id,parent_checkpoint,parent_state,restored,branch_cause,initialization),
                    history=(input_roots.history...,callbacks),
                    inputs_publication=(input_roots.inputs_publication...,prepared_final_request,exact_capture,final_status)))
                limits=_p05_final_limits(solution,terminal,history_recorder,prepared_final_request.request,final_status;
                    production_options=runtime_options,grant_bytes=admitted_grant,live_roots=final_roots,
                    input_documents=(;plan=plan_binding.document,model=prepared_final_request.model_preimage),observer_admission)
                committed,presentation=_p05_commit_final_with_presentation!(history_recorder,solution,terminal;
                    options=config.solver,production_options=runtime_options,execution=exact_capture.execution,
                    domain_adaptation=config.domain_adaptation,kernel_options=kernel_binding,status=final_status,
                    request=prepared_final_request.request,
                    source_mode=parent_state!==nothing && parent_state.boundary===:final ? :completed_restore : :produced,limits...)
                phase_source=_p30_anchor_phase_source(history_recorder,phase_source)
                _p07_retain_input_pair!(native_selected_inputs,".",committed.checkpoint,
                    prepared_final_request.request,limits.maximum_metadata_bytes)
                recorded=_p05_recorded_final(committed,limits.maximum_metadata_bytes)
                observables=Dict{String,Any}("current_density_A_per_m2"=>recorded.current,
                    "sheet_density_per_m2"=>recorded.sheet_density,"wall_seconds"=>(time_ns()-started)*1e-9,
                    "outer_iterations"=>length(terminal.outer_history),"scba_iterations"=>length(terminal.scba.history),
                    "representation_preflight"=>coverage,"scientific_assessment"=>presentation.stationary_assessment,
                    "validation"=>presentation.validation,"positivity"=>presentation.positivity)
                warnings=Dict{String,Any}[deepcopy(w) for w in get(solution.observables,:warnings,Dict{String,Any}[])]
                data=Dict{String,Any}("native_source"=>_p05_native_source(".";committed...),"optical_attachment"=>nothing,
                    "phase_source"=>_phase_source_projection(phase_source))
                derived=Dict{String,Any}("optical"=>Dict{String,Any}("status"=>execution.outputs.optical ? "pending" : "not_requested","error"=>nothing))
                # Terminal result appears only after successful final triple return.
                record=_point_result(point,attempt,initialization,execution.outputs.optical ? :saving : :completed,Symbol(recorded.summary["quality"]),recorded.summary["converged"];
                    warnings,observables,data,postprocessing=derived,phase_source)
                seed_summary=_live_voltage_seed_summary(solution,recorded.summary["quality"],presentation.stationary_assessment)
                if execution.policies.voltage.mode===:strict && !_usable_voltage_state(seed_summary,execution.policies.voltage.mode)
                    remember_failure(record,seed_summary,solution.status)
                end
                _upsert_scientific_point!(results,record,point_order)
                publish()
                if execution.outputs.optical
                    try
                        throw(ArgumentError("native5_optical_provenance_join_pending"))
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
                if execution.outputs.optical
                    record=_point_result(point,attempt,initialization,:completed,Symbol(recorded.summary["quality"]),recorded.summary["converged"];
                        warnings,observables,data,postprocessing=derived,phase_source)
                    _upsert_scientific_point!(results,record,point_order)
                end
                _continuation_record_history!(history,record)
                publish()
                terminal_status=:completed
                _scientific_progress(root, point, attempt, :completed, directory;phase_source,native_source=data["native_source"])
                seed_summary=_live_voltage_seed_summary(
                    solution, recorded.summary["quality"], presentation.stationary_assessment,
                )
                previous=_usable_voltage_state(seed_summary, execution.policies.voltage.mode) ?
                         solution : nothing
                previous_id=point_id
                if execution.policies.on_child_failure===:stop && !solution.converged
                    stop_campaign=true
                end
            catch error
                point_primary=error
                # A final publication or mandatory callback failure cannot be
                # converted to a terminal point/light row or replayed as repair.
                callback_failure=callbacks===nothing ? nothing : callbacks.failure[]
                if final_phase || callback_failure!==nothing || (history_recorder!==nothing && history_recorder.failed)
                    callback_failure===nothing || callback_failure===error || throw(callback_failure)
                    rethrow()
                end
                if (callbacks===nothing || callbacks.latest[]===nothing) && history_recorder!==nothing && parent_checkpoint!==nothing
                    _p30_borrowed_anchor!(history_recorder,parent_checkpoint)
                end
                phase_source=_p30_anchor_phase_source(history_recorder,phase_source)
                error_source=callbacks!==nothing && callbacks.latest[]!==nothing ?
                    _p05_native_source(".";checkpoint=callbacks.latest[],reason="last_accepted_boundary_before_failure") :
                    parent_checkpoint!==nothing ? _p05_native_source(".";checkpoint=parent_checkpoint,relation="retained_source",reason="selected_parent_before_failure") :
                    _p05_native_source(".";reason="no_selected_native_state")
                if callbacks!==nothing && callbacks.latest[]!==nothing
                    try
                        _p07_retain_input_pair!(native_selected_inputs,".",callbacks.latest[],
                            prepared_final_request.request,intermediate_cap)
                    catch publication_error
                        throw(CompositeException([error,publication_error]))
                    end
                end
                if error isa _ScientificPause
                    terminal_status=error.reason
                    data=Dict{String,Any}("native_source"=>error_source,"phase_source"=>_phase_source_projection(phase_source),"optical_attachment"=>nothing)
                    record=_point_result(
                        point,
                        attempt,
                        initialization,
                        error.reason,
                        :unconverged,
                        false;
                        data,
                        warnings = Dict{String,Any}[],
                    )
                    remember_failure(record;interruption=error.reason)
                    record.data["phase_source"]=_phase_source_projection(phase_source)
                    _upsert_scientific_point!(results,record,point_order)
                    _continuation_record_history!(history,record)
                    publish_unrun_descendants(record,"interrupted",error.reason)
                    _scientific_progress(root, point, attempt, error.reason, directory;phase_source)
                    document=result_document(error.reason)
                    publication_roots=merge(input_roots,(;
                        construction=(configured,base_cache,problem,cache,solution,terminal),
                        history=(input_roots.history...,callbacks),
                        inputs_publication=(input_roots.inputs_publication...,prepared_final_request,document)))
                    publication_cap=_p05_input_metadata_limit(admitted_grant,publication_roots;observer_admission)
                    try
                        publish_native_selection!(root,document;selected_inputs=native_selected_inputs,maximum_metadata_bytes=publication_cap)
                    catch publication_error
                        throw(CompositeException([error,publication_error]))
                    end
                    return document
                end
                if error isa InterruptException
                    terminal_status=:cancelled
                    retained=_continuation_current_attempt_row(results,point_id,execution.id,attempt)
                    if retained!==nothing && retained.status===:completed
                        _continuation_record_history!(history,retained)
                        publish_unrun_descendants(retained,"interrupted",:cancelled)
                        _scientific_progress(root,point,attempt,:cancelled,directory;phase_source)
                        rethrow()
                    end
                    record=_point_result(point,attempt,initialization,:cancelled,:not_evaluated,false;
                        data=Dict{String,Any}("native_source"=>error_source),
                        warnings=[Dict{String,Any}("code"=>"CANCELLED","scope"=>"point","message"=>"cooperative cancellation")])
                    remember_failure(record;interruption=:cancelled)
                    record.data["phase_source"]=_phase_source_projection(phase_source)
                    _upsert_scientific_point!(results,record,point_order)
                    _continuation_record_history!(history,record)
                    publish_unrun_descendants(record,"interrupted",:cancelled)
                    _scientific_progress(root,point,attempt,:cancelled,directory;phase_source)
                    rethrow()
                end
                # Preserve a computed current if the mandatory artifact sink failed.
                prior=_continuation_current_attempt_row(results,point_id,execution.id,attempt)
                if prior!==nothing && prior.status===:completed
                    # A later operational error cannot revoke an immutable final.
                    _continuation_record_history!(history,prior)
                    branch_failed=true
                    previous=nothing
                    previous_id=point_id
                    execution.policies.on_child_failure===:stop && (stop_campaign=true)
                    publish()
                    _scientific_progress(root,point,attempt,:failed,directory;phase_source)
                    continue
                end
                warnings=prior===nothing ? Dict{String,Any}[] : copy(prior.warnings)
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
                    recorded===nothing ? :not_evaluated : Symbol(recorded.summary["quality"]),
                    solution===nothing ? false : solution.converged;
                    warnings,
                    observables = prior===nothing ? Dict{String,Any}() : deepcopy(prior.observables),
                    data = prior===nothing ? Dict{String,Any}("native_source"=>error_source) : deepcopy(prior.data),
                    postprocessing = prior===nothing ? Dict{String,Any}() :
                                     deepcopy(prior.postprocessing),
                )
                remember_failure(record,nothing,solution===nothing ? nothing : solution.status;
                    artifact_error=solution===nothing ? nothing : sprint(showerror,error))
                record.data["phase_source"]=_phase_source_projection(phase_source)
                _upsert_scientific_point!(results,record,point_order)
                _continuation_record_history!(history,record)
                publish()
                _scientific_progress(root, point, attempt, :failed, directory;phase_source)
                previous=nothing
                previous_id=point_id
                execution.policies.on_child_failure===:stop && (stop_campaign=true)
            finally
                try
                phase_observer===nothing || _close_phase_observer!(phase_observer)
                telemetry_sender===nothing || close(telemetry_sender)
                _p05_flush_open_history!(history_recorder,point_primary)
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
                finally
                    # No callback-bearing object escapes into the point/history record.
                    phase_observer=nothing;telemetry_sender=nothing;event_sink=nothing
                    observe_solver_event=nothing;runtime_options=nothing;callbacks=nothing
                    input_roots=nothing;pre_roots=nothing
                    reporter=nothing;history_recorder=nothing;latest_commit=nothing
                    phase_anchor=nothing;performance_anchor_path=nothing
                    # Only `previous` remains an intentional numerical continuation.
                    # Other point locals have reached their last use; retaining them
                    # would hide old problem/cache/restoration payload from the next
                    # build/point admission's declared stable roots.
                    solution=nothing;problem=nothing;cache=nothing
                    terminal=nothing;committed=nothing;presentation=nothing;recorded=nothing
                    final_roots=nothing;final_status=nothing;limits=nothing;callbacks=nothing;callback_roots=nothing;intermediate_cap=nothing
                    error_source=nothing;callback_failure=nothing
                    parent_state=nothing;restored=nothing;prepared_final_request=nothing
                    exact_capture=nothing;kernel_binding=nothing
                    checkpoint_request=nothing;checkpoint_clock=nothing
                    response=nothing;photon_energies=nothing
                    observer_admission===nothing || _p05_end_observers!(observer_admission)
                end
            end
        end
        # Last use in this execution: do not retain prior numerical residents
        # invisibly across the next execution's pre-build admission.
        previous=nothing;solution=nothing;configured=nothing;base_cache=nothing
        GC.gc()
    end
    final_status=(stop_campaign || branch_failed) ? :failed :
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
    publication_roots=(;entry=(plan,selected_executions,selected_points,points,source_graph,document,native_selected_inputs),
        resources=(envelope,),construction=(),continuation=(),history=(results,history,existing,point_order),
        observers=(),inputs_publication=(plan_binding,))
    declared=minimum(e.configuration.production.memory_budget_bytes for e in selected_executions)
    publication_cap=_p05_closed_metadata_limit(declared,publication_roots;envelope)
    publish_native_selection!(root,document;selected_inputs=native_selected_inputs,maximum_metadata_bytes=publication_cap)
    # Native v4 has no legacy result_commit receipt. Q1 typed transport-close
    # remains an explicit release dependency; do not manufacture its success.
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
