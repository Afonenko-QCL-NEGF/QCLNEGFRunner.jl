function _string_keyed_yaml(value, path::AbstractString)
    if value isa AbstractDict
        result = Dict{String,Any}()
        for (key, child) in value
            key isa AbstractString ||
                _configuration_error(path, "mapping keys must be strings, got $(repr(key))")
            skey = String(key)
            haskey(result, skey) &&
                _configuration_error(path, "duplicate mapping key $(repr(skey))")
            child_path = isempty(path) ? skey : string(path, '.', skey)
            result[skey] = _string_keyed_yaml(child, child_path)
        end
        return result
    elseif value isa AbstractVector
        return Any[
            _string_keyed_yaml(child, string(path, '[', index, ']')) for
            (index, child) in pairs(value)
        ]
    end
    return value
end

function _load_yaml_mapping(path::AbstractString)
    isfile(path) || _configuration_error(path, "file does not exist")
    strict_mapping =
        (constructor, node) -> YAML.construct_mapping(
            Dict{Any,Any},
            constructor,
            node;
            strict_unique_keys = true,
        )
    parsed = try
        YAML.load_file(path, Dict("tag:yaml.org,2002:map" => strict_mapping))
    catch error
        _configuration_error(path, "invalid YAML: $(sprint(showerror, error))")
    end
    parsed isa AbstractDict ||
        _configuration_error(path, "top-level YAML value must be a mapping")
    return _string_keyed_yaml(parsed, "")
end

function _expect_keys(
    mapping::Dict{String,Any},
    path::AbstractString;
    required::Tuple = (),
    optional::Tuple = (),
)
    allowed = Set{String}((String(key) for key in (required..., optional...)))
    unknown = sort!(collect(setdiff(Set(keys(mapping)), allowed)))
    isempty(unknown) || _configuration_error(path, "unknown key(s): $(join(unknown, ", "))")
    missing = sort!(collect(setdiff(Set(String.(required)), Set(keys(mapping)))))
    isempty(missing) ||
        _configuration_error(path, "missing required key(s): $(join(missing, ", "))")
    return mapping
end

function _mapping(value, path)
    value isa Dict{String,Any} ||
        _configuration_error(path, "expected a mapping, got $(typeof(value))")
    return value
end

function _array(value, path)
    value isa AbstractVector ||
        _configuration_error(path, "expected an array, got $(typeof(value))")
    return value
end

function _string(value, path; nonempty::Bool = true)
    value isa AbstractString ||
        _configuration_error(path, "expected a string, got $(typeof(value))")
    result = String(value)
    nonempty &&
        isempty(strip(result)) &&
        _configuration_error(path, "string cannot be empty")
    return result
end

function _bool(value, path)
    value isa Bool || _configuration_error(path, "expected a Boolean, got $(typeof(value))")
    return value
end

function _integer(value, path; minimum = nothing, maximum = nothing)
    value isa Integer && !(value isa Bool) ||
        _configuration_error(path, "expected an integer, got $(typeof(value))")
    result = try
        Int(value)
    catch
        _configuration_error(path, "integer is outside the machine range")
    end
    minimum !== nothing &&
        result < minimum &&
        _configuration_error(path, "must be at least $minimum")
    maximum !== nothing &&
        result > maximum &&
        _configuration_error(path, "must not exceed $maximum")
    return result
end

function _real(
    value,
    path;
    minimum = nothing,
    maximum = nothing,
    minimum_open::Bool = false,
    maximum_open::Bool = false,
)
    value isa Real && !(value isa Bool) ||
        _configuration_error(path, "expected a real number, got $(typeof(value))")
    result = Float64(value)
    isfinite(result) || _configuration_error(path, "must be finite")
    if minimum !== nothing
        invalid = minimum_open ? result <= minimum : result < minimum
        invalid && _configuration_error(
            path,
            minimum_open ? "must be greater than $minimum" : "must be at least $minimum",
        )
    end
    if maximum !== nothing
        invalid = maximum_open ? result >= maximum : result > maximum
        invalid && _configuration_error(
            path,
            maximum_open ? "must be smaller than $maximum" : "must not exceed $maximum",
        )
    end
    return result
end

function _choice(value, path, allowed::Tuple)
    text = _string(value, path)
    result = Symbol(text)
    result in allowed || _configuration_error(
        path,
        "must be one of $(join(string.(allowed), ", ")), got $(repr(text))",
    )
    return result
end

const _QUANTITY_PATTERN =
    r"^\s*([+-]?(?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:[eE][+-]?\d+)?)\s+(.+?)\s*$"

function _untyped_quantity(value, path)
    magnitude = nothing
    unit_text = nothing
    if value isa AbstractString
        matched = match(_QUANTITY_PATTERN, String(value))
        matched === nothing && _configuration_error(
            path,
            "quantity must have the form \"number unit\", for example \"3.26 nm\"",
        )
        magnitude = tryparse(Float64, matched.captures[1])
        unit_text = matched.captures[2]
    elseif value isa Dict{String,Any}
        _expect_keys(value, path; required = ("value", "unit"))
        magnitude = _real(value["value"], string(path, ".value"))
        unit_text = _string(value["unit"], string(path, ".unit"))
    else
        _configuration_error(
            path,
            "quantity must be a \"number unit\" string or {value, unit} mapping",
        )
    end
    magnitude !== nothing && isfinite(magnitude) ||
        _configuration_error(path, "quantity magnitude must be finite")
    unit = try
        Unitful.uparse(unit_text)
    catch error
        _configuration_error(
            path,
            "invalid or unsupported unit $(repr(unit_text)): $(sprint(showerror, error))",
        )
    end
    return magnitude * unit
end

function _quantity(value, path, converter::Function)
    quantity = _untyped_quantity(value, path)
    return try
        converter(quantity)
    catch error
        _configuration_error(path, "wrong physical dimension: $(sprint(showerror, error))")
    end
end

_length_configuration(value, path) = _quantity(value, path, _length)
_energy_configuration(value, path) = _quantity(value, path, _energy)
_temperature_configuration(value, path) = _quantity(value, path, _temperature)
_field_configuration(value, path) = _quantity(value, path, _field)
_wavenumber_configuration(value, path) = _quantity(value, path, _wavenumber)
_sheetdensity_configuration(value, path) = _quantity(value, path, _sheetdensity)
_massdensity_configuration(value, path) = _quantity(value, path, _massdensity)
_speed_configuration(value, path) = _quantity(value, path, _speed)
_volume_configuration(value, path) = _quantity(value, path, _volume)
_mass_configuration(value, path) = _quantity(value, path, _mass)

function _voltage_configuration(value, path)
    quantity = _untyped_quantity(value, path)
    return try
        Float64(ustrip(u"V", uconvert(u"V", quantity))) * u"V"
    catch error
        _configuration_error(path, "wrong physical dimension: $(sprint(showerror, error))")
    end
end

function _remove_provenance_subtree!(sources::Dict{String,Vector{String}}, path)
    prefix = string(path, '.')
    for key in collect(keys(sources))
        (key == path || startswith(key, prefix)) && delete!(sources, key)
    end
    return sources
end

function _deep_merge!(
    destination::Dict{String,Any},
    source::Dict{String,Any},
    provenance::Dict{String,Vector{String}},
    source_file::AbstractString,
    prefix::AbstractString = "",
)
    for (key, value) in source
        path = isempty(prefix) ? key : string(prefix, '.', key)
        if value isa Dict{String,Any} && get(destination, key, nothing) isa Dict{String,Any}
            _deep_merge!(destination[key], value, provenance, source_file, path)
        elseif value isa Dict{String,Any}
            _remove_provenance_subtree!(provenance, path)
            destination[key] = Dict{String,Any}()
            _deep_merge!(destination[key], value, provenance, source_file, path)
        else
            if get(destination, key, nothing) isa Dict{String,Any}
                _remove_provenance_subtree!(provenance, path)
            end
            destination[key] = deepcopy(value)
            push!(get!(provenance, path, String[]), abspath(source_file))
        end
    end
    return destination
