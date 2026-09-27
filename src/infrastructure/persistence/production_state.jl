# Optional production checkpoint and summary persistence adapter.

function _atomic_checkpoint(path::AbstractString, solution::NEGFSolution)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary, stream = mktemp(directory)
    close(stream)
    try
        save_checkpoint(temporary, solution; include_kernels = false)
        _atomic_replace_file(temporary, path)
        _sync_artifact_directory(directory)
    catch
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return path
end

function _read_restart_family(parent, name::AbstractString)
    group = parent[name]
    family = SelfEnergyFamily(
        _read_complex(group, "SR"),
        _read_complex(group, "SL"),
        _read_complex(group, "SG"),
    )
    all(component -> all(isfinite, component), (family.Σᴿ, family.Σˡ, family.Σᵍ)) ||
        throw(ArgumentError("restart self-energy family $name contains non-finite values"))
    return family
end

struct _ProductionRestartMismatch <: Exception
    message::String
end

Base.showerror(io::IO, error::_ProductionRestartMismatch) = print(io, error.message)

_restart_mismatch(message::AbstractString) =
    throw(_ProductionRestartMismatch(String(message)))

function _require_restart_equal(label::AbstractString, actual, expected)
    actual == expected ||
        _restart_mismatch("restart $label mismatch: stored=$actual, expected=$expected")
end

function _require_restart_close(label::AbstractString, actual::Real, expected::Real)
    a, b = Float64(actual), Float64(expected)
    isfinite(a) && isfinite(b) ||
        throw(ArgumentError("restart $label contains a non-finite value"))
    scale = max(abs(a), abs(b), floatmin(Float64))
    abs(a - b) ≤ 256eps(Float64) * scale ||
        _restart_mismatch("restart $label mismatch: stored=$actual, expected=$expected")
end

function _require_restart_fraction(numerical, dataset::AbstractString)
    haskey(numerical, dataset) ||
        throw(ArgumentError("restart is missing required numerical_inputs/$dataset"))
    stored = read(numerical[dataset])
    stored isa Real ||
        throw(ArgumentError("restart numerical_inputs/$dataset must be a real scalar"))
    value = Float64(stored)
    isfinite(value) || throw(
        ArgumentError("restart numerical_inputs/$dataset contains a non-finite value"),
    )
    0 < value < 1 ||
        throw(ArgumentError("restart numerical_inputs/$dataset must lie in (0,1)"))
    return value
end

function _require_restart_array_close(label::AbstractString, actual, expected)
    size(actual) == size(expected) || _restart_mismatch(
        "restart $label shape mismatch: stored=$(size(actual)), " *
        "expected=$(size(expected))",
    )
    all(isfinite, actual) ||
        throw(ArgumentError("restart $label contains non-finite values"))
    isempty(actual) && return nothing
    scale = max(maximum(abs, actual), maximum(abs, expected), floatmin(Float64))
    maximum(abs, actual .- expected) ≤ 512eps(Float64) * scale ||
        _restart_mismatch("restart $label values differ from problem")
    return nothing
end

function _require_restart_array_equal(label::AbstractString, actual, expected)
    size(actual) == size(expected) || _restart_mismatch("restart $label shape mismatch")
    actual == expected || _restart_mismatch("restart $label values differ from problem")
    return nothing
end

