"""Artifacts produced by the
[configured expert comparison workflow](@ref expert-comparison-workflow)."""
struct ProductionStudyResult
    configuration::ResolvedRunConfiguration
    method_catalog::String
    method_report::NamedTuple
    convergence_csv::String
    convergence_markdown::String
    output_directory::String
end

function _output_with_directory(
    output::OutputConfiguration,
    directory::AbstractString;
    resume::Bool = output.resume,
)
    return OutputConfiguration(
        String(directory),
        output.checkpoint_prefix,
        resume,
        output.fail_fast,
        output.save_full_state,
        output.save_csv,
        output.save_plots,
        output.live_visualization,
        output.snapshot_every_scba,
        output.snapshot_every_outer,
        output.progress,
        output.report_directory,
        output.save_expert_markdown,
        output.save_comparison_csv,
        output.save_comparison_plots,
        output.device_geometry,
        output.debug_hdf5,
        output.light_max_space_points,
        output.light_max_energy_points,
        output.light_max_momentum_points,
        output.light_max_snapshots,
    )
end

function _sweep_study(study::StudyConfiguration)
    return StudyConfiguration(
        :sweep,
        copy(study.voltages_per_period),
        copy(study.temperatures),
        String[],
        nothing,
        StudyMethodConfiguration[],
        1,
        study.calculate_optical_response,
        study.photon_energy_min,
        study.photon_energy_max,
        study.photon_energy_points,
        study.optical_edge_tolerance,
        ConvergenceStudyConfiguration(Int[], Int[], Int[], Int[]),
    )
end

_configured_study_source() = _package_path("src", "composition", "configured_study.jl")

function _append_generated_source!(sources::Dict{String,Vector{String}}, path)
    history = get!(sources, String(path), String[])
    source = _configured_study_source()
    (isempty(history) || last(history) != source) && push!(history, source)
    return sources
end

function _combined_provenance(
    study::ResolvedRunConfiguration,
    method::ResolvedRunConfiguration,
)
    sources = deepcopy(study.provenance.sources)
    # The study owns every hardware/resource option so timings remain
    # comparable.  A method contributes only its mathematical algorithms,
    # kernel construction, backend implementation, and report classification.
    method_prefixes = ("algorithms.", "kernel_construction.")
    for (path, history) in method.provenance.sources
        from_method =
            any(startswith(path, prefix) for prefix in method_prefixes) ||
            path == "execution.solver_backend" ||
            path == "run.description" ||
            path == "run.classification"
        from_method || continue
        sources[path] = copy(history)
    end
    for path in (
        "run.name",
        "output.directory",
        "study.mode",
        "study.comparison_profiles",
        "study.reference_profile",
        "study.methods",
        "study.repetitions",
        "study.convergence.spatial_nodes",
        "study.convergence.energy_nodes",
        "study.convergence.momentum_nodes",
        "study.convergence.angular_nodes",
    )
        _append_generated_source!(sources, path)
    end
    return ConfigurationProvenance(
        unique(vcat(study.provenance.manifests, method.provenance.manifests)),
        unique(vcat(study.provenance.files, method.provenance.files)),
        sources,
    )
end

function _production_with_algorithms(
    options::ProductionOptions,
    algorithms::AlgorithmOptions,
)
    return with_production_options(options; algorithms)
end

function _method_configuration(
    study::ResolvedRunConfiguration,
    method::ResolvedRunConfiguration,
    output_directory::AbstractString;
    overrides::Dict{String,Any} = Dict{String,Any}(),
)
    raw = deepcopy(study.raw)
    for section in ("algorithms", "kernel_construction")
        raw[section] = deepcopy(method.raw[section])
    end
    # Every method in an in-process comparison receives the same hardware
    # budget declared by the study.  Only the backend implementation is a
    # method choice; Julia's thread count cannot be changed after startup.
    raw["execution"] = deepcopy(study.raw["execution"])
    raw["execution"]["solver_backend"] = String(method.execution.solver_backend)
    raw["run"] = Dict{String,Any}(
        "name" => "$(study.name)__$(method.name)",
        "description" => method.description,
        "classification" => String(method.classification),
    )
    raw["output"]["directory"] = String(output_directory)
    raw["study"]["mode"] = "sweep"
    raw["study"]["comparison_profiles"] = Any[]
    raw["study"]["reference_profile"] = nothing
    raw["study"]["methods"] = Any[]
    raw["study"]["repetitions"] = 1
    for axis in ("spatial_nodes", "energy_nodes", "momentum_nodes", "angular_nodes")
        raw["study"]["convergence"][axis] = Any[]
    end
    function merge_case!(destination, patch)
        for (key, value) in patch
            if value isa AbstractDict && get(destination, key, nothing) isa AbstractDict
                merge_case!(destination[key], value)
            else
                destination[key] = deepcopy(value)
            end
        end
    end
    merge_case!(raw, overrides)
    physical_change = haskey(overrides, "physical") || haskey(overrides, "scattering")
    physical_change && (raw["run"]["classification"]="physics_changing")
    provenance = _combined_provenance(study, method)
    return _resolve_configuration(raw, provenance)