end

function _parse_run(mapping)
    path = "run"
    _expect_keys(mapping, path; required = ("name", "description", "classification"))
    classification = _choice(
        mapping["classification"],
        "$path.classification",
        (
            :reference,
            :computationally_equivalent,
            :controlled_numerical,
            :physics_changing,
            :study,
        ),
    )
    return (
        _string(mapping["name"], "$path.name"),
        _string(mapping["description"], "$path.description"),
        classification,
    )
end

function _parse_layer(value, index)
    path = "physical.layers[$index]"
    layer = _mapping(value, path)
    _expect_keys(
        layer,
        path;
        required = (
            "thickness",
            "material",
            "aluminium_fraction",
            "conduction_band_edge",
            "longitudinal_relative_mass",
            "transverse_relative_mass",
            "relative_permittivity",
            "doped",
        ),
    )
    return try
        Layer(
            d = _length_configuration(layer["thickness"], "$path.thickness"),
            material = Symbol(_string(layer["material"], "$path.material")),
            x_Al = _real(
                layer["aluminium_fraction"],
                "$path.aluminium_fraction";
                minimum = 0.0,
                maximum = 1.0,
            ),
            Eᶜ = _energy_configuration(
                layer["conduction_band_edge"],
                "$path.conduction_band_edge",
            ),
            mᶻᵣ = _real(
                layer["longitudinal_relative_mass"],
                "$path.longitudinal_relative_mass";
                minimum = 0.0,
                minimum_open = true,
            ),
            m_parallelᵣ = _real(
                layer["transverse_relative_mass"],
                "$path.transverse_relative_mass";
                minimum = 0.0,
                minimum_open = true,
            ),
            εᵣ = _real(
                layer["relative_permittivity"],
                "$path.relative_permittivity";
                minimum = 0.0,
                minimum_open = true,
            ),
            doped = _bool(layer["doped"], "$path.doped"),
        )
    catch error
        error isa ConfigurationError && rethrow()
        _configuration_error(path, sprint(showerror, error))
    end
end

function _parse_physical(mapping)
    path = "physical"
    _expect_keys(
        mapping,
        path;
        required = (
            "layers",
            "interfaces",
            "donor_sheet_density",
            "ionization_fraction",
            "position_origin",
            "reference_energy",
            "lattice_temperature",
            "lo_temperature",
            "static_relative_permittivity",
            "high_frequency_relative_permittivity",
            "lo_phonon_energy",
            "impurity_screening_wavenumber",
            "lo_screening_wavenumber",
            "interface_roughness_height",
            "interface_correlation_length",
            "acoustic_deformation_potential",
            "mass_density",
            "sound_velocity",
            "spin_degeneracy",
        ),
        optional = (
            "voltage_per_period",
            "field_bias",
            "alloy_potential",
            "primitive_cell_volume",
        ),
    )

    layers_input = _array(mapping["layers"], "$path.layers")
    isempty(layers_input) &&
        _configuration_error("$path.layers", "at least one layer is required")
    layers = Layer[_parse_layer(value, index) for (index, value) in pairs(layers_input)]
    period = sum(layer.d for layer in layers)

    voltage_present =
        haskey(mapping, "voltage_per_period") && mapping["voltage_per_period"] !== nothing
    field_present = haskey(mapping, "field_bias") && mapping["field_bias"] !== nothing
    xor(voltage_present, field_present) || _configuration_error(
        path,
        "exactly one of voltage_per_period and field_bias must be non-null",
    )
    field = if voltage_present
        voltage = _voltage_configuration(
            mapping["voltage_per_period"],
            "$path.voltage_per_period",
        )
        try
            _field(uconvert(u"V/m", voltage / period))
        catch error
            _configuration_error("$path.voltage_per_period", sprint(showerror, error))
        end
    else
        _field_configuration(mapping["field_bias"], "$path.field_bias")
    end
    field ≥ 0u"V/m" ||
        _configuration_error(path, "the reference design sign convention requires a nonnegative field")

    interface_input = _array(mapping["interfaces"], "$path.interfaces")
    interfaces = LengthQuantity[
        _length_configuration(value, "$path.interfaces[$index]") for
        (index, value) in pairs(interface_input)
    ]
    issorted(interfaces) ||
        _configuration_error("$path.interfaces", "interface positions must be sorted")
    all(position -> 0u"m" ≤ position ≤ period, interfaces) || _configuration_error(
        "$path.interfaces",
        "interface positions must lie inside one period",
    )

    has_alloy = haskey(mapping, "alloy_potential") && mapping["alloy_potential"] !== nothing
    has_volume =
        haskey(mapping, "primitive_cell_volume") &&
        mapping["primitive_cell_volume"] !== nothing
    has_alloy == has_volume || _configuration_error(
        path,
        "alloy_potential and primitive_cell_volume must be supplied together",
    )
    alloy =
        has_alloy ?
        _energy_configuration(mapping["alloy_potential"], "$path.alloy_potential") : nothing
    volume =
        has_volume ?
        _volume_configuration(
            mapping["primitive_cell_volume"],
            "$path.primitive_cell_volume",
        ) : nothing

    donor_density = _sheetdensity_configuration(
        mapping["donor_sheet_density"],
        "$path.donor_sheet_density",
    )
    donor_density > 0u"m^-2" ||
        _configuration_error("$path.donor_sheet_density", "must be positive")
    ionization = _real(
        mapping["ionization_fraction"],
        "$path.ionization_fraction";
        minimum = 0.0,
        maximum = 1.0,
        minimum_open = true,
    )
    lattice_temperature = _temperature_configuration(
        mapping["lattice_temperature"],
        "$path.lattice_temperature",
    )
    lo_temperature =
        _temperature_configuration(mapping["lo_temperature"], "$path.lo_temperature")
    lattice_temperature > 0u"K" && lo_temperature > 0u"K" ||
        _configuration_error(path, "temperatures must be positive")
    static_permittivity = _real(
        mapping["static_relative_permittivity"],
        "$path.static_relative_permittivity";
        minimum = 0.0,
        minimum_open = true,
    )
    high_frequency_permittivity = _real(
        mapping["high_frequency_relative_permittivity"],
        "$path.high_frequency_relative_permittivity";
        minimum = 0.0,
        minimum_open = true,
    )
    high_frequency_permittivity < static_permittivity || _configuration_error(
        path,
        "high-frequency permittivity must be smaller than static permittivity",
    )
    lo_energy = _energy_configuration(mapping["lo_phonon_energy"], "$path.lo_phonon_energy")
    lo_energy > 0u"eV" || _configuration_error("$path.lo_phonon_energy", "must be positive")
    impurity_screening = _wavenumber_configuration(
        mapping["impurity_screening_wavenumber"],
        "$path.impurity_screening_wavenumber",
    )
    lo_screening = _wavenumber_configuration(
        mapping["lo_screening_wavenumber"],
        "$path.lo_screening_wavenumber",
    )
    impurity_screening > 0u"m^-1" && lo_screening > 0u"m^-1" ||
        _configuration_error(path, "screening wave numbers must be positive")
    roughness_height = _length_configuration(
        mapping["interface_roughness_height"],
        "$path.interface_roughness_height",
    )
    correlation_length = _length_configuration(
        mapping["interface_correlation_length"],
        "$path.interface_correlation_length",
    )
    roughness_height ≥ 0u"m" && correlation_length > 0u"m" || _configuration_error(
        path,
        "roughness height must be nonnegative and correlation length positive",
    )
    deformation = _energy_configuration(
        mapping["acoustic_deformation_potential"],
        "$path.acoustic_deformation_potential",
    )
    deformation > 0u"eV" ||
        _configuration_error("$path.acoustic_deformation_potential", "must be positive")
    mass_density = _massdensity_configuration(mapping["mass_density"], "$path.mass_density")
    sound_velocity = _speed_configuration(mapping["sound_velocity"], "$path.sound_velocity")
    mass_density > 0u"kg/m^3" && sound_velocity > 0u"m/s" ||
        _configuration_error(path, "mass density and sound velocity must be positive")

    return PhysicalParameters(
        layers,
        donor_density,
        ionization,
        field,
        _length_configuration(mapping["position_origin"], "$path.position_origin"),
        _energy_configuration(mapping["reference_energy"], "$path.reference_energy"),
        lattice_temperature,
        lo_temperature,
        static_permittivity,
        high_frequency_permittivity,
        lo_energy,
        impurity_screening,
        lo_screening,
        roughness_height,
        correlation_length,
        deformation,
        mass_density,
        sound_velocity,
        alloy,
        volume,
        _integer(mapping["spin_degeneracy"], "$path.spin_degeneracy"; minimum = 1),
        interfaces,
    )