function _validate_restart_metadata(file, problem::NEGFProblem)
    identity = _checkpoint_identity(file)
    identity.package == _CHECKPOINT_PACKAGE || _restart_mismatch(
        "unsupported restart package $(identity.package) " *
        "(expected $(_CHECKPOINT_PACKAGE))",
    )
    identity.schema == _CHECKPOINT_SCHEMA_VERSION || _restart_mismatch(
        "unsupported restart schema $(identity.schema) " *
        "(expected $(_CHECKPOINT_SCHEMA_VERSION))",
    )
    _require_native_metadata(file, ("qcl-negf-checkpoint-v4", "qcl-negf-physics-v4"))
    haskey(file, "convergence") ||
        throw(ArgumentError("native v4 requires convergence history"))
    _require_native_scba_tables(file["convergence"])
    model_metadata=file["metadata"]
    haskey(model_metadata, "physical_models_identity_yaml") ||
        _restart_mismatch("native v4 checkpoint lacks required physical model identity")
    stored_models=YAML.load(
        String(read(model_metadata["physical_models_identity_yaml"]));
        dicttype = Dict{String,Any},
    )
    expected_models=YAML.load(
        YAML.write(
            Dict(String(k)=>v for (k, v) in pairs(physical_model_identity(problem.models))),
        );
        dicttype = Dict{String,Any},
    )
    _require_restart_equal("physical model identity", stored_models, expected_models)
    numerical = file["numerical_inputs"]
    haskey(attributes(numerical), "energy_shift_discretization") || _restart_mismatch(
        "checkpoint has no energy-shift discretization identity; start a new run",
    )
    _require_restart_equal(
        "energy-shift discretization",
        Symbol(String(read_attribute(numerical, "energy_shift_discretization"))),
        problem.energy_shift_discretization,
    )
    for dataset in ("energy_tail_window_fraction", "momentum_tail_window_fraction")
        _require_restart_fraction(numerical, dataset)
    end
    n = problem.numerical
    _require_restart_equal("N_z", Int(read(numerical["Nz"])), n.N_z)
    _require_restart_equal("N_E", Int(read(numerical["NE"])), n.N_E)
    _require_restart_equal("N_k", Int(read(numerical["Nk"])), n.N_k)
    _require_restart_equal("N_b", Int(read(numerical["Nb"])), n.N_b)
    _require_restart_equal("P_basis", Int(read(numerical["P_basis"])), n.P_basis)
    for (label, dataset, expected) in (
        ("E_min", "E_min_eV", _electronvolts(n.E_min)),
        ("E_max", "E_max_eV", _electronvolts(n.E_max)),
        ("M_E", "M_E_eV", _electronvolts(n.M_E)),
        ("k_max", "k_max_per_m", _inverse_metres(n.k_max)),
        ("qz_max", "qz_max_per_m", _inverse_metres(n.qz_max)),
        ("eta_seed", "eta_seed_eV", _electronvolts(n.η_seed)),
    )
        _require_restart_close(label, Float64(read(numerical[dataset])), expected)
    end
    for (label, dataset, expected) in (("N_phi", "Nphi", n.N_φ), ("N_qz", "Nqz", n.N_qz))
        _require_restart_equal(label, Int(read(numerical[dataset])), expected)
    end
    for name in fieldnames(ScatteringOptions)
        stored = Bool(read(numerical["scattering_$(String(name))"]))
        _require_restart_equal(
            "scattering $name",
            stored,
            getfield(problem.scattering, name),
        )
    end

    inputs = file["inputs"]
    p = problem.physical
    expected_voltage = Float64(ustrip(u"V", uconvert(u"V", p.F_bias * period_length(p))))
    _require_restart_close(
        "voltage per period",
        Float64(read(inputs["V_period_V"])),
        expected_voltage,
    )
    for (label, dataset, expected) in (
        ("field", "F_bias_V_per_m", _volts_per_metre(p.F_bias)),
        ("sheet doping", "N_dop_2D_per_m2", _per_square_metre(p.N_dop²ᴰ)),
        ("ionization", "f_ion", p.f_ion),
        ("coordinate origin", "z0_m", _metres(p.z₀)),
        ("energy reference", "E_ref_eV", _electronvolts(p.E_ref)),
        ("static permittivity", "epsilon_static_relative", p.ε_s),
        ("infinite-frequency permittivity", "epsilon_infinity_relative", p.ε_∞),
        ("LO energy", "hbar_omega_LO_eV", _electronvolts(p.ħωᴸᴼ)),
        ("screening", "q_screen_per_m", _inverse_metres(p.q_s)),
        ("LO screening", "q_LO_screen_per_m", _inverse_metres(p.qᴸᴼ_s)),
        ("IFR height", "Delta_IFR_m", _metres(p.Δᴵᶠᴿ)),
        ("IFR length", "Lambda_IFR_m", _metres(p.Λᴵᶠᴿ)),
        ("deformation potential", "Xi_eV", _electronvolts(p.Ξ)),
        ("mass density", "rho_m_kg_per_m3", Float64(ustrip(u"kg/m^3", p.ρ_m))),
        ("sound speed", "v_s_m_per_s", Float64(ustrip(u"m/s", p.v_s))),
    )
        _require_restart_close(label, Float64(read(inputs[dataset])), expected)
    end
    _require_restart_close(
        "lattice temperature",
        Float64(read(inputs["T_L_K"])),
        _kelvin(p.Tᴸ),
    )
    _require_restart_close(
        "LO temperature",
        Float64(read(inputs["T_LO_K"])),
        _kelvin(p.Tᴸᴼ),
    )
    _require_restart_equal("spin degeneracy", Int(read(inputs["spin_degeneracy"])), p.g_s)
    _require_restart_equal(
        "alloy switch",
        Bool(read_attribute(inputs, "alloy_enabled")),
        problem.scattering.alloy,
    )
    layer_arrays = (
        ("layer thickness", "layer_thickness_m", _metres.([x.d for x in p.layers])),
        ("layer Ec", "layer_Ec_eV", _electronvolts.([x.Eᶜ for x in p.layers])),
        ("layer mz", "layer_mz_relative", [x.mᶻᵣ for x in p.layers]),
        ("layer mparallel", "layer_mparallel_relative", [x.m_parallelᵣ for x in p.layers]),
        ("layer epsilon", "layer_epsilon_relative", [x.εᵣ for x in p.layers]),
        ("layer xAl", "layer_x_Al", [x.x_Al for x in p.layers]),
        ("interfaces", "interface_m", _metres.(p.interfaces)),
    )
    for (label, dataset, expected) in layer_arrays
        _require_restart_array_close(label, read(inputs[dataset]), expected)
    end
    _require_restart_array_equal(
        "layer doping flags",
        read(inputs["layer_doped"]),
        Int8[x.doped for x in p.layers],
    )
    if problem.scattering.alloy
        p.ΔV_alloy === nothing &&
            throw(ArgumentError("alloy restart requires DeltaV_alloy"))
        p.Ω₀ === nothing && throw(ArgumentError("alloy restart requires Omega0"))
        _require_restart_close(
            "alloy potential",
            Float64(read(inputs["DeltaV_alloy_eV"])),
            _electronvolts(p.ΔV_alloy),
        )
        _require_restart_close(
            "alloy volume",
            Float64(read(inputs["Omega0_m3"])),
            Float64(ustrip(u"m^3", p.Ω₀)),
        )
    end

    scales = file["scales"]
    _require_restart_close("E₀", Float64(read(scales["E0_eV"])), problem.scales.E₀_eV)
    _require_restart_close("L₀", Float64(read(scales["L0_m"])), problem.scales.L₀_m)
    _require_restart_close(
        "Poisson scale",
        Float64(read(scales["lambda_P"])),
        problem.scales.λ_P,
    )
    _require_restart_close(
        "current scale",
        Float64(read(scales["J0_A_per_m2"])),
        Float64(ustrip(u"A/m^2", problem.scales.J₀)),
    )
    _require_restart_close(
        "mass scale",
        Float64(read(scales["m_ref_kg"])),
        Float64(ustrip(u"kg", problem.scales.m_ref)),
    )

    grids = file["grids_dimensionless"]
    for (label, dataset, expected) in (
        ("x grid", "x", problem.grids.x),
        ("x weights", "wx", problem.grids.wˣ),
        ("energy grid", "energy", problem.grids.ε),
        ("energy weights", "wE", problem.grids.wᴱ),
        ("k grid", "k", problem.grids.κ),
        ("k weights", "wk", problem.grids.wᵏ),
        ("qz grid", "qz", problem.grids.qᶻ),
        ("qz weights", "wqz", problem.grids.wᑫᶻ),
    )
        _require_restart_array_close(label, read(grids[dataset]), expected)
    end
    _require_restart_array_equal(
        "trusted energy mask",
        read(grids["trusted_energy"]),
        Int8.(problem.grids.trusted_energy),
    )

    profiles = file["profiles_dimensionless"]
    for (label, dataset, expected) in (
        ("Ec profile", "Ec", problem.profiles.Eᶜ),
        ("mz profile", "mz_relative", problem.profiles.mᶻᵣ),
        ("mparallel profile", "mparallel_relative", problem.profiles.m_parallelᵣ),
        ("epsilon profile", "epsilon_relative", problem.profiles.εᵣ),
        ("donor profile", "ND", problem.profiles.Nᴰ),
        ("xAl profile", "x_Al", problem.profiles.x_Al),
    )
        _require_restart_array_close(label, read(profiles[dataset]), expected)
    end
    _require_restart_array_equal(
        "layer-index profile",
        read(profiles["layer_index"]),
        problem.profiles.layer_index,
    )

    basis = file["basis_dimensionless"]
    stored_localization = Symbol(String(read_attribute(basis, "localization")))
    _require_restart_equal(
        "basis localization",
        stored_localization,
        problem.basis.localization,
    )
    for (label, dataset, expected) in (
        ("basis H0", "H0", problem.basis.H₀),
        ("basis Z", "Z", problem.basis.Z),
        ("basis Tplus", "Tplus", problem.basis.T₊),
        ("basis Tminus", "Tminus", problem.basis.T₋),
    )
        _require_restart_array_close(label, _read_complex(basis, dataset), expected)
    end
    selfenergy = file["selfenergy_dimensionless"]
    stored_mechanisms = Set(
        Symbol(String(name)) for
        name in keys(selfenergy) if !startswith(String(name), "embedding_")
    )
    expected_mechanisms = Set(problem.kernels.enabled)
    stored_mechanisms == expected_mechanisms || _restart_mismatch(
        "restart mechanisms mismatch: stored=$(sort!(collect(stored_mechanisms); by=String)), " *
        "expected=$(sort!(collect(expected_mechanisms); by=String))",
    )
    return nothing
