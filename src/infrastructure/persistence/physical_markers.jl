const _SEED_MARKER_FIELDS =
    (:seed_mu_eV, :seed_number_ratio, :fdt_raw_seed_mu, :fdt_normalized_seed_mu)
"""Required typed physical diagnostics; unmeasured rows remain explicitly absent."""
const _PHYSICAL_MARKER_DEFINITIONS = merge(
    Dict(
        :seed_mu_eV => (
            "eV",
            "Chemical potential of the Fermi seed before the first physical map; NaN when this SCBA has no recorded original seed",
            "available=1 and finite seed reference",
        ),
        :seed_number_ratio => (
            "1",
            "Measured N(seed)/Ntarget before initial scattering and embedding; not the raw first-map charge",
            "available=1 and finite seed reference",
        ),
        :fdt_raw_seed_mu => (
            "1",
            "Raw paired FDT defect relative to the original seed chemical potential on the current spectral function",
            "equilibrium_applicable=1 and finite seed reference",
        ),
        :fdt_normalized_seed_mu => (
            "1",
            "Normalized paired FDT defect relative to the original seed chemical potential",
            "equilibrium_applicable=1 and finite seed reference",
        ),
        :measured_iteration => (
            "1",
            "SCBA iteration at which this unmixed state was measured",
            "available=1",
        ),
        :raw_hole_charge => (
            "dimensionless sheet number",
            "Spin and momentum/energy weighted trace of raw empty correlation matrix",
            "available=1",
        ),
        :represented_capacity => (
            "dimensionless sheet number",
            "Sum of raw occupied and raw empty sheet numbers on represented domain; any spectral identity defect remains measurable",
            "available=1",
        ),
        :occupied_fraction_a => (
            "1",
            "Coefficient a multiplying raw occupied matrix in normalized Gn = a*Gn_raw + c*Gp_raw",
            "available=1 and valid configured normalization coefficients",
        ),
        :empty_fraction_c => (
            "1",
            "Coefficient c transferring raw empty weight into occupied matrix in normalized Gn = a*Gn_raw + c*Gp_raw",
            "available=1 and valid configured normalization coefficients",
        ),
        :relative_correction_Gn => (
            "1",
            "Quadrature weighted Frobenius norm of normalized minus raw occupied matrix divided by raw occupied norm",
            "available=1",
        ),
        :relative_correction_Gp => (
            "1",
            "Quadrature weighted Frobenius norm of normalized minus raw empty matrix divided by raw empty norm",
            "available=1",
        ),
        :equilibrium_applicable => (
            "1",
            "Whether zero bias, thermal LO population and equal enabled bath temperatures permit equilibrium comparison",
            "available=1",
        ),
        :equilibrium_status => (
            "1",
            "Explicit equilibrium measurement status; not_applicable is never a passing result",
            "available=1",
        ),
        :equilibrium_mu_eV => (
            "eV",
            "Chemical potential relative to E_ref, fitted to target sheet number using represented spectral function at lattice temperature",
            "equilibrium_applicable=1 and successful equilibrium_status",
        ),
        :fdt_raw => (
            "1",
            "Quadrature weighted paired Frobenius defect of raw occupied/empty matrices versus f*A and (1-f)*A, normalized by the quadrature weighted Frobenius norm of A",
            "equilibrium_applicable=1 and successful equilibrium_status",
        ),
        :fdt_normalized => (
            "1",
            "Quadrature weighted paired Frobenius equilibrium defect after occupation normalization",
            "equilibrium_applicable=1 and successful equilibrium_status",
        ),
        :equilibrium_abs_current_A_m2 => (
            "A/m^2",
            "Absolute current density in the equilibrium-applicable state; stationarity is not implied",
            "equilibrium_applicable=1",
        ),
        :delta_energy_eV => (
            "eV",
            "Actual adjacent-node spacing of the uniform energy grid",
            "available=1",
        ),
        :sampled_gamma_over_dE_q10 => (
            "1",
            "Spectral-weighted sampled 10th percentile of modal i*(SigmaGreater-SigmaLesser) linewidth divided by energy spacing",
            "linewidth_status records availability; sampled diagnostic only",
        ),
        :sampled_gamma_over_dE_q50 => (
            "1",
            "Spectral-weighted sampled median of modal energy linewidth divided by energy spacing",
            "linewidth_status records availability; sampled diagnostic only",
        ),
        :sampled_gamma_over_dE_q90 => (
            "1",
            "Spectral-weighted sampled 90th percentile of modal energy linewidth divided by energy spacing",
            "linewidth_status records availability; sampled diagnostic only",
        ),
        :sampled_spectral_weight_underresolved => (
            "1",
            "Sampled positive spectral weight fraction with modal Gamma/dE below one; not a quadrature certificate",
            "linewidth_status records availability; sampled diagnostic only",
        ),
        :linewidth_sampled_blocks => (
            "1",
            "Number of distinct energy/momentum blocks inspected by linewidth diagnostic",
            "available=1",
        ),
        :linewidth_status =>
            ("1", "Explicit status of sampled linewidth calculation", "available=1"),
        :linewidth_sampling_method =>
            ("1", "Deterministic spectral sampling rule actually used", "available=1"),
        :marker_cadence => (
            "iteration",
            "Configured regular marker measurement interval; initial, checkpoint and final states also measured",
            "available=1",
        ),
        :linewidth_max_blocks => (
            "1",
            "Configured maximum number of sampled energy/momentum blocks",
            "available=1",
        ),
        :relative_mode_weight_floor => (
            "1",
            "Relative spectral-mode weight floor used only for the diagnostic sampling distribution",
            "available=1",
        ),
    ),
    Dict(
        :fresh_map_status => (
            "1",
            "Availability of fresh Sigma[G] and mixed Sigma measured on this exact Green state before mixing",
            "available=1",
        ),
        :lo_shift_over_dE => (
            "1",
            "LO phonon energy divided by energy grid spacing; fractional values require interpolation",
            "LO channel enabled",
        ),
        :field_shift_over_dE => (
            "1",
            "Signed electrostatic energy drop per period divided by energy grid spacing",
            "available=1",
        ),
        :lo_boundary_occupied_fraction => (
            "1",
            "Signed occupied quadrature fraction in edge bands exposed by plus/minus LO shifts; not lost collision flux",
            "LO channel enabled and positive occupied trace",
        ),
        :lo_boundary_spectral_fraction => (
            "1",
            "Signed spectral quadrature fraction in edge bands exposed by plus/minus LO shifts",
            "LO channel enabled and positive spectral trace",
        ),
        :field_boundary_occupied_fraction => (
            "1",
            "Signed occupied quadrature fraction exposed by one period field shifts",
            "positive occupied trace",
        ),
        :field_boundary_spectral_fraction => (
            "1",
            "Signed spectral quadrature fraction exposed by one period field shifts",
            "positive spectral trace",
        ),
    ),
)
const _MARKER_CHILD_TYPES =
    (:channels => SCBAChannelMarker, :collisions => SCBACollisionMarker)