end

function _parse_numerical(mapping)
    path = "numerical"
    _expect_keys(
        mapping,
        path;
        required = (
            "spatial_nodes",
            "basis_states",
            "basis_periods",
            "energy_min",
            "energy_max",
            "energy_nodes",
            "energy_trust_margin",
            "momentum_max",
            "momentum_nodes",
            "angular_nodes",
            "longitudinal_momentum_max",
            "longitudinal_momentum_nodes",
            "seed_broadening",
        ),
    )
    return try
        NumericalParameters(
            N_z = _integer(mapping["spatial_nodes"], "$path.spatial_nodes"),
            N_b = _integer(mapping["basis_states"], "$path.basis_states"),
            P_basis = _integer(mapping["basis_periods"], "$path.basis_periods"),
            E_min = _energy_configuration(mapping["energy_min"], "$path.energy_min"),
            E_max = _energy_configuration(mapping["energy_max"], "$path.energy_max"),
            N_E = _integer(mapping["energy_nodes"], "$path.energy_nodes"),
            M_E = _energy_configuration(
                mapping["energy_trust_margin"],
                "$path.energy_trust_margin",
            ),
            k_max = _wavenumber_configuration(
                mapping["momentum_max"],
                "$path.momentum_max",
            ),
            N_k = _integer(mapping["momentum_nodes"], "$path.momentum_nodes"),
            N_φ = _integer(mapping["angular_nodes"], "$path.angular_nodes"),
            qz_max = _wavenumber_configuration(
                mapping["longitudinal_momentum_max"],
                "$path.longitudinal_momentum_max",
            ),
            N_qz = _integer(
                mapping["longitudinal_momentum_nodes"],
                "$path.longitudinal_momentum_nodes",
            ),
            η_seed = _energy_configuration(
                mapping["seed_broadening"],
                "$path.seed_broadening",
            ),
        )
    catch error
        error isa ConfigurationError && rethrow()
        _configuration_error(path, sprint(showerror, error))
    end
end

function _parse_scales(mapping)
    path = "scales"
    _expect_keys(mapping, path; required = ("energy", "length", "reference_mass_ratio"))
    ratio = _real(
        mapping["reference_mass_ratio"],
        "$path.reference_mass_ratio";
        minimum = 0.0,
        minimum_open = true,
    )
    return try
        ScaleSystem(
            E₀ = _energy_configuration(mapping["energy"], "$path.energy"),
            L₀ = _length_configuration(mapping["length"], "$path.length"),
            m_ref = ratio * CODATA.m₀,
        )
    catch error
        error isa ConfigurationError && rethrow()
        _configuration_error(path, sprint(showerror, error))
    end
end

function _parse_scattering(mapping, physical)
    path = "scattering"
    _expect_keys(
        mapping,
        path;
        required = (
            "lo_phonon",
            "acoustic_phonon",
            "ionized_impurity",
            "interface_roughness",
            "alloy_disorder",
        ),
    )
    result = ScatteringOptions(
        LO = _bool(mapping["lo_phonon"], "$path.lo_phonon"),
        acoustic = _bool(mapping["acoustic_phonon"], "$path.acoustic_phonon"),
        impurity = _bool(mapping["ionized_impurity"], "$path.ionized_impurity"),
        IFR = _bool(mapping["interface_roughness"], "$path.interface_roughness"),
        alloy = _bool(mapping["alloy_disorder"], "$path.alloy_disorder"),
    )
    result.alloy &&
        (physical.ΔV_alloy === nothing || physical.Ω₀ === nothing) &&
        _configuration_error(
            "$path.alloy_disorder",
            "alloy scattering requires physical alloy_potential and primitive_cell_volume",
        )
    return result
end

const _TOLERANCE_KEYS = (
    "dyson",
    "spectral_identity",
    "keldysh",
    "self_energy",
    "normalization",
    "poisson",
    "hartree",
    "density",
    "neutrality",
    "current_continuity",
    "collision",
    "power",
    "positivity",
    "causality",
    "sum_rule",
    "observables",
    "poisson_gauge",
    "imaginary_part",
    "tail",
    "energy_edge",
    "fft_roundoff",
)

function _parse_tolerances(mapping)
    path = "solver.tolerances"
    _expect_keys(mapping, path; required = _TOLERANCE_KEYS)
    values = Dict(
        key => _real(mapping[key], "$path.$key"; minimum = 0.0) for key in _TOLERANCE_KEYS
    )
    return SolverTolerances(
        r_D = values["dyson"],
        r_A = values["spectral_identity"],
        r_K = values["keldysh"],
        r_Σ = values["self_energy"],
        r_λ = values["normalization"],
        r_P = values["poisson"],
        r_U = values["hartree"],
        r_n = values["density"],
        r_neutral = values["neutrality"],
        r_J = values["current_continuity"],
        r_C = values["collision"],
        r_power = values["power"],
        r_PSD = values["positivity"],
        r_caus = values["causality"],
        r_sum = values["sum_rule"],
        r_obs = values["observables"],
        r_ζ = values["poisson_gauge"],
        r_imag = values["imaginary_part"],
        r_tail = values["tail"],
        r_edge = values["energy_edge"],
        r_roundoff = values["fft_roundoff"],
    )
end

