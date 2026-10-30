"""
    QCLProductionPointRunner(configuration)

Adapter between the solver-independent [`QCLApplicationRuntime`](@ref) and
the existing configured production workflow. Each runtime point is translated
to a one-temperature/one-voltage [`ResolvedRunConfiguration`](@ref), whose
artifacts are confined to that content-addressed point directory.

The generic runtime remains unaware of `NEGFProblem`, `ConfiguredRunResult`,
HDF5, and the production solver. The adapter deliberately reuses
[`run_from_configuration`](@ref) as the certified solver entry point.
"""
struct QCLProductionPointRunner <: AbstractPointRunner
    configuration::ResolvedRunConfiguration
    phase_telemetry::QCLScientificWorkflow.TelemetryOutputPolicy
    phase_observation_policy::Union{Nothing,PhaseObservationPolicy}
    source_graph::Union{Nothing,Dict{String,Any}}
    plan_capture::_P05PlanCapture
    function QCLProductionPointRunner(configuration::ResolvedRunConfiguration;
        phase_telemetry::QCLScientificWorkflow.TelemetryOutputPolicy=ScientificOutputs().telemetry,
        phase_observation_policy::Union{Nothing,PhaseObservationPolicy}=nothing,
        source_graph::Union{Nothing,AbstractDict}=nothing,
        frozen_plan_capture::Union{Nothing,_P05PlanCapture}=nothing)
        configuration.execution.solver_backend === :production || throw(
            ArgumentError("QCLProductionPointRunner requires the production backend"),
        )
        configuration.study.mode in (:single, :sweep) || throw(
            ArgumentError(
                "nested operating-point runtime accepts single/sweep " *
                "configurations; use run_production_study for comparison",
            ),
        )
        isempty(configuration.study.temperatures) &&
            throw(ArgumentError("configured nested sweep has no temperatures"))
        isempty(configuration.study.voltages_per_period) &&
            throw(ArgumentError("configured nested sweep has no voltages per period"))
        _assert_runtime_configuration_consistency(configuration)
        phase_telemetry.buffer_events>0 || throw(ArgumentError("phase telemetry buffer_events must be positive"))
        phase_observation_policy===nothing || phase_observation_policy.batch_events<=phase_telemetry.buffer_events ||
            throw(ArgumentError("phase observation batch exceeds event capacity"))
        graph=source_graph===nothing ? nothing : _require_source_graph(source_graph)
        capture=frozen_plan_capture===nothing ? _p05_capture_plan(Vector{UInt8}(codeunits(YAML.write(
            QCLApplicationRuntime._sweep_plan_dict(configured_nested_sweep_plan(configuration))))),:nested_sweep;
            maximum_metadata_bytes=configuration.production.memory_budget_bytes) : frozen_plan_capture
        capture.kind===:nested_sweep || throw(ArgumentError("configured original plan kind differs"))
        new(configuration,phase_telemetry,phase_observation_policy,graph,capture)
    end
end

QCLApplicationRuntime._native_point_source(::QCLProductionPointRunner)=_p05_native_source(".";reason="no_selected_native_state")
function QCLApplicationRuntime._verify_completed_point(runner::QCLProductionPointRunner,repository,definition,point,result)
    result["schema"]=="qcl-negf-configured-point-result-v2" || throw(ArgumentError("native configured result schema differs"))
    source=result["result"]["native_source"]
    source["kind"]=="final" || throw(ArgumentError("completed configured result lacks native final"))
    identity=source["selected_state"]["identity"]
    identity["run_id"]==definition.identity.run_id && identity["point_id"]==point.point_id || throw(ArgumentError("native configured row identity differs"))
    source["relation"]=="current_point_attempt" && identity["attempt"]==string(result["attempt"]) || throw(ArgumentError("native configured attempt differs"))
    roots=(;entry=(runner,definition,point,result),resources=(),construction=(),continuation=(),history=(),observers=(),inputs_publication=(source,))
    limit=_p05_closed_metadata_limit(runner.configuration.production.memory_budget_bytes,roots)
    root=run_workspace_directory(repository,definition.identity.run_id)
    _p05_verify_native_source(root,source,limit)
    result["result"]["optical_attachment"]===nothing || throw(ArgumentError("native5_optical_codec_verification_pending"))
    nothing
end

_production_runtime_adapter_source() =
    _package_path("src", "composition", "production_runtime_adapter.jl")

"""Build the configured temperature -> voltage application sweep tree."""
function configured_nested_sweep_plan(configuration::ResolvedRunConfiguration)
    temperatures = Any[_runner_kelvin(value) for value in configuration.study.temperatures]
    voltages = Any[
        Float64(ustrip(u"V", uconvert(u"V", value))) for
        value in configuration.study.voltages_per_period
    ]
    return NestedSweepPlan(
        "configured_operating_points",
        SweepLevel(
            "temperature",
            [SweepAxis("temperature_K", temperatures)],
            SweepLevel(
                "voltage",
                [SweepAxis("voltage_per_period_V", voltages)],
                SweepLeaf("poisson_scba"),
            ),
        ),
    )
end

_runtime_typed_identity(::Nothing) = nothing
_runtime_typed_identity(value::Bool) = value
_runtime_typed_identity(value::Integer) = value
_runtime_typed_identity(value::AbstractFloat) = Float64(value)
_runtime_typed_identity(value::AbstractString) = String(value)
_runtime_typed_identity(value::Symbol) = String(value)

function _runtime_typed_identity(value::Unitful.AbstractQuantity)
    return Dict{String,Any}(
        "value" => Float64(Unitful.ustrip(value)),
        "unit" => string(Unitful.unit(value)),
    )
end

function _runtime_typed_identity(values::Union{AbstractVector,Tuple})
    return Any[_runtime_typed_identity(value) for value in values]
end

function _runtime_typed_identity(value)
    type = typeof(value)
    isstructtype(type) ||
        throw(ArgumentError("unsupported typed runtime identity value $type"))
    names = fieldnames(type)
    isempty(names) && throw(
        ArgumentError("typed runtime identity requires an explicit encoder for $type"),
    )
    fields = Dict{String,Any}()
    for name in names
        fields[String(name)] = _runtime_typed_identity(getfield(value, name))
    end
    return Dict{String,Any}("type" => String(nameof(type)), "fields" => fields)
end

function _runtime_production_configuration_identity(production::ProductionOptions)
    fields = Dict{String,Any}()
    for name in fieldnames(ProductionOptions)
        # A reporter is an injected process-local presentation adapter. It is
        # neither expressible in YAML nor a numerical input.
        name === :event_sink && continue
        fields[String(name)] = _runtime_typed_identity(getfield(production, name))
    end
    return Dict{String,Any}("type" => "ProductionOptions", "fields" => fields)
end

function _runtime_complete_configuration_identity(configuration::ResolvedRunConfiguration)
    return Dict{String,Any}(
        "run" => Dict{String,Any}(
            "name" => configuration.name,
            "description" => configuration.description,
            "classification" => String(configuration.classification),
        ),
        "physical" => _runtime_typed_identity(configuration.physical),
        "numerical" => _runtime_typed_identity(configuration.numerical),
        "scales" => _runtime_typed_identity(configuration.scales),
        "scattering" => _runtime_typed_identity(configuration.scattering),
        "solver" => _runtime_typed_identity(configuration.solver),
        "production" =>
            _runtime_production_configuration_identity(configuration.production),
        "kernel_construction" => _runtime_typed_identity(configuration.kernels),
        "algorithms" => _runtime_typed_identity(configuration.algorithms),
        "execution" => _runtime_typed_identity(configuration.execution),
        "output" => _runtime_typed_identity(configuration.output),
        "study" => _runtime_typed_identity(configuration.study),
    )
