# Forecast-only transport: installed source IDs are trusted process arguments.
# Target fields are net admitted per-allocation capacities from the controller;
# this adapter never discovers worker/host facts or claims a resource reservation.
const RESOURCE_PROPOSAL_REQUEST_BYTES=5*1024^2
const RESOURCE_PROPOSAL_RESPONSE_BYTES=1024^2
const RESOURCE_POLICY_BYTES=64*1024

struct ResourceForecastUnavailable <: Exception
    detail::String
end
_resource_unavailable(detail)=throw(ResourceForecastUnavailable(detail))
struct _TrustedResourcePolicy
    policy_id::String
    policy_sha256::String
    runner_source_id::String
    core_source_id::String
    runtime_id::String
    plan_sha256::String
    maximum_solver_threads::Int
    maximum_hard_memory_bytes::Int
    runtime_upper_bytes::Int
    allocator_retention_upper_bytes::Int
    confidence::String
    approval_ref::String
    calibration_ref::Union{Nothing,NamedTuple{(:artifact_sha256,:locator),Tuple{String,String}}}
end

# Retain original immutable bytes, never a mutable typed-plan alias or a SHA
# inferred by serializing that alias. The owner port binds actual entry bytes.
struct _ResourceExecutionEntry
    raw_plan::String
    trusted_policy::_TrustedResourcePolicy
    entry_binding::NamedTuple{(:plan_sha256,:runner_source_id,:core_source_id,:runtime_id),Tuple{String,String,String,String}}
end

function _resource_bind_entry(raw::AbstractString,policy,runner_source_id,core_source_id,runtime_id)
    policy isa _TrustedResourcePolicy || _resource_unavailable("margin_policy_required")
    ncodeunits(raw)<=CONFIGURATOR_PLAN_BYTES && isvalid(raw) || _cfg_refuse("input_limit")
    binding=(plan_sha256=_cfg_sha(raw),runner_source_id=String(runner_source_id),
        core_source_id=String(core_source_id),runtime_id=String(runtime_id))
    _resource_entry_policy((trusted_policy=policy,entry_binding=binding))
    load_scientific_plan(_configurator_json(raw;maximum=CONFIGURATOR_PLAN_BYTES))
    return _ResourceExecutionEntry(String(raw),policy,binding)
end

function _resource_execution_plan(plan::ScientificPlan,context)
    context===nothing && return load_scientific_plan(scientific_plan_dict(plan))
    context isa _ResourceExecutionEntry || _resource_unavailable("actual_raw_entry_required")
    _resource_entry_policy(context)
    _cfg_sha(context.raw_plan)==context.entry_binding.plan_sha256 ||
        _resource_unavailable("margin_policy_entry_mismatch")
    bound=load_scientific_plan(_configurator_json(context.raw_plan;maximum=CONFIGURATOR_PLAN_BYTES))
    actual=load_scientific_plan(scientific_plan_dict(plan))
    # This compares two owning validated logical load results. It does not
    # claim serialization of a typed plan reproduces the original raw bytes.
    canonical_bytes(scientific_plan_dict(actual))==canonical_bytes(scientific_plan_dict(bound)) ||
        _resource_unavailable("margin_plan_mismatch")
    return bound
end

function _resource_string(value;maximum=256)
    value isa AbstractString && 0<ncodeunits(value)<=maximum &&
        all(c->!iscntrl(c),value) || _cfg_refuse("invalid_policy_string")
    return String(value)
end
function _resource_sha(value)
    value isa AbstractString && occursin(r"^[0-9a-f]{64}$",value) || _cfg_refuse("invalid_policy_sha256")
    return String(value)
end

