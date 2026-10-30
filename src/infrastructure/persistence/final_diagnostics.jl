# Closed stored diagnostics; the public Core capture already performed the only PSD scan.
const _P05_MATRIX_KINDS=("spectral","occupied","unoccupied","broadening","raw_occupied","raw_unoccupied")
const _P05_INTEGRAL_SPECS=(
    ("spectral_integral","ComplexF64",["k","a","b"],"1"),
    ("spectral_integral_eigenvalues","Float64",["k","state"],"1"),
    ("spectral_trace_cumulative","Float64",["E","k"],"1"),
    ("negative_energy_integral_scaled","Float64",["matrix_kind","k"],"scaled solver units; broadening carries energy squared"))
_p05_metric_map(value)=value===nothing ? nothing :
    [Dict("name"=>String(name),"value"=>_p05_f64(value[name])) for name in sort!(collect(keys(value));by=String)]
function _p05_diagnostic_records(snapshot::QCLNEGF.FinalObservationSnapshot,arrays)
    metrics=Dict(string(name)=>_p05_metric_map(getfield(snapshot.metrics,name)) for name in fieldnames(QCLNEGF.SolutionMetricDiagnostics))
    positivity=snapshot.positivity
    if positivity===nothing
        rows=filter(row->row.target===:positivity,snapshot.issues)
        _p04_require(length(rows)==1,"missing original positivity issue")
        issue=only(rows)
        return metrics,Dict("status"=>String(issue.status),"reason"=>String(issue.reason)*": "*issue.detail,"data"=>nothing)
    end
    _p04_require(positivity.integrals!==nothing && String.(positivity.matrix_kinds)==_P05_MATRIX_KINDS &&
        positivity.scan_order===:momentum_energy,"incomplete final positivity capture")
    integrals=positivity.integrals
    wire=Dict{String,Any}()
    for spec in _P05_INTEGRAL_SPECS
        name,type,axes,units=spec;value=getfield(integrals,Symbol(name))
        descriptor=Dict{String,Any}("dataset"=>"/final_diagnostics/arrays/"*name,"eltype"=>type,
            "shape"=>string.(collect(size(value))),"order"=>"F","axes"=>axes,"units"=>units)
        wire[name]=descriptor;push!(arrays,descriptor["dataset"]=>value)
    end
    for name in (:negative_block_count,:beyond_backward_error_block_count,:invalid_block_count)
        wire[String(name)]=collect(_p05_int.(getfield(integrals,name)))
    end
    wire["total_blocks_per_kind"]=_p05_int(integrals.total_blocks_per_kind)
    wire["negative_phase_space_weight_per_m2"]=collect(_p05_f64.(integrals.negative_phase_space_weight_per_m2))
    witnesses=[Dict{String,Any}(string(name)=>(name in (:status,:matrix_kind) ? String(getfield(w,name)) :
        name in (:energy_index,:momentum_index) ? _p05_int(getfield(w,name)) : _p05_f64(getfield(w,name)))
        for name in fieldnames(QCLNEGF.PositivityWitness)) for w in positivity.witnesses]
    data=Dict("metric_version"=>_p05_int(positivity.metric_version),"matrix_kinds"=>collect(_P05_MATRIX_KINDS),"witnesses"=>witnesses,
        "strict_ratio_limit"=>_p05_f64(positivity.strict_ratio_limit),"strict_absolute_limits_scaled"=>collect(_p05_f64.(positivity.strict_absolute_limits_scaled)),
        "strict_threshold_satisfied"=>collect(positivity.strict_threshold_satisfied),"scan_order"=>String(positivity.scan_order),"integrals"=>wire)
    metrics,Dict("status"=>"measured","reason"=>nothing,"data"=>data)
end
function _p05_diagnostics(snapshot,declaration,checkpoint_ref,arrays)
    metrics,positivity=_p05_diagnostic_records(snapshot,arrays)
    _,e,k,b=snapshot.context.dimensions
    Dict{String,Any}("schema"=>"qcl-negf.final-diagnostics.v1","contract_set"=>_P04_CONTRACT,
        (key=>declaration[key] for key in ("identity","invocation","state_id","state_sequence"))...,
        "checkpoint"=>checkpoint_ref,"dimensions"=>Dict("energy"=>string(e),"momentum"=>string(k),"basis"=>string(b)),
        "solution_metrics"=>metrics,"positivity"=>positivity)
end

function _p05_envelope(value,schema,declaration,extra)
    _p04_keys(value,("schema","contract_set","identity","invocation","state_id","state_sequence","checkpoint",extra...))
    _p04_require(value["schema"]==schema && value["contract_set"]==_P04_CONTRACT,"unsupported final declaration")
    for key in ("identity","invocation","state_id","state_sequence")
        _p04_require(value[key]==declaration[key],"analysis differs from selected checkpoint")
    end
    _p04_file_fields(value["checkpoint"])
end
function _p05_local_descriptor(value,expected,shape)
    _p04_keys(value,keys(expected))
    _p04_require(value==merge(expected,Dict("shape"=>string.(collect(shape)))) && all(>(0),shape),"local descriptor profile/shape differs")