end

"""
Reparse the retained YAML tree and prove that it describes the same typed
configuration that will reach the solver. This prevents a programmatically
constructed `ResolvedRunConfiguration` from deriving a content ID from one
model while emitting `resolved_configuration.yaml` for another model.
"""
function _assert_runtime_configuration_consistency(configuration::ResolvedRunConfiguration)
    reparsed = try
        _resolve_configuration(deepcopy(configuration.raw), configuration.provenance)
    catch error
        error isa ConfigurationError || rethrow()
        throw(
            ArgumentError(
                "runtime raw configuration cannot be resolved consistently: " *
                sprint(showerror, error),
            ),
        )
    end
    typed_identity = _runtime_complete_configuration_identity(configuration)
    raw_identity = _runtime_complete_configuration_identity(reparsed)
    canonical_bytes(typed_identity) == canonical_bytes(raw_identity) || throw(
        ArgumentError(
            "runtime typed/raw configuration mismatch: refusing to derive " *
            "or reuse a content-addressed run; typed=" *
            content_id("configuration", typed_identity) *
            ", raw=" *
            content_id("configuration", raw_identity),
        ),
    )
    return reparsed
end

function _runtime_study_controls(study::StudyConfiguration)
    return Dict{String,Any}(
        "calculate_optical_response" => study.calculate_optical_response,
        "photon_energy_min" => _runtime_typed_identity(study.photon_energy_min),
        "photon_energy_max" => _runtime_typed_identity(study.photon_energy_max),
        "photon_energy_points" => study.photon_energy_points,
        "optical_edge_tolerance" => study.optical_edge_tolerance,
    )
end

function _runtime_scientific_identity(configuration::ResolvedRunConfiguration)
    # Production chunks, worker counts, memory guards, checkpoint cadence, and
    # progress cadence are execution policy. The mathematical backend is fully
    # represented by solver, kernel_construction, algorithms, and source bytes.
    algorithms = _runtime_typed_identity(configuration.algorithms)
    production_algorithms = _runtime_typed_identity(configuration.production.algorithms)
    canonical_bytes(algorithms) == canonical_bytes(production_algorithms) ||
        throw(ArgumentError("configuration.algorithms and production.algorithms disagree"))
    configuration.algorithms.solver_backend === configuration.execution.solver_backend ||
        throw(ArgumentError("algorithm and execution solver backends disagree"))
    identity = Dict{String,Any}(
        "physical" => _runtime_typed_identity(configuration.physical),
        "numerical" => _runtime_typed_identity(configuration.numerical),
        "scales" => _runtime_typed_identity(configuration.scales),
        "scattering" => _runtime_typed_identity(configuration.scattering),
        "solver" => _runtime_typed_identity(configuration.solver),
        "kernel_construction" => _runtime_typed_identity(configuration.kernels),
        "algorithms" => algorithms,
    )
    identity["solver_backend"] = String(configuration.execution.solver_backend)
    identity["production_validation"] = Dict{String,Any}(
        "verify_fft_roundoff" => configuration.production.verify_fft_roundoff,
    )
    identity["study_controls"] = _runtime_study_controls(configuration.study)
    return identity
end

function _runtime_source_files(root::AbstractString = _package_path())
    paths = String[joinpath(root, "Project.toml")]
    manifest = joinpath(root, "Manifest.toml")
    isfile(manifest) && push!(paths, manifest)
    schema = joinpath(root, "schema", "run.schema.json")
    isfile(schema) && push!(paths, schema)
    for (directory, _, names) in walkdir(joinpath(root, "src"))
        append!(paths, joinpath.(directory, filter(name -> endswith(name, ".jl"), names)))
    end
    sort!(paths)
    return root, paths
end

function _runtime_blas_vendor()
    return try
        string(BLAS.vendor())
    catch
        "unknown"
    end
end

function _runtime_software_identity()
    sources = Dict{String,Any}[]
    for (name, package) in (("QCLNEGF", QCLNEGF), ("QCLNEGFRunner", @__MODULE__))
        root, paths = _runtime_source_files(pkgdir(package))
        for record in fingerprint_sources(paths; root)
            record["path"] = name * "/" * record["path"]
            push!(sources, record)
        end
    end
    sort!(sources; by = record -> record["path"])
    return Dict{String,Any}(
        "package" => "QCLNEGFRunner",
        "package_version" => _runner_package_version(),
        "julia_version" => string(VERSION),
        "blas_vendor" => _runtime_blas_vendor(),
        "source_files" => sources,
        "toolchain" => _runtime_toolchain_provenance(),
    )
end

function _runtime_completion_policy(output::OutputConfiguration)
    fields = Dict{String,Any}()
    for name in fieldnames(OutputConfiguration)
        # Physical storage may be relocated between devices without changing
        # content identity. Every other output field can change the promised
        # completion certificate or generated artifact set and is therefore
        # identity-bearing.
        name === :directory && continue
        fields[String(name)] = _runtime_typed_identity(getfield(output, name))
    end
    return Dict{String,Any}("type" => "OutputCompletionPolicy", "fields" => fields)
end

"""
    configured_nested_run_definition(configuration)

Bind the resolved physical/numerical model, solver source tree, requested
artifact/completion policy, and nested operating-point set to a SHA-256 run
identity. The relocatable output directory and display labels are excluded;
changing an artifact policy produces a new run so a completed point cannot be
silently reused without newly requested outputs.
"""
function configured_nested_run_definition(configuration::ResolvedRunConfiguration)
    _assert_runtime_configuration_consistency(configuration)
    plan = configured_nested_sweep_plan(configuration)
    software_identity = _runtime_software_identity()
    software_identity["completion_policy"] =
        _runtime_completion_policy(configuration.output)
    return RunDefinition(
        plan;
        scientific_identity = _runtime_scientific_identity(configuration),
        software_identity,
        labels = Dict{String,Any}(
            "name" => configuration.name,
            "description" => configuration.description,
            "classification" => String(configuration.classification),
        ),
    )
end

function _runtime_coordinate(point::SweepPoint, key::AbstractString)
    coordinates = Dict{String,Any}(point.coordinates)
    haskey(coordinates, key) ||
        throw(ArgumentError("runtime point $(point.point_id) is missing coordinate $key"))
    value = coordinates[key]
    value isa Real || throw(
        ArgumentError("runtime coordinate $key must be numeric, got $(typeof(value))"),
    )
    number = Float64(value)
    isfinite(number) || throw(ArgumentError("runtime coordinate $key must be finite"))
    return number
end

function _runtime_generated_provenance(configuration::ResolvedRunConfiguration)
    sources = deepcopy(configuration.provenance.sources)
    source = _production_runtime_adapter_source()
    for path in (
        "run.name",
        "output.directory",
        "study.mode",
        "study.voltages_per_period",
        "study.temperatures",
        "study.comparison_profiles",
        "study.reference_profile",
        "study.methods",
        "study.repetitions",
        "study.convergence.spatial_nodes",
        "study.convergence.energy_nodes",
        "study.convergence.momentum_nodes",
        "study.convergence.angular_nodes",
    )
        history = get!(sources, path, String[])
        if isempty(history) || last(history) != source
            push!(history, source)
        end
    end
    return ConfigurationProvenance(
        copy(configuration.provenance.manifests),
        copy(configuration.provenance.files),
        sources,
    )
