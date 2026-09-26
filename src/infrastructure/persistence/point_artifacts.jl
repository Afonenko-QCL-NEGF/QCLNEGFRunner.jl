function _sync_artifact_file(path; release_cache::Bool = false)
    Sys.isunix() || return nothing
    open(path, "r") do io
        ccall(:fsync, Cint, (Cint,), fd(io))==0 ||
            throw(SystemError("fsync $(path)", Libc.errno()))
        # Only closed, hashed, immutable generation files reach this path. The
        # durability barrier precedes a best-effort hint; never drop dirty pages
        # or global caches, and never fail a valid commit when hints are ignored.
        if release_cache && Sys.islinux() && filesize(path)>=_SERIALIZATION_SLAB_BYTES
            ccall(:posix_fadvise, Cint, (Cint, Int64, Int64, Cint), fd(io), 0, 0, 4)
        end
    end
    return nothing
end
function _sync_artifact_directory(path)
    Sys.isunix() || return nothing
    descriptor=ccall(:open, Cint, (Cstring, Cint), path, 0)
    descriptor>=0 || throw(SystemError("open directory $(path)", Libc.errno()))
    try
        ccall(:fsync, Cint, (Cint,), descriptor)==0 ||
            throw(SystemError("fsync directory $(path)", Libc.errno()))
    finally
        ccall(:close, Cint, (Cint,), descriptor)
    end
    return nothing
end
function _prepare_generation!(root)
    for (directory, _, files) in walkdir(root)
        chmod(directory, 0o2750)
        for name in files
            path=joinpath(directory, name)
            chmod(path, 0o640)
            _sync_artifact_file(path; release_cache = true)
        end
        _sync_artifact_directory(directory)
    end
    return nothing
end

function _physics_axes(path, rank)
    rank==0 && return "scalar"
    if occursin("/state_dimensionless/", path)
        occursin(r"/(GR|GL|GG|A)/", path) && return "E,k,a,b"
        occursin("/h/", path) && return "k,a,b"
        return rank==1 ? "z" : "E,k"
    end
    (occursin("/selfenergy_dimensionless/", path) || occursin("/algorithm_state/", path)) &&
        return "E,k,a,b"
    if occursin("/basis_dimensionless/", path)
        occursin(r"/(Phi|chi)/", path) && return "z,state"
        rank==2 && return "state,state_prime"
    end
    if occursin("/basis/", path)
        occursin("wavefunctions", path) && return "z,state"
        (occursin("density_matrix", path) || occursin("effective_transform", path)) &&
            return "state,state_prime"
        return "state"
    end
    occursin("/kernels_dimensionless/", path) && return rank==6 ? "k,kprime,a,c,d,b" :
           join(["operator_dimension_$(i)" for i = 1:rank], ",")
    occursin("/profiles_dimensionless/", path) && return "z"
    occursin("/optical/", path) && return "photon_energy"
    return join(["dimension_$(i)" for i = 1:rank], ",")
end

"""Native scientific storage and immutable publication. No display sampling occurs here."""
const POINT_COMMIT_SCHEMA = "qcl-negf.artifact-commit.v2"

function _resolved_configuration_envelope(configuration)
    return Dict(
        "schema"=>"qcl-negf-resolved-configuration-v3",
        "contract_set"=>_RESULT_CONTRACT_SET,
        "configuration"=>configuration,
        "configuration_hash"=>bytes2hex(sha256(canonical_bytes(configuration))),
        "hash_encoding"=>"qcl-negf-canonical-bytes-v1",
    )
end

"""Read the versioned resolved-input envelope."""
function load_resolved_configuration_envelope(path)
    envelope=YAML.load_file(path; dicttype = Dict{String,Any})
    get(envelope, "schema", nothing)=="qcl-negf-resolved-configuration-v3" &&
    get(envelope, "contract_set", nothing)==_RESULT_CONTRACT_SET &&
    get(envelope, "hash_encoding", nothing)=="qcl-negf-canonical-bytes-v1" ||
        throw(ArgumentError("unsupported resolved configuration envelope"))
    configuration=get(envelope, "configuration", nothing)
    configuration isa AbstractDict || throw(ArgumentError("missing resolved configuration"))
    bytes2hex(sha256(canonical_bytes(configuration)))==get(
        envelope,
        "configuration_hash",
        nothing,
    ) || throw(ArgumentError("resolved configuration identity differs"))
    return configuration
end

function _verify_recovery_reference(path, envelope)
    get(envelope, "contract_set", nothing)==_RESULT_CONTRACT_SET ||
        throw(ArgumentError("unsupported recovery contract set"))
    get(envelope, "schema", nothing)=="qcl-negf-recovery-reference-v1" ||
        throw(ArgumentError("unsupported recovery reference schema"))
    payload=envelope["payload"]
    payload["path"]=="physics.h5" ||
        throw(ArgumentError("recovery must reference its canonical physics payload"))
    physical=joinpath(dirname(path), "physics.h5")
    islink(physical) && throw(ArgumentError("recovery payload cannot be a symbolic link"))
    filesize(physical)==payload["bytes"] &&
    bytes2hex(open(sha256, physical))==payload["sha256"] ||
        throw(ArgumentError("recovery payload identity differs"))
    return physical