function _resource_load_policy(path,expected_sha,runtime_id,runner_source_id,core_source_id)
    try
        _resource_sha(expected_sha)
        path isa AbstractString && isabspath(path) && normpath(path)==path &&
            !islink(path) && !any(islink(p) for p in splitpath_ancestors(path)) && isfile(path) ||
            _resource_unavailable("margin_policy_file_unavailable")
        filesize(path)<=RESOURCE_POLICY_BYTES || _resource_unavailable("margin_policy_limit")
        bytes=open(path,"r") do io
            read(io,RESOURCE_POLICY_BYTES+1)
        end
        length(bytes)<=RESOURCE_POLICY_BYTES && _cfg_sha(bytes)==expected_sha ||
            _resource_unavailable("margin_policy_sha256_mismatch")
        raw=_configurator_json(String(bytes);maximum=RESOURCE_POLICY_BYTES)
        _cfg_keys(raw,["schema","policy_id","runner_source_id","core_source_id","runtime_id","plan_sha256",
            "maximum_solver_threads","maximum_hard_memory_bytes","coverage_contract","runtime_upper_bytes",
            "allocator_retention_upper_bytes","confidence","approval_ref","calibration_ref"])
        raw["schema"]=="qcl-negf-runtime-margin-policy-v1" && raw["coverage_contract"]=="disjoint_non_numerical_v1" ||
            _resource_unavailable("margin_policy_coverage_unsupported")
        for (key,expected) in (("runtime_id",runtime_id),("runner_source_id",runner_source_id),("core_source_id",core_source_id))
            _resource_string(raw[key])==_resource_string(expected) || _resource_unavailable("margin_policy_source_mismatch")
        end
        confidence=raw["confidence"]
        confidence in ("approved_conservative_uncalibrated","calibrated_within_scope") || _cfg_refuse("invalid_policy_confidence")
        calibration=raw["calibration_ref"]
        if confidence=="calibrated_within_scope"
            _cfg_keys(calibration,["artifact_sha256","locator"])
            calibration=(artifact_sha256=_resource_sha(calibration["artifact_sha256"]),locator=_resource_string(calibration["locator"]))
        else
            calibration===nothing || _cfg_refuse("invalid_policy_calibration")
        end
        r=_resource_integer(raw["runtime_upper_bytes"];minimum=1)
        a=_resource_integer(raw["allocator_retention_upper_bytes"];minimum=1)
        Base.checked_add(r,a)
        return _TrustedResourcePolicy(_resource_string(raw["policy_id"];maximum=128),String(expected_sha),
            String(runner_source_id),String(core_source_id),String(runtime_id),_resource_sha(raw["plan_sha256"]),
            _resource_integer(raw["maximum_solver_threads"];minimum=1,maximum=256),
            _resource_integer(raw["maximum_hard_memory_bytes"];minimum=1),r,a,String(confidence),
            _resource_string(raw["approval_ref"]),calibration)
    catch error
        error isa ResourceForecastUnavailable && rethrow()
        error isa Union{ConfiguratorRefusal,ArgumentError,IOError,SystemError,OverflowError} || rethrow()
        _resource_unavailable("margin_policy_invalid")
    end
end

# Walk only lexical ancestors; never resolve symlinks into a different asset.
function splitpath_ancestors(path)
    result=String[]; parent=dirname(path)
    while true
        push!(result,parent)
        next=dirname(parent);next==parent && break;parent=next
    end
    return result
end

function _resource_entry_policy(context)
    if context isa _ResourceExecutionEntry
        context=(trusted_policy=context.trusted_policy,entry_binding=context.entry_binding)
    end
    context isa NamedTuple && Set(keys(context))==Set((:trusted_policy,:entry_binding)) ||
        _resource_unavailable("margin_context_invalid")
    policy=context.trusted_policy
    policy isa _TrustedResourcePolicy || _resource_unavailable("margin_policy_required")
    binding=context.entry_binding
    binding isa NamedTuple && Set(keys(binding))==Set((:plan_sha256,:runner_source_id,:core_source_id,:runtime_id)) ||
        _resource_unavailable("margin_context_invalid")
    for key in keys(binding)
        getfield(binding,key)==getfield(policy,key) || _resource_unavailable("margin_policy_entry_mismatch")
    end
    return policy
