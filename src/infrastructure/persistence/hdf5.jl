function _storage_order(X::AbstractArray)
    ndims(X) ≤ 1 && return Array(X)
    return permutedims(X, reverse(1:ndims(X)))
end

_restore_order(X::AbstractArray) = _storage_order(X)

function _checkpoint_array_identity(array::Array{ComplexF64})
    return Dict{String,Any}(
        "shape" => collect(size(array)),
        "sha256" => bytes2hex(SHA.sha256(reinterpret(UInt8, vec(array)))),
    )
end

"""Identity of the actual discrete scattering operators, independent of builder options."""
function _checkpoint_kernel_identity(kernels::KernelSet)
    names = sort!(collect(keys(kernels.K)); by = String)
    return Dict{String,Any}(
        "schema" => "qcl-negf-kernel-identity-v1",
        "byte_order" => string(Base.ENDIAN_BOM),
        "enabled" => String.(kernels.enabled),
        "Khat" => Dict{String,Any}(
            String(name) => _checkpoint_array_identity(kernels.K[name]) for name in names
        ),
        "qK" => Dict{String,Any}(String(name) => value for (name, value) in kernels.qᴷ),
        "F_LO" => _checkpoint_array_identity(kernels.Fᴸᴼ),
    )
end

"""Lossless native arrays: bounded chunks and low-cost deflate; no precision conversion."""
function _write_native_dataset(parent, name, values)
    if values isa AbstractArray &&
       isbitstype(eltype(values)) &&
       eltype(values)<:Real &&
       !isempty(values) &&
       sizeof(values)>=4096
        # HDF5.jl reverses dimensions for external readers. Bound actual chunks
        # to 256 KiB while retaining contiguous elements in Julia storage order.
        remaining=max(1, div(256*1024, sizeof(eltype(values))))
        chunk=ntuple(ndims(values)) do axis
            width=min(size(values, axis), remaining)
            remaining=max(1, div(remaining, width))
            width
        end
        parent[name, chunk=chunk, shuffle=true, deflate=1]=values
    else
        parent[name]=values
    end
    return parent[name]
end

function _write_array(
    parent,
    name::AbstractString,
    X::AbstractArray;
    axis_order::Union{Nothing,AbstractString} = nothing,
)
    dataset = _write_slab_array(parent, name, X, identity, eltype(X))
    attributes(dataset)["logical_shape"] = join(size(X), ",")
    attributes(dataset)["storage_contract"] = "reverse-axis compensation for row-major HDF5 readers"
    axis_order === nothing || (attributes(dataset)["logical_axis_order"] = axis_order)
    return dataset
end

const _SERIALIZATION_SLAB_BYTES = 1024*1024

"""Tile all dimensions; neither wide rows nor the full complex field are copied."""
function _serialization_block(shape, element_bytes)
    remaining=max(1, div(_SERIALIZATION_SLAB_BYTES, element_bytes))
    return ntuple(length(shape)) do axis
        width=max(1, min(shape[axis], remaining))
        remaining=max(1, div(remaining, width))
        width
    end
end