end

function _find_profile_root(configuration_source::AbstractString)
    candidate=realpath(configuration_source)
    isfile(candidate) || throw(ArgumentError("configuration must be a canonical file"))
    directory=dirname(candidate)
    # Internal method fixtures resolve next to their canonical document. The
    # scientific production path has fully resolved configurations in its DAG.
    return directory
end

function _profile_directory(root::AbstractString, profile::AbstractString)
    isabspath(profile) &&
        throw(ArgumentError("comparison configuration path must be relative"))
    directory=realpath(root)
    candidate=normpath(joinpath(directory, profile))
    isfile(candidate) ||
        throw(ArgumentError("comparison configuration file is absent: $profile"))
    canonical=realpath(candidate)
    first(splitpath(relpath(canonical, directory)))==".." &&
        throw(ArgumentError("comparison configuration escapes its root"))
    basename(canonical)=="manifest.yaml" &&
        throw(ArgumentError("paired profiles are not supported"))
    return canonical
end

function _expected_method_family(configuration::ResolvedRunConfiguration)
    impact = algorithm_impact(configuration.algorithms)
    return if configuration.classification === :physics_changing
        :reduced_model
    elseif impact === :physics_preserving
        configuration.classification === :reference ? :direct_reference : :exact_optimized
    elseif impact === :controlled_numerical
        :controlled_approximation
    else
        :reduced_model
    end
end

function _validate_method_metadata(
    method::StudyMethodConfiguration,
    configuration::ResolvedRunConfiguration,
)
    configuration.classification === :study && throw(
        ArgumentError(
            "comparison profile $(repr(method.profile)) resolves to a study; " *
            "study profiles cannot be nested as solver methods",
        ),
    )
    impact = algorithm_impact(configuration.algorithms)
    modifies_physics =
        impact === :physical_model || configuration.classification === :physics_changing
    method.modifies_physics == modifies_physics || throw(
        ArgumentError(
            "study metadata for profile $(repr(method.profile)) declares " *
            "modifies_physics=$(method.modifies_physics), but its resolved " *
            "algorithm impact is $(impact)",
        ),
    )
    expected_family = _expected_method_family(configuration)
    method.algorithm_family === expected_family || throw(
        ArgumentError(
            "study metadata for profile $(repr(method.profile)) declares " *
            "algorithm_family=$(method.algorithm_family), expected " *
            "$(expected_family) from the resolved profile",
        ),
    )
    return configuration
end

# Length-prefixed hexadecimal text keeps CSV/Markdown delimiters out of the
# identity while preserving every UTF-8 byte.
_signature_text(value::AbstractString) =
    string(ncodeunits(value), ':', bytes2hex(codeunits(value)))

_signature_value(::Nothing) = "nothing"
_signature_value(value::Bool) = value ? "bool:1" : "bool:0"
_signature_value(value::Integer) = string("integer:", value)
_signature_value(value::AbstractFloat) =
    "float64:" * string(reinterpret(UInt64, Float64(value)); base = 16, pad = 16)
_signature_value(value::Symbol) = "symbol:" * _signature_text(String(value))

function _signature_value(value)
    throw(
        ArgumentError(
            "unsupported study-signature value type " *
            "$(typeof(value)); add an explicit canonical encoder",
        ),
    )
end

function _signature_value(value::Unitful.AbstractQuantity)
    # PhysicalParameters and Layer store quantities in their canonical units,
    # but retain the unit token as a type/contract guard.  The Float64 bit
    # pattern prevents close inputs from collapsing through report formatting.
    unit_token = string(Unitful.unit(value))
    magnitude = _signature_value(Float64(Unitful.ustrip(value)))
    return "quantity:" * _signature_text(unit_token) * _signature_text(magnitude)
end

function _signature_value(values::AbstractVector)
    encoded = (_signature_text(_signature_value(value)) for value in values)
    return string("vector:", length(values), ':', join(encoded))
end

function _signature_record(tag::AbstractString, value, fields = fieldnames(typeof(value)))
    encoded = String[]
    sizehint!(encoded, 2 * length(fields))
    for field in fields
        push!(encoded, _signature_text(String(field)))
        push!(encoded, _signature_text(_signature_value(getfield(value, field))))
    end
    return "record:" * _signature_text(tag) * string(length(fields), ':', join(encoded))
end

_signature_value(value::Layer) = _signature_record("Layer", value)
_signature_value(value::PhysicalParameters) = _signature_record("PhysicalParameters", value)
_signature_value(value::ScatteringOptions) = _signature_record("ScatteringOptions", value)