function _parse_solver_unchecked(mapping)
    path = "solver"
    _expect_keys(
        mapping,
        path;
        required = (
            "self_energy_mixing",
            "poisson_mixing",
            "maximum_scba_iterations",
            "maximum_poisson_iterations",
            "convergence",
            "tolerances",
            "validation_windows",
        ),
    )
    convergence = _mapping(mapping["convergence"], "$path.convergence")
    _expect_keys(
        convergence,
        "$path.convergence";
        required = (
            "minimum_scba_iterations",
            "required_consecutive_scba_passes",
            "minimum_poisson_iterations",
            "required_consecutive_poisson_passes",
            "stagnation_window",
            "stagnation_relative_improvement",
            "diagnostic_quality",
        ),
        optional = ("mode", "trend"),
    )
    trend =
        _mapping(get(convergence, "trend", Dict{String,Any}()), "$path.convergence.trend")
    _expect_keys(
        trend,
        "$path.convergence.trend";
        optional = (
            "window",
            "minimum_reduction",
            "promising_threshold",
            "max_regression",
            "max_oscillation",
        ),
    )
    diagnostic_quality =
        _mapping(convergence["diagnostic_quality"], "$path.convergence.diagnostic_quality")
    _expect_keys(
        diagnostic_quality,
        "$path.convergence.diagnostic_quality";
        required = (
            "enabled",
            "keldysh",
            "self_energy",
            "normalization",
            "required_consecutive_passes",
        ),
        optional = (
            "target_fixed_point",
            "coarse_wait_iterations",
            "strict_attempt_iterations",
            "observables",
            "positivity",
            "causality",
            "outer_threshold",
        ),
    )
    windows = _mapping(mapping["validation_windows"], "$path.validation_windows")
    _expect_keys(
        windows,
        "$path.validation_windows";
        required = ("energy_tail_fraction", "momentum_tail_fraction"),
    )
    options = SolverOptions(
        α_Σ = _real(mapping["self_energy_mixing"], "$path.self_energy_mixing"),
        α_P = _real(mapping["poisson_mixing"], "$path.poisson_mixing"),
        max_scba = _integer(
            mapping["maximum_scba_iterations"],
            "$path.maximum_scba_iterations",
        ),
        max_poisson = _integer(
            mapping["maximum_poisson_iterations"],
            "$path.maximum_poisson_iterations",
        ),
        tolerances = _parse_tolerances(_mapping(mapping["tolerances"], "$path.tolerances")),
        convergence = ConvergencePolicy(
            mode = Symbol(get(convergence, "mode", "strict_fail_fast")),
            trend = ResearchTrendPolicy(
                window = _integer(
                    get(trend, "window", 32),
                    "$path.convergence.trend.window",
                ),
                minimum_reduction = _real(
                    get(trend, "minimum_reduction", 0.5),
                    "$path.convergence.trend.minimum_reduction",
                ),
                promising_threshold = _real(
                    get(trend, "promising_threshold", 1e-4),
                    "$path.convergence.trend.promising_threshold",
                ),
                max_regression = _real(
                    get(trend, "max_regression", 2.0),
                    "$path.convergence.trend.max_regression",
                ),
                max_oscillation = _real(
                    get(trend, "max_oscillation", 10.0),
                    "$path.convergence.trend.max_oscillation",
                ),
            ),
            minimum_scba_iterations = _integer(
                convergence["minimum_scba_iterations"],
                "$path.convergence.minimum_scba_iterations",
            ),
            required_consecutive_scba_passes = _integer(
                convergence["required_consecutive_scba_passes"],
                "$path.convergence.required_consecutive_scba_passes",
            ),
            minimum_poisson_iterations = _integer(
                convergence["minimum_poisson_iterations"],
                "$path.convergence.minimum_poisson_iterations",
            ),
            required_consecutive_poisson_passes = _integer(
                convergence["required_consecutive_poisson_passes"],
                "$path.convergence.required_consecutive_poisson_passes",
            ),
            stagnation_window = _integer(
                convergence["stagnation_window"],
                "$path.convergence.stagnation_window",
            ),
            stagnation_relative_improvement = _real(
                convergence["stagnation_relative_improvement"],
                "$path.convergence.stagnation_relative_improvement",
            ),
            diagnostic_quality = DiagnosticQualityPolicy(
                target_fixed_point_threshold = _real(
                    get(diagnostic_quality, "target_fixed_point", 1e-4),
                    "$path.convergence.diagnostic_quality.target_fixed_point",
                ),
                coarse_wait_iterations = _integer(
                    get(diagnostic_quality, "coarse_wait_iterations", 64),
                    "$path.convergence.diagnostic_quality.coarse_wait_iterations",
                ),
                strict_attempt_iterations = _integer(
                    get(diagnostic_quality, "strict_attempt_iterations", 8),
                    "$path.convergence.diagnostic_quality.strict_attempt_iterations",
                ),
                observable_threshold = _real(
                    get(diagnostic_quality, "observables", 1e-3),
                    "$path.convergence.diagnostic_quality.observables",
                ),
                positivity_threshold = _real(
                    get(diagnostic_quality, "positivity", 1e-6),
                    "$path.convergence.diagnostic_quality.positivity",
                ),
                causality_threshold = _real(
                    get(diagnostic_quality, "causality", 1e-10),
                    "$path.convergence.diagnostic_quality.causality",
                ),
                outer_threshold = _real(
                    get(diagnostic_quality, "outer_threshold", 1e-4),
                    "$path.convergence.diagnostic_quality.outer_threshold",
                ),
                enabled = _bool(
                    diagnostic_quality["enabled"],
                    "$path.convergence.diagnostic_quality.enabled",
                ),
                keldysh_threshold = _real(
                    diagnostic_quality["keldysh"],
                    "$path.convergence.diagnostic_quality.keldysh";
                    minimum = 0.0,
                    minimum_open = true,
                ),
                self_energy_threshold = _real(
                    diagnostic_quality["self_energy"],
                    "$path.convergence.diagnostic_quality.self_energy";
                    minimum = 0.0,
                    minimum_open = true,
                ),
                normalization_threshold = _real(
                    diagnostic_quality["normalization"],
                    "$path.convergence.diagnostic_quality.normalization";
                    minimum = 0.0,
                    minimum_open = true,
                ),
                required_consecutive_passes = _integer(
                    diagnostic_quality["required_consecutive_passes"],
                    "$path.convergence.diagnostic_quality.required_consecutive_passes";
                    minimum = 3,
                ),
            ),
        ),
        energy_tail_window_fraction = _real(
            windows["energy_tail_fraction"],
            "$path.validation_windows.energy_tail_fraction";
            minimum = 0.0,
            minimum_open = true,
            maximum = 1.0,
            maximum_open = true,
        ),
        momentum_tail_window_fraction = _real(
            windows["momentum_tail_fraction"],
            "$path.validation_windows.momentum_tail_fraction";
            minimum = 0.0,
            minimum_open = true,
            maximum = 1.0,
            maximum_open = true,
        ),
    )
    return try
        _check_options(options)
    catch error
        _configuration_error(path, sprint(showerror, error))
    end
end

function _parse_physics_marker_policy(value, path::AbstractString)
    mapping = _mapping(value, path)
    _expect_keys(
        mapping,
        path;
        optional = ("cadence", "max_spectral_blocks", "relative_mode_weight_floor"),
    )
    defaults = SCBAPhysicsMarkerPolicy()
    return SCBAPhysicsMarkerPolicy(
        cadence = _integer(
            get(mapping, "cadence", defaults.cadence),
            "$path.cadence";
            minimum = 1,
        ),
        max_spectral_blocks = _integer(
            get(mapping, "max_spectral_blocks", defaults.max_spectral_blocks),
            "$path.max_spectral_blocks";
            minimum = 1,
        ),
        relative_mode_weight_floor = _real(
            get(mapping, "relative_mode_weight_floor", defaults.relative_mode_weight_floor),
            "$path.relative_mode_weight_floor";
            minimum = 0.0,
            maximum = 1.0,
            maximum_open = true,
        ),
    )
end

function _parse_production(mapping, algorithms::AlgorithmOptions)
    path = "production"
    _expect_keys(
        mapping,
        path;
        required = (
            "energy_chunk",
            "hilbert_columns",
            "parallel_backend",
            "worker_count",
            "residual_chunk",
            "phase_timing",
            "verify_fft_roundoff",
            "checkpoint_every_outer",
            "checkpoint_every_scba",
            "progress_every_scba",
            "progress_every_outer",
        ),
        optional = ("physics_markers",),
    )
    options = ProductionOptions(
        energy_chunk = _integer(mapping["energy_chunk"], "$path.energy_chunk"),
        hilbert_columns = _integer(mapping["hilbert_columns"], "$path.hilbert_columns"),
        parallel_backend = _choice(
            mapping["parallel_backend"],
            "$path.parallel_backend",
            (:threads, :blas),
        ),
        worker_count = _integer(mapping["worker_count"], "$path.worker_count"),
        residual_chunk = _integer(mapping["residual_chunk"], "$path.residual_chunk"),
        phase_timing = _bool(mapping["phase_timing"], "$path.phase_timing"),
        physics_markers = _parse_physics_marker_policy(
            get(mapping, "physics_markers", Dict{String,Any}()),
            "$path.physics_markers",
        ),
        verify_fft_roundoff = _bool(
            mapping["verify_fft_roundoff"],
            "$path.verify_fft_roundoff",
        ),
        checkpoint_every_outer = _integer(
            mapping["checkpoint_every_outer"],
            "$path.checkpoint_every_outer",
        ),
        checkpoint_every_scba = _integer(
            mapping["checkpoint_every_scba"],
            "$path.checkpoint_every_scba",
        ),
        progress_every_scba = _integer(
            mapping["progress_every_scba"],
            "$path.progress_every_scba",
        ),
        progress_every_outer = _integer(
            mapping["progress_every_outer"],
            "$path.progress_every_outer",
        ),
        algorithms = algorithms,
    )
    return try
        _check_production_options(options)
    catch error
        _configuration_error(path, sprint(showerror, error))
    end
end

