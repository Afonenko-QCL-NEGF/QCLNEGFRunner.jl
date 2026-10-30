# Compact measured history and physical audit data. No acceptance is inferred from storage.
include("physical_markers.jl")
include("packed_witnesses.jl")
const _PSD_HISTORY_FLOAT_FIELDS = (
    :minimum_eigenvalue,
    :block_norm,
    :backward_error,
    :absolute_defect,
    :relative_defect,
    :ratio,
    :hermiticity_defect,
)

function _require_native_scba_tables(parent)
    haskey(parent, "scba") ||
        throw(ArgumentError("native v4 requires the SCBA history table"))
    scba=parent["scba"]
    backend=HDF5
    if scba isa backend.Group
        coordinate=haskey(scba, "sequence") ? "sequence" : "ν"
        haskey(scba, coordinate) ||
            throw(ArgumentError("native v4 SCBA history lacks row coordinates"))
        count=length(scba[coordinate])
    else
        ndims(scba)==2 && size(scba, 1)==18 || throw(
            ArgumentError("native v4 SCBA checkpoint history requires exactly 18 columns"),
        )
        count=size(scba, 2)
    end
    for (name, schema) in (
        ("physical_markers", "qcl-negf-physical-markers-v3"),
        ("psd_history", "qcl-negf-psd-history-v2"),
    )
        haskey(parent, name) ||
            throw(ArgumentError("native v4 requires $name, including empty tables"))
        table=parent[name]
        haskey(attributes(table), "schema") &&
        String(read_attribute(table, "schema"))==schema ||
            throw(ArgumentError("native v4 requires $schema"))
    end
    _require_physical_marker_storage(parent, count)
    table=parent["psd_history"]
    haskey(table, "selected_blocks") ||
        throw(ArgumentError("native v4 requires packed selected PSD evidence"))
    _require_packed_witness_schema(table["selected_blocks"])
    all(size(table[name])==(count,) for name in keys(table) if name!="selected_blocks") ||
        throw(
            DimensionMismatch("native v4 PSD diagnostics differ from SCBA history length"),
        )
    return nothing
end

function _selected_witness_indices(rows)
    available=findall(row->row.witness!==nothing && !isempty(row.witness.matrices), rows)
    isempty(available) && return Int[]
    worst=available[argmax([rows[i].witness.ratio for i in available])]
    selected=[first(available), worst, last(available)]
    violation=findfirst(i->rows[i].witness.ratio>0, available)
    violation===nothing || push!(selected, available[violation])
    return sort!(unique(selected))
end

function _write_psd_history!(
    parent,
    rows;
    problem = nothing,
    sequences = collect(eachindex(rows)),
)
    table=create_group(parent, "psd_history")
    attributes(table)["schema"]="qcl-negf-psd-history-v2"
    attributes(table)["index_origin"]=1
    attributes(table)["scalar_sampling"]="every recorded SCBA iteration; missing witnesses are explicit"
    attributes(
        table,
    )["matrix_sampling"]="first, first violation, worst and last available witness per stored segment"
    table["sequence"]=Int64.(sequences)
    table["available"]=Int8[row.witness!==nothing for row in rows]
    table["matrix_kind"]=String[
        row.witness===nothing ? "not_recorded" : String(row.witness.matrix_kind) for
        row in rows
    ]
    for field in (:energy_index, :momentum_index)
        table[String(field)]=Int64[
            row.witness===nothing ? 0 : getfield(row.witness, field) for row in rows
        ]
    end
    for field in _PSD_HISTORY_FLOAT_FIELDS
        _physical_dataset(
            table,
            String(field),
            Float64[
                row.witness===nothing ? NaN : getfield(row.witness, field) for row in rows
            ];
            units = field in (:relative_defect, :ratio) ? "1" :
                    "dimensionless solver value; matrix kind defines scale",
            axes = "iteration",
            description = "Measured PSD witness $(field)",
        )
    end
    if problem!==nothing
        for (name, field, coordinates) in (
            (
                "energy_eV",
                :energy_index,
                problem.grids.ε .* problem.scales.E₀_eV .+
                _runner_electronvolts(problem.physical.E_ref),
            ),
            (
                "momentum_per_nm",
                :momentum_index,
                problem.grids.κ ./ problem.scales.L₀_m .* 1e-9,
            ),
        )
            table[name]=Float64[
                row.witness===nothing || getfield(row.witness, field)==0 ? NaN :
                coordinates[getfield(row.witness, field)] for row in rows
            ]
        end
    end
    for name in ("energy_eV", "momentum_per_nm")
        haskey(table, name) || (table[name]=fill(NaN, length(rows)))
    end
    records=[
        _witness_record(sequences[index], rows[index].ν, rows[index].witness; problem) for
        index in _selected_witness_indices(rows)
    ]
    _write_packed_witness_records!(table, records)
    _annotate_psd_columns!(table)
    return table