_marker_scalar_fields() =
    filter(field -> !(field in (:channels, :collisions)), fieldnames(SCBAPhysicalMarkers))
_marker_storage_type(T, field) =
    fieldtype(T, field) === Symbol ? String :
    fieldtype(T, field) === Bool ? Int8 : fieldtype(T, field) <: Integer ? Int64 : Float64
_marker_storage_type(field) = _marker_storage_type(SCBAPhysicalMarkers, field)
_marker_missing(field) =
    _marker_storage_type(field) === String ? "not_recorded" :
    _marker_storage_type(field) <: Integer ? 0 : NaN

function _physical_marker_columns(markers, sequences)
    columns = Dict{String,Any}(
        "sequence" => Int64.(sequences),
        "available" => Int8[marker !== nothing for marker in markers],
    )
    for field in _marker_scalar_fields()
        T = _marker_storage_type(field)
        columns[String(field)] = T[
            marker === nothing ? _marker_missing(field) :
            T === String ? String(getfield(marker, field)) : getfield(marker, field) for
            marker in markers
        ]
    end
    for (child, T) in _MARKER_CHILD_TYPES
        rows = [
            (Int64(sequence), row) for
            (sequence, marker) in zip(sequences, markers) if marker !== nothing for
            row in getfield(marker, child)
        ]
        table = Dict{String,Any}("sequence" => Int64[first(pair) for pair in rows])
        for field in fieldnames(T)
            C = _marker_storage_type(T, field)
            table[String(field)] = C[
                C === String ? String(getfield(row, field)) : getfield(row, field) for
                (_, row) in rows
            ]
        end
        columns[String(child)] = table
    end
    return columns
end