function _write_slab_array(parent, name, values, project, storage_type)
    isbitstype(storage_type) && storage_type<:Real ||
        return _write_native_dataset(parent, name, _storage_order(project.(values)))
    isempty(values) &&
        return _write_native_dataset(parent, name, _storage_order(project.(values)))
    length(values)*sizeof(storage_type)<4096 &&
        return _write_native_dataset(parent, name, _storage_order(project.(values)))
    shape=size(values)
    block=_serialization_block(shape, sizeof(storage_type))
    datatype=_hdf5_call(:datatype, storage_type)
    dataspace=_hdf5_call(:dataspace, reverse(shape))
    dataset=try
        _hdf5_call(
            :create_dataset,
            parent,
            name,
            datatype,
            dataspace;
            chunk = reverse(block),
            shuffle = true,
            deflate = 1,
        )
    finally
        close(datatype)
        close(dataspace)
    end
    # Reuse one bounded backing allocation. reshape shares its storage, and the
    # synchronous HDF5 write finishes before the next resize/fill. Projecting a
    # lazy axis permutation avoids both a projected slab and a permuted copy for
    # every tile of each Green/self-energy field.
    buffer=Vector{storage_type}(undef, prod(block))
    permutation=reverse(ntuple(identity, length(shape)))
    for starts in
        Iterators.product((1:block[axis]:shape[axis] for axis in eachindex(shape))...)
        ranges=ntuple(
            axis->starts[axis]:min(starts[axis]+block[axis]-1, shape[axis]),
            length(shape),
        )
        storage_shape=reverse(map(length, ranges))
        resize!(buffer, prod(storage_shape))
        storage=reshape(buffer, storage_shape)
        storage .= project.(PermutedDimsArray(view(values, ranges...), permutation))
        dataset[reverse(ranges)...]=storage
    end
    return dataset
end

function _read_array(parent, name::AbstractString)
    return _restore_order(read(parent[name]))
end

function _write_complex(parent, name::AbstractString, X::AbstractArray{<:Complex})
    group = create_group(parent, name)
    for (component, project) in (("real", real), ("imag", imag))
        dataset=_write_slab_array(
            group,
            component,
            X,
            project,
            typeof(real(zero(eltype(X)))),
        )
        attributes(dataset)["logical_shape"]=join(size(X), ",")
        attributes(dataset)["storage_contract"]="reverse-axis compensation for row-major HDF5 readers"
        close(dataset)
    end
    attributes(group)["representation"] = "split_complex"
    attributes(group)["serialization_slab_bytes"]=_SERIALIZATION_SLAB_BYTES
    return group
end

function _read_complex(parent, name::AbstractString)
    group = parent[name]
    shape=reverse(size(group["real"]))
    size(group["imag"])==reverse(shape) ||
        throw(DimensionMismatch("complex components differ"))
    values=Array{ComplexF64}(undef, shape)
    isempty(values) && return values
    block=_serialization_block(shape, sizeof(ComplexF64))
    for starts in
        Iterators.product((1:block[axis]:shape[axis] for axis in eachindex(shape))...)
        ranges=ntuple(
            axis->starts[axis]:min(starts[axis]+block[axis]-1, shape[axis]),
            length(shape),
        )
        permutation=reverse(ntuple(identity, length(shape)))
        real_part=PermutedDimsArray(group["real"][reverse(ranges)...], permutation)
        imag_part=PermutedDimsArray(group["imag"][reverse(ranges)...], permutation)
        view(values, ranges...) .= complex.(real_part, imag_part)
    end
    return values
end

const _RESULT_CONTRACT_SET = "qcl-negf.results.v1"
const _CHECKPOINT_PACKAGE = "QCLNEGF"
const _CHECKPOINT_SCHEMA_VERSION = "4.0"
const _NATIVE_SCIENCE_SCHEMAS = (
    "qcl-negf-checkpoint-v4",
    "qcl-negf-physics-v4",
    "qcl-negf-physics-analysis-v4",
    "qcl-negf-scientific-history-v4",
    "qcl-negf-optical-v4",
    "qcl-negf-operator-diagnostics-v4",
)
const _NATIVE_SCIENCE_ROLES = Dict(
    "qcl-negf-checkpoint-v4"=>"recovery",
    "qcl-negf-physics-v4"=>"physics.full",
    "qcl-negf-physics-analysis-v4"=>"physics.analysis",
    "qcl-negf-scientific-history-v4"=>"science.history",
    "qcl-negf-optical-v4"=>"physics.analysis",
    "qcl-negf-operator-diagnostics-v4"=>"science.comparison",
)