end

function _load_production_restart(
    path::AbstractString,
    problem::NEGFProblem;
    algorithms::Union{Nothing,AlgorithmOptions} = nothing,
    solver_options::Union{Nothing,SolverOptions} = nothing,
)
    return h5open(path, "r") do file
        _validate_restart_metadata(file, problem)
        metadata = file["metadata"]
        String(read_attribute(metadata, "package_version")) == _software_version() ||
            _restart_mismatch("exact restart requires the same package version")
        haskey(metadata, "restart_contract_yaml") || _restart_mismatch(
            "checkpoint lacks the required exact numerical restart contract; start a new run",
        )
        contract = YAML.load(
            String(read(metadata["restart_contract_yaml"]));
            dicttype = Dict{String,Any},
        )
        contract isa Dict{String,Any} &&
        get(contract, "schema", nothing)=="qcl-negf-exact-restart-v1" ||
            throw(ArgumentError("invalid exact restart contract"))
        haskey(metadata, "kernel_identity_yaml") ||
            _restart_mismatch("checkpoint lacks the exact scattering-operator identity")
        kernel_identity = YAML.load(
            String(read(metadata["kernel_identity_yaml"]));
            dicttype = Dict{String,Any},
        )
        kernel_identity == _checkpoint_kernel_identity(problem.kernels) ||
            _restart_mismatch("restart scattering operators differ (Khat, qK, or F_LO)")
        if algorithms !== nothing
            get(contract, "algorithms", nothing) == _restart_contract_value(algorithms) ||
                _restart_mismatch(
                    "restart algorithm contract differs from requested algorithms",
                )
        end
        if solver_options !== nothing
            get(contract, "solver", nothing) == _solver_restart_contract(
                solver_options,
                algorithms === nothing ? AlgorithmOptions() : algorithms,
            )["solver"] || _restart_mismatch(
                "restart mixing/quality policy differs from requested solver options",
            )
        end
        state = file["state_dimensionless"]
        shape = (
            problem.numerical.N_E,
            problem.numerical.N_k,
            problem.numerical.N_b,
            problem.numerical.N_b,
        )
        Gᴿ = _read_complex(state, "GR")
        Gˡ = _read_complex(state, "GL")
        Gᵍ = _read_complex(state, "GG")
        A = _read_complex(state, "A")
        all(size(X) == shape for X in (Gᴿ, Gˡ, Gᵍ, A)) ||
            throw(DimensionMismatch("restart Green arrays differ from problem"))
        all(X -> all(isfinite, X), (Gᴿ, Gˡ, Gᵍ, A)) ||
            throw(ArgumentError("restart Green arrays contain non-finite values"))
        condition_number = _read_array(state, "condition_number")
        dyson_scale = _read_array(state, "dyson_scale")
        size(condition_number) ==
        (problem.numerical.N_E, problem.numerical.N_k) ==
        size(dyson_scale) ||
            throw(DimensionMismatch("restart Dyson diagnostics differ from problem"))
        all(isfinite, condition_number) && all(isfinite, dyson_scale) ||
            throw(ArgumentError("restart Dyson diagnostics are non-finite"))
        green = GreenState(Gᴿ, Gˡ, Gᵍ, A, condition_number, dyson_scale)
        parent = file["selfenergy_dimensionless"]
        scattering = Dict{Symbol,SelfEnergyFamily}()
        for name in problem.kernels.enabled
            haskey(parent, String(name)) ||
                throw(ArgumentError("restart is missing mechanism $name"))
            scattering[name] = _read_restart_family(parent, String(name))
        end
        plus = _read_restart_family(parent, "embedding_plus")
        minus = _read_restart_family(parent, "embedding_minus")
        embedding = _read_restart_family(parent, "embedding_total")
        all(
            size(getfield(family, component)) == shape for
            family in (values(scattering)..., embedding, plus, minus) for
            component in (:Σᴿ, :Σˡ, :Σᵍ)
        ) || throw(DimensionMismatch("restart self-energy arrays differ"))
        # Checkpoint histories are logical progress, not the age of this process.
        convergence = file["convergence"]
        scba_rows = _read_array(convergence, "scba")
        size(scba_rows, 2) == 18 || throw(
            ArgumentError("native v4 SCBA checkpoint history requires exactly 18 columns"),
        )
        history = SCBAIteration[
            SCBAIteration(
                Int(row[1]),
                Float64.(row[2:13])...,
                Float64.(row[15:18])...,
                nothing,
                nothing,
            ) for row in eachrow(scba_rows)
        ]
        witnesses = _read_psd_history(convergence, length(history))
        physical_markers = _read_physical_markers(convergence, length(history))
        history = SCBAIteration[
            SCBAIteration(
                (getfield(row, field) for field in fieldnames(SCBAIteration)[1:17])...,
                witnesses[index],
                physical_markers[index],
            ) for (index, row) in enumerate(history)
        ]
        all(i -> history[i].ν == i, eachindex(history)) ||
            throw(ArgumentError("SCBA checkpoint history is not contiguous"))
        outer_rows = _read_array(convergence, "outer")
        populations = _read_array(convergence, "outer_populations")
        density = _read_array(convergence, "outer_density")
        outer_history = OuterIteration[
            OuterIteration(
                Int(row[1]),
                Float64.(row[2:10])...,
                Float64.(vec(populations[i, :])),
                Float64.(vec(density[i, :])),
            ) for (i, row) in enumerate(eachrow(outer_rows))
        ]
        all(i -> outer_history[i].μ == i, eachindex(outer_history)) ||
            throw(ArgumentError("Poisson checkpoint history is not contiguous"))
        stored_status = Symbol(String(read_attribute(file["metadata"], "status")))
        stored_quality = Symbol(String(read_attribute(file["metadata"], "scba_quality")))
        haskey(file, "algorithm_state") ||
            throw(ArgumentError("checkpoint lacks algorithm state"))
        algorithm = file["algorithm_state"]
        method = Symbol(String(read_attribute(algorithm, "method")))
        count = Int(read_attribute(algorithm, "history_count"))
        families_count = length(problem.kernels.enabled)+2
        expected_order = join(
            [String.(problem.kernels.enabled); "embedding_plus"; "embedding_minus"],
            ",",
        )
        String(read_attribute(algorithm, "family_order")) == expected_order ||
            throw(ArgumentError("checkpoint mixer family order differs"))
        read_history(kind) = [
            SelfEnergyFamily[
                _read_restart_family(algorithm[kind][string(i)], string(j)) for
                j = 1:families_count
            ] for i = 1:count
        ]
        mixer = SCBAMixerState(method, read_history("states"), read_history("residuals"))
        all(
            size(getfield(family, component)) == shape for
            rows in (mixer.states, mixer.residuals) for families in rows for
            family in families for component in (:Σᴿ, :Σˡ, :Σᵍ)
        ) || throw(DimensionMismatch("checkpoint mixer array shape differs"))
        scba = SCBAResult(
            green,
            scattering,
            embedding,
            plus,
            minus,
            history,
            false,
            :restart,
            stored_quality === :strictly_converged ? :unresolved : stored_quality,
            contract,
            mixer,
        )
        Uᴴ = Float64.(read(state["UH"]))
        length(Uᴴ) == problem.numerical.N_z ||
            throw(DimensionMismatch("restart Hartree field differs from problem"))
        all(isfinite, Uᴴ) ||
            throw(ArgumentError("restart Hartree field contains non-finite values"))
        metadata=file["metadata"]
        for name in ("warnings_json", "adaptation_checkpoint_json")
            haskey(metadata, name) ||
                throw(ArgumentError("native v4 recovery requires metadata/$name"))
        end
        warning_data=YAML.load(
            String(read(metadata["warnings_json"]));
            dicttype = Dict{String,Any},
        )
        warning_data isa AbstractVector ||
            throw(ArgumentError("checkpoint warnings must be an array"))
        warnings=Dict{String,Any}[Dict{String,Any}(warning) for warning in warning_data]
        adaptation = YAML.load(
            String(read(metadata["adaptation_checkpoint_json"]));
            dicttype = Dict{String,Any},
        )
        return (;
            Uᴴ,
            scba,
            outer_history,
            warnings,
            adaptation,
            status = stored_status,
            original_scba_status = Symbol(String(read_attribute(metadata, "scba_status"))),
            original_scba_converged = Bool(read_attribute(metadata, "scba_converged")),
            original_scba_quality = stored_quality,
            resume_scba = !(stored_status in (:running, :snapshot)),
            completed = stored_status in (:converged, :approximate),
        )
    end