end

# Storage policy, independent of scientific tolerances. The observer is called
# at accepted boundaries; a long iteration may delay a deadline, never split it.
const CHECKPOINT_INTERVAL_SECONDS = 1800.0
mutable struct CheckpointDeadline
    last_commit_ns::UInt64
end
CheckpointDeadline() = CheckpointDeadline(time_ns())
checkpoint_elapsed(clock::CheckpointDeadline, now::UInt64 = time_ns()) =
    Float64(now-clock.last_commit_ns)*1e-9
checkpoint_due(clock::CheckpointDeadline, now::UInt64 = time_ns()) =
    checkpoint_elapsed(clock, now)>=CHECKPOINT_INTERVAL_SECONDS
checkpoint_completed!(clock::CheckpointDeadline) =
    (clock.last_commit_ns = time_ns(); nothing)
checkpoint_policy(clock::CheckpointDeadline) = Dict{String,Any}(
    "interval_seconds"=>CHECKPOINT_INTERVAL_SECONDS,
    "elapsed_since_previous_commit_seconds"=>checkpoint_elapsed(clock),
    "safe_boundary_delay_seconds"=>max(
        0.0,
        checkpoint_elapsed(clock)-CHECKPOINT_INTERVAL_SECONDS,
    ),
    "boundary"=>"accepted_scba_or_outer",
)

function _dataset_units(path::String)
    occursin("/basis/", path) && occursin("wavefunctions", path) && return "nm^-1/2"
    occursin("/basis/effective_transform/", path) && return "1"
    (
        occursin("/optical/susceptibility/", path) ||
        occursin("/optical/refractive_index/", path)
    ) && return "1"
    occursin("density_matrix_per_m2", path) && return "m^-2"
    for (suffix, unit) in (
        ("_kg_per_m3", "kg/m^3"),
        ("_A_per_m2", "A/m^2"),
        ("_V_per_m", "V/m"),
        ("_m_per_s", "m/s"),
        ("_per_m2", "m^-2"),
        ("_per_m3", "m^-3"),
        ("_per_m", "m^-1"),
        ("_eV", "eV"),
        ("_K", "K"),
        ("_V", "V"),
        ("_nm", "nm"),
        ("_m3", "m^3"),
        ("_m", "m"),
        ("_kg", "kg"),
        ("_Hz", "Hz"),
    )
        endswith(path, suffix) && return unit
    end
    any(
        group->occursin(group, path),
        (
            "_dimensionless/",
            "/algorithm_state/",
            "/numerical_inputs/",
            "/scales/",
            "/inputs/",
        ),
    ) && return "1"
    return "not_applicable"
end

function _annotate_physics_tree!(parent, prefix = "")
    extension = @__MODULE__
    for name in keys(parent)
        object = parent[name]
        path = prefix * "/" * name
        if object isa extension.HDF5.Group
            _annotate_physics_tree!(object, path)
        elseif object isa extension.HDF5.Dataset
            attrs = attributes(object)
            haskey(attrs, "description") || (attrs["description"] = path)
            haskey(attrs, "units") || (attrs["units"] = _dataset_units(path))
            if !haskey(attrs, "logical_axis_order")
                attrs["logical_axis_order"] = _physics_axes(path, ndims(object))
            end
            dtype=eltype(object)
            haskey(attrs, "logical_dtype") || (attrs["logical_dtype"] = string(dtype))
            haskey(attrs, "native_precision") || (
                attrs["native_precision"] =
                    dtype<:AbstractFloat ? "IEEE binary$(8sizeof(dtype))" :
                    dtype<:Integer ? "exact $(8sizeof(dtype))-bit integer" :
                    dtype<:AbstractString ? "UTF-8 string" : string(dtype)
            )
            if dtype<:AbstractFloat
                haskey(attrs, "nonfinite_semantics") || (
                    attrs["nonfinite_semantics"] = "NaN/Inf are preserved diagnostic invalid values, never imputed as zero"
                )
            end
            if occursin("_dimensionless/", path)
                haskey(attrs, "scale_system_path") || (attrs["scale_system_path"]="/scales")
                haskey(attrs, "normalization") || (
                    attrs["normalization"]="dimensionless solver value; physical conversion defined by quantity and /scales"
                )
            end
        end
    end
    return nothing
end

function _physical_dataset(parent, name, values; units, axes, description)
    object = _write_array(parent, name, values; axis_order = axes)
    attributes(object)["units"] = units
    attributes(object)["description"] = description
    attributes(object)["native_grid"] = true
    attributes(object)["nonfinite_count"] = count(x -> x isa Number && !isfinite(x), values)
    return object