end

function _configured_point_study(
    study::StudyConfiguration,
    temperature_K::Real,
    voltage_per_period_V::Real,
)
    return StudyConfiguration(
        :single,
        typeof(1.0u"V")[Float64(voltage_per_period_V)*u"V"],
        TemperatureQuantity[Float64(temperature_K)*u"K"],
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

function _configured_point_configuration(
    runner::QCLProductionPointRunner,
    point::SweepPoint,
    output_directory::AbstractString,
)
    configuration = runner.configuration
    temperature_K = _runtime_coordinate(point, "temperature.temperature_K")
    voltage_V = _runtime_coordinate(point, "voltage.voltage_per_period_V")
    point_name = "$(configuration.name)__$(point.point_id[7:18])"
    absolute_output_directory = abspath(output_directory)
    raw = deepcopy(configuration.raw)
    raw["run"]["name"] = point_name
    raw["output"]["directory"] = absolute_output_directory
    raw["study"]["mode"] = "single"
    raw["study"]["temperatures"] = ["$(temperature_K) K"]
    raw["study"]["voltages_per_period"] = ["$(voltage_V) V"]
    raw["study"]["comparison_profiles"] = Any[]
    raw["study"]["reference_profile"] = nothing
    raw["study"]["methods"] = Any[]
    raw["study"]["repetitions"] = 1
    for axis in ("spatial_nodes", "energy_nodes", "momentum_nodes", "angular_nodes")
        raw["study"]["convergence"][axis] = Any[]
    end
    point_configuration = ResolvedRunConfiguration(
        point_name,
        configuration.description,
        configuration.classification,
        configuration.physical,
        configuration.numerical,
        configuration.scales,
        configuration.scattering,
        configuration.solver,
        configuration.production,
        configuration.kernels,
        configuration.algorithms,
        configuration.execution,
        _output_with_directory(configuration.output, absolute_output_directory),
        _configured_point_study(configuration.study, temperature_K, voltage_V),
        _runtime_generated_provenance(configuration),
        raw,
        configuration.physical_models,
        configuration.domain_adaptation,
    )
    _assert_runtime_configuration_consistency(point_configuration)
    return point_configuration
end

function _runtime_artifact(
    run_root::AbstractString,
    path::AbstractString;
    media_type::AbstractString,
)
    isempty(path) && return nothing
    absolute = abspath(path)
    root = realpath(run_root)
    relative = relpath(absolute, root)
    first(splitpath(relative)) == ".." &&
        throw(ArgumentError("point artifact escapes content-addressed run: $absolute"))
    isfile(absolute) || return nothing
    islink(absolute) &&
        throw(ArgumentError("point artifact must not be a symlink: $absolute"))
    resolved = realpath(absolute)
    first(splitpath(relpath(resolved, root))) == ".." && throw(
        ArgumentError("point artifact resolves outside content-addressed run: $resolved"),
    )
    return Dict{String,Any}(
        "path" => replace(relative, '\\' => '/'),
        "media_type" => String(media_type),
        "bytes" => filesize(absolute),
        "sha256" => file_sha256(absolute),
        "integrity_required" => true,
    )
end

function _runtime_artifact_media_type(path::AbstractString)
    suffix = lowercase(splitext(path)[2])
    return get(
        Dict(
            ".yaml" => "application/yaml",
            ".yml" => "application/yaml",
            ".json" => "application/json",
            ".csv" => "text/csv",
            ".html" => "text/html",
            ".md" => "text/markdown",
            ".h5" => "application/x-hdf5",
            ".hdf5" => "application/x-hdf5",
            ".png" => "image/png",
            ".svg" => "image/svg+xml",
            ".pdf" => "application/pdf",
        ),
        suffix,
        "application/octet-stream",
    )
end

function _runtime_point_artifacts(
    result,
    record::ProductionSweepRecord,
    run_root::AbstractString;
    phase_directory::Union{Nothing,AbstractString}=nothing,
)
    output_root = abspath(result.output_directory)
    phase_root = phase_directory===nothing ? nothing : abspath(phase_directory)
    function inside(path,root)
        relative=relpath(abspath(path),root)
        return relative=="." || (relative!=".." && !startswith(relative,"../") && !startswith(relative,"..\\"))
    end
    phase_root===nothing || (phase_root!=output_root && inside(phase_root,output_root)) ||
        throw(ArgumentError("phase directory must belong to point output"))
    candidates = (
        "resolved_configuration" => (
            joinpath(result.output_directory, "resolved_configuration.yaml"),
            "application/yaml",
        ),
        "execution_plan" => (
            joinpath(result.output_directory, "execution_plan.yaml"),
            "application/yaml",
        ),
        "output_policy" => (
            joinpath(result.output_directory, "output_policy.yaml"),
            "application/yaml",
        ),
        "algorithm_manifest" => (
            joinpath(result.output_directory, "algorithm_manifest.yaml"),
            "application/yaml",
        ),
        "optimization_catalog" => (
            joinpath(result.output_directory, "optimization_catalog.yaml"),
            "application/yaml",
        ),
        "configuration_provenance" => (
            joinpath(result.output_directory, "configuration_provenance.yaml"),
            "application/yaml",
        ),
        "summary" => (result.sweep.summary_path, "text/csv"),
        "progress_events" => (
            result.progress_csv,
            endswith(result.progress_csv, ".jsonl") ? "application/x-ndjson" : "text/csv",
        ),
        "progress_dashboard" => (result.live_dashboard, "text/html"),
        "checkpoint" => (record.checkpoint, "application/x-hdf5"),
    )
    artifacts = Dict{String,Any}()
    for (name, (path, media_type)) in candidates
        isempty(path) || phase_root===nothing || !inside(path,phase_root) || continue
        artifact = _runtime_artifact(run_root, path; media_type)
        artifact === nothing || (artifacts[name] = artifact)
    end
    # The configured workflow can add optical tables, kernel diagnostics, and
    # optional plot/report outputs. Catalogue every generated regular file so
    # completed-point resume verifies their digests instead of checking only a
    # fixed historical shortlist.
    if isdir(output_root)
        seen = Set(String(artifact["path"]) for artifact in values(artifacts))
        for (directory, directories, files) in walkdir(output_root; follow_symlinks = false)
            any(name -> islink(joinpath(directory, name)), directories) &&
                throw(ArgumentError("point output must not contain symlinked directories"))
            phase_root===nothing || filter!(name->abspath(joinpath(directory,name))!=phase_root,directories)
            for filename in sort(files)
                path = joinpath(directory, filename)
                islink(path) && throw(
                    ArgumentError(
                        "point output must not contain symlinked files: $filename",
                    ),
                )
                artifact = _runtime_artifact(
                    run_root,
                    path;
                    media_type = _runtime_artifact_media_type(path),
                )
                artifact === nothing && continue
                artifact["path"] in seen && continue
                relative = replace(relpath(path, output_root), '\\' => '/')
                key = "output:$relative"
                haskey(artifacts, key) &&
                    throw(ArgumentError("duplicate point artifact key $key"))
                artifacts[key] = artifact
                push!(seen, artifact["path"])
            end
        end
    end
    return artifacts
end

const _RUNTIME_RESIDUAL_METRICS = Set((
    :current_continuity,
    :charge_neutrality,
    :poisson,
    :hartree,
    :density,
    :dyson,
    :spectral_identity,
    :keldysh,
    :self_energy,
    :normalization,
    :positivity,
    :causality,
    :fft_roundoff,
))

const _RUNTIME_OPTICAL_METRIC_UNITS = Dict{Symbol,String}(
    :optical_trusted_fraction => "1",
    :optical_max_edge_loss => "1",
    :gain_peak_per_cm => "cm^-1",
    :gain_peak_energy_eV => "eV",
    :gain_peak_frequency_Hz => "Hz",
)

function _runtime_metric_trees(metrics::AbstractDict{Symbol,<:Real})
    residuals = Dict{String,Any}()
    optical = Dict{String,Any}()
    for (name, value) in metrics
        if name in _RUNTIME_RESIDUAL_METRICS
            residuals[String(name)] =
                Dict{String,Any}("value" => Float64(value), "unit" => "1")
        elseif haskey(_RUNTIME_OPTICAL_METRIC_UNITS, name)
            optical[String(name)] = Dict{String,Any}(
                "value" => Float64(value),
                "unit" => _RUNTIME_OPTICAL_METRIC_UNITS[name],
            )
        else
            throw(
                ArgumentError(
                    "runtime result has no explicit unit mapping for metric $name",
                ),
            )
        end
    end
    return residuals, optical
end

function _runtime_point_metadata(record::ProductionSweepRecord)
    residuals, optical = _runtime_metric_trees(record.metrics)
    current_A_per_cm2 =
        isfinite(record.current_A_per_m2) ?
        current_density_A_per_cm2(record.current_A_per_m2) : nothing
    return Dict{String,Any}(
        "quality" =>
            record.converged ? "strict" :
            record.scba_quality === :invalid ? "invalid" :
            record.status === :approximate ? "approximate" : "unconverged",
        "warnings" => copy(record.warnings),
        "operating_point" => Dict{String,Any}(
            "temperature" => Dict("value" => record.temperature_K, "unit" => "K"),
            "voltage_per_period" =>
                Dict("value" => record.voltage_per_period_V, "unit" => "V"),
            "electric_field" => Dict("value" => record.field_V_per_m, "unit" => "V/m"),
        ),
        "observables" => Dict{String,Any}(
            "electron_flow_current_density" =>
                Dict("value" => current_A_per_cm2, "unit" => "A/cm^2"),
            "optical_response" => optical,
        ),
        "convergence" => Dict{String,Any}(
            "converged" => record.converged,
            "status" => String(record.status),
            "scba_quality" => String(record.scba_quality),
            "outer_iterations" => record.outer_iterations,
            "final_scba_iterations" => record.final_scba_iterations,
            "residuals" => residuals,
        ),
        "performance" => Dict{String,Any}(
            "wall_time" => Dict("value" => record.wall_seconds, "unit" => "s"),
            "estimated_peak_memory" =>
                Dict("value" => record.estimated_peak_bytes, "unit" => "byte"),
        ),
    )
end

const _RUNTIME_PHYSICAL_PROGRESS_STAGES = (:poisson, :scba)
const _RUNTIME_POINT_TEXT_ARTIFACT_ESTIMATE_BYTES = 1_000_000
const _RUNTIME_OPTICAL_ROW_ESTIMATE_BYTES = 256
const _RUNTIME_PRODUCTION_CHECKPOINT_KIND = "production_state"
const _RUNTIME_PRODUCTION_CHECKPOINT_FORMAT = "QCLNEGF/HDF5"

"""Path-bearing state used only while a current HDF5 payload crosses the
generic checkpoint-codec port."""
struct _RuntimeProductionCheckpointPayload
    path::String
end

function _runtime_validate_current_hdf5_checkpoint(path::AbstractString)
    absolute = abspath(path)
    isfile(absolute) ||
        throw(CheckpointIntegrityError(absolute, "HDF5 checkpoint payload is missing"))
    islink(absolute) && throw(
        CheckpointIntegrityError(absolute, "HDF5 checkpoint payload must not be a symlink"),
    )
    try
        h5open(absolute, "r") do file
            _require_current_checkpoint(file)
        end
    catch error
        error isa CheckpointIntegrityError && rethrow()
        error isa InterruptException && rethrow()
        throw(
            CheckpointIntegrityError(
                absolute,
                "cannot read current HDF5 checkpoint metadata: " * sprint(showerror, error),
            ),
        )
    end
    return absolute
end

function _runtime_write_production_checkpoint(destination::AbstractString, state)
    state isa _RuntimeProductionCheckpointPayload ||
        throw(ArgumentError("production checkpoint codec requires an HDF5 payload"))
    source = _runtime_validate_current_hdf5_checkpoint(state.path)
    cp(source, destination; force = true)
    _runtime_validate_current_hdf5_checkpoint(destination)
    return destination
end

function _runtime_read_production_checkpoint(path::AbstractString)
    return _RuntimeProductionCheckpointPayload(
        _runtime_validate_current_hdf5_checkpoint(path),
    )
end

"""Current checkpoint codec for content-addressed production points.

The `reference2019-runtime-checkpoint-v1` envelope owns integrity and generation
metadata; its payload is the current QCLNEGFRunner HDF5 schema itself. No reference
file or compatibility translation participates in recovery.
"""
function _runtime_production_checkpoint_codec()
    return CallbackCheckpointCodec(
        "h5",
        _runtime_write_production_checkpoint,
        _runtime_read_production_checkpoint;
        validator = state -> state isa _RuntimeProductionCheckpointPayload,
    )
end

function _runtime_checkpoint_signature(path::AbstractString)
    info = stat(path)
    return (info.device, info.inode, info.size, info.mtime, info.ctime)
end

function _runtime_validate_staging_checkpoint_path(path::AbstractString)
    absolute = abspath(path)
    islink(absolute) && throw(
        CheckpointIntegrityError(absolute, "checkpoint staging path must not be a symlink"),
    )
    ispath(absolute) &&
        !isfile(absolute) &&
        throw(
            CheckpointIntegrityError(
                absolute,
                "checkpoint staging path is not a regular file",
            ),
        )
    return absolute
end

function _runtime_discard_staging_checkpoint!(path::AbstractString)
    absolute = _runtime_validate_staging_checkpoint_path(path)
    isfile(absolute) && rm(absolute; force = true)
    return absolute
end

function _runtime_atomic_copy_checkpoint(
    source::AbstractString,
    destination::AbstractString,
)
    validated_source = _runtime_validate_current_hdf5_checkpoint(source)
    validated_destination = _runtime_validate_staging_checkpoint_path(destination)
    directory = dirname(validated_destination)
    mkpath(directory)
    temporary, stream = mktemp(directory)
    close(stream)
    try
        cp(validated_source, temporary; force = true)
        _runtime_validate_current_hdf5_checkpoint(temporary)
        return _atomic_replace_file(temporary, validated_destination)
    catch
        isfile(temporary) && rm(temporary; force = true)
        rethrow()
    end
end

function _runtime_checkpoint_path(
    configuration::ResolvedRunConfiguration,
    output_directory::AbstractString,
)
    configuration.output.save_full_state || return nothing
    return _production_checkpoint_name(
        output_directory,
        configuration.output.checkpoint_prefix,
        1,
        1,
    )
end

function _runtime_checkpoint_payload_metadata(loaded::LoadedCheckpoint)
    metadata = get(loaded.metadata, "metadata", nothing)
    metadata isa AbstractDict || throw(
        CheckpointIntegrityError(
            loaded.reference.metadata_path,
            "production checkpoint envelope has no metadata mapping",
        ),
    )
    get(metadata, "payload_format", nothing) == _RUNTIME_PRODUCTION_CHECKPOINT_FORMAT ||
        throw(
            CheckpointIntegrityError(
                loaded.reference.metadata_path,
                "unsupported production checkpoint payload format",
            ),
        )
    get(metadata, "payload_schema_version", nothing) == _CHECKPOINT_SCHEMA_VERSION || throw(
        CheckpointIntegrityError(
            loaded.reference.metadata_path,
            "unsupported production checkpoint payload schema",
        ),
    )
    return metadata
end

"""Install only an envelope-verified current checkpoint into solver staging.

An HDF5 file left in `artifacts/` without a committed runtime envelope is
removed and never considered for restart.
"""
function _runtime_prepare_checkpoint!(
    context::PointExecutionContext,
    configuration::ResolvedRunConfiguration,
    output_directory::AbstractString,
)
    checkpoint_path = _runtime_checkpoint_path(configuration, output_directory)
    enabled = checkpoint_path !== nothing && configuration.output.resume
    loaded = context.resume_checkpoint
    if !enabled
        loaded === nothing || throw(
            CheckpointIntegrityError(
                loaded.reference.payload_path,
                "a runtime checkpoint exists although production resume is disabled",
            ),
        )
        checkpoint_path === nothing || _runtime_discard_staging_checkpoint!(checkpoint_path)
        return (path = nothing, resume = false, signature = nothing)
    end
    if loaded === nothing
        _runtime_discard_staging_checkpoint!(checkpoint_path)
        return (path = checkpoint_path, resume = false, signature = nothing)
    end
    loaded.reference.kind == _RUNTIME_PRODUCTION_CHECKPOINT_KIND || throw(
        CheckpointIntegrityError(
            loaded.reference.metadata_path,
            "unsupported production checkpoint kind " * repr(loaded.reference.kind),
        ),
    )
    _runtime_checkpoint_payload_metadata(loaded)
    loaded.state isa _RuntimeProductionCheckpointPayload || throw(
        CheckpointIntegrityError(
            loaded.reference.payload_path,
            "production checkpoint codec returned an unknown state",
        ),
    )
    _runtime_atomic_copy_checkpoint(loaded.state.path, checkpoint_path)
    signature = _runtime_checkpoint_signature(checkpoint_path)
    emit_runtime_event!(
        context.tracer,
        :resume_checkpoint_installed;
        name = _RUNTIME_PRODUCTION_CHECKPOINT_KIND,
        status = :completed,
        attributes = Dict{String,Any}(
            "point_id" => context.point.point_id,
            "generation" => loaded.reference.generation,
            "sha256" => loaded.reference.sha256,
            "payload_schema_version" => _CHECKPOINT_SCHEMA_VERSION,
        ),
    )
    return (path = checkpoint_path, resume = true, signature = signature)
end

mutable struct _RuntimeSolverEventBridge
    context::PointExecutionContext
    tokens::Vector{Pair{Symbol,SpanToken}}
end

_RuntimeSolverEventBridge(context::PointExecutionContext) =
    _RuntimeSolverEventBridge(context, Pair{Symbol,SpanToken}[])

mutable struct _RuntimeCheckpointPublisher
    context::PointExecutionContext
    checkpoint_path::Union{Nothing,String}
    observed_signature::Any
    published_signature::Any
end

function _RuntimeCheckpointPublisher(
    context::PointExecutionContext;
    checkpoint_path = nothing,
    checkpoint_signature = nothing,
)
    path = checkpoint_path === nothing ? nothing : abspath(checkpoint_path)
    return _RuntimeCheckpointPublisher(
        context,
        path,
        checkpoint_signature,
        checkpoint_signature,
    )
end

function _runtime_checkpoint_metadata(event)
    return Dict{String,Any}(
        "payload_format" => _RUNTIME_PRODUCTION_CHECKPOINT_FORMAT,
        "payload_schema_version" => _CHECKPOINT_SCHEMA_VERSION,
        "observed_during_stage" => event === nothing ? "terminal" : String(event.stage),
        "observed_during_action" => event === nothing ? "terminal" : String(event.action),
        "observed_iteration" => event isa SolverEvent ? event.iteration : nothing,
    )
end

function _runtime_publish_checkpoint!(
    publisher::_RuntimeCheckpointPublisher,
    event = nothing;
    terminal::Bool = false,
)
    path = publisher.checkpoint_path
    (path === nothing || !isfile(path)) && return nothing
    signature = nothing
    if terminal
        publisher.context.retention.snapshot_mode === :none && return nothing
        signature = _runtime_checkpoint_signature(path)
        signature == publisher.published_signature && return nothing
        publisher.observed_signature = signature
    else
        event isa SolverEvent && event.action === :progress || return nothing
        event.stage in _RUNTIME_PHYSICAL_PROGRESS_STAGES || return nothing
        iteration = event.iteration
        total = event.total
        iteration !== nothing && total !== nothing && iteration > 0 || return nothing
        retained = should_retain_snapshot(publisher.context.retention, iteration; total)
        signature = _runtime_checkpoint_signature(path)
        signature == publisher.observed_signature && return nothing
        publisher.observed_signature = signature
        retained || return nothing
    end
    checkpoint_iteration = event isa SolverEvent ? event.iteration : nothing
    reference = checkpoint!(
        publisher.context,
        _RuntimeProductionCheckpointPayload(path);
        kind = _RUNTIME_PRODUCTION_CHECKPOINT_KIND,
        iteration = checkpoint_iteration,
        metadata = _runtime_checkpoint_metadata(event),
    )
    publisher.published_signature = signature
    emit_runtime_event!(
        publisher.context.tracer,
        :checkpoint_published;
        name = _RUNTIME_PRODUCTION_CHECKPOINT_KIND,
        status = :completed,
        attributes = Dict{String,Any}(
            "point_id" => publisher.context.point.point_id,
            "generation" => reference.generation,
            "iteration" => reference.iteration,
            "sha256" => reference.sha256,
            "payload_schema_version" => _CHECKPOINT_SCHEMA_VERSION,
            "terminal" => terminal,
        ),
    )
    return reference
end

function _runtime_progress_metrics(values::Union{Tuple,AbstractVector{SolverMetric}})
    metrics = Dict{String,Any}()
    for metric in values
        name = String(metric.name)
        value = metric.value
        key = metric.name === :J ? "current_A_per_cm2" : name
        metrics[key*"_measurement_status"] = String(metric.measurement_status)
        metrics[key*"_reason"] = metric.reason === nothing ? nothing : String(metric.reason)
        if metric.name === :J
            (value === nothing || value isa Real && !(value isa Bool)) ||
                throw(ArgumentError("current progress metric must be numeric"))
            metric.unit == "A/cm^2" || throw(
                ArgumentError(
                    "current SolverEvent metric must use A/cm^2, got " * repr(metric.unit),
                ),
            )
            haskey(metrics, "current_A_per_cm2") &&
                throw(ArgumentError("duplicate runtime progress metric J"))
            metrics["current_A_per_cm2"] = value === nothing ? nothing : Float64(value)
            metrics["current_A_per_cm2_unit"] = "A/cm^2"
            continue
        end
        haskey(metrics, name) &&
            throw(ArgumentError("duplicate runtime progress metric $name"))
        metrics[name] = value
        if value isa Real && !(value isa Bool)
            metrics[name*"_unit"] = isempty(metric.unit) ? "1" : metric.unit
        elseif !isempty(metric.unit)
            metrics[name*"_unit"] = metric.unit
        end
    end
    return metrics
end

function _runtime_progress_span_name(stage::Symbol)
    stage === :poisson && return "Poisson"
    stage === :scba && return "SCBA"
    throw(ArgumentError("unsupported physical progress stage $stage"))
end

function _observe_runtime_solver_event!(
    bridge::_RuntimeSolverEventBridge,
    event::SolverEvent,
)
    stage = event.stage
    stage in _RUNTIME_PHYSICAL_PROGRESS_STAGES || return event
    if event.action === :begin
        token = start_span!(
            bridge.context.tracer,
            :physical,
            _runtime_progress_span_name(stage);
            core = String(stage),
            attributes = Dict{String,Any}(
                "point_id" => bridge.context.point.point_id,
                "stage" => String(stage),
                "label" => event.label,
            ),
        )
        push!(bridge.tokens, stage => token)
    elseif event.action === :progress
        iteration = event.iteration
        total = event.total
        if iteration !== nothing && total !== nothing && iteration > 0
            record_iteration!(
                bridge.context,
                iteration,
                total,
                _runtime_progress_metrics(event.metrics);
                phase = String(stage),
            )
        else
            emit_runtime_event!(
                bridge.context.tracer,
                :stage_progress;
                span_class = :physical,
                name = String(stage),
                status = :progress,
                attributes = Dict{String,Any}(
                    "point_id" => bridge.context.point.point_id,
                    "metrics" => _runtime_progress_metrics(event.metrics),
                    "message" => event.message,
                ),
            )
        end
    elseif event.action === :end
        isempty(bridge.tokens) &&
            throw(ArgumentError("runtime progress ended $stage without a matching span"))
        open_stage, token = last(bridge.tokens)
        open_stage === stage ||
            throw(ArgumentError("runtime progress ended $stage while $open_stage is open"))
        end_span!(
            bridge.context.tracer,
            token;
            status = event.status,
            attributes = Dict{String,Any}(
                "iteration" => event.iteration,
                "total" => event.total,
                "metrics" => _runtime_progress_metrics(event.metrics),
                "message" => event.message,
            ),
        )
        pop!(bridge.tokens)
    end
    return event
end

function _configured_plan_capture(runner::QCLProductionPointRunner,context::PointExecutionContext,
    run_root::AbstractString;source_capture::Union{Nothing,_P05PlanCapture},
    parent::Union{Nothing,VerifiedExactCheckpoint},maximum_metadata_bytes::Int)::_P05PlanCapture
    maximum_metadata_bytes>0 || throw(ArgumentError("invalid plan metadata allowance"))
    parent!==nothing && source_capture===nothing && throw(ArgumentError("native5_parent_plan_bytes_required"))
    capture=if source_capture===nothing
        path=joinpath(run_root,"execution_plan.yaml")
        isfile(path) && !islink(path) || throw(ArgumentError("configured frozen execution plan unavailable"))
        bytes=open(path,"r") do io
            stamp(s)=(s.device,s.inode,s.size,s.mtime,s.ctime)
            before=stamp(stat(io))
            before==stamp(stat(path)) || throw(ArgumentError("configured plan path rebound"))
            data=read(io,Base.checked_add(maximum_metadata_bytes÷8,1))
            !islink(path) && before==stamp(stat(io))==stamp(stat(path)) ||
                throw(ArgumentError("configured plan changed during capture"))
            data
        end
        _p05_capture_plan(bytes,:nested_sweep;maximum_metadata_bytes)
    else
        source_capture.kind===:nested_sweep || throw(ArgumentError("configured plan kind differs"))
        bytes2hex(sha256(source_capture.bytes))==source_capture.plan_sha256 || throw(ArgumentError("captured plan bytes changed"))
        parsed=_p05_yaml(source_capture.bytes,maximum_metadata_bytes)
        _p05_nested_plan(parsed)
        canonical_bytes(parsed)==canonical_bytes(source_capture.document) || throw(ArgumentError("captured plan document changed"))
        source_capture
    end
    function tree(node)
        node["kind"]=="leaf" && return SweepLeaf(node["name"])
        axes=[SweepAxis(a["name"],a["values"]) for a in node["axes"]]
        SweepLevel(node["name"],axes,tree(node["child"]))
    end
    source_plan=NestedSweepPlan(capture.document["name"],tree(capture.document["root"]))
    canonical_bytes(QCLApplicationRuntime._sweep_plan_identity_dict(source_plan))==
        canonical_bytes(QCLApplicationRuntime._sweep_plan_identity_dict(context.definition.plan)) ||
        throw(ArgumentError("configured source plan identity differs"))
    if parent!==nothing
        _p05_parent_root_check(parent,run_root)
        checkpoint_reference(parent)["identity"]["plan_sha256"]==capture.plan_sha256 ||
            throw(ArgumentError("native5 parent original plan bytes differ"))
    end
    return capture
end

function _configured_point_identity(runner::QCLProductionPointRunner,context::PointExecutionContext,
    capture::_P05PlanCapture,model_preimage::AbstractDict)::Dict{String,Any}
    capture.kind===:nested_sweep || throw(ArgumentError("configured point requires nested sweep plan"))
    bytes2hex(sha256(capture.bytes))==capture.plan_sha256 || throw(ArgumentError("captured plan bytes changed"))
    run_id=context.definition.identity.run_id
    execution_id=content_id("execution",Dict("run_id"=>run_id,"point_id"=>context.point.point_id))
    branch_id=content_id("branch",Dict("execution_id"=>execution_id,"leaf"=>context.point.leaf))
    context.attempt>0 || throw(ArgumentError("configured attempt must be positive"))
    return Dict{String,Any}("run_id"=>run_id,"execution_id"=>execution_id,
        "point_id"=>context.point.point_id,"attempt"=>string(context.attempt),"branch_id"=>branch_id,
        "model_sha256"=>bytes2hex(sha256(canonical_bytes(model_preimage))),"plan_sha256"=>capture.plan_sha256)
end

function _configured_point_identity(runner::QCLProductionPointRunner,context::PointExecutionContext,run_root::AbstractString)
    run_id=context.definition.identity.run_id
    execution_id=content_id("execution",Dict("run_id"=>run_id,"point_id"=>context.point.point_id))
    branch_id=content_id("branch",Dict("execution_id"=>execution_id,"leaf"=>context.point.leaf))
    plan_path=joinpath(run_root,"execution_plan.yaml")
    isfile(plan_path) && !islink(plan_path) || throw(ArgumentError("configured frozen execution plan unavailable"))
    before=stat(plan_path)
    plan_sha256=open(io->bytes2hex(sha256(io)),plan_path)
    after=stat(plan_path)
    (before.device,before.inode,before.size,before.mtime,before.ctime)==
        (after.device,after.inode,after.size,after.mtime,after.ctime) ||
        throw(ArgumentError("configured execution plan changed during capture"))
    configuration=runner.configuration
    T=_runtime_coordinate(context.point,"temperature.temperature_K")
    V=_runtime_coordinate(context.point,"voltage.voltage_per_period_V")
    raw=deepcopy(configuration.raw)
    sources=deepcopy(configuration.provenance.sources)
    QCLScientificWorkflow._deep_merge!(raw,QCLScientificWorkflow._point_axis_inputs(T,V),sources,
        "point:"*context.point.point_id*"#generated:point-axes")
    resolved=QCLScientificWorkflow._resolve_configuration(raw,ConfigurationProvenance(
        copy(configuration.provenance.manifests),copy(configuration.provenance.files),sources))
    model_sha256=bytes2hex(sha256(canonical_bytes(QCLScientificWorkflow._snapshot_model(resolved))))
    context.attempt>0 || throw(ArgumentError("configured attempt must be positive"))
    return Dict{String,Any}("run_id"=>run_id,"execution_id"=>execution_id,
        "point_id"=>context.point.point_id,"attempt"=>string(context.attempt),"branch_id"=>branch_id,
        "model_sha256"=>model_sha256,"plan_sha256"=>plan_sha256)
end

function execute_point!(runner::QCLProductionPointRunner, context::PointExecutionContext)
    initial=runner.phase_telemetry.enabled ?
        (status=:unavailable,session_id=nothing,current_path=nothing,reason="phase_source_not_initialized") :
        (status=:disabled,session_id=nothing,current_path=nothing,reason="telemetry_disabled")
    QCLApplicationRuntime._set_context_phase_source!(context,QCLScientificWorkflow._phase_source_projection(initial))
    _require_source_graph(runner.source_graph)
    repository = context.repository
    run_id = context.definition.identity.run_id
    run_root = run_workspace_directory(repository, run_id)
    point_root = point_workspace_directory(repository, run_id, context.point.point_id)
    output_directory = joinpath(point_root, "artifacts")
    phase_observer=nothing
    observer_admission=nothing
    try
    configuration=_configured_point_configuration(runner,context.point,output_directory)
    prepared_execution=_p05_prepared_execution(configuration,nothing)
    configuration,execution_plan=prepared_execution
    context.resume_checkpoint===nothing || throw(ArgumentError("native5_explicit_parent_selection_pending_Q1: legacy adapter checkpoint is not a VerifiedExactCheckpoint"))
    # This original was captured before repository initialization rewrote operational YAML.
    capture=_configured_plan_capture(runner,context,run_root;source_capture=runner.plan_capture,
        parent=nothing,maximum_metadata_bytes=configuration.production.memory_budget_bytes)
    model_preimage=QCLScientificWorkflow._snapshot_model(configuration)
    identity=_configured_point_identity(runner,context,capture,model_preimage)
    native_context=(;artifact_root=run_root,identity,plan_capture=capture,parent_checkpoint=nothing)
    native_refs=Ref{Union{Nothing,Dict{String,Any}}}(nothing)
    display=Ref{Union{Nothing,NamedTuple}}(nothing)
    function retain_display(bundle,it,iv)
        it==iv==1 && display[]===nothing || throw(ArgumentError("duplicate/mismatched configured presentation"))
        keys(bundle)==(:stationary_assessment,:validation,:positivity) || throw(ArgumentError("final presentation fields differ"))
        display[]=bundle
        nothing
    end
    function retain_native(triple,it,iv)
        it==iv==1 && native_refs[]===nothing || throw(ArgumentError("duplicate/mismatched configured native final"))
        keys(triple)==(:checkpoint,:diagnostics,:observations) || throw(ArgumentError("exact native final triple required"))
        triple.checkpoint.root==abspath(run_root) || throw(ArgumentError("configured artifact root differs"))
        checkpoint_reference(triple.checkpoint)["identity"]==identity || throw(ArgumentError("configured native identity differs"))
        native_refs[]=_p05_native_source(".";triple...)
        nothing
    end
    session="phase-"*string(time_ns())
    policy=runner.phase_observation_policy===nothing ?
        _normal_phase_policy(runner.phase_telemetry.buffer_events) : runner.phase_observation_policy
    attempt_directory=joinpath(output_directory,"points","T1-V1","attempt-$(context.attempt)")
    phase_request=runner.phase_telemetry.enabled ?
        (;directory=joinpath(attempt_directory,"progress","phases",session),artifact_root=run_root,
            identity,source_session=session,policy,capacity_events=runner.phase_telemetry.buffer_events) : nothing
    observer_admission=_p05_begin_observers!(;phase_request,scalar_request=nothing)
    roots=(;entry=(runner,context,configuration,native_context),resources=(execution_plan,configuration.production,observer_admission),
        construction=(),continuation=(context.resume_checkpoint,),history=(),observers=(retain_native,retain_display),
        inputs_publication=(identity,context.phase_source,capture,model_preimage,native_refs,display))
    grant=min(execution_plan.memory_budget_bytes,configuration.production.memory_budget_bytes)
    available=_p05_input_metadata_limit(grant,roots;observer_admission)
    execution_plan.estimated_peak_bytes<=available || throw(ArgumentError("observer payload exceeds configured grant"))
    if runner.phase_telemetry.enabled
        try
            observer_admission.start_phase || throw(_PhaseObserverUnavailable(:previous_phase_writer_pending))
            phase_observer=_start_phase_observer(joinpath(attempt_directory,"progress","phases",session);
                artifact_root=run_root,identity,source_session=session,policy,
                capacity_events=runner.phase_telemetry.buffer_events,admission=observer_admission)
            QCLApplicationRuntime._set_context_phase_source!(context,
                QCLScientificWorkflow._phase_source_projection(_phase_source_descriptor(phase_observer)))
        catch phase_error
            phase_error isa InterruptException && rethrow()
            reason=phase_error isa _PhaseObserverUnavailable ? phase_error.reason : :phase_source_initialization_failed
            QCLApplicationRuntime._set_context_phase_source!(context,QCLScientificWorkflow._phase_source_projection(
                (status=:unavailable,session_id=nothing,current_path=nothing,reason=reason)))
        end
    end
    try
        QCLApplicationRuntime._publish_context_phase_source!(context)
    catch phase_error
        phase_error isa InterruptException && rethrow()
        phase_observer===nothing || _close_phase_observer!(phase_observer)
        phase_observer=nothing
        QCLApplicationRuntime._set_context_phase_source!(context,QCLScientificWorkflow._phase_source_projection(
            (status=:unavailable,session_id=nothing,current_path=nothing,reason=:phase_source_status_write_failed)))
        @warn "phase source status publication failed" exception=(phase_error,catch_backtrace())
    end
    throw(ArgumentError("native5_configured_consumer_unavailable: typed Results/AiiDA/Q1 transport qualification pending"))
    bridge = _RuntimeSolverEventBridge(context)
    function solver_event_observer(event)
        event.action in (:phase_begin,:phase_end) && return event
        _observe_runtime_solver_event!(bridge,event)
        event
    end
    result=with_span(context.tracer,:physical,"Poisson_SCBA";core="poisson_scba",
        attributes=Dict{String,Any}("point_id"=>context.point.point_id,"attempt"=>context.attempt,"native_profile"=>"native5")) do _
        run_from_configuration(configuration;solver_event_observer,resume_from_checkpoint=false,phase_observer,
            observer_admission,prepared_execution,source_graph=runner.source_graph,
            frozen_plan_bytes=capture.bytes,run_id,native_context,native_publication_sink=retain_native,final_presentation_sink=retain_display)
    end
    native_refs[]===nothing && throw(ArgumentError("configured final publication missing"))
    display[]===nothing && throw(ArgumentError("configured final presentation missing"))
    length(result.sweep.records) == 1 || throw(
        ArgumentError(
            "one-point configured run returned $(length(result.sweep.records)) " *
            "records",
        ),
    )
    record = only(result.sweep.records)
    metadata=_runtime_point_metadata(record)
    # Preserve the existing public display encoding (nonfinite display values are
    # null); raw IEEE values and scientific authority remain in O1/D1.
    stored_display=_p04_parse(sprint(_light_json,display[]))
    for name in ("stationary_assessment","validation","positivity")
        metadata[name]=stored_display[name]
    end
    metadata["native_source"]=native_refs[]
    metadata["optical_attachment"]=nothing
    optical_failure=findfirst(w->get(w,"code",nothing)=="OPTIONAL_OPTICS_FAILED",record.warnings)
    if configuration.study.calculate_optical_response
        optical_failure===nothing && throw(ArgumentError("native5_optical_attachment_missing"))
        metadata["postprocessing"]=Dict("optical"=>Dict("status"=>"failed","error"=>record.warnings[optical_failure]["message"]))
    else
        metadata["postprocessing"]=Dict("optical"=>Dict("status"=>"not_requested","error"=>nothing))
    end
    phase_directory=nothing
    if context.phase_source!==nothing
        metadata["phase_source"]=deepcopy(context.phase_source)
        if context.phase_source["status"]=="available"
            phase_directory=dirname(joinpath(run_root,context.phase_source["current_path"]))
        end
    end
    return PointExecutionResult(
        (record.converged || record.status === :approximate) ? :completed : :incomplete;
        metadata,
        artifacts = Dict{String,Any}(),
    )
    finally
        phase_observer===nothing || _close_phase_observer!(phase_observer)
        # Returned records have only detached metadata. Dead callback/P/root aliases may
        # no longer retain this producer when caller ownership is released.
        phase_observer=nothing;roots=nothing;solver_event_observer=nothing
        native_context=nothing;capture=nothing;model_preimage=nothing;native_refs=nothing;retain_native=nothing;display=nothing;retain_display=nothing;stored_display=nothing
        observer_admission===nothing || _p05_end_observers!(observer_admission)
    end
end

function _runtime_default_iterations_per_point(configuration::ResolvedRunConfiguration)
    outer = configuration.solver.max_poisson
    inner = configuration.solver.max_scba
    scba_events = Base.checked_mul(Base.checked_add(outer, 1), inner)
    return Base.checked_add(scba_events, outer)
end

function _runtime_default_disk_model(configuration::ResolvedRunConfiguration)
    mechanisms = count(
        name -> getfield(configuration.scattering, name),
        fieldnames(ScatteringOptions),
    )
    memory = estimate_production_memory(
        configuration.numerical,
        mechanisms;
        dense_mechanism_count = mechanisms,
        options = configuration.production,
    )
    hdf5_state_bytes = configuration.output.save_full_state ? memory.resident_bytes : 0
    optical_bytes =
        configuration.study.calculate_optical_response && configuration.output.save_csv ?
        Base.checked_mul(
            configuration.study.photon_energy_points,
            _RUNTIME_OPTICAL_ROW_ESTIMATE_BYTES,
        ) : 0
    artifacts = Base.checked_add(
        _RUNTIME_POINT_TEXT_ARTIFACT_ESTIMATE_BYTES,
        Base.checked_add(hdf5_state_bytes, optical_bytes),
    )
    return DiskBudgetModel(
        checkpoint_payload_bytes = hdf5_state_bytes,
        events_per_iteration = 2,
        additional_artifacts_bytes_per_point = artifacts,
    )
end

function _runtime_default_provenance(configuration::ResolvedRunConfiguration)
    return Dict{String,Any}(
        "configuration" => Dict{String,Any}(
            "scientific_content_id" => content_id(
                "configuration",
                _runtime_scientific_identity(configuration),
            ),
        ),
        "package" =>
            Dict{String,Any}("name" => "QCLNEGFRunner", "version" => _runner_package_version()),
    )
end

function _runtime_default_session_provenance()
    return Dict{String,Any}(
        "toolchain" => _runtime_toolchain_provenance(),
        "julia_version" => string(VERSION),
        "julia_threads" => Base.Threads.nthreads(:default),
        "blas_threads" => BLAS.get_num_threads(),
        "blas_vendor" => _runtime_blas_vendor(),
    )
end

"""
    run_configured_nested_sweep(configuration; ...)

Execute the configured temperature -> voltage set through the
content-addressed application coordinator. Completed `result.yaml` points are
checksum-verified and skipped on resume. An unfinished point re-enters the
same one-point `run_from_configuration` workflow and can reuse its current,
problem-validated HDF5 checkpoint when `output.resume` and
`output.save_full_state` are enabled.
"""
function run_configured_nested_sweep(
    configuration::ResolvedRunConfiguration;
    repository = nothing,
    resume::Bool = true,
    retry_failed::Bool = true,
    fail_fast::Bool = configuration.output.fail_fast,
    retention::IterationRetentionPolicy = IterationRetentionPolicy(),
    provenance = nothing,
    session_provenance = nothing,
    disk_model::Union{Nothing,DiskBudgetModel} = nothing,
    iterations_per_point::Union{Nothing,Integer} = nothing,
    phase_telemetry::QCLScientificWorkflow.TelemetryOutputPolicy=ScientificOutputs().telemetry,
    phase_observation_policy::Union{Nothing,PhaseObservationPolicy}=nothing,
    source_graph::Union{Nothing,AbstractDict}=nothing,
)
    source_graph=_require_source_graph(source_graph)
    runner = QCLProductionPointRunner(configuration;phase_telemetry,phase_observation_policy,source_graph)
    definition = configured_nested_run_definition(configuration)
    selected_repository =
        repository === nothing ?
        default_run_repository(
            joinpath(configuration_output_directory(configuration), "runs"),
        ) : repository
    immutable_provenance =
        provenance === nothing ? _runtime_default_provenance(configuration) : provenance
    attempt_provenance =
        session_provenance === nothing ? _runtime_default_session_provenance() :
        session_provenance
    selected_disk_model =
        disk_model === nothing ? _runtime_default_disk_model(configuration) : disk_model
    selected_iterations =
        iterations_per_point === nothing ?
        _runtime_default_iterations_per_point(configuration) : iterations_per_point
    checkpoint_codec = _runtime_production_checkpoint_codec()
    return run_sweep!(
        selected_repository,
        definition,
        runner;
        checkpoint_codec,
        retention,
        provenance = immutable_provenance,
        session_provenance = attempt_provenance,
        resume,
        retry_failed,
        fail_fast,
        disk_model = selected_disk_model,
        iterations_per_point = selected_iterations,
    )
end

run_configured_nested_sweep(source::AbstractString; keywords...) =
    run_configured_nested_sweep(load_run_configuration(source); keywords...)

run_configured_nested_sweep(sources::AbstractVector{<:AbstractString}; keywords...) =
    run_configured_nested_sweep(load_run_configuration(sources); keywords...)
