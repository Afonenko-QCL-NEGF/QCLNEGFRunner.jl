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
    interval_seconds::Float64
end
CheckpointDeadline(last::UInt64) = CheckpointDeadline(last,CHECKPOINT_INTERVAL_SECONDS)
CheckpointDeadline(; interval_seconds::Real = CHECKPOINT_INTERVAL_SECONDS) = CheckpointDeadline(time_ns(),Float64(interval_seconds))
checkpoint_elapsed(clock::CheckpointDeadline, now::UInt64 = time_ns()) =
    Float64(now-clock.last_commit_ns)*1e-9
checkpoint_due(clock::CheckpointDeadline, now::UInt64 = time_ns()) =
    checkpoint_elapsed(clock, now)>=clock.interval_seconds
checkpoint_completed!(clock::CheckpointDeadline) =
    (clock.last_commit_ns = time_ns(); nothing)
checkpoint_policy(clock::CheckpointDeadline) = Dict{String,Any}(
    "interval_seconds"=>clock.interval_seconds,
    "elapsed_since_previous_commit_seconds"=>checkpoint_elapsed(clock),
    "safe_boundary_delay_seconds"=>max(
        0.0,
        checkpoint_elapsed(clock)-clock.interval_seconds,
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
        attributes(metadata)["scientific_accepted"]=solution_scientific_assessment(solution)["scientific_accepted"]
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

function _storage_bytes(paths)
    total=0
    visited=Set{String}()
    for root in paths
        isdir(root) || continue
        for (directory,_,files) in walkdir(root;follow_symlinks=false), name in files
            path=abspath(joinpath(directory,name))
            islink(path) && throw(ArgumentError("operational storage rejects symbolic links"))
            path in visited && continue
            push!(visited,path)
            total=Base.checked_add(total,filesize(path))
        end
    end
    return total
end
function _checkpoint_storage_forecast(solution)
    n=solution.problem.numerical
    # Conservative allowance for Green/selfenergy, kernels, typed histories,
    # native analysis and HDF5 metadata. Actual staged bytes are checked too.
    arrays=128*n.N_E*n.N_k*n.N_b^2
    kernels=sum(sizeof(value) for value in values(solution.problem.kernels.K);init=0)+sizeof(solution.problem.kernels.Fᴸᴼ)
    return Base.checked_add(16*1024^2,Base.checked_mul(4,arrays+kernels))
end
function _check_storage_budget(paths,budget,reserve,additional)
    used=_storage_bytes(paths)
    Base.checked_add(Base.checked_add(used,reserve),additional)<=budget ||
        throw(ArgumentError("operational storage byte budget exhausted: used=$used reserve=$reserve additional=$additional budget=$budget"))
    return used
end
function _check_storage_free(path,required)
    available=Int(Base.Filesystem.diskstat(path).available)
    available>=required || throw(ArgumentError("publication storage reserve unavailable: required=$required available=$available"))
    return available
end
function _write_bundle_receipt(commit_path)
    commit=verify_point_artifacts(commit_path)
    receipt=Dict("schema"=>"qcl-negf-recovery-receipt-v1","status"=>"verified",
        "commit_sha256"=>bytes2hex(open(sha256,commit_path)),"identity"=>commit["identity"],
        "state_id"=>commit["state_id"],"state_sequence"=>commit["state_sequence"],
        "verified_unix"=>time(),"publication_scope"=>"local_filesystem")
    path=joinpath(dirname(commit_path),"receipt.json")
    _observability_atomic_text(path) do io
        _light_json(io,receipt)
    end
    _sync_artifact_file(path)
    _sync_artifact_directory(dirname(path))
    return receipt
end
function verify_recovery_receipt(commit_path)
    commit=verify_point_artifacts(commit_path)
    path=joinpath(dirname(commit_path),"receipt.json")
    isfile(path) && !islink(path) || throw(ArgumentError("bundle has no durable receipt"))
    receipt=YAML.load_file(path;dicttype=Dict{String,Any})
    get(receipt,"schema",nothing)=="qcl-negf-recovery-receipt-v1" && get(receipt,"status",nothing)=="verified" ||
        throw(ArgumentError("unsupported recovery receipt"))
    get(receipt,"commit_sha256",nothing)==bytes2hex(open(sha256,commit_path)) ||
        throw(ArgumentError("receipt commit digest differs"))
    all(get(receipt,key,nothing)==get(commit,key,nothing) for key in ("identity","state_id","state_sequence")) ||
        throw(ArgumentError("receipt state identity differs"))
    return receipt
end
function _verify_prior_final_dependencies(progress,archive_root;byte_budget::Int=64*1024^3,reserve_bytes::Int=0,
    receipt_verifier::Function=verify_recovery_receipt)
    byte_budget>0 && 0<=reserve_bytes<byte_budget || throw(ArgumentError("invalid archive verification budget"))
    get(progress,"schema",nothing)=="qcl-negf-execution-progress-v1" &&
    get(progress,"contract_set",nothing)==_RESULT_CONTRACT_SET || throw(ArgumentError("unsupported execution progress"))
    entries=get(progress,"completed_points",nothing)
    entries isa AbstractVector || throw(ArgumentError("execution progress has no completed-point index"))
    dependencies=Any[]
    point_ids=Set{String}()
    required_bytes=0
    try
        for entry in entries
            point=entry["point"]
            point["status"]=="completed" && point["execution_id"]==progress["execution_id"] &&
            point["id"]!=progress["active_point_id"] || throw(ArgumentError("archive dependency point identity differs"))
            point["id"] in point_ids && throw(ArgumentError("duplicate completed archive dependency"))
            push!(point_ids,point["id"])
            relative=entry["final_commit"]
            relative isa String && occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*/final/commit\.json$",relative) ||
                throw(ArgumentError("invalid prior final archive path"))
            relative==join([point["execution_id"],point["id"],"final","commit.json"],'/') ||
                throw(ArgumentError("prior final is outside its canonical archive path"))
            islink(archive_root) && throw(ArgumentError("archive root cannot be a symbolic link"))
            cursor=archive_root
            for segment in split(relative,'/')
                cursor=joinpath(cursor,segment)
                islink(cursor) && throw(ArgumentError("archive dependency cannot traverse symbolic links"))
            end
            commit_path=_contained_result_file(archive_root,relative)
            # Establish the complete owner set before hashing or opening native
            # arrays. The portable index cannot omit a large artifact to evade
            # its finite verification/transfer budget.
            commit_bytes=filesize(commit_path)
            commit_bytes<=min(16*1024^2,byte_budget-required_bytes-reserve_bytes) ||
                throw(ArgumentError("prior final metadata exceeds archive verification budget"))
            commit=YAML.load_file(commit_path;dicttype=Dict{String,Any})
            get(commit,"storage_class",nothing)=="archive" || throw(ArgumentError("prior point has no immutable final"))
            issubset(Set(["physics.full","science.history","model"]),Set(a["role"] for a in commit["artifacts"])) ||
                throw(ArgumentError("prior final lacks physical, history or model closure"))
            expected=Set(vcat(["commit.json","receipt.json"],String[a["path"] for a in commit["artifacts"]]))
            get(point["data"],"optical",nothing)===nothing || push!(expected,"optical.h5")
            Set(String[file["path"] for file in entry["files"]])==expected && length(entry["files"])==length(expected) ||
                throw(ArgumentError("prior final file closure differs"))
            for file in entry["files"]
                name=String(file["path"])
                name==basename(name) || throw(ArgumentError("prior archive artifact must be a filename"))
                path=joinpath(dirname(commit_path),name)
                islink(path) && throw(ArgumentError("prior archive dependency cannot be a symbolic link"))
                filesize(path)==file["bytes"] || throw(ArgumentError("prior archive dependency byte count differs"))
                required_bytes=Base.checked_add(required_bytes,filesize(path))
                Base.checked_add(required_bytes,reserve_bytes)<=byte_budget || throw(ArgumentError("archive verification byte budget exhausted"))
            end
            filesize(joinpath(dirname(commit_path),"receipt.json"))<=16*1024^2 ||
                throw(ArgumentError("prior final receipt exceeds metadata verification bound"))
            receipt=receipt_verifier(commit_path)
            all(get(entry["receipt"],key,nothing)==get(receipt,key,nothing) for key in
                ("identity","state_id","state_sequence","commit_sha256")) ||
                throw(ArgumentError("prior final receipt differs from checkpoint progress"))
            identity=receipt["identity"]
            identity["point_id"]==point["id"] && identity["execution_id"]==point["execution_id"] &&
            identity["attempt"]==point["attempt"] && identity["plan_fingerprint"]==progress["plan_fingerprint"] ||
                throw(ArgumentError("prior final state identity differs from progress point"))
            for file in entry["files"]
                name=String(file["path"])
                name==basename(name) || throw(ArgumentError("prior archive artifact must be a filename"))
                path=joinpath(dirname(commit_path),name)
                islink(path) && throw(ArgumentError("prior archive dependency cannot be a symbolic link"))
                filesize(path)==file["bytes"] && bytes2hex(open(sha256,path))==file["sha256"] ||
                    throw(ArgumentError("prior archive dependency hash differs"))
                if name=="optical.h5"
                    h5open(path,"r") do handle
                        _require_internal_hdf5_storage(handle)
                    end
                end
            end
            expected_commit=replace(joinpath("archive",relative),'\\'=>'/')
            get(point["data"],"result_commit",nothing)==expected_commit &&
            get(point["data"],"full_state",nothing)==replace(joinpath(dirname(expected_commit),"physics.h5"),'\\'=>'/') ||
                throw(ArgumentError("prior point state paths differ from archive owner"))
            push!(dependencies,(source=dirname(commit_path),relative=relative,entry=entry))
        end
    catch error
        error isa InterruptException && rethrow()
        error isa ArgumentError && rethrow()
        throw(ArgumentError("prior final dependency verification failed: "*sprint(showerror,error)))
    end
    return (dependencies=dependencies,bytes=required_bytes)
end
function _verify_execution_progress_dependencies(root,commit_path;required::Bool=false,archive_byte_budget::Int=64*1024^3)
    commit=verify_point_artifacts(commit_path)
    artifacts=filter(a->a["role"]=="execution.progress",commit["artifacts"])
    if isempty(artifacts)
        required && throw(ArgumentError("pause checkpoint lacks its completed-point dependency index"))
        return nothing
    end
    length(artifacts)==1 || throw(ArgumentError("bundle has duplicate execution progress owners"))
    progress=YAML.load_file(joinpath(dirname(commit_path),only(artifacts)["path"]);dicttype=Dict{String,Any})
    identity=commit["identity"]
    get(progress,"execution_id",nothing)==identity["execution_id"] &&
    get(progress,"active_point_id",nothing)==identity["point_id"] &&
    get(progress,"plan_fingerprint",nothing)==identity["plan_fingerprint"] ||
        throw(ArgumentError("completed-point index belongs to another frozen execution"))
    return _verify_prior_final_dependencies(progress,joinpath(root,"archive");byte_budget=archive_byte_budget)
end
function _verify_recovery_pointer(root,pointer_path)
    pointer=YAML.load_file(pointer_path;dicttype=Dict{String,Any})
    get(pointer,"schema",nothing)=="qcl-negf.artifact-pointer.v2" && get(pointer,"contract_set",nothing)==_RESULT_CONTRACT_SET ||
        throw(ArgumentError("unsupported recovery pointer"))
    relative=get(pointer,"commit_path","")
    relative isa String && occursin(r"^generation-\d+/commit\.json$",relative) ||
        throw(ArgumentError("nonportable recovery pointer"))
    path=joinpath(root,relative)
    islink(dirname(path)) && throw(ArgumentError("recovery generation is a symbolic link"))
    bytes2hex(open(sha256,path))==get(pointer,"sha256",nothing) || throw(ArgumentError("recovery pointer digest differs"))
    verify_recovery_receipt(path)
    return path
end
"""Select acknowledged latest, then previous; never silently start from an invalid bundle."""
function load_recovery_commit(directory; recovery_root=nothing)
    root=something(recovery_root,joinpath(directory,"artifacts"))
    failures=String[]
    for name in ("current.json","previous.json")
        path=joinpath(root,name)
        isfile(path) || continue
        try
            return _verify_recovery_pointer(root,path)
        catch error
            error isa InterruptException && rethrow()
            push!(failures,"$name: "*sprint(showerror,error))
        end
    end
    throw(ArgumentError("no valid acknowledged recovery generation; "*join(failures,"; ")))
end
function _prune_recovery_generations!(root,retain)
    valid=Tuple{Int,String}[]
    for name in readdir(root)
        occursin(r"^generation-\d+$",name) || continue
        path=joinpath(root,name,"commit.json")
        try
            receipt=verify_recovery_receipt(path)
            push!(valid,(receipt["state_sequence"],name))
        catch error
            error isa InterruptException && rethrow()
        end
    end
    sort!(valid;by=first,rev=true)
    keep=Set{String}()
    for pointer in ("current.json","previous.json")
        isfile(joinpath(root,pointer)) || continue
        try
            path=_verify_recovery_pointer(root,joinpath(root,pointer))
            push!(keep,basename(dirname(path)))
        catch error
            error isa InterruptException && rethrow()
        end
    end
    for (_,name) in valid
        length(keep)>=retain && break
        push!(keep,name)
    end
    for name in readdir(root)
        occursin(r"^generation-\d+$",name) || continue
        name in keep || rm(joinpath(root,name);recursive=true)
    end
    _sync_artifact_directory(root)
    return nothing
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
    storage_class::Symbol = :recovery,
    retain_generations::Int = 2,
    byte_budget::Int = 8*1024^3,
    reserve_bytes::Int = 64*1024^2,
    recovery_root::Union{Nothing,AbstractString} = nothing,
    archive_root::Union{Nothing,AbstractString} = nothing,
    operational_roots = String[],
    state_sequence::Union{Nothing,Int} = nothing,
    publication_hook::Function = stage -> nothing,
    execution_progress::Union{Nothing,AbstractDict} = nothing,
)
    checkpoint_started=time_ns()
    actual_contract=get(solution.observables,:restart_contract,nothing)
    actual_contract===nothing && (actual_contract=solution.scba.restart_contract)
    recoverable=algorithms!==nothing || actual_contract!==nothing
    storage_class===:recovery && !recoverable &&
        throw(ArgumentError("recovery requires the actual executed algorithm contract; unknown provenance can only be archived"))
    storage_class in (:archive,:recovery) || throw(ArgumentError("unknown storage class"))
    retain_generations>=2 || throw(ArgumentError("retention needs latest and previous"))
    byte_budget>0 && 0<=reserve_bytes<byte_budget || throw(ArgumentError("invalid operational byte budget"))
    storage_class===:archive && terminal_status in ("running","running_scba","snapshot","paused","crashed","cancelled") &&
        throw(ArgumentError("an interrupted point has recovery, not a final state"))
    root=storage_class===:archive ? something(archive_root,joinpath(directory,"archive")) :
        something(recovery_root,joinpath(directory,"artifacts"))
    mkpath(root)
    accounted=isempty(operational_roots) ? [storage_class===:recovery ? root : something(recovery_root,joinpath(directory,"artifacts"))] : operational_roots
    forecast=_checkpoint_storage_forecast(solution)
    storage_class===:recovery && _check_storage_budget(accounted,byte_budget,reserve_bytes,forecast)
    _check_storage_free(root,forecast+reserve_bytes)
    generations=[
        parse(Int, match(r"^generation-(\d+)$", name).captures[1]) for
        name in readdir(root) if occursin(r"^generation-\d+$", name)
    ]
    generation=isempty(generations) ? 1 : maximum(generations)+1
    generation=max(generation,something(state_sequence,generation))
    sequence=generation
    identity=merge(Dict{String,Any}(String(k)=>v for (k,v) in identity),Dict(
        "state_sequence"=>sequence,
        "state_id"=>bytes2hex(sha256(canonical_bytes(Dict("identity"=>identity,"sequence"=>sequence,"nonce"=>string(time_ns()))))),
    ))
    name=storage_class===:archive ? "final" : "generation-"*lpad(string(generation), 6, '0')
    final=joinpath(root, name)
    ispath(final) && throw(ArgumentError("immutable final already exists"))
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
            h5open(destination,"r+") do file
                file["metadata"]["state_identity_json"]=sprint(_light_json,identity)
            end
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
        if execution_progress!==nothing
            progress=deepcopy(execution_progress)
            progress["schema"]="qcl-negf-execution-progress-v1"
            progress["contract_set"]=_RESULT_CONTRACT_SET
            progress["identity"]=identity
            path=joinpath(stage,"execution_progress.json")
            _observability_atomic_text(path) do io
                _light_json(io,progress)
            end
            push!(artifacts,_artifact_record(path,"execution.progress","qcl-negf-execution-progress-v1",identity))
        end
        commit=Dict{String,Any}(
            "schema"=>POINT_COMMIT_SCHEMA,
            "contract_set"=>_RESULT_CONTRACT_SET,
            "generation"=>generation,
            "identity"=>identity,
            "physics_ready"=>true,
            "checkpoint_ready"=>recoverable,
            "presentation_ready"=>false,
            "terminal_status"=>terminal_status,
            "scientific_accepted"=>solution_scientific_assessment(solution)["scientific_accepted"],
            "stationary_assessment"=>solution_scientific_assessment(solution),
            "storage_class"=>String(storage_class),
            "state_id"=>identity["state_id"],
            "state_sequence"=>sequence,
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
        _observability_atomic_text(joinpath(stage, "commit.json")) do io
            _light_json(io, commit)
        end
        _prepare_generation!(stage)
        verify_point_artifacts(joinpath(stage,"commit.json"))
        publication_hook(:before_publish)
        storage_class===:recovery && _check_storage_budget(accounted,byte_budget,reserve_bytes,0)
        mv(stage, final; force = false)
        _sync_artifact_directory(root)
        commit_path=joinpath(final, "commit.json")
        publication_hook(:after_publish)
        verify_point_artifacts(commit_path)
        _write_bundle_receipt(commit_path)
        publication_hook(:after_verify)
        if storage_class===:recovery
            pointer=Dict("schema"=>"qcl-negf.artifact-pointer.v2","contract_set"=>_RESULT_CONTRACT_SET,
                "generation"=>generation,"commit_path"=>name*"/commit.json",
                "sha256"=>bytes2hex(open(sha256,commit_path)))
            current=joinpath(root,"current.json")
            if isfile(current)
                # Only a verified prior pointer may become previous.
                try
                    _verify_recovery_pointer(root,current)
                    _observability_atomic_text(joinpath(root,"previous.json")) do io
                        write(io,read(current,String))
                    end
                    _sync_artifact_file(joinpath(root,"previous.json"))
                catch error
                    error isa InterruptException && rethrow()
                end
            end
            _observability_atomic_text(current) do io
                _light_json(io,pointer)
            end
            _sync_artifact_file(current)
            _sync_artifact_directory(root)
            _prune_recovery_generations!(root,retain_generations)
        end
        return commit_path
    finally
        isdir(stage) && rm(stage; recursive = true, force = true)
    end
end

function _require_internal_hdf5_storage(file)
    visited=Set{UInt64}()
    inspected=Ref(0)
    function visit(group,depth)
        depth<=64 && length(group)<=10000 || throw(ArgumentError("native HDF5 object graph exceeds verification bounds"))
        for name in keys(group)
            inspected[]+=1
            inspected[]<=100000 || throw(ArgumentError("native HDF5 link count exceeds verification bounds"))
            info=Ref{HDF5.API.H5L_info_t}()
            # HDF5.jl's unversioned H5Lget_info wrapper is absent from the
            # pinned native library. H5Lget_info1 uses its declared H5L_info_t
            # layout (H5Lpublic.h) and remains present in that exact library.
            lock(HDF5.API.liblock)
            status=try
                ccall((:H5Lget_info1,HDF5.API.libhdf5),HDF5.API.herr_t,
                    (HDF5.API.hid_t,Cstring,Ref{HDF5.API.H5L_info_t},HDF5.API.hid_t),
                    group.id,name,info,HDF5.API.H5P_DEFAULT)
            finally
                unlock(HDF5.API.liblock)
            end
            status>=0 || throw(ArgumentError("cannot verify native HDF5 link ownership"))
            info[].linktype==HDF5.API.H5L_TYPE_HARD || throw(ArgumentError("native HDF5 rejects external or soft links"))
            object=group[name]
            try
                if object isa HDF5.Group
                    if !(info[].u in visited)
                        push!(visited,info[].u)
                        visit(object,depth+1)
                    end
                elseif object isa HDF5.Dataset
                    properties=HDF5.get_create_properties(object)
                    try
                        HDF5.API.h5p_get_external_count(properties)==0 && properties.layout!==:virtual ||
                            throw(ArgumentError("native HDF5 rejects external raw or virtual storage"))
                    finally
                        close(properties)
                    end
                end
            finally
                close(object)
            end
        end
    end
    try
        visit(file,0)
    catch error
        error isa InterruptException && rethrow()
        error isa ArgumentError && rethrow()
        throw(ArgumentError("cannot establish internal native HDF5 storage: "*sprint(showerror,error)))
    end
    return nothing
end

"""Verify immutable artifact identities and format metadata without interpreting scientific acceptance."""
function verify_point_artifacts(commit_path::AbstractString)
    commit=YAML.load_file(commit_path; dicttype = Dict{String,Any})
    get(commit, "schema", nothing)==POINT_COMMIT_SCHEMA ||
        throw(ArgumentError("unknown result commit schema"))
    get(commit, "contract_set", nothing)==_RESULT_CONTRACT_SET ||
        throw(ArgumentError("unsupported result contract set"))
    root=dirname(abspath(commit_path))
    for (directory,dirs,files) in walkdir(root;follow_symlinks=false), name in vcat(dirs,files)
        islink(joinpath(directory,name)) && throw(ArgumentError("bundle rejects symbolic links"))
    end
    islink(commit_path) && throw(ArgumentError("commit cannot be a symbolic link"))
    if haskey(commit,"state_id")
        all(get(commit["identity"],key,nothing)==commit[key] for key in ("state_id","state_sequence")) ||
            throw(ArgumentError("commit state identity differs"))
    end
    declared_paths=String[]
    for artifact in commit["artifacts"]
        schema=String(artifact["schema"])
        expected_role=schema=="qcl-negf-recovery-reference-v1" ? "recovery" :
                      schema=="qcl-negf-resolved-configuration-v3" ? "model" :
                      schema=="qcl-negf-execution-progress-v1" ? "execution.progress" :
                      get(_NATIVE_SCIENCE_ROLES, schema, nothing)
        expected_role===nothing &&
            throw(ArgumentError("unsupported point artifact schema $schema"))
        artifact["role"]==expected_role ||
            throw(ArgumentError("declared artifact role differs from the $schema contract"))
        expected_media_type=schema in (
            "qcl-negf-resolved-configuration-v3",
            "qcl-negf-recovery-reference-v1",
            "qcl-negf-operator-diagnostics-v4",
            "qcl-negf-execution-progress-v1",
        ) ? "application/json" : "application/x-hdf5"
        artifact["media_type"]==expected_media_type || throw(
            ArgumentError("declared artifact media type differs from the $schema contract"),
        )
        get(artifact,"identity",nothing)==get(commit,"identity",nothing) ||
            throw(ArgumentError("artifact state identity differs from its commit"))
        relative=String(artifact["path"])
        relative in declared_paths && throw(ArgumentError("duplicate artifact ownership"))
        push!(declared_paths,relative)
        isabspath(relative) && throw(ArgumentError("absolute artifact path"))
        path=abspath(joinpath(root, relative))
        if relpath(path, root)==".." || startswith(relpath(path, root), "../")
            throw(ArgumentError("artifact escapes commit root"))
        end
        islink(path) && throw(ArgumentError("artifact cannot be a symbolic link"))
        filesize(path)==artifact["bytes"] ||
            throw(ArgumentError("artifact byte count differs"))
        bytes2hex(open(sha256, path))==artifact["sha256"] ||
            throw(ArgumentError("artifact digest differs"))
        if artifact["media_type"]=="application/x-hdf5"
            h5open(path, "r") do file
                _require_internal_hdf5_storage(file)
                _require_native_metadata(file, artifact["schema"])
                schema=artifact["schema"]
                if haskey(commit,"state_id")
                    metadata=file["metadata"]
                    key=schema=="qcl-negf-physics-v4" ? "point_identity_json" :
                        schema=="qcl-negf-physics-analysis-v4" ? "identity_json" :
                        schema=="qcl-negf-scientific-history-v4" ? "state_identity_json" : nothing
                    if key!==nothing
                        haskey(metadata,key) || throw(ArgumentError("artifact lacks state identity"))
                        YAML.load(String(read(metadata[key]));dicttype=Dict{String,Any})==commit["identity"] ||
                            throw(ArgumentError("HDF5 state identity differs from commit"))
                    end
                end
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
            elseif artifact["role"]=="execution.progress"
                get(payload,"schema",nothing)=="qcl-negf-execution-progress-v1" &&
                get(payload,"identity",nothing)==commit["identity"] || throw(ArgumentError("execution progress state identity differs"))
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

function save_optical_physics(path, response; source_sha256 = "", stationary_quality = "unknown",
    source_receipt = nothing, identity = Dict{String,Any}(), stationary_assessment = Dict("status"=>"not_evaluated"))
    h5open(path, "w") do file
        metadata=create_group(file, "metadata")
        metadata["toolchain_json"] = sprint(_light_json, _runtime_toolchain_provenance())
        attributes(metadata)["schema"]="qcl-negf-optical-v4"
        attributes(metadata)["schema_version"]=_CHECKPOINT_SCHEMA_VERSION
        attributes(metadata)["contract_set"]=_RESULT_CONTRACT_SET
        attributes(metadata)["artifact_role"]="physics.analysis"
        attributes(metadata)["source_sha256"]=source_sha256
        attributes(metadata)["stationary_quality"]=String(stationary_quality)
        attributes(metadata)["optical_method"]="diagnostic_bare_bubble"
        metadata["source_state_receipt_json"]=sprint(_light_json,source_receipt)
        metadata["stationary_quality_json"]=sprint(_light_json,stationary_assessment)
        metadata["identity_json"]=sprint(_light_json,identity)
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

function request_pause(root,execution_id,attempt;point_id=nothing)
    attempt isa Integer && !(attempt isa Bool) && attempt>0 || throw(ArgumentError("attempt must be positive"))
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",execution_id) || throw(ArgumentError("invalid execution id"))
    directory=joinpath(root,"control")
    mkpath(directory)
    request=Dict("schema"=>"qcl-negf-pause-request-v1","execution_id"=>String(execution_id),"attempt"=>Int(attempt))
    point_id===nothing || (request["point_id"]=String(point_id))
    path=joinpath(directory,"pause.json")
    _observability_atomic_text(path) do io
        _light_json(io,request)
    end
    _sync_artifact_file(path)
    _sync_artifact_directory(directory)
    return path
end
function pause_requested(root,identity)
    path=joinpath(root,"control","pause.json")
    isfile(path) || return false
    request=YAML.load_file(path;dicttype=Dict{String,Any})
    get(request,"schema",nothing)=="qcl-negf-pause-request-v1" &&
    get(request,"attempt",nothing) isa Integer && get(request,"execution_id",nothing) isa String ||
        throw(ArgumentError("pause marker requires a scoped qcl-negf-pause-request-v1 request"))
    return all(get(request,key,nothing)==get(identity,key,nothing) for key in ("execution_id","attempt")) &&
        (!haskey(request,"point_id") || request["point_id"]==get(identity,"point_id",nothing))
end
function write_pause_receipt(root,commit_path,identity;archive_byte_budget::Int=64*1024^3)
    receipt=verify_recovery_receipt(commit_path)
    commit=verify_point_artifacts(commit_path)
    all(get(commit["identity"],key,nothing)==get(identity,key,nothing) for key in ("point_id","execution_id","attempt")) ||
        throw(ArgumentError("pause checkpoint belongs to another attempt"))
    _verify_execution_progress_dependencies(root,commit_path;required=true,archive_byte_budget)
    document=Dict("schema"=>"qcl-negf-pause-receipt-v1","status"=>"paused",
        "execution_id"=>identity["execution_id"],"attempt"=>identity["attempt"],
        "point_id"=>identity["point_id"],"commit_path"=>replace(relpath(commit_path,root),'\\'=>'/'),
        "commit_sha256"=>receipt["commit_sha256"],"state_id"=>receipt["state_id"],
        "state_sequence"=>receipt["state_sequence"],"publication_scope"=>"local_filesystem")
    path=joinpath(root,"pause-receipt.json")
    _observability_atomic_text(path) do io
        _light_json(io,document)
    end
    _sync_artifact_file(path)
    _sync_artifact_directory(root)
    return document
end
function _contained_result_file(root,relative)
    relative isa String && !isabspath(relative) || throw(ArgumentError("receipt path must be relative"))
    path=abspath(joinpath(root,relative))
    rel=relpath(path,abspath(root))
    (rel==".." || startswith(rel,"../")) && throw(ArgumentError("receipt path escapes output root"))
    return path
end
function verify_pause_receipt(root,execution_id,attempt;archive_byte_budget::Int=64*1024^3)
    archive_byte_budget>0 || throw(ArgumentError("archive verification byte budget must be positive"))
    path=joinpath(root,"pause-receipt.json")
    isfile(path) || throw(ArgumentError("pause has no durable acknowledgement"))
    document=YAML.load_file(path;dicttype=Dict{String,Any})
    get(document,"schema",nothing)=="qcl-negf-pause-receipt-v1" && get(document,"status",nothing)=="paused" ||
        throw(ArgumentError("unsupported pause acknowledgement"))
    get(document,"execution_id",nothing)==execution_id && get(document,"attempt",nothing)==attempt ||
        throw(ArgumentError("pause acknowledgement belongs to another attempt"))
    commit_path=_contained_result_file(root,get(document,"commit_path",nothing))
    receipt=verify_recovery_receipt(commit_path)
    all(get(document,key,nothing)==get(receipt,key,nothing) for key in ("commit_sha256","state_id","state_sequence")) ||
        throw(ArgumentError("pause acknowledgement state differs from bundle"))
    all(get(receipt["identity"],key,nothing)==get(document,key,nothing) for key in ("execution_id","attempt","point_id")) ||
        throw(ArgumentError("pause acknowledgement identity differs from bundle"))
    _verify_execution_progress_dependencies(root,commit_path;required=true,archive_byte_budget)
    return document
end
function write_stop_receipt(root,execution_id,attempt,document;archive_byte_budget::Int=64*1024^3)
    path=joinpath(root,"series_result.json")
    _sync_artifact_file(path)
    receipt=Dict("schema"=>"qcl-negf-stop-receipt-v1","status"=>document["status"],
        "execution_id"=>execution_id,"attempt"=>attempt,"result_sha256"=>bytes2hex(open(sha256,path)),
        "publication_scope"=>"local_filesystem")
    target=joinpath(root,"stop-receipt.json")
    _observability_atomic_text(target) do io
        _light_json(io,receipt)
    end
    _sync_artifact_file(target)
    _sync_artifact_directory(root)
    verify_stop_receipt(root,execution_id,attempt;archive_byte_budget)
    return receipt
end
function verify_stop_receipt(root,execution_id,attempt;archive_byte_budget::Int=64*1024^3)
    archive_byte_budget>0 || throw(ArgumentError("archive verification byte budget must be positive"))
    attempt isa Integer && !(attempt isa Bool) && attempt>0 ||
        throw(ArgumentError("stop verification requires a positive attempt"))
    if isfile(joinpath(root,"pause-receipt.json"))
        try
            return verify_pause_receipt(root,execution_id,attempt;archive_byte_budget)
        catch error
            error isa InterruptException && rethrow()
        end
    end
    receipt_path=joinpath(root,"stop-receipt.json")
    isfile(receipt_path) || throw(ArgumentError("attempt has no verified stop acknowledgement"))
    receipt=YAML.load_file(receipt_path;dicttype=Dict{String,Any})
    get(receipt,"schema",nothing)=="qcl-negf-stop-receipt-v1" &&
    get(receipt,"execution_id",nothing)==execution_id && get(receipt,"attempt",nothing)==attempt ||
        throw(ArgumentError("stop acknowledgement belongs to another attempt"))
    result_path=joinpath(root,"series_result.json")
    get(receipt,"result_sha256",nothing)==bytes2hex(open(sha256,result_path)) || throw(ArgumentError("terminal result digest differs"))
    document=YAML.load_file(result_path;dicttype=Dict{String,Any})
    get(document,"status",nothing) in ("completed","completed_with_warnings","failed","cancelled") ||
        throw(ArgumentError("scientific execution is not terminal"))
    get(receipt,"status",nothing)==document["status"] ||
        throw(ArgumentError("stop acknowledgement status differs from terminal result"))
    plan_path=joinpath(root,"scientific_plan.json")
    isfile(plan_path) || throw(ArgumentError("terminal execution has no frozen plan"))
    plan=load_scientific_plan(plan_path)
    get(document,"plan_fingerprint",nothing)==plan.fingerprint ||
        throw(ArgumentError("terminal result differs from its frozen plan"))
    executions=filter(e->e.id==execution_id,plan.executions)
    length(executions)==1 || throw(ArgumentError("terminal execution is absent from its frozen plan"))
    execution=only(executions)
    points=filter(p->p["execution_id"]==execution_id,document["points"])
    length(points)==length(execution.point_ids) && Set(p["id"] for p in points)==Set(execution.point_ids) ||
        throw(ArgumentError("terminal execution does not contain every frozen point exactly once"))
    for point in points
        point["status"] in ("completed","failed","skipped","cancelled") || throw(ArgumentError("point is not terminal"))
        point["attempt"]<=attempt || throw(ArgumentError("terminal point belongs to a newer attempt"))
        commit_path=get(point["data"],"result_commit",nothing)
        if point["status"]=="completed"
            commit_path===nothing && throw(ArgumentError("completed point lacks full final commit"))
            absolute=_contained_result_file(root,commit_path)
            commit=verify_point_artifacts(absolute)
            operator_only=!isempty(commit["artifacts"]) && all(a->a["role"]=="science.comparison",commit["artifacts"])
            operator_only==(execution.operation!==:stationary) ||
                throw(ArgumentError("terminal artifact kind differs from its frozen operation"))
            get(commit,"storage_class",nothing)=="archive" || operator_only || throw(ArgumentError("completed point lacks archive final"))
            expected=Dict("point_id"=>point["id"],"execution_id"=>execution_id,
                "attempt"=>point["attempt"],"plan_fingerprint"=>plan.fingerprint)
            all(get(commit["identity"],key,nothing)==value for (key,value) in expected) ||
                throw(ArgumentError("final identity differs from terminal point"))
            if !operator_only
                commit_path==join(["archive",execution_id,point["id"],"final","commit.json"],'/') ||
                    throw(ArgumentError("stationary final is outside its canonical archive path"))
                roles=Set(a["role"] for a in commit["artifacts"])
                issubset(Set(["physics.full","science.history","model"]),roles) ||
                    throw(ArgumentError("final lacks its full physical, history or model closure"))
                verify_recovery_receipt(absolute)
                _verify_execution_progress_dependencies(root,absolute;archive_byte_budget)
                get(point["data"],"full_state",nothing)==replace(joinpath(dirname(commit_path),"physics.h5"),'\\'=>'/') ||
                    throw(ArgumentError("terminal full-state path differs from its archive owner"))
            end
        elseif isempty(get(point,"warnings",Any[]))
            throw(ArgumentError("point without final state requires an explicit reason"))
        end
    end
    return receipt
end

"""Small node execution check; it never runs SCBA/Poisson or asserts scientific acceptance."""
function runner_self_check(;directory::AbstractString=tempdir())
    try
        gamma=reshape(ComplexF64[0,1,0],3,1,1,1)
        result=QCLNEGF.product_integration_hilbert_transform(gamma,[0.0,1.0,2.0],[0.5,1.0,0.5])
        expected=[-log(2)/π,0.0,log(2)/π]
        error=maximum(abs.(real.(vec(result)).-expected))
        error<=2e-15 || throw(ArgumentError("analytic Hilbert self-check failed"))
        roundtrip=mktempdir(directory;prefix="qcl-self-check-") do work
            path=joinpath(work,"check.h5")
            h5open(path,"w") do file
                file["values"]=real.(vec(result))
            end
            _sync_artifact_file(path)
            h5open(path,"r") do file
                read(file["values"])==real.(vec(result))
            end
        end
        roundtrip || throw(ArgumentError("HDF5 self-check round-trip failed"))
        return Dict("schema"=>"qcl-negf-self-check-v1","status"=>"completed",
            "julia_version"=>string(VERSION),"julia_threads"=>Threads.nthreads(),"blas_threads"=>BLAS.get_num_threads(),
            "analytic_absolute_error"=>error,"hdf5_roundtrip"=>roundtrip,
            "iterative_converged"=>"not_evaluated","scientific_accepted"=>false,
            "discretization_verified"=>"not_evaluated","experimental_validation"=>"not_evaluated",
            "oracle"=>"triangular finite-window principal value; QCLNEGF src/numerics/reference/kernels.jl::product_integration_hilbert_transform")
    catch error
        error isa InterruptException && rethrow()
        throw(ArgumentError("node self-check failed: "*sprint(showerror,error)))
    end
end