end

function _analysis_history!(file, solution)
    diagnostic = create_group(file, "diagnostics")
    for (name, history, type) in (
        ("scba", solution.scba.history, SCBAIteration),
        ("outer", solution.outer_history, OuterIteration),
    )
        table = create_group(diagnostic, name)
        attributes(table)["row_count"] = length(history)
        for field in fieldnames(type)
            values = getfield.(history, field)
            if fieldtype(type, field) <: Real
                _physical_dataset(
                    table,
                    String(field),
                    Float64[Float64(value) for value in values];
                    units = field === :J ? "A/m^2" : "dimensionless",
                    axes = "iteration",
                    description = "Native $(name) diagnostic $(field); acceptance thresholds in metadata",
                )
            elseif fieldtype(type, field) <: AbstractVector
                width =
                    field === :density ? solution.problem.numerical.N_z :
                    solution.problem.numerical.N_b
                matrix =
                    isempty(values) ? zeros(0, width) : reduce(vcat, permutedims.(values))
                _physical_dataset(
                    table,
                    String(field),
                    matrix;
                    units = "dimensionless; see /scales",
                    axes = field === :density ? "iteration,z" : "iteration,state",
                    description = "Native $(name) $(field)",
                )
            end
        end
    end
    _write_psd_history!(diagnostic, solution.scba.history; problem = solution.problem)
    _write_physical_markers!(diagnostic, solution.scba.history)
    _write_scba_threshold_crossings!(
        diagnostic,
        solution.scba.history;
        required_consecutive = solution.options.convergence.required_consecutive_scba_passes,
    )
    witnesses=_write_final_matrix_audit!(diagnostic, solution)
    diagnostic["validation_json"] = sprint(_light_json, _light_validation_data(solution))
    diagnostic["positivity_json"] =
        sprint(_light_json, _light_positivity_data(solution; witnesses))
    diagnostic["warnings_json"] =
        sprint(_light_json, get(solution.observables, :warnings, Any[]))
    return diagnostic
end