function _physics_signature(configuration::ResolvedRunConfiguration)
    algorithms = configuration.algorithms
    model_switches = (
        algorithms.retarded_real_part,
        algorithms.self_energy_structure,
        algorithms.transverse_momentum,
    )
    switch_names = (:retarded_real_part, :self_energy_structure, :transverse_momentum)
    switch_payload = String[]
    for (name, value) in zip(switch_names, model_switches)
        push!(switch_payload, _signature_text(String(name)))
        push!(switch_payload, _signature_text(_signature_value(value)))
    end
    return "reference design-physics-v2:" *
           _signature_text(_signature_value(configuration.physical)) *
           _signature_text(_signature_value(configuration.scattering)) *
           _signature_text(
               string("switches:", length(model_switches), ':', join(switch_payload)),
           )
end

function _structure_signature(configuration::ResolvedRunConfiguration)
    physical = configuration.physical
    # These fields define the grown/material device independently of the
    # operating point and collision-model switches.  Layer order and every
    # Layer property are retained, rather than only total period length.
    structural_fields = (:layers, :N_dop²ᴰ, :z₀, :interfaces)
    return "reference design-structure-v2:" *
           _signature_record("PhysicalStructure", physical, structural_fields)
end

_fatal_diagnostic_error(error) = error isa InterruptException

function _write_diagnostic_failure(
    output_directory::AbstractString;
    invocation_kind::Symbol,
    identity::AbstractString,
    error,
    wall_seconds::Real,
)
    path = joinpath(output_directory, "diagnostic_failure.csv")
    _observability_atomic_text(path) do stream
        println(
            stream,
            join(
                (
                    "schema",
                    "status",
                    "invocation_kind",
                    "identity",
                    "record_status",
                    "scba_quality",
                    "exception_type",
                    "message",
                    "wall_seconds",
                ),
                ',',
            ),
        )
        values = (
            "qcl-negf-diagnostic-failure-v1",
            "failed",
            invocation_kind,
            identity,
            :execution_failed,
            :invalid,
            string(typeof(error)),
            sprint(showerror, error),
            Float64(wall_seconds),
        )
        println(stream, join(_csv_field.(values), ','))
    end
    return abspath(path)
end

function _failed_diagnostic_sweep(
    configuration::ResolvedRunConfiguration,
    output_directory::AbstractString,
    wall_seconds::Real,
)
    records = ProductionSweepRecord[]
    for temperature in configuration.study.temperatures
        for voltage in configuration.study.voltages_per_period
            push!(
                records,
                ProductionSweepRecord(
                    _kelvin(temperature),
                    Float64(ustrip(u"V", uconvert(u"V", voltage))),
                    NaN,
                    NaN,
                    false,
                    :execution_failed,
                    :invalid,
                    0,
                    0,
                    0,
                    Float64(wall_seconds),
                    Dict{Symbol,Float64}(),
                    "",
                ),
            )
        end
    end
    summary = joinpath(output_directory, "diagnostic_failure_summary.csv")
    result = ProductionSweepResult(records, summary)
    save_production_summary(summary, result)
    return result
end

function _materialize_diagnostic_summary(
    sweep::ProductionSweepResult,
    output_directory::AbstractString,
)
    if !isempty(sweep.summary_path) && isfile(sweep.summary_path)
        return sweep
    end
    summary = joinpath(output_directory, "diagnostic_summary.csv")
    result = ProductionSweepResult(sweep.records, summary)
    save_production_summary(summary, result)
    return result
end

function _run_diagnostic_invocation(
    configuration::ResolvedRunConfiguration;
    invocation_kind::Symbol,
    identity::AbstractString,
    runner::Function = run_from_configuration,
)
    started = time_ns()
    try
        result = runner(configuration)
        return (sweep = result.sweep, failure_path = "")
    catch error
        elapsed = (time_ns() - started) * 1.0e-9
        if configuration.output.fail_fast || _fatal_diagnostic_error(error)
            rethrow()
        end
        backtrace = catch_backtrace()
        @error "diagnostic invocation failed; continuing because fail_fast=false" invocation_kind identity exception=(
            error,
            backtrace,
        )
        failure_path = _write_diagnostic_failure(
            configuration_output_directory(configuration);
            invocation_kind,
            identity,
            error,
            wall_seconds = elapsed,
        )
        sweep = _failed_diagnostic_sweep(
            configuration,
            configuration_output_directory(configuration),
            elapsed,
        )
        return (sweep = sweep, failure_path = failure_path)
    end
end