function _parse_kernels(mapping)
    path = "kernel_construction"
    _expect_keys(
        mapping,
        path;
        required = (
            "initial_lookup_nodes",
            "maximum_lookup_nodes",
            "relative_tolerance",
            "lookup_power",
            "validation_fractions",
            "angular_validation_pairs",
            "strict",
        ),
        optional = ("impurity_angular_tolerance",),
    )
    fractions_input = _array(mapping["validation_fractions"], "$path.validation_fractions")
    length(fractions_input) == 3 || _configuration_error(
        "$path.validation_fractions",
        "exactly three fractions are required",
    )
    fractions = Tuple(
        _real(value, "$path.validation_fractions[$index]") for
        (index, value) in pairs(fractions_input)
    )
    options = ProductionKernelOptions(
        impurity_angular_tolerance = _real(
            get(mapping, "impurity_angular_tolerance", 1e-5),
            "$path.impurity_angular_tolerance";
            minimum = 0.0,
            minimum_open = true,
            maximum = 1.0,
            maximum_open = true,
        ),
        initial_lookup_nodes = _integer(
            mapping["initial_lookup_nodes"],
            "$path.initial_lookup_nodes",
        ),
        maximum_lookup_nodes = _integer(
            mapping["maximum_lookup_nodes"],
            "$path.maximum_lookup_nodes",
        ),
        relative_tolerance = _real(
            mapping["relative_tolerance"],
            "$path.relative_tolerance",
        ),
        lookup_power = _real(mapping["lookup_power"], "$path.lookup_power"),
        validation_fractions = fractions,
        angular_validation_pairs = _integer(
            mapping["angular_validation_pairs"],
            "$path.angular_validation_pairs",
        ),
        strict = _bool(mapping["strict"], "$path.strict"),
    )
    return try
        _check_production_kernel_options(options)
    catch error
        _configuration_error(path, sprint(showerror, error))
    end
end

function _parse_algorithms(mapping, solver_backend::Symbol)
    path = "algorithms"
    _expect_keys(
        mapping,
        path;
        required = (
            "energy_shift",
            "hilbert",
            "contraction",
            "kernel_build",
            "mixing",
            "localization",
            "retarded_real_part",
            "self_energy_structure",
            "transverse_momentum",
            "low_rank",
            "anderson",
        ),
        optional = ("embedding", "embedding_periods", "occupation_normalization"),
    )
    low_rank = _mapping(mapping["low_rank"], "$path.low_rank")
    _expect_keys(
        low_rank,
        "$path.low_rank";
        required = ("relative_tolerance", "maximum_rank"),
    )
    anderson = _mapping(mapping["anderson"], "$path.anderson")
    _expect_keys(
        anderson,
        "$path.anderson";
        required = ("history_depth", "damping", "regularization"),
    )
    options = AlgorithmOptions(
        solver_backend = solver_backend,
        occupation_normalization = _choice(
            get(mapping, "occupation_normalization", "paired_convex"),
            "$path.occupation_normalization",
            (:paired_convex, :scalar_lesser),
        ),
        embedding = _choice(
            get(mapping, "embedding", "full_cell_resolvent"),
            "$path.embedding",
            (:full_cell_resolvent, :finite_chain),
        ),
        embedding_periods = _integer(
            get(mapping, "embedding_periods", 8),
            "$path.embedding_periods";
            minimum = 1,
        ),
        energy_shift = _choice(
            mapping["energy_shift"],
            "$path.energy_shift",
            (:dense, :sparse_plan, :conservative_pair),
        ),
        hilbert = _choice(
            mapping["hilbert"],
            "$path.hilbert",
            (:direct, :fft, :product_integration),
        ),
        contraction = _choice(
            mapping["contraction"],
            "$path.contraction",
            (:literal, :dense_blas, :low_rank),
        ),
        kernel_build = _choice(
            mapping["kernel_build"],
            "$path.kernel_build",
            (:direct, :tabulated, :adaptive_direct),
        ),
        mixing = _choice(mapping["mixing"], "$path.mixing", (:linear, :anderson)),
        localization = _choice(
            mapping["localization"],
            "$path.localization",
            (:pzp, :none, :real_space),
        ),
        low_rank_relative_tolerance = _real(
            low_rank["relative_tolerance"],
            "$path.low_rank.relative_tolerance";
            minimum = 0.0,
        ),
        low_rank_maximum_rank = _integer(
            low_rank["maximum_rank"],
            "$path.low_rank.maximum_rank";
            minimum = 0,
        ),
        anderson_history_depth = _integer(
            anderson["history_depth"],
            "$path.anderson.history_depth";
            minimum = 1,
        ),
        anderson_damping = _real(
            anderson["damping"],
            "$path.anderson.damping";
            minimum = 0.0,
            maximum = 1.0,
            minimum_open = true,
        ),
        anderson_regularization = _real(
            anderson["regularization"],
            "$path.anderson.regularization";
            minimum = 0.0,
        ),
        retarded_real_part = _choice(
            mapping["retarded_real_part"],
            "$path.retarded_real_part",
            (:kramers_kronig, :drop),
        ),
        self_energy_structure = _choice(
            mapping["self_energy_structure"],
            "$path.self_energy_structure",
            (:full, :diagonal),
        ),
        transverse_momentum = _choice(
            mapping["transverse_momentum"],
            "$path.transverse_momentum",
            (:resolved, :averaged),
        ),
    )
    return try
        _check_algorithm_options(options)
    catch error
        _configuration_error(path, sprint(showerror, error))
    end
end

function _parse_execution(mapping)
    path = "execution"
    _expect_keys(
        mapping,
        path;
        required = (
            "strategy",
            "solver_backend",
            "julia_threads",
            "blas_threads",
            "fail_on_thread_mismatch",
            "auto",
        ),
    )
    automatic = _mapping(mapping["auto"], "$path.auto")
    _expect_keys(
        automatic,
        "$path.auto";
        required = (
            "memory_reserve_fraction",
            "minimum_memory_reserve_bytes",
            "workspace_budget_fraction",
            "workspace_complex_arrays_per_energy_block",
            "minimum_outer_parallel_threads",
            "large_basis_threshold",
            "minimum_energy_chunk",
            "energy_chunk_alignment",
            "blocks_per_worker",
            "hilbert_columns_per_worker",
            "energy_jobs_per_worker",
        ),
    )
    auto_options = AutomaticExecutionConfiguration(
        _real(
            automatic["memory_reserve_fraction"],
            "$path.auto.memory_reserve_fraction";
            minimum = 0.0,
            maximum = 1.0,
            maximum_open = true,
        ),
        _integer(
            automatic["minimum_memory_reserve_bytes"],
            "$path.auto.minimum_memory_reserve_bytes";
            minimum = 0,
        ),
        _real(
            automatic["workspace_budget_fraction"],
            "$path.auto.workspace_budget_fraction";
            minimum = 0.0,
            minimum_open = true,
            maximum = 1.0,
            maximum_open = true,
        ),
        _integer(
            automatic["workspace_complex_arrays_per_energy_block"],
            "$path.auto.workspace_complex_arrays_per_energy_block";
            minimum = 1,
        ),
        _integer(
            automatic["minimum_outer_parallel_threads"],
            "$path.auto.minimum_outer_parallel_threads";
            minimum = 1,
        ),
        _integer(
            automatic["large_basis_threshold"],
            "$path.auto.large_basis_threshold";
            minimum = 1,
        ),
        _integer(
            automatic["minimum_energy_chunk"],
            "$path.auto.minimum_energy_chunk";
            minimum = 1,
        ),
        _integer(
            automatic["energy_chunk_alignment"],
            "$path.auto.energy_chunk_alignment";
            minimum = 1,
        ),
        _integer(
            automatic["blocks_per_worker"],
            "$path.auto.blocks_per_worker";
            minimum = 1,
        ),
        _integer(
            automatic["hilbert_columns_per_worker"],
            "$path.auto.hilbert_columns_per_worker";
            minimum = 1,
        ),
        _integer(
            automatic["energy_jobs_per_worker"],
            "$path.auto.energy_jobs_per_worker";
            minimum = 1,
        ),
    )
    return ExecutionConfiguration(
        _choice(mapping["strategy"], "$path.strategy", (:manual, :auto_exact)),
        _choice(
            mapping["solver_backend"],
            "$path.solver_backend",
            (:educational, :production),
        ),
        _integer(mapping["julia_threads"], "$path.julia_threads"; minimum = 0),
        _integer(mapping["blas_threads"], "$path.blas_threads"; minimum = 1),
        _bool(mapping["fail_on_thread_mismatch"], "$path.fail_on_thread_mismatch"),
        auto_options,
    )