"""Store native-grid observables sufficient for the declared analysis profile, without Green matrices."""
function save_analysis_physics(
    path::AbstractString,
    solution::NEGFSolution;
    identity = Dict{String,Any}(),
)
    problem=solution.problem
    grids=problem.grids
    scales=problem.scales
    Eref=_electronvolts(problem.physical.E_ref)
    z=grids.x .* scales.L₀_m
    h=project_hamiltonians(problem, solution.Uᴴ)
    decomposition=eigen(Hermitian(Matrix(view(h, 1, :, :))))
    effective_transform=copy(decomposition.vectors)
    effective_wavefunctions=problem.basis.χ*effective_transform
    for state in axes(effective_wavefunctions, 2)
        pivot=argmax(abs.(view(effective_wavefunctions, :, state)))
        amplitude=effective_wavefunctions[pivot, state]
        if abs(amplitude)>0
            phase=conj(amplitude)/abs(amplitude)
            effective_wavefunctions[:, state].*=phase
            effective_transform[:, state].*=phase
        end
    end
    density_matrix=_sheet_density_matrix_bar(problem, solution.scba.green.Gˡ) ./
                   scales.L₀_m^2
    energy_density=spatial_energy_density(problem, solution.scba.green.Gˡ)
    h5open(path, "w") do file
        metadata=create_group(file, "metadata")
        metadata["toolchain_json"] = sprint(_light_json, _runtime_toolchain_provenance())
        attributes(metadata)["schema"]="qcl-negf-physics-analysis-v4"
        attributes(metadata)["schema_version"]=_CHECKPOINT_SCHEMA_VERSION
        attributes(metadata)["contract_set"]=_RESULT_CONTRACT_SET
        attributes(metadata)["artifact_role"]="physics.analysis"
        attributes(metadata)["native_grid"]=true
        attributes(metadata)["quality"]=String(solution_quality(solution))
        attributes(metadata)["scientific_accepted"]=solution.converged
        attributes(metadata)["status"]=String(solution.status)
        attributes(metadata)["current_convention"]="positive electron flow toward +z"
        attributes(metadata)["energy_reference"]="absolute physical energy = scaled energy * E0 + E_ref"
        metadata["identity_json"]=sprint(_light_json, identity)
        _persist_model_scope!(metadata, solution)
        metadata["capabilities_json"]=sprint(
            _light_json,
            ["native_observables", "convergence_history", "configured_comparisons"],
        )
        metadata["omitted_capabilities_json"]=sprint(
            _light_json,
            ["arbitrary_Green_reprocessing", "exact_restart", "new_optical_grid"],
        )
        metadata["model_identity_yaml"]=YAML.write(
            Dict(String(k)=>v for (k, v) in pairs(physical_model_identity(problem.models))),
        )
        metadata["solver_contract_yaml"]=YAML.write(
            get(
                solution.observables,
                :restart_contract,
                _solver_restart_contract(solution.options, AlgorithmOptions()),
            ),
        )
        metadata["temperature_K"]=_kelvin(problem.physical.Tᴸ)
        metadata["voltage_per_period_V"]=_volts_per_metre(problem.physical.F_bias)*_metres(
            period_length(problem.physical),
        )
        scale=create_group(file, "scales")
        scale["E0_eV"]=scales.E₀_eV
        scale["L0_m"]=scales.L₀_m
        axes_group=create_group(file, "axes")
        _physical_dataset(
            axes_group,
            "state_index",
            Int64.(0:(problem.numerical.N_b-1));
            units = "1",
            axes = "state",
            description = "Zero-based basis-state coordinate",
        )
        for (name, value, units, axis) in (
            ("z_nm", z .* 1e9, "nm", "z"),
            ("energy_eV", grids.ε .* scales.E₀_eV .+ Eref, "eV", "E"),
            ("k_per_nm", grids.κ ./ scales.L₀_m .* 1e-9, "nm^-1", "k"),
            ("spatial_weights", grids.wˣ, "dimensionless", "z"),
            ("energy_weights", grids.wᴱ, "dimensionless", "E"),
            ("momentum_weights", grids.wᵏ, "dimensionless", "k"),
            ("trusted_energy", Int8.(grids.trusted_energy), "boolean", "E"),
        )
            _physical_dataset(
                axes_group,
                name,
                value;
                units,
                axes = axis,
                description = "Actual quadrature coordinate or weight $(name)",
            )
        end
        for (name, measure, factor, physical_unit) in (
            ("spatial_weights", "dx with x=z/L0", scales.L₀_m, "m"),
            ("energy_weights", "d epsilon with E=E_ref+E0*epsilon", scales.E₀_eV, "eV"),
            (
                "momentum_weights",
                "kappa*d kappa/(2*pi), annular cell measure",
                inv(scales.L₀_m^2),
                "m^-2",
            ),
        )
            attrs=attributes(axes_group[name])
            attrs["integration_measure"]=measure
            attrs["physical_measure_multiplier"]=factor
            attrs["physical_measure_units"]=physical_unit
        end
        observable=create_group(file, "observables")
        structure=problem.profiles.Eᶜ .* scales.E₀_eV .+ Eref
        external=-_volts_per_metre(problem.physical.F_bias) .*
                 (z .- _metres(problem.physical.z₀))
        hartree=solution.Uᴴ .* scales.E₀_eV
        for (name, value, units) in (
            ("potential_structure_eV", structure, "eV"),
            ("potential_external_eV", external, "eV"),
            ("potential_hartree_eV", hartree, "eV"),
            ("potential_total_eV", structure .+ external .+ hartree, "eV"),
            ("density_per_m3", solution.n ./ scales.L₀_m^3, "m^-3"),
        )
            _physical_dataset(
                observable,
                name,
                value;
                units,
                axes = "z",
                description = name,
            )
        end
        spectral=[
            real(sum(solution.scba.green.A[e, k, a, a] for a = 1:problem.numerical.N_b))/scales.E₀_eV
            for e in eachindex(grids.ε), k in eachindex(grids.κ)
        ]
        occupied=[
            real(
                sum(-im*solution.scba.green.Gˡ[e, k, a, a] for a = 1:problem.numerical.N_b),
            )/scales.E₀_eV for e in eachindex(grids.ε), k in eachindex(grids.κ)
        ]
        _physical_dataset(
            observable,
            "spectral",
            spectral;
            units = "eV^-1",
            axes = "E,k",
            description = "Trace of actual spectral function A",
        )
        _physical_dataset(
            observable,
            "occupied_spectral",
            occupied;
            units = "eV^-1",
            axes = "E,k",
            description = "Trace of actual -i G lesser",
        )
        _physical_dataset(
            observable,
            "spatial_energy_density",
            energy_density.n_per_eV_m3;
            units = "m^-3/eV",
            axes = "E,z",
            description = "Native resolved occupied spatial-energy density n(E,z)",
        )
        observable["current_density_A_per_m2"]=Float64(
            ustrip(
                u"A/m^2",
                CODATA.e*boundary_flux(
                    problem,
                    solution.scba.embedding_plus,
                    solution.scba.green,
                ),
            ),
        )
        observable["sheet_density_per_m2"]=real(tr(density_matrix))
        basis=create_group(file, "basis")
        attributes(basis)["localization"]=String(problem.basis.localization)
        _write_complex(
            basis,
            "localized_wavefunctions",
            problem.basis.χ ./ sqrt(scales.L₀_m*1e9),
        )
        _write_complex(
            basis,
            "effective_wavefunctions",
            effective_wavefunctions ./ sqrt(scales.L₀_m*1e9),
        )
        _write_complex(basis, "effective_transform", effective_transform)
        attributes(
            basis,
        )["effective_gauge"]="k=0 Hermitian eigenvectors, ascending eigenenergy; largest spatial amplitude real positive; degenerate subspaces not matched between points"
        _physical_dataset(
            basis,
            "effective_levels_eV",
            decomposition.values .* scales.E₀_eV .+ Eref;
            units = "eV",
            axes = "state",
            description = "Eigenlevels of projected k=0 Hamiltonian, not interacting spectral peaks",
        )
        _physical_dataset(
            basis,
            "localized_levels_eV",
            real.(diag(view(h, 1, :, :))) .* scales.E₀_eV .+ Eref;
            units = "eV",
            axes = "state",
            description = "Diagonal energies in localized basis",
        )
        _write_complex(basis, "sheet_density_matrix_per_m2", density_matrix)
        _write_complex(
            basis,
            "effective_density_matrix_per_m2",
            effective_transform'*density_matrix*effective_transform,
        )
        haskey(solution.observables, :optical_response) &&
            _write_optical_group!(file, solution.observables[:optical_response])
        _analysis_history!(file, solution)
        _annotate_physics_tree!(file)
        _attach_native_dimensions!(file)
    end
    return path