function _aggregate_repetition_value(values)
    present = Float64[Float64(value) for value in values if value !== nothing]
    missing_count = length(values) - length(present)
    finite = filter(isfinite, present)
    value, classification = if isempty(present)
        (NaN, :missing)
    elseif length(finite) == length(present)
        (something(_report_median(finite), NaN), :finite)
    elseif !isempty(finite)
        (something(_report_median(finite), NaN), :mixed_finite_nonfinite)
    elseif all(isnan, present)
        (NaN, :all_nan)
    elseif all(==(first(present)), present)
        (first(present), first(present) > 0 ? :all_positive_infinity : :all_negative_infinity)
    else
        (NaN, :nonfinite_disagreement)
    end
    if missing_count > 0 && classification !== :missing
        classification = Symbol("missing_repetitions_with_", classification)
    end
    disagreement =
        classification in (:mixed_finite_nonfinite, :nonfinite_disagreement) ||
        startswith(String(classification), "missing_repetitions_with_")
    return (
        value = value,
        classification = classification,
        disagreement = disagreement,
        finite_count = length(finite),
        present_count = length(present),
        missing_count = missing_count,
    )
end

function _write_repetition_aggregation(path::AbstractString, rows)
    _observability_atomic_text(path) do stream
        println(
            stream,
            join(
                (
                    "temperature_K",
                    "voltage_per_period_V",
                    "quantity",
                    "aggregate_value",
                    "value_classification",
                    "finite_count",
                    "present_count",
                    "missing_count",
                    "repetition_count",
                    "converged_count",
                    "statuses",
                    "scba_qualities",
                    "status_agreement",
                    "quality_agreement",
                    "converged_agreement",
                    "memory_estimate_agreement",
                ),
                ',',
            ),
        )
        for row in rows
            println(
                stream,
                join(
                    _csv_field.((
                        row.temperature_K,
                        row.voltage_per_period_V,
                        row.quantity,
                        row.aggregate_value,
                        row.value_classification,
                        row.finite_count,
                        row.present_count,
                        row.missing_count,
                        row.repetition_count,
                        row.converged_count,
                        row.statuses,
                        row.scba_qualities,
                        row.status_agreement,
                        row.quality_agreement,
                        row.converged_agreement,
                        row.memory_estimate_agreement,
                    )),
                    ',',
                ),
            )
        end
    end
    return abspath(path)
end

function _aggregate_sweep_repetitions(
    sweeps::AbstractVector{<:ProductionSweepResult},
    destination::AbstractString,
)
    isempty(sweeps) && throw(ArgumentError("no method repetitions to aggregate"))
    point_count = length(first(sweeps).records)
    all(length(sweep.records) == point_count for sweep in sweeps) ||
        throw(DimensionMismatch("method repetitions contain different point counts"))
    records = ProductionSweepRecord[]
    aggregation_rows = NamedTuple[]
    for index = 1:point_count
        source = first(sweeps).records[index]
        peers = [sweep.records[index] for sweep in sweeps]
        all(
            record.temperature_K == source.temperature_K &&
                record.voltage_per_period_V == source.voltage_per_period_V for
            record in peers
        ) || throw(ArgumentError("method repetitions contain different operating points"))
        status_agreement = all(record.status === source.status for record in peers)
        quality_agreement =
            all(record.scba_quality === source.scba_quality for record in peers)
        converged_agreement = all(record.converged == source.converged for record in peers)
        memory_agreement = all(
            record.estimated_peak_bytes == source.estimated_peak_bytes for record in peers
        )
        metric_names = union((Set(keys(record.metrics)) for record in peers)...)
        aggregates = Dict{Symbol,Any}(
            :field_V_per_m =>
                _aggregate_repetition_value(getfield.(peers, :field_V_per_m)),
            :current_A_per_m2 =>
                _aggregate_repetition_value(getfield.(peers, :current_A_per_m2)),
            :wall_seconds =>
                _aggregate_repetition_value(getfield.(peers, :wall_seconds)),
        )
        for name in metric_names
            aggregates[name] = _aggregate_repetition_value([
                get(record.metrics, name, nothing) for record in peers
            ])
        end
        numeric_disagreement = any(value.disagreement for value in values(aggregates))
        disagreement =
            !status_agreement ||
            !quality_agreement ||
            !converged_agreement ||
            !memory_agreement ||
            numeric_disagreement
        aggregate_status = disagreement ? :repetition_disagreement : source.status
        aggregate_quality = disagreement ? :invalid : source.scba_quality
        aggregate_converged = !disagreement && all(getfield.(peers, :converged))
        statuses = join(String.(getfield.(peers, :status)), ';')
        qualities = join(String.(getfield.(peers, :scba_quality)), ';')
        for (quantity, aggregate) in
            sort!(collect(aggregates); by = pair -> String(first(pair)))
            push!(
                aggregation_rows,
                (
                    temperature_K = source.temperature_K,
                    voltage_per_period_V = source.voltage_per_period_V,
                    quantity = quantity,
                    aggregate_value = aggregate.value,
                    value_classification = aggregate.classification,
                    finite_count = aggregate.finite_count,
                    present_count = aggregate.present_count,
                    missing_count = aggregate.missing_count,
                    repetition_count = length(peers),
                    converged_count = Base.count(record -> record.converged, peers),
                    statuses,
                    scba_qualities = qualities,
                    status_agreement,
                    quality_agreement,
                    converged_agreement,
                    memory_estimate_agreement = memory_agreement,
                ),
            )
        end
        metrics =
            Dict{Symbol,Float64}(name => aggregates[name].value for name in metric_names)
        push!(
            records,
            ProductionSweepRecord(
                source.temperature_K,
                source.voltage_per_period_V,
                source.field_V_per_m,
                source.current_A_per_m2,
                source.converged,
                source.status,
                source.scba_quality,
                maximum(getfield.(peers, :outer_iterations)),
                maximum(getfield.(peers, :final_scba_iterations)),
                maximum(getfield.(peers, :estimated_peak_bytes)),
                aggregates[:wall_seconds].value,
                copy(source.metrics),
                source.checkpoint,
                reduce(
                    vcat,
                    (record.warnings for record in peers);
                    init = Dict{String,Any}[],
                ),
            ),
        )
    end
    summary = joinpath(destination, "sweep_summary.csv")
    result = ProductionSweepResult(records, summary)
    save_production_summary(summary, result)
    _write_repetition_aggregation(
        joinpath(destination, "repetition_aggregation.csv"),
        aggregation_rows,
    )
    return result