function _require_native_metadata(file, expected)
    haskey(file, "metadata") || throw(ArgumentError("native v4 requires metadata"))
    metadata=file["metadata"]
    attrs=attributes(metadata)
    for name in ("schema", "schema_version", "contract_set")
        haskey(attrs, name) || throw(ArgumentError("native v4 requires metadata/$name"))
    end
    String(read_attribute(metadata, "contract_set"))==_RESULT_CONTRACT_SET ||
        throw(ArgumentError("unsupported native result contract set"))
    version=String(read_attribute(metadata, "schema_version"))
    version==_CHECKPOINT_SCHEMA_VERSION || throw(
        ArgumentError(
            "unsupported native science format $version; require $(_CHECKPOINT_SCHEMA_VERSION)",
        ),
    )
    schema=String(read_attribute(metadata, "schema"))
    schema in _NATIVE_SCIENCE_SCHEMAS ||
        throw(ArgumentError("unsupported native science schema $schema"))
    haskey(attrs, "artifact_role") &&
    String(read_attribute(metadata, "artifact_role"))==_NATIVE_SCIENCE_ROLES[schema] ||
        throw(ArgumentError("native science role differs from the $schema contract"))
    allowed=expected isa AbstractString ? (expected,) : expected
    schema in allowed || throw(
        ArgumentError(
            "native science schema $schema differs from required $(join(allowed, ", "))",
        ),
    )
    return metadata
end

function _checkpoint_identity(file)
    haskey(file, "metadata") ||
        throw(ArgumentError("HDF5 checkpoint has no metadata group"))
    metadata = file["metadata"]
    metadata_attributes = attributes(metadata)
    haskey(metadata_attributes, "package") ||
        throw(ArgumentError("HDF5 checkpoint metadata has no package attribute"))
    haskey(metadata_attributes, "schema_version") ||
        throw(ArgumentError("HDF5 checkpoint metadata has no schema_version attribute"))
    return (;
        metadata,
        package = String(read_attribute(metadata, "package")),
        schema = String(read_attribute(metadata, "schema_version")),
    )
end

function _require_current_checkpoint(file)
    identity = _checkpoint_identity(file)
    identity.package == _CHECKPOINT_PACKAGE || throw(
        ArgumentError(
            "HDF5 checkpoint package $(identity.package) is not " * _CHECKPOINT_PACKAGE,
        ),
    )
    identity.schema == _CHECKPOINT_SCHEMA_VERSION || throw(
        ArgumentError(
            "unsupported HDF5 checkpoint schema $(identity.schema); expected " *
            _CHECKPOINT_SCHEMA_VERSION,
        ),
    )
    _require_native_metadata(file, ("qcl-negf-checkpoint-v4", "qcl-negf-physics-v4"))
    haskey(file, "convergence") ||
        throw(ArgumentError("native v4 requires convergence history"))
    _require_native_scba_tables(file["convergence"])
    return identity.metadata
end

