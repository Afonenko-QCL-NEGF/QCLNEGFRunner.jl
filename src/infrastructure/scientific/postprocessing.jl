"""Offline scientific projections from saved data; never launches NEGF.

Supported operations: iv, differential_conductance, gain_voltage, populations,
density_map, potential_map, optical_map. Missing required fields are explicit
errors; display projections retain their sampling declaration.
"""
function postprocess_series(
    directory::AbstractString;
    operations = [
        "iv",
        "gain_voltage",
        "populations",
        "density_map",
        "potential_map",
        "energy_density_map",
        "optical_map",
    ],
    output_directory::AbstractString = joinpath(directory, "analysis"),
    photon_energies = nothing,
)
    series, root=_read_series(directory)
    output=abspath(output_directory)
    mkpath(output)
    supported=Set((
        "iv",
        "differential_conductance",
        "gain_voltage",
        "populations",
        "density_map",
        "potential_map",
        "energy_density_map",
        "optical_map",
        "optical_recompute",
    ))
    all(x->x in supported, operations) ||
        throw(ArgumentError("unsupported postprocessing operation"))
    derived=Dict{String,Any}(
        "schema"=>"qcl-negf-derived-result-v2",
        "source_plan_fingerprint"=>series["plan_fingerprint"],
        "stationary_result"=>relpath(joinpath(root, "series_result.json"), output),
        "operations"=>Dict{String,Any}(),
        "figures"=>Any[],
    )
    rows=series["points"]
    for operation in operations
        try
            value=if operation=="optical_recompute"
                photon_energies===nothing && throw(
                    ArgumentError(
                        "optical_recompute requires an explicit Unitful photon_energies vector and saved full state",
                    ),
                )
                _recompute_optics(rows, root, output, photon_energies)
            elseif operation in ("iv", "gain_voltage", "differential_conductance")
                _scalar_series(rows, operation)
            elseif operation=="optical_map"
                _optical_series(rows, root)
            else
                _projection_series(rows, root, operation)
            end
            derived["operations"][operation]=Dict("status"=>"completed", "data"=>value)
            if operation in ("iv", "gain_voltage", "differential_conductance")
                field=operation=="iv" ? "current_density_A_per_m2" :
                      operation=="gain_voltage" ? "gain_peak_per_cm" :
                      "differential_conductance_A_per_m2_V"
                ylabel=operation=="iv" ? "Current density" :
                       operation=="gain_voltage" ? "Peak gain" :
                       "Differential conductance density"
                unit=operation=="iv" ? "A/m²" :
                     operation=="gain_voltage" ? "cm⁻¹" : "A/(m² V)"
                groups=unique(
                    (item["execution_id"], item["branch"], item["temperature_K"]) for
                    item in value
                )
                curves=Any[]
                for key in groups
                    selected=[
                        item for item in value if
                        (item["execution_id"], item["branch"], item["temperature_K"])==key
                    ]
                    push!(
                        curves,
                        Dict(
                            "id"=>join(string.(key), "/"),
                            "label"=>"$(key[1]); $(key[2]); T=$(key[3]) K",
                            "x"=>[item["voltage_per_period_V"] for item in selected],
                            "y"=>[item[field] for item in selected],
                            "quality"=>[item["quality"] for item in selected],
                            "accepted"=>[item["converged"] for item in selected],
                            "connect"=>[item["converged"] for item in selected],
                        ),
                    )
                end
                push!(
                    derived["figures"],
                    Dict(
                        "id"=>operation,
                        "title"=>ylabel*" versus voltage per period",
                        "x"=>Dict("label"=>"Voltage per period", "unit"=>"V"),
                        "y"=>Dict("label"=>ylabel, "unit"=>unit),
                        "series"=>curves,
                    ),
                )
            end
        catch error
            error isa InterruptException && rethrow()
            derived["operations"][operation]=Dict(
                "status"=>"insufficient_data",
                "message"=>sprint(showerror, error),
            )
        end
    end
    derived=_finite_scientific_value(derived)
    derived["fingerprint"]=bytes2hex(sha256(canonical_bytes(derived)))
    _scientific_json(joinpath(output, "derived_result.json"), derived)
    _observability_atomic_text(joinpath(output, "report.md")) do io
        println(
            io,
            "# ",
            series["name"],
            "\n\nSaved-data analysis; no solver was executed.\n",
        )
        println(io, "| Operation | Status |\n|---|---|")
        for op in operations
            item=derived["operations"][op]
            println(io, "| ", op, " | ", item["status"], " |")
        end
        println(
            io,
            "\nThe primary current is J(V_period,T). No contacts, series resistance or device geometry were inferred.\n\n## Research notes\n\n_Add manual interpretation and model validation here._",
        )
    end
    return derived
