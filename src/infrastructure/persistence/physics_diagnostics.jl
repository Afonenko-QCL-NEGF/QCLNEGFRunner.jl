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
                _electronvolts(problem.physical.E_ref),
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
    limits=_solution_validation_limits(solution.options.tolerances, metrics)
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