function _write_marker_child!(parent, name, columns)
    table = create_group(parent, name)
    attributes(table)["schema"] = "qcl-negf-physical-marker-$(name)-v1"
    attributes(
        table,
    )["state_alignment"] = "Same pre-mixing normalized Green state; fresh=Sigma[G], mixed=Sigma used in Dyson"
    for field in sort!(collect(keys(columns)))
        definition =
            field == "residual_relative" ?
            "Unmixed Frobenius difference / (fresh Frobenius norm + 1e-14), no mixing factor" :
            field == "residual_scale" ?
            "Fresh self-energy component Frobenius norm, dimensionless" :
            field == "residual_absolute" ?
            "Frobenius norm of fresh minus mixed component, dimensionless" :
            startswith(field, "particle") ?
            "Spin/(2pi) weighted integral of Tr(SigmaL*Ggreater-SigmaGreater*Glesser); absolute is incoming plus outgoing magnitude, dimensionless" :
            startswith(field, "energy") ?
            "Same collision integral weighted by dimensionless energy relative to E_ref; absolute uses abs(energy), dimensionless" :
            "Typed identity of the observation"
        object = _physical_dataset(
            table,
            field,
            columns[field];
            units = "1",
            axes = "observation",
            description = definition,
        )
        attributes(object)["definition"] = definition
        attributes(
            object,
        )["applicability"] = "fresh_map_status=available; enabled internal scattering channels for collisions"
    end
    return table
end

function _write_physical_marker_columns!(parent, columns)
    table = create_group(parent, "physical_markers")
    attributes(table)["schema"] = "qcl-negf-physical-markers-v3"
    attributes(table)["index_origin"] = 1
    attributes(
        table,
    )["sampling"] = "Initial, configured cadence, published checkpoint and final exact SCBA state; never forward-filled"
    attributes(table)["acceptance_role"] = "diagnostic only; never changes solver acceptance gates"
    for name in sort!(collect(keys(columns)))
        if name in ("channels", "collisions")
            _write_marker_child!(table, name, columns[name])
            continue
        end
        units, definition, applicability =
            name == "sequence" ? ("1", "Immutable SCBA history sequence", "every row") :
            name == "available" ?
            ("1", "One only when marker measured on this exact row", "every row") :
            _PHYSICAL_MARKER_DEFINITIONS[Symbol(name)]
        object = _physical_dataset(
            table,
            name,
            columns[name];
            units,
            axes = "iteration",
            description = definition,
        )
        attributes(object)["definition"] = definition
        attributes(object)["applicability"] = applicability
    end
    return table
end

function _write_physical_markers!(parent, rows; sequences = collect(eachindex(rows)))
    return _write_physical_marker_columns!(
        parent,
        _physical_marker_columns([row.physical_markers for row in rows], sequences),
    )
end

function _require_marker_column(column, expected, count)
    size(column) == (count,) ||
        throw(DimensionMismatch("physical marker row count differs"))
    stored = expected === String ? eltype(read(column)) : eltype(column)
    stored === expected ||
        throw(ArgumentError("physical marker requires native $expected storage"))
end

function _require_physical_marker_storage(parent, count)
    haskey(parent, "physical_markers") ||
        throw(ArgumentError("native v4 requires typed physical_markers"))
    table = parent["physical_markers"]
    String(read_attribute(table, "schema")) == "qcl-negf-physical-markers-v3" ||
        throw(ArgumentError("unsupported physical marker schema"))
    required = Set(["sequence", "available", String.(fieldnames(SCBAPhysicalMarkers))...])
    Set(keys(table)) == required ||
        throw(ArgumentError("physical marker fields differ from native v4"))
    for name in ("sequence", "available", String.(_marker_scalar_fields())...)
        expected =
            name == "sequence" ? Int64 :
            name == "available" ? Int8 : _marker_storage_type(Symbol(name))
        _require_marker_column(table[name], expected, count)
    end
    sequences, available = read(table["sequence"]), read(table["available"])
    length(unique(sequences)) == count ||
        throw(ArgumentError("duplicate physical marker sequence"))
    all(in((0, 1)), available) ||
        throw(ArgumentError("invalid physical marker availability"))
    measured = Set(sequences[available .== 1])
    if haskey(parent, "psd_history")
        sequences == read(parent["psd_history/sequence"]) ||
            throw(ArgumentError("physical marker and PSD sequence alignment differs"))
    end
    status = read(table["fresh_map_status"])
    all(
        status[i] in ("available", "unavailable") for
        i in eachindex(status) if available[i] == 1
    ) || throw(ArgumentError("invalid fresh-map availability"))
    fresh_available = Set(sequences[(available .== 1) .& (status .== "available")])
    for (child, T) in _MARKER_CHILD_TYPES
        columns = table[String(child)]
        String(read_attribute(columns, "schema")) ==
        "qcl-negf-physical-marker-$(child)-v1" ||
            throw(ArgumentError("unsupported physical marker child schema"))
        Set(keys(columns)) == Set(["sequence", String.(fieldnames(T))...]) ||
            throw(ArgumentError("physical marker child columns differ"))
        seq = read(columns["sequence"])
        all(in(measured), seq) ||
            throw(ArgumentError("child marker references unavailable observation"))
        all(in(fresh_available), seq) ||
            throw(ArgumentError("child marker references unavailable fresh map"))
        _require_marker_column(columns["sequence"], Int64, length(seq))
        for field in fieldnames(T)
            _require_marker_column(
                columns[String(field)],
                _marker_storage_type(T, field),
                length(seq),
            )
        end
        kinds = read(columns[child === :channels ? "component" : "state_kind"])
        allowed =
            child === :channels ? ("retarded", "lesser", "greater") : ("fresh", "mixed")
        all(in(allowed), kinds) ||
            throw(ArgumentError("invalid physical marker state/component"))
        identities = collect(zip(seq, read(columns["channel"]), kinds))
        length(unique(identities)) == length(identities) ||
            throw(ArgumentError("duplicate physical child marker"))
    end
    return table