end
function _scalar_series(rows, operation)
    field=operation=="gain_voltage" ? "gain_peak_per_cm" : "current_density_A_per_m2"
    output=Any[]
    for point in rows
        haskey(point["observables"], field) || continue
        value=point["observables"][field]
        value isa Real && isfinite(value) || continue
        coordinates=point["coordinates"]
        push!(
            output,
            Dict{String,Any}(
                "point_id"=>point["id"],
                "execution_id"=>point["execution_id"],
                "branch"=>coordinates["branch"],
                "order"=>coordinates["order"],
                "temperature_K"=>coordinates["temperature_K"],
                "voltage_per_period_V"=>coordinates["voltage_per_period_V"],
                field=>value,
                "quality"=>point["quality"],
                "converged"=>point["converged"],
            ),
        )
    end
    isempty(output) && throw(ArgumentError("saved point observables do not contain $field"))
    if operation=="differential_conductance"
        keys=unique((p["execution_id"], p["branch"], p["temperature_K"]) for p in output)
        for key in keys
            selected=[
                p for
                p in output if (p["execution_id"], p["branch"], p["temperature_K"])==key
            ]
            sort!(selected; by = p->p["order"])
            all(p->p["converged"], selected) || throw(
                ArgumentError(
                    "dJ/dV requires strictly accepted points; branch $key contains nonaccepted data",
                ),
            )
            derivative=differential_conductance(
                Float64[p["voltage_per_period_V"] for p in selected],
                Float64[p[field] for p in selected],
            )
            for (point, value) in zip(selected, derivative)
                point["differential_conductance_A_per_m2_V"]=value
            end
        end
    end
    return output
end
function _analysis_path(point, root)
    commit_path=get(point["data"], "result_commit", nothing)
    commit_path===nothing &&
        throw(ArgumentError("point has no committed scientific artifacts"))
    absolute=_result_path(root, commit_path)
    commit=verify_point_artifacts(absolute)
    candidates=[a for a in commit["artifacts"] if a["role"]=="physics.analysis"]
    if isempty(candidates) && haskey(commit, "science_parent_commit")
        parent=commit["science_parent_commit"]
        absolute=normpath(joinpath(dirname(dirname(absolute)), parent["path"]))
        bytes2hex(open(sha256, absolute))==parent["sha256"] ||
            throw(ArgumentError("science parent digest differs"))
        commit=verify_point_artifacts(absolute)
        candidates=[a for a in commit["artifacts"] if a["role"]=="physics.analysis"]
    end
    length(candidates)==1 ||
        throw(ArgumentError("point has no unambiguous native analysis artifact"))
    return joinpath(dirname(absolute), only(candidates)["path"])
end