end

function _resource_margin_budget(config,resource_plan,hardware,policy;envelope=nothing,numerical_required_bytes=nothing)
    policy isa _TrustedResourcePolicy || _resource_unavailable("margin_policy_required")
    cpu=envelope===nothing ? max(min(hardware.julia_threads,hardware.logical_cpus),1) : envelope.thread_pool_size
    hard=envelope===nothing ? hardware.total_memory_bytes : envelope.hard_memory_bytes
    1<=cpu<=policy.maximum_solver_threads && hard<=policy.maximum_hard_memory_bytes ||
        _resource_unavailable("margin_policy_scope_exceeded")
    r=policy.runtime_upper_bytes;a=policy.allocator_retention_upper_bytes
    overhead=Base.checked_add(r,a)
    reserve=0;unassigned=nothing
    if envelope!==nothing
        execution_budget(hardware,envelope)
        r<=envelope.runtime_memory_bytes || _resource_unavailable("runtime_partition_undercovered")
        a<=envelope.allocator_memory_bytes || _resource_unavailable("allocator_partition_undercovered")
        budget=min(resource_plan.memory_budget_bytes,envelope.numerical_memory_bytes)
        boundary="explicit_envelope"
    elseif config.execution.strategy===:auto_exact
        budget,reserve=_effective_memory_budget(hardware,config.execution.automatic,nothing)
        overhead<=reserve || _resource_unavailable("margin_not_covered")
        budget==resource_plan.memory_budget_bytes || _resource_unavailable("numerical_boundary_mismatch")
        unassigned=Base.checked_sub(reserve,overhead)
        boundary="standalone_auto"
    elseif config.execution.strategy===:manual
        budget=_resource_integer(resource_plan.memory_budget_bytes;minimum=1)
        combined=try Base.checked_add(budget,overhead) catch error
            error isa OverflowError || rethrow()
            _resource_unavailable("manual_margin_does_not_fit")
        end
        combined<=min(hardware.total_memory_bytes,hardware.available_memory_bytes) ||
            _resource_unavailable("manual_margin_does_not_fit")
        boundary="standalone_manual"
    else
        _resource_unavailable("unsupported_execution_strategy")
    end
    estimate_receipt=numerical_required_bytes===nothing ?
        scientific_resource_estimate(config;worker_capacity=cpu) : nothing
    required=estimate_receipt===nothing ? _resource_integer(numerical_required_bytes) :
        estimate_receipt["estimated_numerical_peak_bytes"]
    required<=budget || _resource_unavailable("numerical_does_not_fit")
    margin=Dict{String,Any}("policy_id"=>policy.policy_id,"policy_sha256"=>policy.policy_sha256,
        "runtime_id"=>policy.runtime_id,"coverage_contract"=>"disjoint_non_numerical_v1",
        "confidence"=>policy.confidence,"boundary"=>boundary,"runtime_upper_bytes"=>r,
        "allocator_retention_upper_bytes"=>a,"non_numerical_upper_bytes"=>overhead,
        "generic_reserve_bytes"=>reserve,"numerical_budget_bytes"=>budget,
        "numerical_required_bytes"=>required,"numerical_headroom_bytes"=>Base.checked_sub(budget,required),
        "unassigned_generic_reserve_bytes"=>unassigned)
    if envelope!==nothing
        margin["envelope"]=Dict("numerical_memory_bytes"=>envelope.numerical_memory_bytes,
            "runtime_memory_bytes"=>envelope.runtime_memory_bytes,"allocator_memory_bytes"=>envelope.allocator_memory_bytes,
            "hard_memory_bytes"=>envelope.hard_memory_bytes)
    end
    return margin
end