end

function _parse_output(mapping)
    path = "output"
    _expect_keys(
        mapping,
        path;
        required = (
            "directory",
            "checkpoint_prefix",
            "resume",
            "fail_fast",
            "save_full_state",
            "save_csv",
            "save_plots",
            "live_visualization",
            "snapshot_every_scba",
            "snapshot_every_outer",
            "progress",
            "report_directory",
            "save_expert_markdown",
            "save_comparison_csv",
            "save_comparison_plots",
            "device_geometry",
        ),
        optional = (
            "debug_hdf5",
            "light_max_space_points",
            "light_max_energy_points",
            "light_max_momentum_points",
            "light_max_snapshots",
        ),
    )
    progress_mapping = _mapping(mapping["progress"], "$path.progress")
    _expect_keys(
        progress_mapping,
        "$path.progress";
        required = (
            "enabled",
            "terminal",
            "significant_digits",
            "human_every",
            "event_log_file",
            "latest_snapshot_file",
            "dashboard_file",
        ),
    )
    function relative_child(value, child_path; nullable = false)
        if value === nothing
            nullable || _configuration_error(child_path, "cannot be null")
            return nothing
        end
        child = _string(value, child_path)
        occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$", child) ||
            _configuration_error(
                child_path,
                "must be a portable relative child path using '/' without dot " *
                "segments, backslashes, drive prefixes, or empty segments",
            )
        isabspath(child) &&
            _configuration_error(child_path, "must be relative to output.directory")
        normalized = normpath(child)
        first(splitpath(normalized)) == ".." &&
            _configuration_error(child_path, "must remain below output.directory")
        normalized == "." && _configuration_error(
            child_path,
            "must name a child path below output.directory",
        )
        return normalized
    end
    event_log = relative_child(
        progress_mapping["event_log_file"],
        "$path.progress.event_log_file";
        nullable = true,
    )
    latest_snapshot = relative_child(
        progress_mapping["latest_snapshot_file"],
        "$path.progress.latest_snapshot_file";
        nullable = true,
    )
    dashboard = relative_child(
        progress_mapping["dashboard_file"],
        "$path.progress.dashboard_file";
        nullable = true,
    )
    progress_paths = String[
        value for value in (event_log, latest_snapshot, dashboard) if value !== nothing
    ]
    allunique(progress_paths) || _configuration_error(
        "$path.progress",
        "event_log_file, latest_snapshot_file, and dashboard_file must differ",
    )
    if event_log !== nothing
        machine_paths = Set(
            joinpath(dirname(event_log), name) for name in
            ("events.jsonl", "progress.yaml", "timings.csv", "timing_summary.yaml")
        )
        any(path -> path in machine_paths, progress_paths) && _configuration_error(
            "$path.progress",
            "configured paths collide with reserved machine telemetry companions",
        )
    end
    progress = ProgressOutputConfiguration(
        _bool(progress_mapping["enabled"], "$path.progress.enabled"),
        _bool(progress_mapping["terminal"], "$path.progress.terminal"),
        _integer(
            progress_mapping["significant_digits"],
            "$path.progress.significant_digits";
            minimum = 2,
            maximum = 17,
        ),
        _integer(
            progress_mapping["human_every"],
            "$path.progress.human_every";
            minimum = 1,
        ),
        event_log,
        latest_snapshot,
        dashboard,
    )
    geometry_mapping = _mapping(mapping["device_geometry"], "$path.device_geometry")
    _expect_keys(
        geometry_mapping,
        "$path.device_geometry";
        required = ("periods", "ridge_width", "cavity_length"),
    )
    geometry = DeviceGeometryConfiguration(
        _integer(geometry_mapping["periods"], "$path.device_geometry.periods"; minimum = 1),
        _length_configuration(
            geometry_mapping["ridge_width"],
            "$path.device_geometry.ridge_width",
        ),
        _length_configuration(
            geometry_mapping["cavity_length"],
            "$path.device_geometry.cavity_length",
        ),
    )
    checkpoint_prefix = _string(mapping["checkpoint_prefix"], "$path.checkpoint_prefix")
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", checkpoint_prefix) ||
        _configuration_error(
            "$path.checkpoint_prefix",
            "must be a portable filename stem of 1--64 ASCII letters, " *
            "digits, '.', '_', or '-', beginning with a letter or digit",
        )
    return OutputConfiguration(
        _string(mapping["directory"], "$path.directory"),
        checkpoint_prefix,
        _bool(mapping["resume"], "$path.resume"),
        _bool(mapping["fail_fast"], "$path.fail_fast"),
        _bool(mapping["save_full_state"], "$path.save_full_state"),
        _bool(mapping["save_csv"], "$path.save_csv"),
        _bool(mapping["save_plots"], "$path.save_plots"),
        _bool(mapping["live_visualization"], "$path.live_visualization"),
        _integer(mapping["snapshot_every_scba"], "$path.snapshot_every_scba"; minimum = 0),
        _integer(
            mapping["snapshot_every_outer"],
            "$path.snapshot_every_outer";
            minimum = 0,
        ),
        progress,
        relative_child(mapping["report_directory"], "$path.report_directory"),
        _bool(mapping["save_expert_markdown"], "$path.save_expert_markdown"),
        _bool(mapping["save_comparison_csv"], "$path.save_comparison_csv"),
        _bool(mapping["save_comparison_plots"], "$path.save_comparison_plots"),
        geometry,
        _bool(get(mapping, "debug_hdf5", false), "$path.debug_hdf5"),
        _integer(
            get(mapping, "light_max_space_points", 2048),
            "$path.light_max_space_points";
            minimum = 2,
            maximum = 16384,
        ),
        _integer(
            get(mapping, "light_max_energy_points", 512),
            "$path.light_max_energy_points";
            minimum = 2,
            maximum = 4096,
        ),
        _integer(
            get(mapping, "light_max_momentum_points", 64),
            "$path.light_max_momentum_points";
            minimum = 2,
            maximum = 256,
        ),
        _integer(
            get(mapping, "light_max_snapshots", 64),
            "$path.light_max_snapshots";
            minimum = 1,
            maximum = 512,
        ),
    )
end

function _validate_output_contract(
    output::OutputConfiguration,
    production::ProductionOptions,
    study::StudyConfiguration,
)
    output.resume &&
        !output.save_full_state &&
        _configuration_error(
            "output.resume",
            "resume requires output.save_full_state: true",
        )
    if !output.save_full_state
        production.checkpoint_every_scba == 0 || _configuration_error(
            "production.checkpoint_every_scba",
            "must be zero when output.save_full_state is false",
        )
        production.checkpoint_every_outer == 0 || _configuration_error(
            "production.checkpoint_every_outer",
            "must be zero when output.save_full_state is false",
        )
    end
    output.live_visualization &&
        !output.progress.enabled &&
        _configuration_error(
            "output.live_visualization",
            "live visualization requires output.progress.enabled: true",
        )
    output.live_visualization &&
        output.progress.dashboard_file === nothing &&
        _configuration_error(
            "output.progress.dashboard_file",
            "a dashboard file is required when live_visualization is true",
        )
    has_snapshot_sink =
        output.progress.latest_snapshot_file !== nothing ||
        (output.live_visualization && output.progress.dashboard_file !== nothing)
    if output.snapshot_every_scba > 0 || output.snapshot_every_outer > 0
        output.progress.enabled || _configuration_error(
            "output.progress.enabled",
            "snapshot cadence requires progress reporting",
        )
        has_snapshot_sink || _configuration_error(
            "output",
            "snapshot cadence requires latest_snapshot_file or a live dashboard",
        )
    end
    study.mode === :comparison &&
        output.save_comparison_plots &&
        !output.save_plots &&
        _configuration_error(
            "output.save_comparison_plots",
            "comparison plots require output.save_plots: true",
        )
    if study.mode === :comparison
        output.save_csv || _configuration_error(
            "output.save_csv",
            "comparison studies require CSV summaries",
        )
        output.save_expert_markdown || _configuration_error(
            "output.save_expert_markdown",
            "comparison workflow currently requires the expert Markdown report",
        )
        output.save_comparison_csv || _configuration_error(
            "output.save_comparison_csv",
            "comparison workflow currently requires comparison CSV output",
        )
    end
    return output