end

function _artifact_record(path, role, schema, identity; profile = "science")
    return Dict{String,Any}(
        "path"=>basename(path),
        "role"=>role,
        "schema"=>schema,
        "bytes"=>filesize(path),
        "sha256"=>bytes2hex(open(sha256, path)),
        "media_type"=>endswith(path, ".h5") ? "application/x-hdf5" : "application/json",
        "profile"=>profile,
        "identity"=>identity,
        "dependencies"=>String[],
    )
end

"""Commit a closed generation, then atomically replace a small pointer. Payloads are immutable."""
function commit_point_artifacts(
    directory::AbstractString,
    solution::NEGFSolution;
    identity = Dict{String,Any}(),
    algorithms = nothing,
    configuration = nothing,
    history_paths = String[],
    analysis::Bool = true,
    terminal_status = String(solution.status),
    checkpoint_metadata = Dict{String,Any}(),
)
    checkpoint_started=time_ns()
    root=joinpath(directory, "artifacts")
    mkpath(root)
    generations=[
        parse(Int, match(r"^generation-(\d+)$", name).captures[1]) for
        name in readdir(root) if occursin(r"^generation-\d+$", name)
    ]
    generation=isempty(generations) ? 1 : maximum(generations)+1
    science_parent=nothing
    if !analysis
        for previous in sort(generations; rev = true)
            parent_path=joinpath(
                root,
                "generation-"*lpad(string(previous), 6, '0'),
                "commit.json",
            )
            parent=YAML.load_file(parent_path; dicttype = Dict{String,Any})
            if any(a->a["role"]=="physics.analysis", parent["artifacts"])
                science_parent=Dict(
                    "path"=>replace(relpath(parent_path, root), '\\'=>'/'),
                    "sha256"=>bytes2hex(open(sha256, parent_path)),
                )
                break
            end
        end
        science_parent===nothing && (analysis=true)
    end
    name="generation-"*lpad(string(generation), 6, '0')
    final=joinpath(root, name)
    stage=mktempdir(root; prefix = "pending-")
    try
        artifacts=Dict{String,Any}[]
        for (filename, role, schema) in
            (("physics.h5", "physics.full", "qcl-negf-physics-v4"),)
            path=joinpath(stage, filename)
            _write_checkpoint(
                path,
                solution;
                include_kernels = true,
                algorithms,
                identity,
                artifact_role = role,
            )
            push!(
                artifacts,
                _artifact_record(path, role, schema, identity; profile = "full-state"),
            )
        end
        # Full Green fields, kernels and exact restart state have one owner.
        # Recovery is an immutable, hash-bound reference within the generation.
        physical=only(filter(item->item["role"]=="physics.full", artifacts))
        recovery_path=joinpath(stage, "recovery.json")
        _observability_atomic_text(recovery_path) do io
            _light_json(
                io,
                Dict(
                    "schema"=>"qcl-negf-recovery-reference-v1",
                    "contract_set"=>_RESULT_CONTRACT_SET,
                    "payload"=>Dict(
                        key=>physical[key] for key in ("path", "sha256", "bytes")
                    ),
                    "restart_boundary"=>"accepted Green/selfenergy evaluation before next mixing step",
                ),
            )
        end
        recovery=_artifact_record(
            recovery_path,
            "recovery",
            "qcl-negf-recovery-reference-v1",
            identity;
            profile = "full-state",
        )
        recovery["dependencies"]=[physical["path"]]
        push!(artifacts, recovery)
        if analysis
            path=joinpath(stage, "analysis.h5")
            save_analysis_physics(path, solution; identity)
            push!(
                artifacts,
                _artifact_record(
                    path,
                    "physics.analysis",
                    "qcl-negf-physics-analysis-v4",
                    identity,
                ),
            )
        end
        if !isempty(history_paths)
            destination=joinpath(stage, "history.h5")
            consolidate_scientific_history(destination, history_paths)
            push!(
                artifacts,
                _artifact_record(
                    destination,
                    "science.history",
                    "qcl-negf-scientific-history-v4",
                    identity,
                ),
            )
        end
        if configuration !== nothing
            resolved=deepcopy(configuration)
            resolved["numerical"]["energy_min"]=string(solution.problem.numerical.E_min)
            resolved["numerical"]["energy_max"]=string(solution.problem.numerical.E_max)
            resolved["numerical"]["energy_nodes"]=solution.problem.numerical.N_E
            resolved["physical"]["voltage_per_period"]=string(
                _volts_per_metre(solution.problem.physical.F_bias)*_metres(
                    period_length(solution.problem.physical),
                ),
            )*" V"
            resolved["physical"]["field_bias"]=nothing
            resolved["physical"]["lattice_temperature"]=string(
                _kelvin(solution.problem.physical.Tᴸ),
            )*" K"
            resolved["physical"]["lo_temperature"]=string(
                _kelvin(solution.problem.physical.Tᴸᴼ),
            )*" K"
            path=joinpath(stage, "resolved_configuration.json")
            _observability_atomic_text(path) do io
                _light_json(io, _resolved_configuration_envelope(resolved))
            end
            push!(
                artifacts,
                _artifact_record(
                    path,
                    "model",
                    "qcl-negf-resolved-configuration-v3",
                    identity,
                ),
            )
        end
        commit=Dict{String,Any}(
            "schema"=>POINT_COMMIT_SCHEMA,
            "contract_set"=>_RESULT_CONTRACT_SET,
            "generation"=>generation,
            "identity"=>identity,
            "physics_ready"=>true,
            "checkpoint_ready"=>true,
            "presentation_ready"=>false,
            "terminal_status"=>terminal_status,
            "scientific_accepted"=>solution.converged,
            "quality"=>String(solution_quality(solution)),
            "artifacts"=>artifacts,
        )
        commit["published_unix"]=time()
        # Every recovery generation, including analysis=false, carries a cheap
        # durable progress coordinate for infrastructure retry policy. A new
        # generation/hash alone does not prove another SCBA step was completed.
        commit["restart_coordinates"]=Dict(
            "domain_revision"=>let adaptation=get(
                    solution.observables,
                    :adaptation_checkpoint,
                    nothing,
                )
                adaptation===nothing ? 0 : Int(get(adaptation, "expansions", 0))
            end,
            "last_completed_outer"=>isempty(solution.outer_history) ? 0 :
                                    last(solution.outer_history).μ,
            "outer_iteration"=>(
                isempty(solution.outer_history) ? 0 : last(solution.outer_history).μ
            ) + (solution.status===:running_scba ? 1 : 0),
            "last_inner"=>isempty(solution.scba.history) ? 0 :
                          last(solution.scba.history).ν,
            "solver_status"=>String(solution.status),
            "coordinate_scope"=>"accepted saved state; last_completed_outer is not active outer index",
        )
        if analysis
            commit["analysis_coordinates"]=Dict(
                "attempt"=>get(identity, "attempt", nothing),
                "last_completed_outer"=>(
                    isempty(solution.outer_history) ? nothing :
                    last(solution.outer_history).μ
                ),
                "last_inner"=>(
                    isempty(solution.scba.history) ? nothing :
                    last(solution.scba.history).ν
                ),
                "coordinate_scope"=>"stored solution histories; last_completed_outer is not an active outer index",
            )
        end
        commit["checkpoint_policy"]=checkpoint_metadata
        commit["performance"]=Dict(
            "checkpoint_payload_seconds"=>(time_ns()-checkpoint_started)*1e-9,
            "checkpoint_payload_bytes"=>sum(artifact["bytes"] for artifact in artifacts),
            "includes_commit_publication"=>false,
            "jit_separately_measured"=>false,
        )
        science_parent===nothing || (commit["science_parent_commit"]=science_parent)
        _observability_atomic_text(joinpath(stage, "commit.json")) do io
            _light_json(io, commit)
        end
        _prepare_generation!(stage)
        mv(stage, final; force = false)
        _sync_artifact_directory(root)
        commit_path=joinpath(final, "commit.json")
        pointer=Dict(
            "schema"=>"qcl-negf.artifact-pointer.v2",
            "contract_set"=>_RESULT_CONTRACT_SET,
            "generation"=>generation,
            "commit_path"=>name*"/commit.json",
            "sha256"=>bytes2hex(open(sha256, commit_path)),
        )
        _observability_atomic_text(joinpath(root, "current.json")) do io
            _light_json(io, pointer)
        end
        _sync_artifact_file(joinpath(root, "current.json"))
        _sync_artifact_directory(root)
        return commit_path
    finally
        isdir(stage) && rm(stage; recursive = true, force = true)
    end
