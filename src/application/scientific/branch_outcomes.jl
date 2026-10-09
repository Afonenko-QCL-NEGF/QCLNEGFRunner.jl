# Metadata/provenance only. Core owns the metric evaluation and strict certificate.
function _continuation_bounded_message(message)
    text=string(message)
    isvalid(text) || return "invalid UTF-8 diagnostic"
    isempty(text) && return "continuation evidence unavailable"
    ncodeunits(text)<=2048 && return text
    io=IOBuffer();used=0
    for char in text
        bytes=ncodeunits(string(char))
        used+bytes>2048 && break
        print(io,char);used+=bytes
    end
    return String(take!(io))
end

function _continuation_failure_reasons(point_result, seed_summary, core_terminal_status;
                                      interruption=nothing, artifact_error=nothing)
    reasons=Tuple{String,String}[]
    function observed(kind,message)
        any(r->first(r)==kind,reasons) ||
            push!(reasons,(kind,_continuation_bounded_message(message)))
    end
    interruption===nothing || observed("interrupted","cooperative interruption: $interruption")
    artifact_error===nothing || observed("data_unavailable",artifact_error)
    for warning in point_result.warnings
        code=get(warning,"code",nothing)
        code in ("POINT_FAILED","PREPARATION_FAILED") &&
            observed("process_failure",get(warning,"message","actual runtime exception"))
        code=="MANDATORY_STORAGE_FAILED" &&
            observed("data_unavailable",get(warning,"message","mandatory storage failure"))
    end
    if point_result.status in (:paused,:cancelled)
        observed("interrupted","cooperative interruption: $(point_result.status)")
    end
    if !(point_result.status===:skipped) &&
       (get(point_result.data,"full_state",nothing)===nothing ||
        get(point_result.data,"result_commit",nothing)===nothing)
        observed("data_unavailable","required final state or commit unavailable")
    end
    terminal=core_terminal_status===nothing ? _voltage_field(seed_summary,:status) : core_terminal_status
    outer_inner=("converged","approximate","research_continue","max_iterations","stagnated","quality_blocked","invalid_candidate","nonfinite_metrics")
    known=terminal in (:max_poisson_iterations,:outer_limit_with_warning,:scba_max_iterations,:scba_stagnated) ||
          any(x->terminal===Symbol("max_poisson_iterations_final_scba_"*x),outer_inner) ||
          _voltage_field(seed_summary,:inner_status) in (:max_iterations,:stagnated)
    known && observed("iteration_not_converged","actual Core terminal nonconvergence: $terminal")
    assessment=get(point_result.observables,"scientific_assessment",nothing)
    if !(assessment isa AbstractDict)
        observed("assessment_unavailable","required stationary assessment unavailable")
    elseif get(assessment,"registry_version",nothing)!="qcl-negf-acceptance-metadata-v1"
        observed("metadata_invalid","unknown stationary assessment registry")
    else
        flags=("stationary_candidate_accepted","iterative_converged","fixed_hartree_converged","physical_gates_passed")
        all(get(assessment,k,nothing) isa Bool for k in flags) ||
            observed("metadata_invalid","malformed stationary assessment flags")
        if get(assessment,"stationary_candidate_accepted",nothing)===true &&
           any(get(assessment,k,nothing)!==true for k in flags[2:end])
            observed("metadata_invalid","inconsistent stationary certificate flags")
        end
        metrics=get(assessment,"metrics",nothing)
        if !(metrics isa AbstractDict)
            observed("assessment_unavailable","required assessment metric records unavailable")
        else
            for (name,metric) in metrics
                if !(metric isa AbstractDict)
                    observed("metadata_invalid","malformed assessment metric: $name")
                    continue
                end
                status=get(metric,"status",nothing);category=get(metric,"category",nothing)
                if !(category in ("nonlinear_fixed_point","physical_and_algebraic")) ||
                   !(status in ("pass","fail","not_measured","not_applicable","error"))
                    observed("metadata_invalid","unknown metric category/status: $name")
                elseif status=="fail"
                    observed(category=="nonlinear_fixed_point" ? "iteration_not_converged" : "physical_gate_failed","Core measured metric failed: $name")
                elseif status=="not_measured"
                    observed("assessment_unavailable","Core metric not measured: $name")
                elseif status=="error"
                    observed("metadata_invalid","Core measurement error $name: $(get(metric,"reason","unavailable measurement"))")
                end
            end
        end
        if isempty(reasons) && any(get(assessment,k,nothing)===false for k in flags)
            observed("assessment_unavailable","stationary certificate lacks an evidenced failure reason")
        end
    end
    reason=_voltage_field(seed_summary,:reason)
    if reason in (:inconsistent_final_state,:inconsistent_persisted_final_metadata,
                  :unknown_stationary_assessment_registry)
        observed("metadata_invalid","inconsistent final certificate: $reason")
    elseif reason in (:missing_or_malformed_stationary_assessment,:final_report_not_passed,
                      :stationary_certificate_not_passed) && isempty(reasons)
        observed("assessment_unavailable","final certificate reason unavailable: $reason")
    end
    return reasons