end

function _integer_vector(value, path; minimum = 1)
    array = _array(value, path)
    return Int[
        _integer(child, "$path[$index]"; minimum = minimum) for
        (index, child) in pairs(array)
    ]
end

function _parse_study(mapping)
    path = "study"
    _expect_keys(
        mapping,
        path;
        required = (
            "mode",
            "voltages_per_period",
            "temperatures",
            "comparison_profiles",
            "reference_profile",
            "methods",
            "repetitions",
            "calculate_optical_response",
            "photon_energy_min",
            "photon_energy_max",
            "photon_energy_points",
            "optical_edge_tolerance",
            "convergence",
        ),
    )
    voltage_input = _array(mapping["voltages_per_period"], "$path.voltages_per_period")
    temperature_input = _array(mapping["temperatures"], "$path.temperatures")
    isempty(voltage_input) && _configuration_error(
        "$path.voltages_per_period",
        "at least one voltage is required",
    )
    isempty(temperature_input) &&
        _configuration_error("$path.temperatures", "at least one temperature is required")
    voltages = typeof(1.0u"V")[
        _voltage_configuration(value, "$path.voltages_per_period[$index]") for
        (index, value) in pairs(voltage_input)
    ]
    temperatures = TemperatureQuantity[
        _temperature_configuration(value, "$path.temperatures[$index]") for
        (index, value) in pairs(temperature_input)
    ]
    all(temperature -> temperature > 0u"K", temperatures) ||
        _configuration_error("$path.temperatures", "temperatures must be positive")
    profile_input = _array(mapping["comparison_profiles"], "$path.comparison_profiles")
    profiles = String[
        _string(value, "$path.comparison_profiles[$index]") for
        (index, value) in pairs(profile_input)
    ]
    reference_profile =
        mapping["reference_profile"] === nothing ? nothing :
        _string(mapping["reference_profile"], "$path.reference_profile")
    method_input = _array(mapping["methods"], "$path.methods")
    methods = StudyMethodConfiguration[]
    for (index, value) in pairs(method_input)
        method_path = "$path.methods[$index]"
        method = _mapping(value, method_path)
        _expect_keys(
            method,
            method_path;
            required = (
                "profile",
                "label",
                "modifies_physics",
                "algorithm_family",
                "description",
                "literature",
            ),
            optional = ("overrides",),
        )
        if haskey(method, "overrides")
            overrides = _mapping(method["overrides"], "$method_path.overrides")
            _expect_keys(
                overrides,
                "$method_path.overrides";
                optional = ("physical", "numerical", "scattering", "solver", "algorithms"),
            )
        end
        literature_input = _array(method["literature"], "$method_path.literature")
        literature = String[
            _string(item, "$method_path.literature[$item_index]") for
            (item_index, item) in pairs(literature_input)
        ]
        push!(
            methods,
            StudyMethodConfiguration(
                _string(method["profile"], "$method_path.profile"),
                _string(method["label"], "$method_path.label"),
                _bool(method["modifies_physics"], "$method_path.modifies_physics"),
                _choice(
                    method["algorithm_family"],
                    "$method_path.algorithm_family",
                    (
                        :direct_reference,
                        :exact_optimized,
                        :controlled_approximation,
                        :reduced_model,
                        :surrogate,
                    ),
                ),
                _string(method["description"], "$method_path.description"),
                literature,
            ),
        )
    end
    method_profiles = getfield.(methods, :profile)
    allunique(method_profiles) ||
        _configuration_error("$path.methods", "method profiles must be unique")
    convergence = _mapping(mapping["convergence"], "$path.convergence")
    _expect_keys(
        convergence,
        "$path.convergence";
        required = ("spatial_nodes", "energy_nodes", "momentum_nodes", "angular_nodes"),
    )
    convergence_config = ConvergenceStudyConfiguration(
        _integer_vector(convergence["spatial_nodes"], "$path.convergence.spatial_nodes"),
        _integer_vector(convergence["energy_nodes"], "$path.convergence.energy_nodes"),
        _integer_vector(convergence["momentum_nodes"], "$path.convergence.momentum_nodes"),
        _integer_vector(convergence["angular_nodes"], "$path.convergence.angular_nodes"),
    )
    photon_min =
        _energy_configuration(mapping["photon_energy_min"], "$path.photon_energy_min")
    photon_max =
        _energy_configuration(mapping["photon_energy_max"], "$path.photon_energy_max")
    photon_max > photon_min ≥ 0u"eV" ||
        _configuration_error(path, "photon energy bounds must satisfy 0 ≤ min < max")
    mode = _choice(mapping["mode"], "$path.mode", (:single, :sweep, :comparison))
    repetitions = _integer(mapping["repetitions"], "$path.repetitions"; minimum = 1)
    mode === :single &&
        length(voltages) != 1 &&
        _configuration_error(
            "$path.voltages_per_period",
            "single mode requires exactly one voltage",
        )
    mode === :single &&
        length(temperatures) != 1 &&
        _configuration_error(
            "$path.temperatures",
            "single mode requires exactly one temperature",
        )
    mode === :comparison &&
        isempty(profiles) &&
        _configuration_error(
            "$path.comparison_profiles",
            "comparison mode requires profiles",
        )
    mode === :comparison &&
        (reference_profile === nothing || count(==(reference_profile), profiles) != 1) &&
        _configuration_error(
            "$path.reference_profile",
            "comparison mode requires exactly one matching comparison profile",
        )
    mode === :comparison &&
        Set(method_profiles) != Set(profiles) &&
        _configuration_error(
            "$path.methods",
            "method metadata must cover every comparison profile exactly once",
        )
    if mode === :comparison
        reference_method =
            only(filter(method -> method.profile == reference_profile, methods))
        reference_method.modifies_physics && _configuration_error(
            "$path.methods",
            "the reference method cannot modify physics",
        )
    end
    if mode !== :comparison
        isempty(profiles) || _configuration_error(
            "$path.comparison_profiles",
            "comparison profiles are only valid in comparison mode",
        )
        reference_profile === nothing || _configuration_error(
            "$path.reference_profile",
            "reference_profile is only valid in comparison mode",
        )
        isempty(methods) || _configuration_error(
            "$path.methods",
            "method metadata is only valid in comparison mode",
        )
        repetitions == 1 || _configuration_error(
            "$path.repetitions",
            "repetitions must equal one outside comparison mode",
        )
        convergence_axes = (
            convergence_config.spatial_nodes,
            convergence_config.energy_nodes,
            convergence_config.momentum_nodes,
            convergence_config.angular_nodes,
        )
        all(isempty, convergence_axes) || _configuration_error(
            "$path.convergence",
            "convergence axes are only executed in comparison mode",
        )
    end
    return StudyConfiguration(
        mode,
        voltages,
        temperatures,
        profiles,
        reference_profile,
        methods,
        repetitions,
        _bool(mapping["calculate_optical_response"], "$path.calculate_optical_response"),
        photon_min,
        photon_max,
        _integer(
            mapping["photon_energy_points"],
            "$path.photon_energy_points";
            minimum = 2,
        ),
        _real(
            mapping["optical_edge_tolerance"],
            "$path.optical_edge_tolerance";
            minimum = 0.0,
            maximum = 1.0,
            maximum_open = true,
        ),
        convergence_config,
    )