function _projection_series(rows, root, operation)
    datasets=operation=="energy_density_map" ?
             ["axes/z_nm", "axes/energy_eV", "observables/spatial_energy_density"] :
             operation=="populations" ? ["basis/sheet_density_matrix_per_m2"] :
             operation=="density_map" ? ["axes/z_nm", "observables/density_per_m3"] :
             [
        "axes/z_nm",
        (
            "observables/potential_"*kind*"_eV" for
            kind in ("structure", "external", "hartree", "total")
        )...,
    ]
    result=Any[]
    for point in rows
        get(point["data"], "result_commit", nothing)===nothing && continue
        path=_analysis_path(point, root)
        h5open(path, "r") do file
            all(dataset->haskey(file, dataset), datasets) ||
                throw(ArgumentError("required native $(operation) datasets absent"))
        end
        push!(
            result,
            Dict(
                "point_id"=>point["id"],
                "execution_id"=>point["execution_id"],
                "coordinates"=>point["coordinates"],
                "quality"=>point["quality"],
                "native_grid"=>true,
                "data"=>Dict(
                    "artifact"=>replace(relpath(path, root), '\\'=>'/'),
                    "sha256"=>bytes2hex(open(sha256, path)),
                    "datasets"=>datasets,
                ),
            ),
        )
    end
    isempty(result) &&
        throw(ArgumentError("$(operation) requires committed native physics"))
    return result
end

function _optical_series(rows, root)
    result=Any[]
    for point in rows
        get(point["data"], "optical", nothing)===nothing && continue
        path=_analysis_path(point, root)
        h5open(path, "r") do file
            haskey(file, "optical") ||
                throw(ArgumentError("saved native optical response is absent"))
        end
        push!(
            result,
            Dict(
                "point_id"=>point["id"],
                "coordinates"=>point["coordinates"],
                "quality"=>point["quality"],
                "artifact"=>replace(relpath(path, root), '\\'=>'/'),
                "dataset"=>"optical",
            ),
        )
    end
    isempty(result) &&
        throw(ArgumentError("optical_map requires a saved annotated optical spectrum"))
    return result
end

"""Render immutable annotated HDF5 into materialized SVG; no solver or JSON arrays."""
function render_saved_snapshot(path::AbstractString, output_directory::AbstractString)
    mkpath(output_directory)
    paths=String[]
    h5open(path, "r") do file
        _require_native_metadata(file, "qcl-negf-physics-analysis-v4")
        haskey(file, "diagnostics") ||
            throw(ArgumentError("native v3 rendering requires diagnostics"))
        _require_native_scba_tables(file["diagnostics"])
        z=read(file["axes/z_nm"])
        energy=read(file["axes/energy_eV"])
        k=read(file["axes/k_per_nm"])
        quality=String(read_attribute(file["metadata"], "quality"))
        function line(id, x, curves, title, xlabel, ylabel)
            target=joinpath(output_directory, id*".svg")
            _light_svg_series(target, x, curves; title, xlabel, ylabel)
            push!(paths, abspath(target))
        end
        line(
            "potential",
            z,
            [
                (kind, read(file["observables/potential_"*kind*"_eV"])) for
                kind in ("structure", "external", "hartree", "total")
            ],
            "Potential components",
            "z [nm]",
            "E [eV]",
        )
        line(
            "density",
            z,
            [("electron density", read(file["observables/density_per_m3"]))],
            "Electron density",
            "z [nm]",
            "n [m^-3]",
        )
        waves=_read_complex(file["basis"], "effective_wavefunctions")
        line(
            "wavefunctions",
            z,
            [("state $(i)", real.(waves[:, i])) for i in axes(waves, 2)],
            "Effective wavefunctions",
            "z [nm]",
            "amplitude [nm^-1/2]",
        )
        populations=real.(diag(_read_complex(file["basis"], "sheet_density_matrix_per_m2")))
        line(
            "populations",
            collect(1:length(populations)),
            [("population", populations)],
            "Localized state populations",
            "state",
            "sheet density [m^-2]",
        )
        for (id, dataset, x, y, xlabel, ylabel, unit, transpose) in (
            ("spectral", "spectral", energy, k, "Energy", "Momentum", "eV^-1", true),
            (
                "occupied-spectral",
                "occupied_spectral",
                energy,
                k,
                "Energy",
                "Momentum",
                "eV^-1",
                true,
            ),
            (
                "energy-density",
                "spatial_energy_density",
                z,
                energy,
                "Position",
                "Energy",
                "m^-3/eV",
                false,
            ),
        )
            values=_read_array(file["observables"], dataset)
            rows=transpose ? [values[:, i] for i in axes(values, 2)] :
                 [values[i, :] for i in axes(values, 1)]
            spec=Dict(
                "title"=>id,
                "x"=>Dict("label"=>xlabel, "unit"=>transpose ? "eV" : "nm"),
                "y"=>Dict("label"=>ylabel, "unit"=>transpose ? "nm^-1" : "eV"),
                "heatmap"=>Dict(
                    "x"=>x,
                    "y"=>y,
                    "values"=>rows,
                    "unit"=>unit,
                    "quality"=>quality,
                ),
            )
            target=joinpath(output_directory, id*".svg")
            _scientific_heatmap_svg(target, spec)
            push!(paths, abspath(target))
        end
    end
    return paths