end


function _annotate_psd_columns!(table)
    for name in keys(table)
        name=="selected_blocks" && continue
        dataset=table[name]
        attrs=attributes(dataset)
        put(name, value) = begin
            haskey(attrs, name) && _hdf5_call(:delete_attribute, dataset, name)
            attrs[name]=value
        end
        put("logical_axis_order", "iteration")
        put("logical_shape", string(length(dataset)))
        values=read(dataset)
        put("nonfinite_count", count(value->value isa Number && !isfinite(value), values))
        units=name=="energy_eV" ? "eV" :
              name=="momentum_per_nm" ? "nm^-1" :
              name in (
            "minimum_eigenvalue",
            "block_norm",
            "backward_error",
            "absolute_defect",
            "hermiticity_defect",
        ) ? "dimensionless solver value; matrix kind defines scale" : "1"
        put("units", units)
        haskey(attrs, "description") ||
            (attrs["description"]="Measured SCBA PSD history $(name)")
    end
    return nothing
end

function _read_psd_history(parent, count)
    result=Union{Nothing,SCBAPhysicsWitness}[nothing for _ = 1:count]
    haskey(parent, "psd_history") || throw(
        ArgumentError("native v4 requires psd_history, including an empty typed table"),
    )
    table=parent["psd_history"]
    haskey(attributes(table), "schema") &&
    String(read_attribute(table, "schema"))=="qcl-negf-psd-history-v2" ||
        throw(ArgumentError("unsupported PSD history schema"))
    available=read(table["available"])
    length(available)==count || throw(DimensionMismatch("PSD history row count differs"))
    kinds=read(table["matrix_kind"])
    energies=read(table["energy_index"])
    momenta=read(table["momentum_index"])
    sequence=read(table["sequence"])
    numeric=Dict(field=>read(table[String(field)]) for field in _PSD_HISTORY_FLOAT_FIELDS)
    records=Dict(
        record.sequence=>record for
        record in _read_packed_witness_records(table["selected_blocks"])
    )
    for index = 1:count
        available[index]==0 && continue
        matrices=Dict{String,Matrix{ComplexF64}}()
        vector=ComplexF64[]
        if haskey(records, sequence[index])
            matrices, vector = _packed_witness_components(records[sequence[index]])
        end
        result[index]=SCBAPhysicsWitness(
            Symbol(kinds[index]),
            energies[index],
            momenta[index],
            (numeric[field][index] for field in _PSD_HISTORY_FLOAT_FIELDS)...,
            matrices,
            vector,
        )
    end
    return result
end

"""Retain all scalar witnesses while copying available compact matrix payloads losslessly."""
function _consolidate_psd_history!(destination, source_paths)
    columns=Dict{String,Any}()
    column_attributes=Dict{String,Dict{String,Any}}()
    records=Any[]
    for path in source_paths
        h5open(path, "r") do file
            _require_native_metadata(file, "qcl-negf-scientific-history-v4")
            haskey(file, "psd_history") ||
                throw(ArgumentError("native v4 requires psd_history"))
            table=file["psd_history"]
            for name in keys(table)
                name=="selected_blocks" && continue
                values=read(table[name])
                get!(column_attributes, name) do
                    Dict{String,Any}(
                        key=>read_attribute(table[name], key) for
                        key in keys(attributes(table[name]))
                    )
                end
                append!(get!(columns, name, eltype(values)[]), values)
            end
            append!(records, _read_packed_witness_records(table["selected_blocks"]))
        end
    end
    isempty(columns) && return nothing
    target=create_group(destination, "psd_history")
    attributes(target)["schema"]="qcl-negf-psd-history-v2"
    attributes(target)["index_origin"]=1
    attributes(target)["scalar_sampling"]="every recorded SCBA iteration; unmeasured witnesses are explicit"
    attributes(
        target,
    )["matrix_sampling"]="lossless union of first/first-violation/worst/last payloads from each source segment"
    sequence=columns["sequence"]
    order=sortperm(sequence)
    length(unique(sequence))==length(sequence) ||
        throw(ArgumentError("duplicate PSD witness sequence"))
    for (name, values) in columns
        length(values)==length(sequence) ||
            throw(DimensionMismatch("mixed PSD history columns"))
        _write_native_dataset(target, name, values[order])
        for (key, value) in get(column_attributes, name, Dict{String,Any}())
            attributes(target[name])[key]=value
        end
    end
    _annotate_psd_columns!(target)
    _write_packed_witness_records!(target, records)
    return nothing
end

function _copy_diagnostic_group!(parent, name, source)
    backend=HDF5
    target=create_group(parent, name)
    for key in keys(attributes(source))
        attributes(target)[key]=read_attribute(source, key)
    end
    for key in keys(source)
        if source[key] isa backend.Group
            _copy_diagnostic_group!(target, key, source[key])
        else
            target[key]=read(source[key])
            for attr in keys(attributes(source[key]))
                attributes(target[key])[attr]=read_attribute(source[key], attr)
            end
        end
    end
    return target