end

"""Verify immutable artifact identities and format metadata without interpreting scientific acceptance."""
function verify_point_artifacts(commit_path::AbstractString)
    commit=YAML.load_file(commit_path; dicttype = Dict{String,Any})
    get(commit, "schema", nothing)==POINT_COMMIT_SCHEMA ||
        throw(ArgumentError("unknown result commit schema"))
    get(commit, "contract_set", nothing)==_RESULT_CONTRACT_SET ||
        throw(ArgumentError("unsupported result contract set"))
    root=dirname(abspath(commit_path))
    for artifact in commit["artifacts"]
        schema=String(artifact["schema"])
        expected_role=schema=="qcl-negf-recovery-reference-v1" ? "recovery" :
                      schema=="qcl-negf-resolved-configuration-v3" ? "model" :
                      get(_NATIVE_SCIENCE_ROLES, schema, nothing)
        expected_role===nothing &&
            throw(ArgumentError("unsupported point artifact schema $schema"))
        artifact["role"]==expected_role ||
            throw(ArgumentError("declared artifact role differs from the $schema contract"))
        expected_media_type=schema in (
            "qcl-negf-resolved-configuration-v3",
            "qcl-negf-recovery-reference-v1",
            "qcl-negf-operator-diagnostics-v4",
        ) ? "application/json" : "application/x-hdf5"
        artifact["media_type"]==expected_media_type || throw(
            ArgumentError("declared artifact media type differs from the $schema contract"),
        )
        relative=String(artifact["path"])
        isabspath(relative) && throw(ArgumentError("absolute artifact path"))
        path=abspath(joinpath(root, relative))
        if relpath(path, root)==".." || startswith(relpath(path, root), "../")
            throw(ArgumentError("artifact escapes commit root"))
        end
        filesize(path)==artifact["bytes"] ||
            throw(ArgumentError("artifact byte count differs"))
        bytes2hex(open(sha256, path))==artifact["sha256"] ||
            throw(ArgumentError("artifact digest differs"))
        if artifact["media_type"]=="application/x-hdf5"
            h5open(path, "r") do file
                _require_native_metadata(file, artifact["schema"])
                schema=artifact["schema"]
                if schema in ("qcl-negf-checkpoint-v4", "qcl-negf-physics-v4")
                    _require_native_scba_tables(file["convergence"])
                elseif schema=="qcl-negf-physics-analysis-v4"
                    _require_native_scba_tables(file["diagnostics"])
                elseif schema=="qcl-negf-scientific-history-v4"
                    _require_native_scba_tables(file)
                end
            end
        elseif artifact["media_type"]=="application/json"
            payload=YAML.load_file(path; dicttype = Dict{String,Any})
            get(payload, "contract_set", nothing)==_RESULT_CONTRACT_SET ||
                throw(ArgumentError("unsupported JSON result contract set"))
            if artifact["role"]=="model"
                load_resolved_configuration_envelope(path)
            elseif artifact["role"]=="recovery"
                _verify_recovery_reference(path, payload)
            elseif artifact["role"]=="science.comparison"
                get(payload, "schema", nothing)=="qcl-negf-operator-diagnostics-v4" &&
                get(payload, "schema_version", nothing)==_CHECKPOINT_SCHEMA_VERSION ||
                    throw(ArgumentError("unsupported operator diagnostic native format"))
            end
        end
    end
    return commit