function _resource_candidate(config,hardware,policy;envelope=nothing)
    config.execution.solver_backend===:production || _resource_unavailable("unsupported_solver_backend")
    cpu=envelope===nothing ? max(min(hardware.julia_threads,hardware.logical_cpus),1) : envelope.thread_pool_size
    config.execution.julia_threads in (0,cpu) || _resource_unavailable("manual_thread_setting_incompatible")
    if config.execution.strategy===:manual
        config.execution.blas_threads==1 &&
            (config.production.worker_count==0 || config.production.worker_count<=cpu) ||
            _resource_unavailable("manual_settings_incompatible")
    end
    resolved,plan=resolve_execution_strategy(config;hardware,envelope)
    if config.execution.strategy===:auto_exact && plan.blas_threads!=1
        candidates=filter(p->p.blas_threads==1,execution_plan_candidates(config;hardware,envelope))
        isempty(candidates) && _resource_unavailable("blas1_strategy_unavailable")
        plan=first(candidates)
        resolved=_configuration_with_execution_plan(config,plan;managed=envelope!==nothing)
    end
    plan.blas_threads==1 || _resource_unavailable("blas1_strategy_unavailable")
    if config.execution.strategy===:manual
        for name in fieldnames(typeof(config.production))
            envelope!==nothing && name===:memory_budget_bytes && continue
            getfield(config.production,name)==getfield(resolved.production,name) ||
                _resource_unavailable("manual_settings_incompatible")
        end
    end
    # Preserve both existing production candidate fit and the broader scientific
    # estimate at declared adaptation/retained-state caps.
    plan.estimated_peak_bytes<=plan.memory_budget_bytes || _resource_unavailable("production_does_not_fit")
    margin=_resource_margin_budget(resolved,plan,hardware,policy;envelope)
    return (configuration=resolved,resource_plan=plan,margin=margin)
end

function _resource_integer(value;minimum=0,maximum=typemax(Int))
    value isa Integer && !(value isa Bool) && minimum<=value<=maximum ||
        _cfg_refuse("invalid_resource_integer")
    return Int(value)
end

# Pure finite descent. The supplied forecast owns the already-reserved numerical
# boundary; this selector neither subtracts reserve nor changes the grid/model.
function _resource_choose(maximum_cpu,forecast)
    maximum_cpu=_resource_integer(maximum_cpu;maximum=256)
    for cpu in maximum_cpu:-1:1
        candidate=forecast(cpu)
        candidate===nothing && continue
        peak=_resource_integer(candidate.peak_bytes)
        budget=_resource_integer(candidate.numerical_budget_bytes)
        peak<=budget && return (requested_solver_threads=cpu,peak_bytes=peak,
                               numerical_budget_bytes=budget)
    end
    return nothing
end