"""
    save_checkpoint(path, solution; include_kernels=true)

Write an interoperable HDF5 checkpoint.  Complex arrays are deliberately
stored as separate `real` and `imag` datasets so Wolfram Language does not
depend on an HDF5 compound-complex convention.  Global metadata records the
axis conventions and scale system; SI units are encoded explicitly in input
dataset names, while dimensionless groups are named accordingly and described
by the versioned [checkpoint schema](@ref native-result-formats).

See [Checkpoint schema](@ref native-result-formats).
"""
function _write_checkpoint(
    path::AbstractString,
    solution::NEGFSolution;
    include_kernels::Bool = true,
    algorithms::Union{Nothing,AlgorithmOptions} = nothing,
    artifact_role::String = "recovery",
    identity::AbstractDict = Dict{String,Any}(),
)
    recorded=get(solution.observables,:restart_contract,nothing)
    recorded===nothing && (recorded=solution.scba.restart_contract)
    requested=algorithms===nothing ? nothing : _solver_restart_contract(solution.options,algorithms)
    recorded!==nothing && requested!==nothing && recorded!=requested &&
        throw(ArgumentError("explicit algorithm contract differs from executed state"))
    actual_contract=requested===nothing ? recorded : requested
    problem = solution.problem
    h5open(path, "w") do file
        metadata = create_group(file, "metadata")
        metadata["toolchain_json"] = sprint(_light_json, _runtime_toolchain_provenance())
        attributes(metadata)["package"] = _CHECKPOINT_PACKAGE
        attributes(metadata)["producer_package"] = "QCLNEGFRunner"
        attributes(metadata)["artifact_role"] = artifact_role
        attributes(metadata)["schema"] =
            artifact_role == "recovery" ? "qcl-negf-checkpoint-v4" : "qcl-negf-physics-v4"
        attributes(metadata)["native_grid"] = true
        attributes(
            metadata,
        )["checkpoint_boundary"] = "accepted Green/selfenergy evaluation before next mixing step"
        metadata["point_identity_json"] = sprint(_light_json, identity)
        _persist_model_scope!(metadata, solution)
        attributes(metadata)["package_version"] = _software_version()
        attributes(metadata)["schema_version"] = _CHECKPOINT_SCHEMA_VERSION
        attributes(metadata)["contract_set"]=_RESULT_CONTRACT_SET
        attributes(metadata)["status"] = String(solution.status)
        attributes(metadata)["converged"] = solution.converged
        attributes(metadata)["scba_quality"] = String(solution.scba.quality)
        attributes(metadata)["scba_status"] = String(solution.scba.status)
        attributes(metadata)["scba_converged"] = solution.scba.converged
        attributes(metadata)["quality"] = String(solution_quality(solution))
        metadata["warnings_json"] =
            sprint(_light_json, get(solution.observables, :warnings, Any[]))
        metadata["adaptation_checkpoint_json"] =
            sprint(_light_json, get(solution.observables, :adaptation_checkpoint, nothing))
        attributes(metadata)["julia_threads"] = Base.Threads.nthreads(:default)
        attributes(metadata)["blas_threads"] = BLAS.get_num_threads()
        attributes(metadata)["runtime_architecture"] = string(Sys.ARCH)
        contract = actual_contract
        attributes(metadata)["algorithm_provenance"] = contract===nothing ? "unknown" : "recorded"
        if contract !== nothing
            metadata["restart_contract_yaml"] = YAML.write(contract)
        end
        metadata["physical_models_identity_yaml"] = YAML.write(
            Dict(String(k)=>v for (k, v) in pairs(physical_model_identity(problem.models))),
        )
        metadata["kernel_identity_yaml"] =
            YAML.write(_checkpoint_kernel_identity(problem.kernels))
        attributes(metadata)["index_origin_julia"] = 1
        attributes(metadata)["index_origin_document"] = 0
        attributes(metadata)["green_axis_order"] = "E,k,a,b"
        attributes(metadata)["kernel_axis_order"] = "k,kprime,a,c,d,b"
        attributes(
            metadata,
        )["external_storage_order"] = "declared logical order; reverse-axis compensation applied before HDF5.jl write"
        attributes(metadata)["current_convention"] = "positive electron flow toward +z"
        attributes(
            metadata,
        )["model_limitations"] = "finite projected basis; configured embedding and scattering approximations; see resolved configuration and diagnostics"
        attributes(metadata)["kernels_included"] = include_kernels

        scales = create_group(file, "scales")
        scales["E0_eV"] = problem.scales.E₀_eV
        scales["L0_m"] = problem.scales.L₀_m
        scales["lambda_P"] = problem.scales.λ_P
        scales["J0_A_per_m2"] = Float64(ustrip(u"A/m^2", problem.scales.J₀))
        scales["m_ref_kg"] = Float64(ustrip(u"kg", problem.scales.m_ref))

        inputs = create_group(file, "inputs")
        inputs["F_bias_V_per_m"] = _volts_per_metre(problem.physical.F_bias)
        inputs["T_L_K"] = _kelvin(problem.physical.Tᴸ)
        inputs["T_LO_K"] = _kelvin(problem.physical.Tᴸᴼ)
        inputs["N_dop_2D_per_m2"] = _per_square_metre(problem.physical.N_dop²ᴰ)
        inputs["f_ion"] = problem.physical.f_ion
        inputs["z0_m"] = _metres(problem.physical.z₀)
        inputs["E_ref_eV"] = _electronvolts(problem.physical.E_ref)
        inputs["V_period_V"] = Float64(
            ustrip(
                u"V",
                uconvert(u"V", problem.physical.F_bias * period_length(problem.physical)),
            ),
        )
        inputs["layer_thickness_m"] =
            _metres.([layer.d for layer in problem.physical.layers])
        inputs["layer_Ec_eV"] =
            _electronvolts.([layer.Eᶜ for layer in problem.physical.layers])
        inputs["layer_mz_relative"] = [layer.mᶻᵣ for layer in problem.physical.layers]
        inputs["layer_mparallel_relative"] =
            [layer.m_parallelᵣ for layer in problem.physical.layers]
        inputs["layer_epsilon_relative"] = [layer.εᵣ for layer in problem.physical.layers]
        inputs["layer_x_Al"] = [layer.x_Al for layer in problem.physical.layers]
        inputs["layer_doped"] = Int8[layer.doped for layer in problem.physical.layers]
        inputs["interface_m"] = _metres.(problem.physical.interfaces)
        inputs["epsilon_static_relative"] = problem.physical.ε_s
        inputs["epsilon_infinity_relative"] = problem.physical.ε_∞
        inputs["hbar_omega_LO_eV"] = _electronvolts(problem.physical.ħωᴸᴼ)
        inputs["q_screen_per_m"] = _inverse_metres(problem.physical.q_s)
        inputs["q_LO_screen_per_m"] = _inverse_metres(problem.physical.qᴸᴼ_s)
        inputs["Delta_IFR_m"] = _metres(problem.physical.Δᴵᶠᴿ)
        inputs["Lambda_IFR_m"] = _metres(problem.physical.Λᴵᶠᴿ)
        inputs["Xi_eV"] = _electronvolts(problem.physical.Ξ)
        inputs["rho_m_kg_per_m3"] = Float64(ustrip(u"kg/m^3", problem.physical.ρ_m))
        inputs["v_s_m_per_s"] = Float64(ustrip(u"m/s", problem.physical.v_s))
        inputs["spin_degeneracy"] = problem.physical.g_s
        attributes(inputs)["alloy_enabled"] = problem.scattering.alloy
        if problem.physical.ΔV_alloy !== nothing
            inputs["DeltaV_alloy_eV"] = _electronvolts(problem.physical.ΔV_alloy)
        end
        if problem.physical.Ω₀ !== nothing
            inputs["Omega0_m3"] = Float64(ustrip(u"m^3", problem.physical.Ω₀))
        end

        numerical = create_group(file, "numerical_inputs")
        attributes(numerical)["energy_shift_discretization"] =
            String(problem.energy_shift_discretization)
        n = problem.numerical
        numerical["Nz"] = n.N_z
        numerical["Nb"] = n.N_b
        numerical["P_basis"] = n.P_basis
        numerical["E_min_eV"] = _electronvolts(n.E_min)
        numerical["E_max_eV"] = _electronvolts(n.E_max)
        numerical["NE"] = n.N_E
        numerical["M_E_eV"] = _electronvolts(n.M_E)
        numerical["k_max_per_m"] = _inverse_metres(n.k_max)
        numerical["Nk"] = n.N_k
        numerical["Nphi"] = n.N_φ
        numerical["qz_max_per_m"] = _inverse_metres(n.qz_max)
        numerical["Nqz"] = n.N_qz
        numerical["eta_seed_eV"] = _electronvolts(n.η_seed)
        numerical["alpha_Sigma"] = solution.options.α_Σ
        numerical["alpha_Poisson"] = solution.options.α_P
        numerical["max_scba"] = solution.options.max_scba
        numerical["max_poisson"] = solution.options.max_poisson
        numerical["energy_tail_window_fraction"] =
            solution.options.energy_tail_window_fraction
        numerical["momentum_tail_window_fraction"] =
            solution.options.momentum_tail_window_fraction
        for name in fieldnames(ScatteringOptions)
            numerical["scattering_$(String(name))"] = getfield(problem.scattering, name)
        end
        tolerances = create_group(numerical, "tolerances")
        for name in fieldnames(SolverTolerances)
            tolerances[String(name)] = getfield(solution.options.tolerances, name)
        end

        grids = create_group(file, "grids_dimensionless")
        grids["state_index"] = Int64.(0:(problem.numerical.N_b-1))
        grids["x"] = problem.grids.x
        grids["wx"] = problem.grids.wˣ
        grids["energy"] = problem.grids.ε
        grids["wE"] = problem.grids.wᴱ
        grids["trusted_energy"] = Int8.(problem.grids.trusted_energy)
        grids["k"] = problem.grids.κ
        grids["wk"] = problem.grids.wᵏ
        grids["qz"] = problem.grids.qᶻ
        grids["wqz"] = problem.grids.wᑫᶻ

        profiles = create_group(file, "profiles_dimensionless")
        profiles["Ec"] = problem.profiles.Eᶜ
        profiles["mz_relative"] = problem.profiles.mᶻᵣ
        profiles["mparallel_relative"] = problem.profiles.m_parallelᵣ
        profiles["epsilon_relative"] = problem.profiles.εᵣ
        profiles["ND"] = problem.profiles.Nᴰ
        profiles["x_Al"] = problem.profiles.x_Al
        profiles["layer_index"] = problem.profiles.layer_index

        basis = create_group(file, "basis_dimensionless")
        attributes(basis)["localization"] = String(problem.basis.localization)
        _write_complex(basis, "Phi", problem.basis.Φ)
        _write_complex(basis, "chi", problem.basis.χ)
        _write_complex(basis, "H0", problem.basis.H₀)
        _write_complex(basis, "Z", problem.basis.Z)
        _write_complex(basis, "Minv", problem.basis.M⁻¹)
        _write_complex(basis, "Tplus", problem.basis.T₊)
        _write_complex(basis, "Tminus", problem.basis.T₋)
        basis["centres"] = problem.basis.centres
        basis["spreads"] = problem.basis.spreads
        basis["overlap_eigenvalues"] = problem.basis.overlap_eigenvalues
        basis["window_eigenvalues"] = problem.basis.window_eigenvalues
        basis["Egrid0"] = problem.basis.Egrid₀
        basis["residuals"] = [
            problem.basis.r_orth,
            problem.basis.r_eigen,
            problem.basis.r_translation,
            problem.basis.r_translation_nearest,
            problem.basis.r_translation_two_pairs,
            problem.basis.κ_overlap,
        ]
        attributes(
            basis,
        )["residual_columns"] = "r_orth,r_eigen,r_translation_all,r_translation_nearest,r_translation_two_pairs,kappa_overlap"

        if include_kernels
            kernels = create_group(file, "kernels_dimensionless")
            attributes(kernels)["representation"] = "Khat=Kbar/qK; contraction restores qK"
            attributes(kernels)["axis_order"] = "k,kprime,a,c,d,b"
            for name in problem.kernels.enabled
                mechanism = create_group(kernels, String(name))
                mechanism["qK"] = problem.kernels.qᴷ[name]
                _write_complex(mechanism, "Khat", problem.kernels.K[name])
            end
            _write_complex(kernels, "F_LO", problem.kernels.Fᴸᴼ)
        end

        state = create_group(file, "state_dimensionless")
        state["UH"] = solution.Uᴴ
        state["density"] = solution.n
        _write_array(
            state,
            "condition_number",
            solution.scba.green.condition_number;
            axis_order = "E,k",
        )
        _write_array(
            state,
            "dyson_scale",
            solution.scba.green.dyson_scale;
            axis_order = "E,k",
        )
        _write_complex(state, "GR", solution.scba.green.Gᴿ)
        _write_complex(state, "GL", solution.scba.green.Gˡ)
        _write_complex(state, "GG", solution.scba.green.Gᵍ)
        _write_complex(state, "A", solution.scba.green.A)
        _write_complex(state, "h", project_hamiltonians(problem, solution.Uᴴ))

        selfenergy = create_group(file, "selfenergy_dimensionless")
        for (name, family) in solution.scba.scattering
            mechanism = create_group(selfenergy, String(name))
            _write_complex(mechanism, "SR", family.Σᴿ)
            _write_complex(mechanism, "SL", family.Σˡ)
            _write_complex(mechanism, "SG", family.Σᵍ)
        end
        for (name, family) in (
            ("embedding_total", solution.scba.embedding),
            ("embedding_plus", solution.scba.embedding_plus),
            ("embedding_minus", solution.scba.embedding_minus),
        )
            group = create_group(selfenergy, name)
            _write_complex(group, "SR", family.Σᴿ)
            _write_complex(group, "SL", family.Σˡ)
            _write_complex(group, "SG", family.Σᵍ)
        end

        convergence = create_group(file, "convergence")
        outer_matrix =
            isempty(solution.outer_history) ? zeros(0, 11) :
            reduce(
                vcat,
                (
                    permutedims(
                        Float64[
                            record.μ,
                            record.r_P,
                            record.r_U,
                            record.r_n,
                            record.r_neutral,
                            record.r_J,
                            record.r_Jchange,
                            record.r_population,
                            record.ζ,
                            record.J,
                            solution.options.α_P,
                        ],
                    ) for record in solution.outer_history
                ),
            )
        scba_matrix =
            isempty(solution.scba.history) ? zeros(0, 18) :
            reduce(
                vcat,
                (
                    permutedims(
                        Float64[
                            record.ν,
                            record.r_D,
                            record.r_A,
                            record.r_K,
                            record.r_Σ,
                            record.r_λ,
                            record.λ,
                            record.r_PSD,
                            record.r_caus,
                            record.r_roundoff,
                            record.r_Jchange,
                            record.r_population,
                            record.J,
                            solution.options.α_Σ,
                            record.raw_charge,
                            record.target_charge,
                            record.normalized_charge,
                            record.lambda_change,
                        ],
                    ) for record in solution.scba.history
                ),
            )
        _write_array(convergence, "outer", outer_matrix; axis_order = "iteration,column")
        _write_array(convergence, "scba", scba_matrix; axis_order = "iteration,column")
        _write_psd_history!(convergence, solution.scba.history; problem = problem)
        _write_physical_markers!(convergence, solution.scba.history)
        _write_scba_threshold_crossings!(
            convergence,
            solution.scba.history;
            required_consecutive = solution.options.convergence.required_consecutive_scba_passes,
        )
        outer_populations =
            isempty(solution.outer_history) ? zeros(0, problem.numerical.N_b) :
            reduce(
                vcat,
                (permutedims(record.populations) for record in solution.outer_history),
            )
        outer_density =
            isempty(solution.outer_history) ? zeros(0, problem.numerical.N_z) :
            reduce(vcat, (permutedims(record.density) for record in solution.outer_history))
        _write_array(
            convergence,
            "outer_populations",
            outer_populations;
            axis_order = "iteration,state",
        )
        _write_array(
            convergence,
            "outer_density",
            outer_density;
            axis_order = "iteration,z",
        )
        attributes(
            convergence["outer"],
        )["columns"] = "mu,r_P,r_U,r_n,r_neutral,r_J,r_Jchange,r_population,zeta,J_A_per_m2,alpha_P"
        attributes(
            convergence["scba"],
        )["columns"] = "nu,r_D,r_A,r_K,r_Sigma,r_lambda,lambda,r_PSD,r_caus,r_roundoff,r_Jchange,r_population,J_A_per_m2,alpha_Sigma,raw_charge,target_charge,normalized_charge,lambda_change"
        metric_names = sort!(collect(keys(solution.report.metrics)); by = String)
        convergence["metric_names"] = String.(metric_names)
        convergence["metric_values"] =
            [solution.report.metrics[name] for name in metric_names]
        if artifact_role in ("recovery", "physics.full")
            algorithm = create_group(file, "algorithm_state")
            mixer = solution.scba.mixer_state
            attributes(algorithm)["method"] = String(mixer.method)
            attributes(algorithm)["boundary"] = "before_next_mixing"
            attributes(algorithm)["history_count"] = length(mixer.states)
            attributes(algorithm)["family_order"] = join(
                [String.(problem.kernels.enabled); "embedding_plus"; "embedding_minus"],
                ",",
            )
            length(mixer.states) == length(mixer.residuals) ||
                throw(ArgumentError("mixer state/residual counts differ"))
            for (kind, history) in
                (("states", mixer.states), ("residuals", mixer.residuals))
                parent = create_group(algorithm, kind)
                for (i, families) in enumerate(history)
                    frame = create_group(parent, string(i))
                    for (j, family) in enumerate(families)
                        group = create_group(frame, string(j))
                        _write_complex(group, "SR", family.Σᴿ)
                        _write_complex(group, "SL", family.Σˡ)
                        _write_complex(group, "SG", family.Σᵍ)
                    end
                end
            end
        end
        _annotate_physics_tree!(file)
        _attach_native_dimensions!(file)
    end
    return path