end

function _physical_certification_data(solution)
    metrics=solution.report.metrics
    limits=QCLNEGF.solution_metric_diagnostics(solution).strict_limits
    function category(required)
        present=filter(name->haskey(metrics, name), required)
        failed=filter(
            name->!isfinite(metrics[name]) ||
                  !haskey(limits, name) ||
                  metrics[name]>limits[name],
            present,
        )
        missing=setdiff(required, present)
        return Dict{String,Any}(
            "status"=>!isempty(failed) ? "failed" :
                      isempty(missing) ? "passed" : "not_evaluated",
            "failed_metrics"=>String.(failed),
            "missing_metrics"=>String.(missing),
            "evaluated_metrics"=>String.(present),
        )
    end
    algebra=category([:r_D, :r_A, :r_caus, :r_PSD, :r_selfenergy_identity])
    stationary=category([
        :r_D_candidate,
        :r_A_candidate,
        :r_lambda_candidate,
        :r_K,
        :r_Σ,
        :r_λ,
        :r_P,
        :r_U,
        :r_n,
        :r_J,
        :r_power,
        (Symbol(:r_C_, name) for name in solution.problem.kernels.enabled)...,
    ])
    audit=get(solution.observables,:final_fixed_point_audit,nothing)
    if audit!==nothing
        for (section,name,metric) in (("dyson","ratio",:r_D_candidate),
                ("spectral","ratio",:r_A_candidate),("charge","candidate_constraint",:r_lambda_candidate))
            measurement=get(get(audit,section,Dict()),name,Dict())
            status=get(measurement,"status",nothing)
            value=get(measurement,"value",nothing)
            failed=status=="error" || get(measurement,"nonfinite",nothing)!==nothing ||
                (value isa Real && !isfinite(value))
            unavailable=status!="measured" || !(value isa Real) || value isa Bool
            if failed
                stationary["status"]="failed"
                String(metric) in stationary["failed_metrics"] || push!(stationary["failed_metrics"],String(metric))
            elseif unavailable
                stationary["status"]=="passed" && (stationary["status"]="not_evaluated")
                String(metric) in stationary["missing_metrics"] || push!(stationary["missing_metrics"],String(metric))
            end
        end
    end
    discretization=category([
        :r_sum,
        :r_tail_low,
        :r_tail_high,
        :r_tail_k,
        :r_edge_gamma,
        :r_edge_spectral,
    ])
    discretization["status_of_local_diagnostics"]=pop!(discretization, "status")
    discretization["status"]="not_certified"
    discretization["reason"]="A single-grid state has no independent energy/momentum/basis/spatial refinement certificate."
    return Dict{String,Any}(
        "schema"=>"qcl-negf-physical-certification-v1",
        "algebra"=>algebra,
        "stationary"=>stationary,
        "discretization"=>discretization,
        "model"=>Dict(
            "status"=>"not_certified",
            "reason"=>"Convergence and invariant tests do not establish quantitative model adequacy.",
        ),
        "solver_accepted"=>solution.converged,
        "quantitative_physics_certified"=>false,
    )
end

function _persist_model_scope!(metadata, solution)
    capabilities=get(solution.observables, :model_capabilities, nothing)
    metadata["model_capabilities_json"]=sprint(
        _light_json,
        capabilities===nothing ?
        Dict(
            "schema"=>"qcl-negf-model-capabilities-v1",
            "status"=>"not_recorded",
            "quantitative_physics_certified"=>false,
        ) : capabilities,
    )
    metadata["physical_certification_json"]=sprint(
        _light_json,
        _physical_certification_data(solution),
    )
end