end

function _resolve_configuration(mapping::Dict{String,Any}, provenance)
    _expect_keys(
        mapping,
        "root";
        required = (
            "run",
            "physical",
            "numerical",
            "scales",
            "scattering",
            "solver",
            "production",
            "kernel_construction",
            "algorithms",
            "execution",
            "output",
            "study",
        ),
        optional = ("physical_models", "domain_adaptation"),
    )
    run = _parse_run(_mapping(mapping["run"], "run"))
    physical = _parse_physical(_mapping(mapping["physical"], "physical"))
    numerical = _parse_numerical(_mapping(mapping["numerical"], "numerical"))
    scales = _parse_scales(_mapping(mapping["scales"], "scales"))
    scattering = _parse_scattering(_mapping(mapping["scattering"], "scattering"), physical)
    solver = _parse_solver(_mapping(mapping["solver"], "solver"))
    kernels =
        _parse_kernels(_mapping(mapping["kernel_construction"], "kernel_construction"))
    execution = _parse_execution(_mapping(mapping["execution"], "execution"))
    algorithms = _parse_algorithms(
        _mapping(mapping["algorithms"], "algorithms"),
        execution.solver_backend,
    )
    impact = algorithm_impact(algorithms)
    classification = run[3]
    if classification in (:reference, :computationally_equivalent) &&
       impact !== :physics_preserving
        _configuration_error(
            "run.classification",
            "$classification cannot label algorithm impact $impact",
        )
    elseif classification === :controlled_numerical && impact !== :controlled_numerical
        _configuration_error(
            "run.classification",
            "controlled_numerical requires a controlled numerical algorithm choice",
        )
    end
    production =
        _parse_production(_mapping(mapping["production"], "production"), algorithms)
    output = _parse_output(_mapping(mapping["output"], "output"))
    study = _parse_study(_mapping(mapping["study"], "study"))
    _validate_output_contract(output, production, study)
    execution.solver_backend === :educational &&
        algorithms.energy_shift !== :dense &&
        _configuration_error(
            "algorithms.energy_shift",
            "educational backend requires the dense reference energy shift",
        )
    execution.solver_backend === :educational &&
        algorithms.occupation_normalization !== :paired_convex &&
        _configuration_error(
            "algorithms.occupation_normalization",
            "legacy scalar_lesser comparison requires the production backend",
        )
    return ResolvedRunConfiguration(
        run...,
        physical,
        numerical,
        scales,
        scattering,
        solver,
        production,
        kernels,
        algorithms,
        execution,
        output,
        study,
        provenance,
        deepcopy(mapping),
        _parse_physical_models(get(mapping, "physical_models", Dict{String,Any}())),
        _parse_domain_adaptation(get(mapping, "domain_adaptation", Dict{String,Any}())),
    )
end

"""
    load_run_configuration(source_or_sources)

Load one or more ordered configuration sources. A source is an individual canonical YAML file. Ordered individual
files are then merged exactly at their position in the source list. Mapping
nodes are merged recursively, while arrays and scalars replace their
predecessor. Unknown keys, missing keys, inheritance cycles, escaping file
paths, invalid units, and inconsistent cross-field choices are errors.

This function does not read environment variables and does not mutate global
threading, BLAS, logging, or output state.

See [YAML run configurations](@ref yaml-run-configurations) and the
[configuration contract](@ref configuration-contract).
"""
function load_run_configuration(sources_input::AbstractVector{<:AbstractString})
    return load_configuration_source(sources_input)
end

load_run_configuration(source::AbstractString) = load_run_configuration([String(source)])

"""Strict boundary decoder for opt-in physical closures; baseline remains explicit."""
function _parse_physical_models(value)
    mapping=_mapping(value, "physical_models")
    fields=(
        "screening",
        "screening_temperature_K",
        "screening_mass_ratio",
        "dispersion",
        "nonparabolicity_per_eV",
        "lo_population",
        "lo_fixed_occupation",
        "lo_decay_ps",
        "lo_mode_density_per_m3",
        "electron_electron",
    )
    _expect_keys(mapping, "physical_models"; optional = fields)
    ee=_mapping(
        get(mapping, "electron_electron", Dict{String,Any}()),
        "physical_models.electron_electron",
    )
    _expect_keys(
        ee,
        "physical_models.electron_electron";
        optional = (
            "mode",
            "screening_dimension",
            "transfer_wavenumber_per_nm",
            "electron_temperature_K",
            "effective_mass_ratio",
            "carrier_density_per_m2",
            "carrier_density_per_m3",
            "include_exchange",
        ),
    )
    mode=Symbol(get(ee, "mode", "none"))
    dimension=_integer(
        get(ee, "screening_dimension", 2),
        "electron_electron.screening_dimension",
    )
    density_name=dimension==2 ? "carrier_density_per_m2" : "carrier_density_per_m3"
    wrong_density=dimension==2 ? "carrier_density_per_m3" : "carrier_density_per_m2"
    haskey(ee, wrong_density) && _configuration_error(
        "physical_models.electron_electron",
        "carrier density dimension does not match screening_dimension",
    )
    ee_options=ElectronElectronOptions(;
        mode,
        screening_dimension = dimension,
        transfer_wavenumber = haskey(ee, "transfer_wavenumber_per_nm") ?
                              _real(
            ee["transfer_wavenumber_per_nm"],
            "transfer_wavenumber_per_nm",
        )*u"nm^-1" : nothing,
        electron_temperature = haskey(ee, "electron_temperature_K") ?
                               _real(
            ee["electron_temperature_K"],
            "electron_temperature_K",
        )*u"K" : nothing,
        effective_mass_ratio = haskey(ee, "effective_mass_ratio") ?
                               _real(ee["effective_mass_ratio"], "effective_mass_ratio") :
                               nothing,
        carrier_density = haskey(ee, density_name) ?
                          _real(ee[density_name], density_name)*(
            dimension==2 ? u"m^-2" : u"m^-3"
        ) : nothing,
        include_exchange = _bool(get(ee, "include_exchange", true), "include_exchange"),
    )
    number(key) = _real(get(mapping, key, 0.0), "physical_models.$key")
    return PhysicalModelOptions(;
        screening = Symbol(get(mapping, "screening", "fixed")),
        screening_temperature_K = number("screening_temperature_K"),
        screening_mass_ratio = number("screening_mass_ratio"),
        dispersion = Symbol(get(mapping, "dispersion", "parabolic")),
        nonparabolicity_per_eV = number("nonparabolicity_per_eV"),
        lo_population = Symbol(get(mapping, "lo_population", "thermal")),
        lo_fixed_occupation = number("lo_fixed_occupation"),
        lo_decay_ps = number("lo_decay_ps"),
        lo_mode_density_per_m3 = number("lo_mode_density_per_m3"),
        electron_electron = ee_options,
    )
end

function _parse_domain_adaptation(value)
    data=_mapping(value, "domain_adaptation")
    _expect_keys(
        data,
        "domain_adaptation";
        optional = (
            "mode",
            "maximum_expansions",
            "maximum_energy_nodes",
            "growth_fraction",
            "tail_threshold",
        ),
    )
    return DomainAdaptationPolicy(;
        mode = Symbol(get(data, "mode", "none")),
        maximum_expansions = _integer(
            get(data, "maximum_expansions", 2),
            "domain_adaptation.maximum_expansions",
        ),
        maximum_energy_nodes = _integer(
            get(data, "maximum_energy_nodes", 100001),
            "domain_adaptation.maximum_energy_nodes",
        ),
        growth_fraction = _real(
            get(data, "growth_fraction", 0.5),
            "domain_adaptation.growth_fraction",
        ),
        tail_threshold = _real(
            get(data, "tail_threshold", 1e-6),
            "domain_adaptation.tail_threshold",
        ),
    )
end


function _parse_solver(mapping)
    try
        return _parse_solver_unchecked(mapping)
    catch error
        error isa Union{ArgumentError,DomainError,DimensionMismatch} || rethrow()
        _configuration_error("solver", sprint(showerror, error))
    end
end