end
function _p05_diagnostic_check(value,declaration)
    _p05_envelope(value,"qcl-negf.final-diagnostics.v1",declaration,("dimensions","solution_metrics","positivity"))
    dimensions=value["dimensions"];_p04_keys(dimensions,("energy","momentum","basis"))
    e,k,b=map(n->Int(_p04_u64(dimensions[n];positive=true)),("energy","momentum","basis"))
    scba=_p05_fields(_p05_fields(declaration["state"])["scba"]);green=_p05_fields(scba["green"])
    _p04_require(all(green[n]["shape"]==string.([e,k,b,b]) for n in ("Gᴿ","Gˡ","Gᵍ","A")),"diagnostic dimensions differ from checkpoint")
    metrics=value["solution_metrics"];_p04_keys(metrics,("summary_metrics","strict_limits","approximate_limits"))
    for (name,rows) in metrics
        rows===nothing && (_p04_require(name=="approximate_limits","required metric map absent");continue)
        _p04_require(rows isa AbstractVector,"metric map is not vector")
        names=String[]
        for row in rows
            _p04_keys(row,("name","value"));_p05_string(row["name"]);push!(names,row["name"]);_p05_decode(row["value"],Float64)
        end
        _p04_require(names==sort!(unique(names)),"metric names not sorted/unique")
    end
    measurement=value["positivity"];_p04_keys(measurement,("status","reason","data"))
    if measurement["data"]===nothing
        _p04_require(measurement["status"] in ("error","not_measured"),"unavailable positivity status differs")
        _p05_string(measurement["reason"];nonblank=true);return nothing
    end
    _p04_require(measurement["status"]=="measured" && measurement["reason"]===nothing,"measured positivity has cause")
    data=measurement["data"];_p04_keys(data,("metric_version","matrix_kinds","witnesses","strict_ratio_limit","strict_absolute_limits_scaled","strict_threshold_satisfied","scan_order","integrals"))
    _p04_require(_p05_decode(data["metric_version"],Int64)>0 && data["matrix_kinds"]==collect(_P05_MATRIX_KINDS) &&
        data["scan_order"]=="momentum_energy","positivity profile differs")
    _p05_decode(data["strict_ratio_limit"],Float64)
    for name in ("witnesses","strict_absolute_limits_scaled","strict_threshold_satisfied")
        _p04_require(data[name] isa AbstractVector && length(data[name])==6,"positivity channel count differs")
    end
    for i in 1:6
        _p05_decode(data["strict_absolute_limits_scaled"][i],Float64)
        flag=data["strict_threshold_satisfied"][i];_p04_require(flag isa Bool,"PSD flag is not Bool")
        w=data["witnesses"][i]
        _p04_keys(w,("status","matrix_kind","energy_index","momentum_index","minimum_eigenvalue","block_norm","floor","ratio","absolute_defect","relative_defect","backward_error","hermiticity_defect","construction_scale"))
        _p04_require(w["status"] in ("measured","error"),"witness status differs")
        low=w["status"]=="error" ? 0 : 1
        _p04_require(low<=_p05_decode(w["energy_index"],Int64)<=e && low<=_p05_decode(w["momentum_index"],Int64)<=k &&
            (w["matrix_kind"]==_P05_MATRIX_KINDS[i] || w["status"]=="error" && w["matrix_kind"]=="none") &&
            (w["status"]!="error" || !flag),"witness coverage/status differs")
        for name in ("minimum_eigenvalue","block_norm","floor","ratio","absolute_defect","relative_defect","backward_error","hermiticity_defect","construction_scale")
            _p05_decode(w[name],Float64)
        end
    end
    integral=data["integrals"]
    _p04_keys(integral,("spectral_integral","spectral_integral_eigenvalues","spectral_trace_cumulative","negative_energy_integral_scaled",
        "negative_block_count","beyond_backward_error_block_count","invalid_block_count","total_blocks_per_kind","negative_phase_space_weight_per_m2"))
    for (spec,shape) in zip(_P05_INTEGRAL_SPECS,((k,b,b),(k,b),(e,k),(6,k)))
        name,type,axes,units=spec
        expected=Dict("dataset"=>"/final_diagnostics/arrays/"*name,"eltype"=>type,"shape"=>String[],"order"=>"F","axes"=>axes,"units"=>units)
        _p05_local_descriptor(integral[name],expected,shape)
    end
    total=_p05_decode(integral["total_blocks_per_kind"],Int64)
    _p04_require(total==_p05_mul(e,k),"full-grid block count differs")
    for name in ("negative_block_count","beyond_backward_error_block_count","invalid_block_count")
        _p04_require(integral[name] isa AbstractVector && length(integral[name])==6,"block count channels differ")
    end
    for i in 1:6
        negative,beyond,invalid=(_p05_decode(integral[name][i],Int64) for name in ("negative_block_count","beyond_backward_error_block_count","invalid_block_count"))
        _p04_require(0<=invalid<=total && 0<=beyond<=negative<=total-invalid,"block count coverage contradicts")
    end
    weights=integral["negative_phase_space_weight_per_m2"]
    _p04_require(weights isa AbstractVector && length(weights)==5,"phase-space channel count differs")
    for weight in weights;_p05_decode(weight,Float64);end
    nothing
end