end

function _quarantine_production_restart(path::AbstractString)
    absolute = abspath(path)
    stem, extension = splitext(absolute)
    token = "$(getpid()).$(time_ns())"
    suffix = 0
    while true
        discriminator = suffix == 0 ? token : "$token.$suffix"
        candidate = "$stem.incompatible.$discriminator$extension"
        try
            mv(absolute, candidate; force = false)
            return candidate
        catch error
            if ispath(candidate) && isfile(absolute)
                suffix += 1
                continue
            end
            rethrow(error)
        end
    end
end

"""
    load_production_restart(path, problem; incompatible=:error)

Load the full Green/self-energy state needed for a warm restart.  The caller
must provide the already rebuilt problem; exact array shapes and mechanism
names and saved histories are checked. Same-stage linear restart restores
logical iteration counts and consumes only the remaining budget. Anderson state and residual histories are serialized at the accepted boundary;
restart replays the next mixing step with the restored history.

`incompatible=:error` (the default) preserves strict loading and throws an
`ArgumentError` for a metadata-incompatible checkpoint.  `:ignore` emits a
warning and returns `nothing`.  `:quarantine` moves the incompatible file
beside the original under a collision-safe `.incompatible.*` name, emits
a warning containing both paths, and returns `nothing`.  Malformed HDF5,
missing datasets, non-finite state arrays, and all other errors remain fatal in
every mode; these indicate corruption or an implementation error rather than
a reusable checkpoint from a different discretization.

See [Production sweep and recovery](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md) and the
[HDF5 checkpoint schema](@ref native-result-formats).
"""
function load_production_restart(
    path::AbstractString,
    problem::NEGFProblem;
    incompatible::Symbol = :error,
    algorithms::Union{Nothing,AlgorithmOptions} = nothing,
    solver_options::Union{Nothing,SolverOptions} = nothing,
)
    incompatible in (:error, :ignore, :quarantine) ||
        throw(ArgumentError("incompatible must be :error, :ignore, or :quarantine"))
    try
        return _load_production_restart(path, problem; algorithms, solver_options)
    catch error
        error isa _ProductionRestartMismatch || rethrow(error)
        message = error.message
        incompatible === :error && throw(ArgumentError(message))
        if incompatible === :ignore
            @warn "ignoring metadata-incompatible production checkpoint; starting fresh" checkpoint=abspath(
                path,
            ) reason=message
        else
            quarantined = _quarantine_production_restart(path)
            @warn "quarantined metadata-incompatible production checkpoint; starting fresh" checkpoint=abspath(
                path,
            ) quarantined reason=message
        end
        return nothing
    end