end

function _continuation_branch_action(policy,causal_reason,predecessor_eligible)
    policy.mode===:independent && return :continue
    predecessor_eligible && return :continue
    return policy.invalid_predecessor===:cold_start ? :cold_fallback_declared : :skip_declared
end

function _continuation_reason_record(code,kind,source_row,message)
    code in ("BRANCH_STOPPED","DEPENDENCY_UNAVAILABLE") || throw(ArgumentError("invalid branch warning code"))
    kind in ("process_failure","iteration_not_converged","physical_gate_failed","interrupted","data_unavailable","assessment_unavailable","metadata_invalid") || throw(ArgumentError("invalid branch reason"))
    _scientific_identity(source_row.id,"source point")
    _scientific_identity(source_row.execution_id,"source execution")
    source_row.attempt>0 || throw(ArgumentError("invalid source attempt"))
    return Dict{String,Any}("code"=>code,"scope"=>"branch","reason_kind"=>kind,
        "source_execution_id"=>source_row.execution_id,"source_point_id"=>source_row.id,
        "source_attempt"=>source_row.attempt,"message"=>_continuation_bounded_message(message))
end

# Only a row published by this exact attempt may donate its current payload.
function _continuation_current_attempt_row(rows,id,execution_id,attempt)
    index=findfirst(r->r.id==id && r.execution_id==execution_id && r.attempt==attempt,rows)
    return index===nothing ? nothing : rows[index]
end

function _continuation_unrun_attempt(default_attempt,source_row,requested_attempt)
    source_row===nothing && return default_attempt
    requested_attempt===nothing || requested_attempt>=source_row.attempt ||
        throw(ArgumentError("scientific_source_invalid: requested unrun attempt precedes causal source"))
    return max(default_attempt,source_row.attempt)
end

function _continuation_record_history!(history,record)
    index=findfirst(r->r.id==record.id && r.execution_id==record.execution_id &&
        r.attempt==record.attempt,history)
    if index===nothing
        push!(history,record)
    else
        old=history[index]
        all(isequal(getfield(old,key),getfield(record,key)) for key in fieldnames(typeof(record))) ||
            throw(ArgumentError("scientific_source_invalid: conflicting terminal history tuple"))
    end
    return history
end

function _upsert_scientific_point!(rows,record,point_order)
    positions=Dict(id=>i for (i,id) in enumerate(point_order))
    length(positions)==length(point_order) || throw(ArgumentError("duplicate frozen point ID"))
    haskey(positions,record.id) || throw(ArgumentError("unknown point ID"))
    ids=[r.id for r in rows]
    length(unique(ids))==length(ids) || throw(ArgumentError("duplicate current point ID"))
    all(haskey(positions,id) for id in ids) || throw(ArgumentError("unknown current point ID"))
    index=findfirst(==(record.id),ids)
    prior=index===nothing ? nothing : rows[index]
    # A completed archive is immutable even when later optional work is cancelled.
    prior===nothing || prior.status!==:completed || return rows
    for warning in record.warnings
        if haskey(warning,"reason_kind")
            source_attempt=get(warning,"source_attempt",nothing)
            source_attempt isa Integer && !(source_attempt isa Bool) &&
            0<source_attempt<=record.attempt ||
                throw(ArgumentError("scientific_source_invalid: branch source attempt exceeds owner attempt"))
        end
    end
    if prior!==nothing && prior.attempt!=record.attempt
        copied=any(get(prior.data,key,nothing)!==nothing &&
            get(record.data,key,nothing)==get(prior.data,key,nothing)
            for key in ("full_state","result_commit"))
        if copied
            historical_source=get(prior.data,"checkpoint_source_attempt",prior.attempt)
            declared=record.status===:paused &&
                get(record.data,"pause_reason",nothing)=="resource_pressure" &&
                get(record.data,"resume_kind",nothing)=="checkpoint" &&
                get(record.data,"recovery_origin",nothing)=="last_committed_before_resource_pause" &&
                get(record.data,"checkpoint_source_attempt",nothing)==historical_source &&
                historical_source isa Integer && !(historical_source isa Bool) &&
                0<historical_source<record.attempt
            declared || throw(ArgumentError("scientific_source_invalid: native payload belongs to a prior attempt"))
        end
    end
    index===nothing ? push!(rows,record) : (rows[index]=record)
    sort!(rows;by=r->positions[r.id])
    return rows
end