end


function _recompute_optics(rows, root, output, photon_energies)
    all(energy->isfinite(energy) && energy>0u"eV", photon_energies) ||
        throw(ArgumentError("photon energies must be finite and positive"))
    plan=load_scientific_plan(joinpath(root, "scientific_plan.json"))
    execution_map=Dict(e.id=>e for e in plan.executions)
    result=Any[]
    for point in rows
        path=get(point["data"], "full_state", nothing)
        path===nothing && throw(
            ArgumentError(
                "point $(point["id"]) has no full_state; arbitrary optical grid requires full Green matrices, basis and grids",
            ),
        )
        execution=execution_map[point["execution_id"]]
        config=execution.configuration
        actual_inputs=replace(
            relpath(
                joinpath(dirname(_result_path(root, path)), "resolved_configuration.json"),
                root,
            ),
            '\\'=>'/',
        )
        if actual_inputs!==nothing
            raw=_mapping_input(
                load_resolved_configuration_envelope(_result_path(root, actual_inputs)),
                "state configuration",
            )
            config=_resolve_configuration(
                raw,
                ConfigurationProvenance(String[], String[], Dict{String,Vector{String}}()),
            )
        end
        built=build_configured_problem(config)
        coordinates=point["coordinates"]
        problem=retarget_problem(
            built.problem;
            V_period = coordinates["voltage_per_period_V"]*u"V",
            Tᴸ = coordinates["temperature_K"]*u"K",
            Tᴸᴼ = coordinates["temperature_K"]*u"K",
            energy_shift = config.algorithms.energy_shift,
        )
        saved=load_production_restart(
            _result_path(root, path),
            problem;
            algorithms = config.algorithms,
            solver_options = config.solver,
        )
        response=bare_bubble_optical_response(
            problem,
            saved.scba.green,
            photon_energies;
            edge_tolerance = config.study.optical_edge_tolerance,
        )
        destination=joinpath(output, "optical-"*point["id"]*".h5")
        save_optical_physics(
            destination,
            response;
            source_sha256 = bytes2hex(open(sha256, _result_path(root, path))),
        )
        peak=peak_gain(response)
        push!(
            result,
            Dict(
                "point_id"=>point["id"],
                "stationary_quality"=>point["quality"],
                "photon_energy_eV"=>Float64.(ustrip.(u"eV", photon_energies)),
                "optical_hdf5"=>relpath(destination, output),
                "gain_peak_per_cm"=>Float64(ustrip(u"cm^-1", peak.gain)),
                "initial_data_sha256"=>bytes2hex(open(sha256, _result_path(root, path))),
            ),
        )
    end
    return result
end

_finite_scientific_value(value::AbstractDict) =
    Dict{String,Any}(String(k)=>_finite_scientific_value(v) for (k, v) in value)
_finite_scientific_value(value::AbstractVector) =
    [_finite_scientific_value(v) for v in value]
_finite_scientific_value(value::AbstractFloat) = isfinite(value) ? value : nothing
_finite_scientific_value(value) = value