"""Matrix spectral sum and negative phase-space weights on the actual final grid."""
function _write_final_matrix_audit!(parent, solution)
    problem=solution.problem
    green=solution.scba.green
    NE, Nk, Nb=problem.numerical.N_E, problem.numerical.N_k, problem.numerical.N_b
    integral=zeros(ComplexF64, Nk, Nb, Nb)
    cumulative=zeros(Float64, NE, Nk)
    eigenvalues=zeros(Float64, Nk, Nb)
    negative=zeros(Float64, 6, Nk)
    negative_blocks=zeros(Int64, 6)
    beyond_budget=zeros(Int64, 6)
    invalid_blocks=zeros(Int64, 6)
    witnesses=fill(_empty_positivity_witness(), 6)
    kinds=(
        "spectral",
        "occupied",
        "unoccupied",
        "broadening",
        "raw_occupied",
        "raw_unoccupied",
    )
    for k = 1:Nk
        for e = 1:NE
            weight=problem.grids.wᴱ[e]/(2π)
            integral[k, :, :] .+= weight .* view(green.A, e, k, :, :)
            cumulative[e, k]=real(tr(view(integral, k, :, :)))
            blocks=_scba_positivity_blocks(solution.scba, problem.kernels.enabled, e, k)
            for (index, (_, block)) in enumerate(blocks)
                values=_diagnostic_eigenvalues(block)
                witness=_positivity_witness(
                    Symbol(kinds[index]),
                    e,
                    k,
                    values;
                    hermiticity_defect = all(isfinite, block) ? norm(block-block')/2 : Inf,
                )
                witness.ratio>witnesses[index].ratio && (witnesses[index]=witness)
                if !all(isfinite, values)
                    negative[index, k]=NaN
                    invalid_blocks[index]+=1
                    continue
                end
                negative[index, k]+=weight*sum(value->max(0.0, -value), values)
                negative_blocks[index]+=minimum(values)<0
                beyond_budget[index]+=minimum(values)<-psd_error_budget(
                    maximum(abs, values),
                    Nb,
                )
            end
        end
        eigenvalues[k, :]=_diagnostic_eigenvalues(Matrix(view(integral, k, :, :)))
    end
    group=create_group(parent, "matrix_audit")
    _physical_dataset(
        group,
        "spectral_integral_eigenvalues",
        eigenvalues;
        units = "1",
        axes = "k,state",
        description = "Eigenvalues of integral A dE/(2pi); orthonormal complete spectral target is one per state",
    )
    complex=_write_complex(group, "spectral_integral", integral)
    for component in ("real", "imag")
        attributes(complex[component])["logical_axis_order"]="k,a,b"
        attributes(complex[component])["units"]="1"
    end
    _physical_dataset(
        group,
        "spectral_trace_cumulative",
        cumulative;
        units = "1",
        axes = "E,k",
        description = "Prefix sum using the complete-grid quadrature weights; no omitted spectrum inferred",
    )
    group["matrix_kind"]=collect(kinds)
    _physical_dataset(
        group,
        "negative_energy_integral_scaled",
        negative;
        units = "scaled solver units; broadening carries energy squared",
        axes = "matrix_kind,k",
        description = "Integral of sum max(0,-eigenvalue) d epsilon/(2pi), without clipping the state or subtracting a tolerance",
    )
    group["negative_block_count"]=negative_blocks
    group["beyond_backward_error_block_count"]=beyond_budget
    group["invalid_block_count"]=invalid_blocks
    group["total_blocks_per_kind"]=NE*Nk
    # Broadening has different units and is kept in scaled form above.
    indices=[1, 2, 3, 5, 6]
    weights=Float64[
        problem.physical.g_s*sum(negative[i, :] .* problem.grids.wᵏ)/problem.scales.L₀_m^2
        for i in indices
    ]
    group["green_matrix_kind"]=collect(kinds)[indices]
    _physical_dataset(
        group,
        "negative_phase_space_weight_per_m2",
        weights;
        units = "m^-2",
        axes = "green_matrix_kind",
        description = "Spin-weighted negative spectral phase-space measure on the finite sampled domain; not missing tail charge",
    )
    return witnesses
end


function _diagnostic_eigenvalues(block)
    all(isfinite, block) || return fill(NaN, size(block, 1))
    try
        return eigvals(Hermitian((block+block')/2))
    catch error
        error isa LinearAlgebra.LAPACKException || rethrow()
        return fill(NaN, size(block, 1))
    end
end

# Transport guards for the owning Core template. The complete portable format
# policy is owned by qcl-negf-contracts/final_audit.py, not a second evaluator.
const _FINAL_FIXED_POINT_SCHEMA = "qcl-negf-final-fixed-point-audit-v1"
const _FINAL_FIXED_POINT_IDENTITY = (
    "execution_id", "point_id", "state_id", "attempt", "state_sequence", "plan_fingerprint",
)
const _FINAL_FIXED_POINT_DESCRIPTION = "Versioned final fixed-point raw measurement record"

function _final_audit_identity(identity)
    all(key->haskey(identity,key), _FINAL_FIXED_POINT_IDENTITY) ||
        throw(ArgumentError("final audit requires all six actual state identity fields"))
    result=Dict{String,Any}(key=>identity[key] for key in _FINAL_FIXED_POINT_IDENTITY)
    for key in ("execution_id","point_id","state_id")
        value=result[key]
        value isa String && 1<=ncodeunits(value)<=128 &&
            occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$",value) ||
            throw(ArgumentError("invalid final audit identity $key"))
    end
    for key in ("attempt","state_sequence")
        value=result[key]
        value isa Integer && !(value isa Bool) && 1<=value<=9007199254740991 ||
            throw(ArgumentError("invalid final audit identity $key"))
    end
    value=result["plan_fingerprint"]
    value isa String && occursin(r"^[0-9a-f]{64}$",value) ||
        throw(ArgumentError("invalid final audit plan fingerprint"))
    return result
end

function _final_audit_transport_value(value, depth=0, members=Ref(0))
    depth<=9 || throw(ArgumentError("final audit exceeds depth budget"))
    if value isa AbstractDict
        members[]+=length(value)
        members[]<=1024 || throw(ArgumentError("final audit exceeds member budget"))
        all(key->key isa String,keys(value)) || throw(ArgumentError("final audit keys must be strings"))
        if Set(keys(value))==Set(("status","value","nonfinite","reason"))
            status,number,tag,reason=(value[key] for key in ("status","value","nonfinite","reason"))
            numeric=number isa Real && !(number isa Bool) && isfinite(number)
            valid = status=="measured" ? numeric && tag===nothing && reason===nothing :
                status in ("unavailable","not_applicable") ? number===nothing && tag===nothing && reason isa String :
                status=="error" ? (number===nothing || numeric) &&
                    (tag===nothing || tag in ("nan","+inf","-inf")) && reason isa String &&
                    (tag===nothing || (number===nothing && reason=="nonfinite_measurement")) : false
            valid || throw(ArgumentError("invalid final audit measurement status/value"))
        end
        return Dict{String,Any}(key=>_final_audit_transport_value(item,depth+1,members) for (key,item) in value)
    elseif value isa AbstractVector
        length(value)<=1024 || throw(ArgumentError("final audit array exceeds budget"))
        return [_final_audit_transport_value(item,depth+1,members) for item in value]
    elseif value isa String
        isvalid(value) && !occursin('\0',value) && ncodeunits(value)<=512 ||
            throw(ArgumentError("invalid final audit UTF-8 string"))
    elseif value isa Real && !(value isa Bool)
        isfinite(value) || throw(ArgumentError("final audit JSON number must be finite"))
        return value isa AbstractFloat && iszero(value) ? 0.0 : value
    elseif value!==nothing && !(value isa Bool)
        throw(ArgumentError("unsupported final audit JSON value"))
    end
    return value
end

function _final_audit_record(template, identity; bind=false)
    template isa AbstractDict || throw(ArgumentError("final audit template must be an object"))
    expected=Set(("schema","record_status","reason","detail","detail_truncated","shape","units",
        "context","history","dyson","spectral","keldysh","selfenergy","charge","poisson"))
    bind || push!(expected,"state_identity")
    Set(keys(template))==expected || throw(ArgumentError("unexpected final audit template fields"))
    record=_final_audit_transport_value(template)
    record["schema"]==_FINAL_FIXED_POINT_SCHEMA || throw(ArgumentError("unknown final audit schema"))
    record["units"]==Dict("native"=>"1","energy_scale"=>"eV","length_scale"=>"m","index"=>"1-based") ||
        throw(ArgumentError("invalid final audit units"))
    state=_final_audit_identity(identity)
    if bind
        record["state_identity"]=state
    else
        Set(keys(record["state_identity"]))==Set(_FINAL_FIXED_POINT_IDENTITY) &&
            all(key->typeof(record["state_identity"][key])===typeof(state[key]) &&
                     record["state_identity"][key]==state[key],_FINAL_FIXED_POINT_IDENTITY) ||
            throw(ArgumentError("final audit state identity differs"))
    end
    status=record["record_status"]
    expected_reason=status=="measured" ? nothing : status=="partial_error" ? "measurement_error" :
                    status=="unavailable" ? "map_unavailable" : "invalid"
    expected_reason!="invalid" && record["reason"]==expected_reason ||
        throw(ArgumentError("invalid final audit record status/reason"))
    mandatory=String[]
    fresh=String[]
    function statuses(value,path=())
        if value isa AbstractDict
            if Set(keys(value))==Set(("status","value","nonfinite","reason"))
                path in (("history","previous_lambda"),("charge","lambda_change")) ||
                    push!(mandatory,value["status"])
                if !isempty(path) && (first(path) in ("dyson","spectral","keldysh","selfenergy") ||
                        first(path)=="charge" && last(path) in ("candidate_raw_sheet","candidate_lambda","candidate_constraint"))
                    push!(fresh,value["status"])
                end
            else
                for (key,item) in value
                    statuses(item,(path...,key))
                end
            end
        elseif value isa AbstractVector
            for item in value
                statuses(item,path)
            end
        end
    end
    statuses(record)
    if status!="unavailable"
        all(s->s in ("measured","error"),mandatory) &&
            ((status=="partial_error")==any(==("error"),mandatory)) ||
            throw(ArgumentError("final audit status contradicts mandatory measurements"))
    else
        all(==("unavailable"),fresh) ||
            throw(ArgumentError("unavailable final map contains fresh measured values"))
    end
    text=sprint(_light_json,record)
    1<=ncodeunits(text)<=65536 || throw(ArgumentError("final audit exceeds JSON byte budget"))
    return record
end

function _bound_final_audit(solution,identity;final_state)
    final_state || return nothing
    template=get(solution.observables,:final_fixed_point_audit,nothing)
    # Legacy states have no template. A present but malformed new template fails.
    if template===nothing
        haskey(solution.observables,:acceptance_measurement_context) &&
            throw(ArgumentError("new final state lacks its final audit template"))
        return nothing
    end
    return _final_audit_record(template,identity;bind=true)
end

function _write_final_audit!(file,record)
    record===nothing && return nothing
    diagnostic=haskey(file,"diagnostics") ? file["diagnostics"] : create_group(file,"diagnostics")
    group=create_group(diagnostic,"final_fixed_point_audit")
    attributes(group)["schema"]=_FINAL_FIXED_POINT_SCHEMA
    # Instance String dispatch in pinned HDF5.jl creates fixed UTF-8 scalar;
    # datatype(String) and string vectors would instead create vlen strings.
    group["record_json"]=sprint(_light_json,record)
    dataset=group["record_json"]
    attributes(dataset)["units"]="1"
    attributes(dataset)["logical_axis_order"]="scalar"
    attributes(dataset)["description"]=_FINAL_FIXED_POINT_DESCRIPTION
    return nothing
end

function _verify_final_audit_pair(file,commit;role="physics.full")
    assessment=get(commit,"stationary_assessment",Dict{String,Any}())
    record_present=haskey(assessment,"final_fixed_point_audit")
    record=get(assessment,"final_fixed_point_audit",nothing)
    present=haskey(file,"diagnostics/final_fixed_point_audit")
    final_state=get(commit,"storage_class",nothing)=="archive"
    if !final_state
        !present && !record_present || throw(ArgumentError("recovery cannot publish a final audit"))
        return nothing
    end
    if role=="recovery"
        !present || throw(ArgumentError("recovery payload cannot publish a final audit"))
        return nothing
    end
    record_present && !(record isa AbstractDict) &&
        throw(ArgumentError("present final audit must be an object"))
    !present && !record_present && return nothing # Legacy final native4.
    # The canonical full copy is required. An analysis owner may omit its copy;
    # a present copy still has the complete binding and equality obligations.
    !present && role=="physics.analysis" && return nothing
    present && record_present || throw(ArgumentError("final audit presence differs"))
    metadata=file["metadata"]
    identity_key=role=="physics.analysis" ? "identity_json" : "point_identity_json"
    haskey(metadata,identity_key) || throw(ArgumentError("final audit lacks native state identity"))
    native_identity=YAML.load(String(read(metadata[identity_key]));dicttype=Dict{String,Any})
    _final_audit_equal(_final_audit_identity(native_identity),_final_audit_identity(commit["identity"])) ||
        throw(ArgumentError("final audit native state identity differs from commit"))
    group=file["diagnostics/final_fixed_point_audit"]
    Set(keys(group))==Set(["record_json"]) || throw(ArgumentError("invalid final audit native inventory"))
    _require_final_audit_constant(group,"schema",_FINAL_FIXED_POINT_SCHEMA)
    dataset=group["record_json"]
    dtype=HDF5.datatype(dataset)
    properties=HDF5.get_create_properties(dataset)
    try
        ndims(dataset)==0 && HDF5.API.h5t_get_class(dtype)==HDF5.API.H5T_STRING &&
            !HDF5.API.h5t_is_variable_str(dtype) && 1<=sizeof(dtype)<=65536 &&
            HDF5.API.h5t_get_cset(dtype)==HDF5.API.H5T_CSET_UTF8 &&
            properties.layout in (:contiguous,:compact) &&
            HDF5.API.h5p_get_nfilters(properties)==0 && HDF5.API.h5p_get_external_count(properties)==0 ||
            throw(ArgumentError("invalid final audit scalar storage"))
    finally
        close(dtype)
        close(properties)
    end
    for (name,expected) in (("units","1"),("logical_axis_order","scalar"),("description",_FINAL_FIXED_POINT_DESCRIPTION))
        _require_final_audit_constant(dataset,name,expected)
    end
    text=String(read(dataset))
    isvalid(text) && !occursin('\0',text) && 1<=ncodeunits(text)<=65536 ||
        throw(ArgumentError("invalid final audit native payload"))
    native=YAML.load(text;dicttype=Dict{String,Any})
    _final_audit_equal(_final_audit_record(native,commit["identity"]),_final_audit_record(record,commit["identity"])) ||
        throw(ArgumentError("native and commit final audit values differ"))
    return nothing
end

function _require_final_audit_constant(parent,name,expected)
    attribute=HDF5.open_attribute(parent,name)
    dtype=HDF5.datatype(attribute)
    space=HDF5.dataspace(attribute)
    try
        HDF5.API.h5t_get_class(dtype)==HDF5.API.H5T_STRING &&
            !HDF5.API.h5t_is_variable_str(dtype) &&
            ncodeunits(expected)<=sizeof(dtype)<=65536 &&
            HDF5.API.h5t_get_cset(dtype) in (HDF5.API.H5T_CSET_ASCII,HDF5.API.H5T_CSET_UTF8) &&
            HDF5.API.h5s_get_simple_extent_type(space)==HDF5.API.H5S_SCALAR ||
            throw(ArgumentError("invalid final audit constant storage $name"))
        # This readback verifies Runner's just-written fixed scalar constants;
        # independent hostile-input padding/JSON policy belongs to Results.
        read(attribute)==expected || throw(ArgumentError("invalid final audit native $name"))
    finally
        close(space)
        close(dtype)
        close(attribute)
    end
    return nothing
end

function _final_audit_equal(left,right)
    if left isa AbstractDict && right isa AbstractDict
        return Set(keys(left))==Set(keys(right)) && all(key->_final_audit_equal(left[key],right[key]),keys(left))
    elseif left isa AbstractVector && right isa AbstractVector
        return length(left)==length(right) && all(_final_audit_equal(a,b) for (a,b) in zip(left,right))
    elseif left isa Bool || right isa Bool || left isa Integer || right isa Integer
        return typeof(left)===typeof(right) && left==right
    elseif left isa AbstractFloat && right isa AbstractFloat
        return Float64(left)==Float64(right)
    end
    return typeof(left)===typeof(right) && left==right
end

# This is a bounded non-wire composition port, not a new scientific receipt.
function _p05_display_tree(value,path=(),depth=0)
    _p04_require(depth<=16,"display nesting exceeds producer profile")
    if value isa AbstractDict
        _p04_require(all(k->k isa String && isvalid(k),keys(value)),"display key is not UTF-8 string")
        for (key,child) in value;_p05_display_tree(child,(path...,key),depth+1);end
    elseif value isa AbstractVector
        if length(path)==3 && path[1]=="quadrature" && path[2] in ("energy","radial","spatial") && path[3]=="weights"
            _p04_require(value isa Vector{Float64},"display quadrature dtype differs")
        else
            _p04_require(ndims(value)==1 && length(value)<=1024 && !(eltype(value)<:Number),"numeric/large array on display port")
            for item in value;_p05_display_tree(item,path,depth+1);end
        end
    elseif value isa String
        _p05_string(value)
    else
        _p04_require(value===nothing || value isa Union{Bool,Integer} || value isa AbstractFloat && isfinite(value),"unsupported/nonfinite display object")
    end
    nothing
end
function _p05_presentation(snapshot,status,quality,messages,limit)
    assessment=snapshot.assessment
    _p04_keys(assessment,("registry_version","registry_source","model_context","quadrature","scales","iterative_converged",
        "fixed_hartree_converged","physical_gates_passed","stationary_candidate_accepted","discretization_verified","scientific_accepted",
        "scientific_acceptance_reason","outer_confirmation_count","metrics","final_fixed_point_audit","evaluator"))
    _p04_keys(assessment["model_context"],("boundary_condition","basis_contract","energy_shift_discretization","enabled_scattering","physical_models"))
    _p04_keys(assessment["quadrature"],("energy","radial","spatial","spin_degeneracy"))
    for name in ("energy","radial","spatial");_p04_keys(assessment["quadrature"][name],("weights","units"));end
    z,e,k,_=snapshot.context.dimensions
    _p04_require(all(length(assessment["quadrature"][name]["weights"])==n for (name,n) in (("energy",e),("radial",k),("spatial",z))),"display quadrature domain differs")
    _p04_keys(assessment["scales"],("E0_eV","L0_m","lambda_P","Nb","energy_tail_window_fraction","momentum_tail_window_fraction"))
    for record in values(assessment["metrics"])
        _p04_keys(record,("registry_version","metric_id","theory_reference","formula","formula_source","formula_context","units","normalization",
            "denominator_floor","weights","applicability","threshold_origin","error_budget","value","recorded_value","status","threshold","comparison","iteration_comparison","category","reason"))
        _p04_keys(record["denominator_floor"],("kind","value","units"))
        _p04_keys(record["applicability"],("applies","scope","reason"))
        _p04_keys(record["threshold_origin"],("kind","parameter","source","literature_threshold","interpretation"))
        _p04_keys(record["error_budget"],("class","estimated_bound","bound_status","interpretation","discretization_evidence"))
    end
    audit=assessment["final_fixed_point_audit"]
    audit===nothing || _p05_audit_shape(audit)
    # Guard ownership shape before metadata display allocations; no array deepcopy.
    _p05_metadata_cost((assessment,messages),limit)
    _p05_display_tree(assessment)
    for message in messages;_p05_string(message);end
    validation=_light_validation_data(snapshot;messages)
    positivity=_light_positivity_data(snapshot;status,quality)
    (;stationary_assessment=assessment,validation,positivity)
end

function _p05_audit_measure_shape(value)
    _p04_keys(value,("status","value","nonfinite","reason"))
    _p04_require(value["status"] in ("measured","error","unavailable","not_applicable") &&
        (value["value"]===nothing || value["value"] isa Real && !(value["value"] isa Bool) && isfinite(value["value"])) &&
        (value["nonfinite"]===nothing || value["nonfinite"] in ("nan","+inf","-inf")) &&
        (value["reason"]===nothing || value["reason"] isa String),"unknown captured audit measurement shape")
end
function _p05_audit_shape(audit)
    _p04_keys(audit,("schema","record_status","reason","detail","detail_truncated","shape","units","context","history","dyson","spectral","keldysh","selfenergy","charge","poisson"))
    _p04_require(audit["schema"]=="qcl-negf-final-fixed-point-audit-v1" && audit["record_status"] in ("measured","partial_error","unavailable") &&
        audit["detail_truncated"] isa Bool,"unknown captured audit profile")
    _p04_keys(audit["shape"],("NE","Nk","Nb"));_p04_keys(audit["units"],("native","energy_scale","length_scale","index"))
    context=audit["context"]
    _p04_keys(context,("status","reason","unknown_fields","backend","energy_shift","hilbert","contraction","kernel_build","embedding","electron_electron_mode",
        "embedding_periods","enabled_scattering","E0_eV","L0_m","lambda_P","map_kernels_shared_with_solver","independent_physics_oracle","state_alignment",
        "alignment_reason","source_owner_role","source_paths"))
    _p04_keys(context["source_paths"],("U","n","GR","GL","GG","A"))
    _p05_strings(context["unknown_fields"]);_p05_strings(context["enabled_scattering"])
    _p04_require(context["status"] in ("known","unknown") && context["independent_physics_oracle"]===false &&
        context["source_owner_role"]=="physics.full","unknown captured audit context")
    history=audit["history"];_p04_keys(history,("inner_last","inner_previous","outer_last","previous_lambda"))
    _p05_audit_measure_shape(history["previous_lambda"])
    dyson=audit["dyson"];_p04_keys(dyson,("ratio","global_abs_F","max_abs_F","ratio_witness","absolute_witness"))
    for name in ("ratio","global_abs_F","max_abs_F");_p05_audit_measure_shape(dyson[name]);end
    for name in ("ratio_witness","absolute_witness")
        witness=dyson[name];_p04_keys(witness,("status","e_index","k_index","numerator_F","D_F","GR_F","identity_F","denominator","ratio"))
        for key in ("numerator_F","D_F","GR_F","identity_F","denominator","ratio");_p05_audit_measure_shape(witness[key]);end
    end
    for name in ("spectral","keldysh")
        record=audit[name];_p04_keys(record,("numerator_F","scale_F","denominator","ratio","floor"))
        for key in ("numerator_F","scale_F","denominator","ratio");_p05_audit_measure_shape(record[key]);end
    end
    selfenergy=audit["selfenergy"];_p04_keys(selfenergy,("rows","winner","max_ratio","floor"))
    _p04_require(selfenergy["rows"] isa AbstractVector && length(selfenergy["rows"])<=27,"captured selfenergy display rows exceed current producer")
    for row in selfenergy["rows"]
        _p04_keys(row,("family","component","numerator_F","scale_F","denominator","ratio"))
        _p04_require(row["family"] in (_P05_SCATTERING...,"electron_electron","embedding_total","embedding_plus","embedding_minus") &&
            row["component"] in ("R","L","G"),"captured audit family/component differs")
        for key in ("numerator_F","scale_F","denominator","ratio");_p05_audit_measure_shape(row[key]);end
    end
    selfenergy["winner"]===nothing || _p04_keys(selfenergy["winner"],("family","component"))
    _p05_audit_measure_shape(selfenergy["max_ratio"])
    charge=audit["charge"]
    _p04_keys(charge,("target_sheet","stored_raw_sheet","normalized_sheet","candidate_raw_sheet","stored_lambda","candidate_lambda","stored_constraint","candidate_constraint","normalized_residual","lambda_change"))
    for value in values(charge);_p05_audit_measure_shape(value);end
    poisson=audit["poisson"]
    _p04_keys(poisson,("residual_ratio","residual_numerator_F","rhs_F","additive_floor","denominator","border_scale","zeta_signed","neutrality_signed","neutrality_abs","target_sheet","neutrality_ratio","rU_max"))
    for value in values(poisson);_p05_audit_measure_shape(value);end
    _p05_display_tree(audit,("final_fixed_point_audit",));nothing
end