end

function _read_physical_markers(parent, count)
    result = Union{Nothing,SCBAPhysicalMarkers}[nothing for _ = 1:count]
    table = _require_physical_marker_storage(parent, count)
    columns = Dict(
        name => read(table[name]) for
        name in ("sequence", "available", String.(_marker_scalar_fields())...)
    )
    children = Dict{Symbol,Any}()
    for (child, T) in _MARKER_CHILD_TYPES
        stored = Dict(
            name => read(table[String(child)][name]) for name in keys(table[String(child)])
        )
        grouped = Dict{Int64,Vector{T}}()
        for i in eachindex(stored["sequence"])
            row = T(
                (
                    fieldtype(T, field)(stored[String(field)][i]) for
                    field in fieldnames(T)
                )...,
            )
            push!(get!(grouped, stored["sequence"][i], T[]), row)
        end
        children[child] = grouped
    end
    for index = 1:count
        columns["available"][index] == 0 && continue
        sequence = columns["sequence"][index]
        result[index] = SCBAPhysicalMarkers(
            (
                fieldtype(SCBAPhysicalMarkers, field)(columns[String(field)][index]) for
                field in _marker_scalar_fields()
            )...,
            get(children[:channels], sequence, SCBAChannelMarker[]),
            get(children[:collisions], sequence, SCBACollisionMarker[]),
        )
    end
    return result
end

function _consolidate_physical_markers!(parent, paths)
    sequences = Int64[]
    markers = Union{Nothing,SCBAPhysicalMarkers}[]
    for path in paths
        h5open(path, "r") do source
            _require_native_metadata(source, "qcl-negf-scientific-history-v4")
            sequence = read(source["scba/sequence"])
            append!(sequences, sequence)
            append!(markers, _read_physical_markers(source, length(sequence)))
        end
    end
    order = sortperm(sequences)
    length(unique(sequences)) == length(order) ||
        throw(ArgumentError("duplicate physical marker sequence"))
    return _write_physical_marker_columns!(
        parent,
        _physical_marker_columns(markers[order], sequences[order]),
    )
end

"""Bounded derived summary of one complete inner history; parent owns its identity."""
function _write_scba_threshold_crossings!(parent, history; required_consecutive::Int = 3)
    rows = QCLNumerics._scba_threshold_crossings(history; required_consecutive)
    table = create_group(parent, "scba_threshold_crossings")
    attributes(table)["schema"] = "qcl-negf-scba-threshold-crossings-v1"
    attributes(
        table,
    )["acceptance_role"] = "diagnostic crossing only; final scientific acceptance remains separate"
    attributes(
        table,
    )["trajectory"] = "One current inner SCBA history of the owning point/attempt/outer state; no cross-attempt joins"
    attributes(table)["absent_iteration"] = 0
    attributes(table)["comparison"] = "finite raw residual <= threshold; joint=max(r_Sigma,r_K,r_lambda)"
    for field in keys(first(rows))
        values =
            field === :metric ? String[String(getfield(row, field)) for row in rows] :
            field in (
                :required_consecutive,
                :first_iteration,
                :sustained_start_iteration,
                :sustained_end_iteration,
            ) ? Int64[getfield(row, field) for row in rows] :
            Float64[getfield(row, field) for row in rows]
        units = field in (:first_current_A_m2, :sustained_current_A_m2) ? "A/m^2" : "1"
        _physical_dataset(
            table,
            String(field),
            values;
            units,
            axes = "threshold_observation",
            description = "Derived $(field); absent iteration=0, unavailable observable=NaN; no solver acceptance implied",
        )
    end
    return table
end