end

function commit_operator_artifacts(
    directory::AbstractString,
    checks;
    identity,
    operation,
    accepted,
)
    root=joinpath(directory, "artifacts")
    mkpath(root)
    final=joinpath(root, "generation-000001")
    ispath(final) && throw(ArgumentError("operator generation already exists"))
    stage=mktempdir(root; prefix = "pending-")
    try
        path=joinpath(stage, "operator_checks.json")
        _observability_atomic_text(path) do io
            _light_json(
                io,
                Dict(
                    "schema"=>"qcl-negf-operator-diagnostics-v4",
                    "contract_set"=>_RESULT_CONTRACT_SET,
                    "schema_version"=>_CHECKPOINT_SCHEMA_VERSION,
                    "operation"=>operation,
                    "checks"=>checks,
                ),
            )
        end
        record=_artifact_record(
            path,
            "science.comparison",
            "qcl-negf-operator-diagnostics-v4",
            identity,
        )
        commit=Dict(
            "schema"=>POINT_COMMIT_SCHEMA,
            "contract_set"=>_RESULT_CONTRACT_SET,
            "generation"=>1,
            "identity"=>identity,
            "physics_ready"=>true,
            "checkpoint_ready"=>false,
            "presentation_ready"=>false,
            "terminal_status"=>"completed",
            "scientific_accepted"=>accepted,
            "quality"=>accepted ? "strict" : "unconverged",
            "artifacts"=>[record],
        )
        _observability_atomic_text(joinpath(stage, "commit.json")) do io
            _light_json(io, commit)
        end
        _prepare_generation!(stage)
        mv(stage, final; force = false)
        _sync_artifact_directory(root)
        path=joinpath(final, "commit.json")
        _observability_atomic_text(joinpath(root, "current.json")) do io
            _light_json(
                io,
                Dict(
                    "schema"=>"qcl-negf.artifact-pointer.v2",
                    "contract_set"=>_RESULT_CONTRACT_SET,
                    "generation"=>1,
                    "commit_path"=>"generation-000001/commit.json",
                    "sha256"=>bytes2hex(open(sha256, path)),
                ),
            )
        end
        _sync_artifact_file(joinpath(root, "current.json"))
        _sync_artifact_directory(root)
        return path
    finally
        isdir(stage) && rm(stage; recursive = true, force = true)
    end