function _resource_proposal(bytes,runner_source_id,core_source_id;trusted_policy=nothing,runtime_id=nothing,policy_failure=nothing)
    request=_configurator_json(bytes;maximum=RESOURCE_PROPOSAL_REQUEST_BYTES)
    _cfg_keys(request,["plan","plan_sha256","expected_runner_source_id","expected_core_source_id",
                       "target","candidate_cpu_max","runtime_margin_policy"])
    for (key,trusted) in (("expected_runner_source_id",runner_source_id),("expected_core_source_id",core_source_id))
        trusted isa AbstractString && !isempty(trusted) && ncodeunits(trusted)<=256 || _cfg_refuse("source_binding_unavailable")
        get(request,key,nothing)==trusted || _cfg_refuse("source_identity_mismatch",key)
    end
    raw=request["plan"]
    raw isa AbstractString || _cfg_refuse("invalid_plan")
    request["plan_sha256"]==_cfg_sha(raw) || _cfg_refuse("plan_sha256_mismatch")
    frozen=_configurator_json(raw;maximum=CONFIGURATOR_PLAN_BYTES)
    plan=load_scientific_plan(frozen)
    0<length(plan.executions)<=64 && 0<length(plan.points)<=256 || _cfg_refuse("forecast_plan_limit")
    cmax=_resource_integer(request["candidate_cpu_max"];minimum=1,maximum=256)
    target=request["target"]
    target isa AbstractDict || _cfg_refuse("invalid_target")
    _cfg_keys(target,["logical_cpu_limit","memory_limit_bytes","available_memory_bytes",
                      "affinity_limit","quota_full_cpu_limit","resource_policy_id"])
    target["resource_policy_id"] isa AbstractString && !isempty(target["resource_policy_id"]) &&
        ncodeunits(target["resource_policy_id"])<=256 || _cfg_refuse("invalid_target_policy")
    response=Dict{String,Any}("schema"=>"qcl-negf-resource-proposal-v1","decision_kind"=>"forecast",
        "status"=>"unavailable","launch_allowed"=>false,"reasons"=>["memory_forecast_unavailable"],
        "plan_sha256"=>request["plan_sha256"],"plan_fingerprint"=>frozen["fingerprint"],
        "plan_scientific_fingerprint"=>frozen["scientific_fingerprint"],
        "runner_source_id"=>runner_source_id,"core_source_id"=>core_source_id,
        "target"=>target,"requested_solver_threads"=>nothing,"memory_limit_bytes"=>nothing,
        "allocated_cpus_upper"=>nothing,"allocation_policy_digest"=>nothing,
        "allocation_width_binding"=>"unavailable","effective_max_concurrent"=>1,
        "historical_preview_estimates"=>[Dict("execution_id"=>e.id,"estimated_peak_bytes"=>e.estimated_peak_bytes) for e in plan.executions],
        "estimated_peak_bytes"=>nothing,"headroom_bytes"=>nothing,"confidence"=>"unavailable")
    selector=request["runtime_margin_policy"]
    if selector!==nothing
        _cfg_keys(selector,["policy_id","policy_sha256"])
        _resource_string(selector["policy_id"];maximum=128)
        _resource_sha(selector["policy_sha256"])
    end
    for key in ("logical_cpu_limit","affinity_limit","quota_full_cpu_limit","memory_limit_bytes","available_memory_bytes")
        value=target[key]
        if !(value isa Integer && !(value isa Bool) && 0<=value<=typemax(Int))
            response["reasons"]=["target_capacity_unavailable"]
            return response
        end
    end
    cmax=min(cmax,target["logical_cpu_limit"],target["affinity_limit"],target["quota_full_cpu_limit"])
    if cmax<1 || min(target["memory_limit_bytes"],target["available_memory_bytes"])<1
        response["reasons"]=["insufficient_capacity"]
        return response
    end
    if selector===nothing || !(trusted_policy isa _TrustedResourcePolicy) || runtime_id===nothing
        response["detail"]=policy_failure===nothing ? "margin_policy_required" : policy_failure
        return response
    end
    try
        policy=_resource_entry_policy((trusted_policy=trusted_policy,entry_binding=(plan_sha256=request["plan_sha256"],
            runner_source_id=runner_source_id,core_source_id=core_source_id,runtime_id=runtime_id)))
        selector["policy_id"]==policy.policy_id && selector["policy_sha256"]==policy.policy_sha256 ||
            _resource_unavailable("margin_policy_selector_mismatch")
        hard=min(target["memory_limit_bytes"],target["available_memory_bytes"])
        hard<=policy.maximum_hard_memory_bytes || _resource_unavailable("margin_policy_scope_exceeded")
        cmax=min(cmax,policy.maximum_solver_threads)
        selected_points=Ref{Any}(nothing)
        failures=String[]
        function forecast(cpu)
            hardware=HardwareProfile(cpu,cpu,hard,hard,"target_BLAS1",hard,hard,hard,0,cpu,Float64(cpu),
                "","trusted_net_target","trusted_net_target")
            rows=Any[]
            try
                for execution in plan.executions
                    for point in plan.points
                        point.execution_id==execution.id || continue
                        point_config=_point_resolved_configuration(execution.configuration,point)
                        candidate=_resource_candidate(point_config,hardware,policy)
                        push!(rows,Dict("execution_id"=>execution.id,"point_id"=>point.id,
                            "estimated_peak_bytes"=>candidate.margin["numerical_required_bytes"],"margin"=>candidate.margin,
                            "strategy"=>Dict("requested"=>String(candidate.resource_plan.requested_strategy),
                                "parallel_backend"=>String(candidate.resource_plan.parallel_backend),
                                "worker_count"=>candidate.resource_plan.worker_count,"blas_threads"=>candidate.resource_plan.blas_threads,
                                "energy_chunk"=>candidate.resource_plan.energy_chunk,"hilbert_columns"=>candidate.resource_plan.hilbert_columns,
                                "residual_chunk"=>candidate.resource_plan.residual_chunk)))
                    end
                end
            catch error
                if error isa Union{ResourceForecastUnavailable,ArgumentError,OverflowError}
                    push!(failures,error isa ResourceForecastUnavailable ? error.detail : "candidate_does_not_fit")
                    return nothing
                end
                rethrow()
            end
            isempty(rows) && _cfg_refuse("forecast_plan_limit")
            selected_points[]=rows
            return (peak_bytes=maximum(row["estimated_peak_bytes"] for row in rows),
                    numerical_budget_bytes=maximum(row["margin"]["numerical_budget_bytes"] for row in rows))
        end
        chosen=_resource_choose(cmax,forecast)
        if chosen===nothing
            response["detail"]=isempty(failures) ? "numerical_does_not_fit" : last(failures)
            return response
        end
        response["status"]="available";response["reasons"]=["shared_grant_unavailable"]
        response["requested_solver_threads"]=chosen.requested_solver_threads
        response["memory_limit_bytes"]=hard
        response["estimated_peak_bytes"]=chosen.peak_bytes
        response["headroom_bytes"]=minimum(row["margin"]["numerical_headroom_bytes"] for row in selected_points[])
        response["point_forecasts"]=selected_points[]
        response["confidence"]=policy.confidence
        response["margin_policy"]=Dict("policy_id"=>policy.policy_id,"policy_sha256"=>policy.policy_sha256,
            "runtime_id"=>policy.runtime_id,"approval_ref"=>policy.approval_ref,
            "calibration_ref"=>policy.calibration_ref===nothing ? nothing :
                Dict("artifact_sha256"=>policy.calibration_ref.artifact_sha256,"locator"=>policy.calibration_ref.locator))
    catch error
        error isa ResourceForecastUnavailable || rethrow()
        response["detail"]=error.detail
    end
    return response
end

function resource_proposal(bytes::AbstractString,runner_source_id::AbstractString,core_source_id::AbstractString;
    trusted_policy=nothing,runtime_id=nothing,policy_failure=nothing)
    response=try
        _resource_proposal(bytes,runner_source_id,core_source_id;trusted_policy,runtime_id,policy_failure)
    catch error
        error isa Union{ConfiguratorRefusal,ArgumentError,QCLNEGFRunner.ConfigurationError,OverflowError,KeyError,TypeError,InexactError} || rethrow()
        Dict{String,Any}("schema"=>"qcl-negf-resource-proposal-v1","decision_kind"=>"forecast",
            "status"=>"error","launch_allowed"=>false,
            "reasons"=>[error isa ConfiguratorRefusal ? error.code : "invalid_frozen_plan"])
    end
    dto=_cfg_dto(response)
    ncodeunits(_cfg_json(dto))<=RESOURCE_PROPOSAL_RESPONSE_BYTES ||
        return Dict("schema"=>"qcl-negf-resource-proposal-v1","status"=>"error",
                    "launch_allowed"=>false,"reasons"=>["response_limit"])
    return dto
end