function _scientific_validate_raw_source_rows(plan,document)
    function refusal(kind,field,section,index,row)
        id=row isa AbstractDict ? get(row,"id","absent") : "absent"
        execution=row isa AbstractDict ? get(row,"execution_id","absent") : "absent"
        attempt=row isa AbstractDict ? get(row,"attempt","absent") : "absent"
        # Locator strings only; malformed objects are not expanded into diagnostics.
        locator(x)=x isa AbstractString || x isa Real ? _continuation_bounded_message(x) : "malformed"
        message="scientific_source_$kind: $section[$index].$field; id=$(locator(id)), execution_id=$(locator(execution)), attempt=$(locator(attempt))"
        throw(ArgumentError(_continuation_bounded_message(message)))
    end
    function required(row,field,section,index)
        haskey(row,field) || refusal("unavailable",field,section,index,row)
        return row[field]
    end
    function finite_json(value,section,index,row)
        if value===nothing || value isa Bool || value isa Integer
            return true
        elseif value isa AbstractFloat
            isfinite(value) || refusal("invalid","nonfinite JSON",section,index,row)
        elseif value isa AbstractString
            isvalid(value) || refusal("invalid","UTF-8",section,index,row)
        elseif value isa AbstractDict
            for (key,item) in value
                key isa AbstractString && isvalid(key) || refusal("invalid","JSON key",section,index,row)
                finite_json(item,section,index,row)
            end
        elseif value isa AbstractVector
            for item in value;finite_json(item,section,index,row);end
        else
            refusal("invalid","unsupported JSON value",section,index,row)
        end
        return true
    end
    function equal_json(a,b)
        if a isa Bool || b isa Bool
            return a isa Bool && b isa Bool && a===b
        elseif a isa Integer || b isa Integer
            return a isa Integer && b isa Integer && a==b
        elseif a isa AbstractFloat || b isa AbstractFloat
            return a isa AbstractFloat && b isa AbstractFloat && a==b
        elseif a isa AbstractDict && b isa AbstractDict
            return Set(keys(a))==Set(keys(b)) && all(equal_json(a[k],b[k]) for k in keys(a))
        elseif a isa AbstractVector && b isa AbstractVector
            return length(a)==length(b) && all(equal_json(x,y) for (x,y) in zip(a,b))
        end
        return typeof(a)===typeof(b) && a==b
    end
    document isa AbstractDict || refusal("invalid","document","document",0,nothing)
    haskey(document,"points") || refusal("unavailable","points","document",0,nothing)
    document["points"]===nothing && refusal("unavailable","points","document",0,nothing)
    document["points"] isa AbstractVector || refusal("invalid","points","document",0,nothing)
    if haskey(document,"attempt_history")
        document["attempt_history"]===nothing && refusal("unavailable","attempt_history","document",0,nothing)
        document["attempt_history"] isa AbstractVector || refusal("invalid","attempt_history","document",0,nothing)
    end
    frozen=Dict(p.id=>p for p in plan.points)
    executions=Set(e.id for e in plan.executions)
    current=Set{String}();tuples=Dict{Tuple{String,String,Int},Any}()
    sections=haskey(document,"attempt_history") ? ("points","attempt_history") : ("points",)
    for section in sections, (index,row) in enumerate(document[section])
        row isa AbstractDict || refusal("invalid","row",section,index,row)
        finite_json(row,section,index,row)
        id=required(row,"id",section,index);execution=required(row,"execution_id",section,index)
        id isa String && execution isa String || refusal("invalid","identity type",section,index,row)
        haskey(frozen,id) && execution in executions && frozen[id].execution_id==execution || refusal("invalid","frozen identity",section,index,row)
        attempt=required(row,"attempt",section,index)
        attempt isa Integer && !(attempt isa Bool) && 0<attempt<=typemax(Int) || refusal("invalid","attempt",section,index,row)
        required(row,"converged",section,index) isa Bool || refusal("invalid","converged",section,index,row)
        coordinates=required(row,"coordinates",section,index)
        coordinates isa AbstractDict || refusal("invalid","coordinates",section,index,row)
        fields=("temperature_K","voltage_per_period_V","branch","order")
        for field in fields
            haskey(coordinates,field) || refusal("unavailable","coordinates.$field",section,index,row)
        end
        Set(keys(coordinates))==Set(fields) || refusal("invalid","coordinate keys",section,index,row)
        point=frozen[id]
        for (field,target) in (("temperature_K",point.temperature_K),("voltage_per_period_V",point.voltage_per_period_V))
            value=coordinates[field]
            value isa Real && !(value isa Bool) && isfinite(value) && value==target || refusal("invalid",field,section,index,row)
        end
        coordinates["branch"] isa String && coordinates["branch"]==point.branch || refusal("invalid","branch",section,index,row)
        value=coordinates["order"]
        value isa Integer && !(value isa Bool) && 0<value<=typemax(Int) && value==point.order || refusal("invalid","order",section,index,row)
        if section=="points"
            id in current && refusal("invalid","duplicate current ID",section,index,row)
            push!(current,id)
        end
        key=(execution,id,Int(attempt))
        haskey(tuples,key) && !equal_json(tuples[key],row) && refusal("invalid","conflicting historical tuple",section,index,row)
        tuples[key]=row
    end
    return nothing
end