end

function _csv_field(value)
    text = string(value)
    return occursin(r"[,\"\n\r]", text) ? "\"" * replace(text, "\"" => "\"\"") * "\"" : text
end

"""
Atomically write a language-neutral CSV sweep summary.

See [Production plots and saved data](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md).
"""
function save_production_summary(path::AbstractString, result::ProductionSweepResult)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary, stream = mktemp(directory)
    try
        metric_set = Set{Symbol}()
        for record in result.records
            union!(metric_set, keys(record.metrics))
        end
        metric_names = sort!(collect(metric_set); by = String)
        header = String[
            "temperature_K",
            "voltage_per_period_V",
            "field_V_per_m",
            "current_A_per_m2",
            "converged",
            "status",
            "scba_quality",
            "outer_iterations",
            "final_scba_iterations",
            "estimated_peak_bytes",
            "wall_seconds",
            "checkpoint",
            "quality",
            "warning_count",
            "warnings_json",
        ]
        append!(header, ["metric_$(String(name))" for name in metric_names])
        println(stream, join(header, ','))
        for record in result.records
            values = Any[
                record.temperature_K,
                record.voltage_per_period_V,
                record.field_V_per_m,
                record.current_A_per_m2,
                record.converged,
                record.status,
                record.scba_quality,
                record.outer_iterations,
                record.final_scba_iterations,
                record.estimated_peak_bytes,
                record.wall_seconds,
                record.checkpoint,
                record.converged ? "strict" :
                record.scba_quality === :invalid ? "invalid" :
                record.status === :approximate ? "approximate" : "unconverged",
                length(record.warnings),
                sprint(_light_json, record.warnings),
            ]
            append!(values, [get(record.metrics, name, "") for name in metric_names])
            println(stream, join(_csv_field.(values), ','))
        end
        close(stream)
        _atomic_replace_file(temporary, path)
    catch
        isopen(stream) && close(stream)
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
    return path
end