end


function _aggregate_repetitions(
    results::Vector{ProductionSweepResult},
    destination::AbstractString,
)
    return _aggregate_sweep_repetitions(results, destination)
end

function _method_catalog(
    path::AbstractString,
    study::ResolvedRunConfiguration,
    summaries::Dict{String,String},
    configurations::AbstractDict{String,<:ResolvedRunConfiguration},
)
    _observability_atomic_text(path) do stream
        println(
            stream,
            join(
                (
                    "method_id",
                    "label",
                    "structure_id",
                    "physics_signature",
                    "modifies_physics",
                    "algorithm_family",
                    "summary_path",
                    "description",
                    "literature",
                ),
                ',',
            ),
        )
        for method in study.study.methods
            summary = summaries[method.profile]
            configuration = configurations[method.profile]
            _validate_method_metadata(method, configuration)
            values = (
                splitext(basename(method.profile))[1],
                method.label,
                _structure_signature(configuration),
                _physics_signature(configuration),
                method.modifies_physics,
                method.algorithm_family,
                relpath(summary, dirname(path)),
                method.description,
                join(method.literature, "; "),
            )
            println(stream, join(_csv_field.(values), ','))
        end
    end
    return abspath(path)
end

"""
    run_comparison_study(configuration_directory)

Deprecated combined compute wrapper. For saved analysis use `compare_saved_results`
or CLI `compare`; `plan`/`run-plan` create and execute declared plans.

Run every `study.methods` profile on the same physical structure, grid,
operating points, and convergence tolerances.  Each repetition has its own
checkpoint directory; its physical records remain separate. The comparison
uses the first actual repetition and reports timing statistics and finite-value
disagreement evidence instead of aborting the remaining diagnostics.
Only after all calculations finish is the expert Markdown/CSV report assembled.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
function run_comparison_study(configuration_directory::AbstractString)
    study = load_run_configuration(configuration_directory)
    return run_comparison_study(study, _find_profile_root(configuration_directory))
end

function run_comparison_study(study::ResolvedRunConfiguration, profile_root::AbstractString)
    @warn "run_comparison_study is a deprecated combined compute wrapper: executes declared methods × repetitions. Use plan/run-plan for create/execute and compare_saved_results/CLI compare for saved analysis."
    study.study.mode === :comparison ||
        throw(ArgumentError("run_comparison_study requires study.mode: comparison"))
    output = configuration_output_directory(study)
    summaries = Dict{String,String}()
    effective_configurations = Dict{String,ResolvedRunConfiguration}()
    for (method_index, method_metadata) in enumerate(study.study.methods)
        profile = load_run_configuration(
            _profile_directory(profile_root, method_metadata.profile),
        )
        repetition_results = ProductionSweepResult[]
        method_root = joinpath(output, "methods", method_metadata.profile)
        for repetition = 1:study.study.repetitions
            repetition_output = joinpath(method_root, "repetition_$repetition")
            overrides = get(
                study.raw["study"]["methods"][method_index],
                "overrides",
                Dict{String,Any}(),
            )
            configured = _method_configuration(study, profile, repetition_output; overrides)
            _validate_method_metadata(method_metadata, configured)
            effective_configurations[method_metadata.profile] = configured
            invocation = _run_diagnostic_invocation(
                configured;
                invocation_kind = :method_repetition,
                identity = "$(method_metadata.profile)/repetition_$repetition",
            )
            push!(repetition_results, invocation.sweep)
        end
        summaries[method_metadata.profile] =
            _aggregate_repetitions(repetition_results, method_root).summary_path
    end
    catalog = _method_catalog(
        joinpath(output, "method_catalog.csv"),
        study,
        summaries,
        effective_configurations,
    )
    report_directory = joinpath(output, study.output.report_directory)
    generated = generate_expert_report(
        catalog,
        report_directory;
        reference_id = Symbol(splitext(basename(study.study.reference_profile))[1]),
        title = "reference design NEGF production method comparison",
    )
    return (
        configuration = study,
        summaries = summaries,
        catalog = catalog,
        report = generated,
        output_directory = output,
    )
end

function _numerical_with_axis(n::NumericalParameters, axis::Symbol, value::Int)
    axis in (:spatial_nodes, :energy_nodes, :momentum_nodes, :angular_nodes) ||
        throw(ArgumentError("unknown convergence axis: $(axis)"))
    return NumericalParameters(
        N_z = axis === :spatial_nodes ? value : n.N_z,
        N_b = n.N_b,
        P_basis = n.P_basis,
        E_min = n.E_min,
        E_max = n.E_max,
        N_E = axis === :energy_nodes ? value : n.N_E,
        M_E = n.M_E,
        k_max = n.k_max,
        N_k = axis === :momentum_nodes ? value : n.N_k,
        N_φ = axis === :angular_nodes ? value : n.N_φ,
        qz_max = n.qz_max,
        N_qz = n.N_qz,
        η_seed = n.η_seed,
    )
end

const _CONVERGENCE_AXES = (:spatial_nodes, :energy_nodes, :momentum_nodes, :angular_nodes)

_numerical_grid_key(numerical::NumericalParameters) =
    (numerical.N_z, numerical.N_E, numerical.N_k, numerical.N_φ)

function _convergence_grid_id(key::NTuple{4,Int})
    return "z$(key[1])_e$(key[2])_k$(key[3])_phi$(key[4])"
end

function _convergence_grid_requests(configuration::ResolvedRunConfiguration)
    owners = Dict{NTuple{4,Int},Tuple{Symbol,Int}}()
    requests = NamedTuple[]
    for axis in _CONVERGENCE_AXES
        values = sort!(unique(getproperty(configuration.study.convergence, axis)))
        for value in values
            numerical = _numerical_with_axis(configuration.numerical, axis, value)
            key = _numerical_grid_key(numerical)
            owner = get(owners, key, nothing)
            if owner === nothing
                owner = (axis, value)
                owners[key] = owner
            end
            push!(
                requests,
                (
                    axis = axis,
                    value = value,
                    numerical = numerical,
                    key = key,
                    grid_id = _convergence_grid_id(key),
                    canonical_axis = owner[1],
                    canonical_value = owner[2],
                    reused = owner != (axis, value),
                ),
            )
        end
    end
    return requests
end

_unique_convergence_grid_count(configuration::ResolvedRunConfiguration) =
    Base.count(request -> !request.reused, _convergence_grid_requests(configuration))

function _write_convergence_plan(output::AbstractString, requests)
    path = joinpath(output, "convergence_grid_plan.csv")
    _observability_atomic_text(path) do stream
        println(
            stream,
            join(
                (
                    "axis",
                    "nodes",
                    "grid_id",
                    "solver_invocation",
                    "reused",
                    "canonical_axis",
                    "canonical_nodes",
                ),
                ',',
            ),
        )
        for request in requests
            println(
                stream,
                join(
                    _csv_field.((
                        request.axis,
                        request.value,
                        request.grid_id,
                        !request.reused,
                        request.reused,
                        request.canonical_axis,
                        request.canonical_value,
                    )),
                    ',',
                ),
            )
        end
    end
    return abspath(path)
end

function _configuration_with_numerical(
    configuration::ResolvedRunConfiguration,
    numerical::NumericalParameters,
    output_directory::AbstractString,
    name::AbstractString,
)
    raw = deepcopy(configuration.raw)
    raw["run"]["name"] = String(name)
    raw["output"]["directory"] = String(output_directory)
    raw["numerical"]["spatial_nodes"] = numerical.N_z
    raw["numerical"]["energy_nodes"] = numerical.N_E
    raw["numerical"]["momentum_nodes"] = numerical.N_k
    raw["numerical"]["angular_nodes"] = numerical.N_φ
    sources = deepcopy(configuration.provenance.sources)
    _append_generated_source!(sources, "run.name")
    _append_generated_source!(sources, "output.directory")
    for (path, actual, previous) in (
        ("numerical.spatial_nodes", numerical.N_z, configuration.numerical.N_z),
        ("numerical.energy_nodes", numerical.N_E, configuration.numerical.N_E),
        ("numerical.momentum_nodes", numerical.N_k, configuration.numerical.N_k),
        ("numerical.angular_nodes", numerical.N_φ, configuration.numerical.N_φ),
    )
        actual == previous || _append_generated_source!(sources, path)
    end
    provenance = ConfigurationProvenance(
        copy(configuration.provenance.manifests),
        copy(configuration.provenance.files),
        sources,
    )
    return ResolvedRunConfiguration(
        String(name),
        configuration.description,
        configuration.classification,
        configuration.physical,
        numerical,
        configuration.scales,
        configuration.scattering,
        configuration.solver,
        configuration.production,
        configuration.kernels,
        configuration.algorithms,
        configuration.execution,
        _output_with_directory(configuration.output, output_directory),
        configuration.study,
        provenance,
        raw,
        configuration.physical_models,
        configuration.domain_adaptation,
    )
end

function _write_convergence_report(output::AbstractString, rows)
    csv_path = joinpath(output, "convergence_comparison.csv")
    _observability_atomic_text(csv_path) do stream
        println(
            stream,
            join(
                (
                    "axis",
                    "nodes",
                    "reference_nodes",
                    "temperature_K",
                    "voltage_per_period_V",
                    "metric",
                    "reference_value",
                    "candidate_value",
                    "absolute_error",
                    "relative_error",
                    "reference_status",
                    "candidate_status",
                    "reference_scba_quality",
                    "candidate_scba_quality",
                    "pair_converged",
                ),
                ',',
            ),
        )
        for row in rows
            println(
                stream,
                join(
                    _csv_field.((
                        row.axis,
                        row.nodes,
                        row.reference_nodes,
                        row.temperature_K,
                        row.voltage_per_period_V,
                        row.metric,
                        row.reference_value,
                        row.candidate_value,
                        row.absolute_error,
                        row.relative_error,
                        row.reference_status,
                        row.candidate_status,
                        row.reference_scba_quality,
                        row.candidate_scba_quality,
                        row.pair_converged,
                    )),
                    ',',
                ),
            )
        end
    end
    markdown_path = joinpath(output, "convergence_report.md")
    _observability_atomic_text(markdown_path) do stream
        println(stream, "# reference design discretization convergence\n")
        println(
            stream,
            "The largest configured node count on each axis is the " *
            "comparison reference. Unconverged pairs are retained but must not " *
            "be used for error claims. Status and independent SCBA quality are " *
            "reported for both sides of every pair.\n",
        )
        println(
            stream,
            "| Axis | Nodes | Reference | Metric | Max converged relative error | Pairs | Status / SCBA quality |",
        )
        println(stream, "|---|---:|---:|---|---:|---:|---|")
        groups =
            unique((row.axis, row.nodes, row.reference_nodes, row.metric) for row in rows)
        for key in sort!(collect(groups); by = x -> (String(x[1]), x[2], String(x[4])))
            selected = filter(
                row -> (row.axis, row.nodes, row.reference_nodes, row.metric) == key,
                rows,
            )
            valid = [
                row.relative_error for
                row in selected if row.pair_converged && isfinite(row.relative_error)
            ]
            maximum_error = isempty(valid) ? NaN : maximum(valid)
            states = sort!(
                unique(
                    "$(row.reference_status)/$(row.candidate_status); " *
                    "$(row.reference_scba_quality)/$(row.candidate_scba_quality)" for
                    row in selected
                ),
            )
            println(
                stream,
                "| `$(key[1])` | $(key[2]) | $(key[3]) | " *
                "`$(key[4])` | $(compact_number(maximum_error)) | " *
                "$(length(selected)) | $(join(states, "<br>")) |",
            )
        end
    end
    return csv_path, markdown_path
end

"""
    run_convergence_study(configuration_directory)