end

"""
    load_checkpoint(path)

Read the language-neutral core of a current HDF5 checkpoint into a nested
named tuple.  The package and schema identity are validated before any state
is read.  The function intentionally does not deserialize Julia types; the
same datasets can therefore be imported by Wolfram Language.

See the versioned [HDF5 checkpoint schema](@ref native-result-formats).
"""
function load_checkpoint(path::AbstractString)
    return h5open(path, "r") do file
        _require_current_checkpoint(file)
        state = file["state_dimensionless"]
        (;
            Uᴴ = read(state["UH"]),
            n = read(state["density"]),
            Gᴿ = _read_complex(state, "GR"),
            Gˡ = _read_complex(state, "GL"),
            Gᵍ = _read_complex(state, "GG"),
            A = _read_complex(state, "A"),
            h = _read_complex(state, "h"),
            condition_number = _read_array(state, "condition_number"),
            dyson_scale = _read_array(state, "dyson_scale"),
            x = read(file["grids_dimensionless/x"]),
            ε = read(file["grids_dimensionless/energy"]),
            trusted_energy = Bool.(read(file["grids_dimensionless/trusted_energy"])),
            κ = read(file["grids_dimensionless/k"]),
            E₀_eV = read(file["scales/E0_eV"]),
            L₀_m = read(file["scales/L0_m"]),
        )
    end
end

"""Publish a complete [checkpoint](@ref native-result-formats) atomically; failed writes never replace a previous state."""
function save_checkpoint(path::AbstractString, solution::NEGFSolution; kwargs...)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary, stream = mktemp(directory)
    close(stream)
    try
        _write_checkpoint(temporary, solution; kwargs...)
        _sync_artifact_file(temporary)
        _atomic_replace_file(temporary, path)
        _sync_artifact_directory(directory)
    finally
        isfile(temporary) && rm(temporary; force = true)
    end
    return path
end