end

function _write_optical_group!(file, response)
    optical=create_group(file, "optical")
    attributes(optical)["model"]=String(response.model)
    attributes(optical)["gauge"]=String(response.gauge)
    attributes(optical)["vertex_corrections"]=response.vertex_corrections
    for (name, values, units) in (
        ("photon_energy_eV", _electronvolts.(response.photon_energy), "eV"),
        ("frequency_Hz", Float64.(ustrip.(u"Hz", response.frequency)), "Hz"),
        ("gain_per_m", Float64.(ustrip.(u"m^-1", response.gain)), "m^-1"),
        ("trusted", Int8.(response.trusted), "boolean"),
        ("edge_loss", response.edge_loss, "dimensionless"),
    )
        _physical_dataset(
            optical,
            name,
            values;
            units,
            axes = "photon_energy",
            description = name,
        )
    end
    _write_complex(optical, "susceptibility", response.susceptibility)
    _write_complex(optical, "refractive_index", response.refractive_index)
    return nothing
end

function save_optical_physics(path, response; source_sha256 = "")
    h5open(path, "w") do file
        metadata=create_group(file, "metadata")
        metadata["toolchain_json"] = sprint(_light_json, _runtime_toolchain_provenance())
        attributes(metadata)["schema"]="qcl-negf-optical-v4"
        attributes(metadata)["schema_version"]=_CHECKPOINT_SCHEMA_VERSION
        attributes(metadata)["contract_set"]=_RESULT_CONTRACT_SET
        attributes(metadata)["artifact_role"]="physics.analysis"
        attributes(metadata)["source_sha256"]=source_sha256
        _write_optical_group!(file, response)
        _annotate_physics_tree!(file)
        _attach_native_dimensions!(file)
    end
    return path
end

"""Attach HDF5 dimension scales in external C/logical axis order, without a transpose heuristic."""
function _attach_native_dimensions!(file)
    backend=HDF5
    native=haskey(file, "axes")
    coordinates=native ?
                Dict(
        "E"=>"axes/energy_eV",
        "k"=>"axes/k_per_nm",
        "kprime"=>"axes/k_per_nm",
        "z"=>"axes/z_nm",
        "state"=>"axes/state_index",
        "state_prime"=>"axes/state_index",
        "a"=>"axes/state_index",
        "b"=>"axes/state_index",
    ) :
                Dict(
        "E"=>"grids_dimensionless/energy",
        "k"=>"grids_dimensionless/k",
        "kprime"=>"grids_dimensionless/k",
        "z"=>"grids_dimensionless/x",
        "state"=>"grids_dimensionless/state_index",
        "state_prime"=>"grids_dimensionless/state_index",
        "a"=>"grids_dimensionless/state_index",
        "b"=>"grids_dimensionless/state_index",
        "c"=>"grids_dimensionless/state_index",
        "d"=>"grids_dimensionless/state_index",
    )
    haskey(file, "optical/photon_energy_eV") &&
        (coordinates["photon_energy"]="optical/photon_energy_eV")
    scale_paths=Set(values(coordinates))
    for path in scale_paths
        haskey(file, path) || continue
        backend.API.h5ds_set_scale(file[path].id, basename(path))
    end
    function visit(parent, prefix = "")
        for name in keys(parent)
            object=parent[name]
            path=isempty(prefix) ? name : prefix*"/"*name
            if object isa backend.Group
                visit(object, path)
            elseif object isa backend.Dataset && !(path in scale_paths) && ndims(object)>0
                axes=split(String(read_attribute(object, "logical_axis_order")), ',')
                length(axes)==ndims(object) || continue
                dimensions=reverse(size(object))
                references=Union{Nothing,String}[]
                for (index, axis) in enumerate(axes)
                    coordinate=get(coordinates, axis, nothing)
                    if coordinate!==nothing &&
                       haskey(file, coordinate) &&
                       length(file[coordinate])==dimensions[index]
                        backend.API.h5ds_attach_scale(
                            object.id,
                            file[coordinate].id,
                            UInt32(index-1),
                        )
                        push!(references, "/"*coordinate)
                    else
                        push!(references, nothing)
                    end
                end
                attributes(object)["axis_coordinate_paths_json"]=sprint(
                    _light_json,
                    references,
                )
            end
        end
    end
    visit(file)
    return nothing
end