Run one-at-a-time ``N_z``, ``N_E``, ``N_k``, and ``N_\\varphi`` refinements with the
declared reference profile and write full-precision pointwise errors plus a
Markdown summary.  Empty axis lists are skipped.

See [Expert comparison workflow](@ref expert-comparison-workflow) and
[Physics-first tests](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/12_validation.md).
"""
function run_convergence_study(configuration_directory::AbstractString)
    study = load_run_configuration(configuration_directory)
    return run_convergence_study(study, _find_profile_root(configuration_directory))
end

function run_convergence_study(
    study::ResolvedRunConfiguration,
    profile_root::AbstractString,
)
    study.study.mode === :comparison ||
        throw(ArgumentError("run_convergence_study requires study.mode: comparison"))
    reference_metadata = only(
        filter(
            method -> method.profile == study.study.reference_profile,
            study.study.methods,
        ),
    )
    reference_profile = load_run_configuration(
        _profile_directory(profile_root, study.study.reference_profile),
    )
    _validate_method_metadata(reference_metadata, reference_profile)
    output = joinpath(configuration_output_directory(study), "convergence")
    base = _method_configuration(study, reference_profile, joinpath(output, "points"))
    requests = _convergence_grid_requests(study)
    plan = _write_convergence_plan(output, requests)
    runs = Dict{NTuple{4,Int},MethodRun}()
    for request in requests
        request.reused && continue
        directory = joinpath(output, "points", request.grid_id)
        configured = _configuration_with_numerical(
            base,
            request.numerical,
            directory,
            "$(study.name)__$(request.grid_id)",
        )
        invocation = _run_diagnostic_invocation(
            configured;
            invocation_kind = :convergence_grid,
            identity = request.grid_id,
        )
        sweep = _materialize_diagnostic_summary(invocation.sweep, directory)
        descriptor = MethodDescriptor(
            id = Symbol(request.grid_id),
            label = request.grid_id,
            structure_id = _structure_signature(study),
            physics_signature = _physics_signature(base),
            modifies_physics = false,
            algorithm_family = reference_metadata.algorithm_family,
            description = "unique one-axis discretization convergence grid",
        )
        runs[request.key] = load_method_run(descriptor, sweep.summary_path)
    end
    rows = NamedTuple[]
    for axis in _CONVERGENCE_AXES
        axis_requests = filter(request -> request.axis === axis, requests)
        isempty(axis_requests) && continue
        reference_request = axis_requests[argmax(getfield.(axis_requests, :value))]
        reference_nodes = reference_request.value
        reference = runs[reference_request.key]
        for request in axis_requests
            request.value == reference_nodes && continue
            candidate = runs[request.key]
            comparison = compare_method_runs(
                [reference, candidate];
                reference_id = reference.descriptor.id,
            )
            for row in comparison.rows
                reference_point = only(
                    filter(
                        point ->
                            point.temperature_K == row.temperature_K &&
                            point.voltage_per_period_V == row.voltage_per_period_V,
                        reference.points,
                    ),
                )
                candidate_point = only(
                    filter(
                        point ->
                            point.temperature_K == row.temperature_K &&
                            point.voltage_per_period_V == row.voltage_per_period_V,
                        candidate.points,
                    ),
                )
                push!(
                    rows,
                    (
                        axis = axis,
                        nodes = request.value,
                        reference_nodes = reference_nodes,
                        temperature_K = row.temperature_K,
                        voltage_per_period_V = row.voltage_per_period_V,
                        metric = row.metric,
                        reference_value = row.reference_value,
                        candidate_value = row.candidate_value,
                        absolute_error = row.absolute_error,
                        relative_error = something(row.relative_error, NaN),
                        reference_status = reference_point.status,
                        candidate_status = candidate_point.status,
                        reference_scba_quality = row.reference_scba_quality,
                        candidate_scba_quality = row.candidate_scba_quality,
                        pair_converged = row.reference_converged && row.candidate_converged,
                    ),
                )
            end
        end
    end
    csv, markdown = _write_convergence_report(output, rows)
    return (
        configuration = study,
        rows = rows,
        csv = csv,
        markdown = markdown,
        plan = plan,
        output_directory = output,
    )
end

"""Run method comparison first, then the independent grid-convergence study.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
function run_production_study(configuration_directory::AbstractString)
    study = load_run_configuration(configuration_directory)
    return run_production_study(study, _find_profile_root(configuration_directory))
end

function _run_study_phase(
    operation::Function,
    study::ResolvedRunConfiguration,
    output::AbstractString,
    phase::Symbol,
)
    started = time_ns()
    try
        return operation()
    catch error
        if study.output.fail_fast || _fatal_diagnostic_error(error)
            rethrow()
        end
        backtrace = catch_backtrace()
        @error "diagnostic study phase failed; continuing because fail_fast=false" phase exception=(
            error,
            backtrace,
        )
        _write_diagnostic_failure(
            joinpath(output, "study_failures", String(phase));
            invocation_kind = :study_phase,
            identity = String(phase),
            error,
            wall_seconds = (time_ns() - started) * 1.0e-9,
        )
        return nothing
    end
end


function run_production_study(study::ResolvedRunConfiguration, profile_root::AbstractString)
    output = configuration_output_directory(study)
    methods = _run_study_phase(study, output, :method_comparison) do
        run_comparison_study(study, profile_root)
    end
    convergence = _run_study_phase(study, output, :grid_convergence) do
        run_convergence_study(study, profile_root)
    end
    method_catalog = methods === nothing ? "" : methods.catalog
    method_report =
        methods === nothing ? (markdown = "", comparison_csv = "", points_csv = "") :
        methods.report.paths
    convergence_csv = convergence === nothing ? "" : convergence.csv
    convergence_markdown = convergence === nothing ? "" : convergence.markdown
    return ProductionStudyResult(
        study,
        method_catalog,
        method_report,
        convergence_csv,
        convergence_markdown,
        output,
    )
end
