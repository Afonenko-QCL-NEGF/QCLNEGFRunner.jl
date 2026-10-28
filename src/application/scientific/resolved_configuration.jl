_snapshot_sha(value) = bytes2hex(sha256(value))

# Finite owning projections. No reflection/repr/raw-map substitution is used.
_cfg_project(x::Nothing)=nothing
_cfg_project(x::Bool)=x
_cfg_project(x::AbstractString)=String(x)
_cfg_project(x::Symbol)=String(x)
function _cfg_project(x::Real)
    isfinite(x) || _snapshot_error("projection", "unsupported_projection")
    return x
end
_cfg_project(x::Unitful.AbstractQuantity)=Dict("value"=>ustrip(x),"unit"=>string(unit(x)))
_cfg_project(x::Union{AbstractVector,Tuple})=[_cfg_project(v) for v in x]
_cfg_project(x)=_snapshot_error("projection", "unsupported_projection")
import ..QCLNEGFRunner
function _cfg_project(x::QCLNEGFRunner.Layer)
    return Dict{String,Any}(
        "d"=>_cfg_project(x.d),
        "material"=>_cfg_project(x.material),
        "x_Al"=>_cfg_project(x.x_Al),
        "Eᶜ"=>_cfg_project(x.Eᶜ),
        "mᶻᵣ"=>_cfg_project(x.mᶻᵣ),
        "m_parallelᵣ"=>_cfg_project(x.m_parallelᵣ),
        "εᵣ"=>_cfg_project(x.εᵣ),
        "doped"=>_cfg_project(x.doped),
    )
end
function _cfg_project(x::QCLNEGFRunner.PhysicalParameters)
    return Dict{String,Any}(
        "layers"=>_cfg_project(x.layers),
        "N_dop²ᴰ"=>_cfg_project(x.N_dop²ᴰ),
        "f_ion"=>_cfg_project(x.f_ion),
        "F_bias"=>_cfg_project(x.F_bias),
        "z₀"=>_cfg_project(x.z₀),
        "E_ref"=>_cfg_project(x.E_ref),
        "Tᴸ"=>_cfg_project(x.Tᴸ),
        "Tᴸᴼ"=>_cfg_project(x.Tᴸᴼ),
        "ε_s"=>_cfg_project(x.ε_s),
        "ε_∞"=>_cfg_project(x.ε_∞),
        "ħωᴸᴼ"=>_cfg_project(x.ħωᴸᴼ),
        "q_s"=>_cfg_project(x.q_s),
        "qᴸᴼ_s"=>_cfg_project(x.qᴸᴼ_s),
        "Δᴵᶠᴿ"=>_cfg_project(x.Δᴵᶠᴿ),
        "Λᴵᶠᴿ"=>_cfg_project(x.Λᴵᶠᴿ),
        "Ξ"=>_cfg_project(x.Ξ),
        "ρ_m"=>_cfg_project(x.ρ_m),
        "v_s"=>_cfg_project(x.v_s),
        "ΔV_alloy"=>_cfg_project(x.ΔV_alloy),
        "Ω₀"=>_cfg_project(x.Ω₀),
        "g_s"=>_cfg_project(x.g_s),
        "interfaces"=>_cfg_project(x.interfaces),
    )
end
function _cfg_project(x::QCLNEGFRunner.NumericalParameters)
    return Dict{String,Any}(
        "N_z"=>_cfg_project(x.N_z),
        "N_b"=>_cfg_project(x.N_b),
        "P_basis"=>_cfg_project(x.P_basis),
        "E_min"=>_cfg_project(x.E_min),
        "E_max"=>_cfg_project(x.E_max),
        "N_E"=>_cfg_project(x.N_E),
        "M_E"=>_cfg_project(x.M_E),
        "k_max"=>_cfg_project(x.k_max),
        "N_k"=>_cfg_project(x.N_k),
        "N_φ"=>_cfg_project(x.N_φ),
        "qz_max"=>_cfg_project(x.qz_max),
        "N_qz"=>_cfg_project(x.N_qz),
        "η_seed"=>_cfg_project(x.η_seed),
    )
end
function _cfg_project(x::QCLNEGFRunner.SolverTolerances)
    return Dict{String,Any}(
        "r_D"=>_cfg_project(x.r_D),
        "r_A"=>_cfg_project(x.r_A),
        "r_K"=>_cfg_project(x.r_K),
        "r_Σ"=>_cfg_project(x.r_Σ),
        "r_λ"=>_cfg_project(x.r_λ),
        "r_P"=>_cfg_project(x.r_P),
        "r_U"=>_cfg_project(x.r_U),
        "r_n"=>_cfg_project(x.r_n),
        "r_neutral"=>_cfg_project(x.r_neutral),
        "r_J"=>_cfg_project(x.r_J),
        "r_C"=>_cfg_project(x.r_C),
        "r_power"=>_cfg_project(x.r_power),
        "r_PSD"=>_cfg_project(x.r_PSD),
        "r_caus"=>_cfg_project(x.r_caus),
        "r_sum"=>_cfg_project(x.r_sum),
        "r_obs"=>_cfg_project(x.r_obs),
        "r_ζ"=>_cfg_project(x.r_ζ),
        "r_imag"=>_cfg_project(x.r_imag),
        "r_tail"=>_cfg_project(x.r_tail),
        "r_edge"=>_cfg_project(x.r_edge),
        "r_roundoff"=>_cfg_project(x.r_roundoff),
    )
end
function _cfg_project(x::QCLNEGFRunner.DiagnosticQualityPolicy)
    return Dict{String,Any}(
        "enabled"=>_cfg_project(x.enabled),
        "keldysh_threshold"=>_cfg_project(x.keldysh_threshold),
        "self_energy_threshold"=>_cfg_project(x.self_energy_threshold),
        "normalization_threshold"=>_cfg_project(x.normalization_threshold),
        "required_consecutive_passes"=>_cfg_project(x.required_consecutive_passes),
        "target_fixed_point_threshold"=>_cfg_project(x.target_fixed_point_threshold),
        "coarse_wait_iterations"=>_cfg_project(x.coarse_wait_iterations),
        "strict_attempt_iterations"=>_cfg_project(x.strict_attempt_iterations),
        "observable_threshold"=>_cfg_project(x.observable_threshold),
        "positivity_threshold"=>_cfg_project(x.positivity_threshold),
        "causality_threshold"=>_cfg_project(x.causality_threshold),
        "outer_threshold"=>_cfg_project(x.outer_threshold),
    )
end
function _cfg_project(x::QCLNEGFRunner.ResearchTrendPolicy)
    return Dict{String,Any}(
        "window"=>_cfg_project(x.window),
        "minimum_reduction"=>_cfg_project(x.minimum_reduction),
        "promising_threshold"=>_cfg_project(x.promising_threshold),
        "max_regression"=>_cfg_project(x.max_regression),
        "max_oscillation"=>_cfg_project(x.max_oscillation),
    )
end
function _cfg_project(x::QCLNEGFRunner.ConvergencePolicy)
    return Dict{String,Any}(
        "mode"=>_cfg_project(x.mode),
        "trend"=>_cfg_project(x.trend),
        "minimum_scba_iterations"=>_cfg_project(x.minimum_scba_iterations),
        "required_consecutive_scba_passes"=>_cfg_project(x.required_consecutive_scba_passes),
        "minimum_poisson_iterations"=>_cfg_project(x.minimum_poisson_iterations),
        "required_consecutive_poisson_passes"=>_cfg_project(x.required_consecutive_poisson_passes),
        "stagnation_window"=>_cfg_project(x.stagnation_window),
        "stagnation_relative_improvement"=>_cfg_project(x.stagnation_relative_improvement),
        "diagnostic_quality"=>_cfg_project(x.diagnostic_quality),
    )
end
function _cfg_project(x::QCLNEGFRunner.SolverOptions)
    return Dict{String,Any}(
        "α_Σ"=>_cfg_project(x.α_Σ),
        "α_P"=>_cfg_project(x.α_P),
        "max_scba"=>_cfg_project(x.max_scba),
        "max_poisson"=>_cfg_project(x.max_poisson),
        "tolerances"=>_cfg_project(x.tolerances),
        "convergence"=>_cfg_project(x.convergence),
        "energy_tail_window_fraction"=>_cfg_project(x.energy_tail_window_fraction),
        "momentum_tail_window_fraction"=>_cfg_project(x.momentum_tail_window_fraction),
    )
end
function _cfg_project(x::QCLNEGFRunner.ScatteringOptions)
    return Dict{String,Any}(
        "LO"=>_cfg_project(x.LO),
        "acoustic"=>_cfg_project(x.acoustic),
        "impurity"=>_cfg_project(x.impurity),
        "IFR"=>_cfg_project(x.IFR),
        "alloy"=>_cfg_project(x.alloy),
    )
end
function _cfg_project(x::QCLNEGFRunner.ScaleSystem)
    return Dict{String,Any}(
        "E₀"=>_cfg_project(x.E₀),
        "L₀"=>_cfg_project(x.L₀),
        "m_ref"=>_cfg_project(x.m_ref),
        "E₀_eV"=>_cfg_project(x.E₀_eV),
        "E₀_J"=>_cfg_project(x.E₀_J),
        "L₀_m"=>_cfg_project(x.L₀_m),
        "λ_P"=>_cfg_project(x.λ_P),
        "J₀"=>_cfg_project(x.J₀),
    )
end
function _cfg_project(x::QCLNEGFRunner.PhysicalModelOptions)
    return Dict{String,Any}(
        "screening"=>_cfg_project(x.screening),
        "screening_temperature_K"=>Dict("value"=>x.screening_temperature_K,"unit"=>"K"),
        "screening_mass_ratio"=>_cfg_project(x.screening_mass_ratio),
        "dispersion"=>_cfg_project(x.dispersion),
        "nonparabolicity_per_eV"=>Dict("value"=>x.nonparabolicity_per_eV,"unit"=>"eV^-1"),
        "lo_population"=>_cfg_project(x.lo_population),
        "lo_fixed_occupation"=>_cfg_project(x.lo_fixed_occupation),
        "lo_decay_ps"=>Dict("value"=>x.lo_decay_ps,"unit"=>"ps"),
        "lo_mode_density_per_m3"=>Dict("value"=>x.lo_mode_density_per_m3,"unit"=>"m^-3"),
        "electron_electron"=>_cfg_project(x.electron_electron),
    )
end
function _cfg_project(x::QCLNEGFRunner.ElectronElectronOptions)
    return Dict{String,Any}(
        "mode"=>_cfg_project(x.mode),
        "screening_dimension"=>_cfg_project(x.screening_dimension),
        "transfer_wavenumber"=>_cfg_project(x.transfer_wavenumber),
        "electron_temperature"=>_cfg_project(x.electron_temperature),
        "effective_mass_ratio"=>_cfg_project(x.effective_mass_ratio),
        "carrier_density_si"=>Dict("value"=>x.carrier_density_si,"unit"=>(x.screening_dimension==2 ? "m^-2" : "m^-3")),
        "include_exchange"=>_cfg_project(x.include_exchange),
    )
end
function _cfg_project(x::QCLNEGFRunner.DomainAdaptationPolicy)
    return Dict{String,Any}(
        "mode"=>_cfg_project(x.mode),
        "maximum_expansions"=>_cfg_project(x.maximum_expansions),
        "maximum_energy_nodes"=>_cfg_project(x.maximum_energy_nodes),
        "growth_fraction"=>_cfg_project(x.growth_fraction),
        "tail_threshold"=>_cfg_project(x.tail_threshold),
    )
end
function _cfg_project(x::QCLNEGFRunner.AlgorithmOptions)
    return Dict{String,Any}(
        "solver_backend"=>_cfg_project(x.solver_backend),
        "energy_shift"=>_cfg_project(x.energy_shift),
        "hilbert"=>_cfg_project(x.hilbert),
        "contraction"=>_cfg_project(x.contraction),
        "kernel_build"=>_cfg_project(x.kernel_build),
        "mixing"=>_cfg_project(x.mixing),
        "localization"=>_cfg_project(x.localization),
        "embedding"=>_cfg_project(x.embedding),
        "embedding_periods"=>_cfg_project(x.embedding_periods),
        "occupation_normalization"=>_cfg_project(x.occupation_normalization),
        "low_rank_relative_tolerance"=>_cfg_project(x.low_rank_relative_tolerance),
        "low_rank_maximum_rank"=>_cfg_project(x.low_rank_maximum_rank),
        "anderson_history_depth"=>_cfg_project(x.anderson_history_depth),
        "anderson_damping"=>_cfg_project(x.anderson_damping),
        "anderson_regularization"=>_cfg_project(x.anderson_regularization),
        "retarded_real_part"=>_cfg_project(x.retarded_real_part),
        "self_energy_structure"=>_cfg_project(x.self_energy_structure),
        "transverse_momentum"=>_cfg_project(x.transverse_momentum),
    )
end
function _cfg_project(x::QCLNEGFRunner.SCBAPhysicsMarkerPolicy)
    return Dict{String,Any}(
        "cadence"=>_cfg_project(x.cadence),
        "max_spectral_blocks"=>_cfg_project(x.max_spectral_blocks),
        "relative_mode_weight_floor"=>_cfg_project(x.relative_mode_weight_floor),
    )
end
function _cfg_project(x::QCLNEGFRunner.ProductionOptions)
    return Dict{String,Any}(
        "memory_budget_bytes"=>_cfg_project(x.memory_budget_bytes),
        "energy_chunk"=>_cfg_project(x.energy_chunk),
        "hilbert_columns"=>_cfg_project(x.hilbert_columns),
        "parallel_backend"=>_cfg_project(x.parallel_backend),
        "worker_count"=>_cfg_project(x.worker_count),
        "residual_chunk"=>_cfg_project(x.residual_chunk),
        "phase_timing"=>_cfg_project(x.phase_timing),
        "physics_markers"=>_cfg_project(x.physics_markers),
        "verify_fft_roundoff"=>_cfg_project(x.verify_fft_roundoff),
        "checkpoint_every_outer"=>_cfg_project(x.checkpoint_every_outer),
        "checkpoint_every_scba"=>_cfg_project(x.checkpoint_every_scba),
        "progress_every_scba"=>_cfg_project(x.progress_every_scba),
        "progress_every_outer"=>_cfg_project(x.progress_every_outer),
        "algorithms"=>_cfg_project(x.algorithms),
        "event_sink"=>_cfg_project(x.event_sink),
        "checkpoint_request"=>_cfg_project(x.checkpoint_request),
        "phase_request"=>_cfg_project(x.phase_request),
        "outer_iteration"=>_cfg_project(x.outer_iteration),
    )
end
function _cfg_project(x::QCLNEGFRunner.ProductionKernelOptions)
    return Dict{String,Any}(
        "initial_lookup_nodes"=>_cfg_project(x.initial_lookup_nodes),
        "maximum_lookup_nodes"=>_cfg_project(x.maximum_lookup_nodes),
        "relative_tolerance"=>_cfg_project(x.relative_tolerance),
        "lookup_power"=>_cfg_project(x.lookup_power),
        "validation_fractions"=>_cfg_project(x.validation_fractions),
        "angular_validation_pairs"=>_cfg_project(x.angular_validation_pairs),
        "impurity_angular_tolerance"=>_cfg_project(x.impurity_angular_tolerance),
        "strict"=>_cfg_project(x.strict),
    )
end
function _cfg_project(x::QCLNEGFRunner.AutomaticExecutionConfiguration)
    return Dict{String,Any}(
        "memory_reserve_fraction"=>_cfg_project(x.memory_reserve_fraction),
        "minimum_memory_reserve_bytes"=>_cfg_project(x.minimum_memory_reserve_bytes),
        "workspace_budget_fraction"=>_cfg_project(x.workspace_budget_fraction),
        "workspace_complex_arrays_per_energy_block"=>_cfg_project(x.workspace_complex_arrays_per_energy_block),
        "minimum_outer_parallel_threads"=>_cfg_project(x.minimum_outer_parallel_threads),
        "large_basis_threshold"=>_cfg_project(x.large_basis_threshold),
        "minimum_energy_chunk"=>_cfg_project(x.minimum_energy_chunk),
        "energy_chunk_alignment"=>_cfg_project(x.energy_chunk_alignment),
        "blocks_per_worker"=>_cfg_project(x.blocks_per_worker),
        "hilbert_columns_per_worker"=>_cfg_project(x.hilbert_columns_per_worker),
        "energy_jobs_per_worker"=>_cfg_project(x.energy_jobs_per_worker),
    )
end
function _cfg_project(x::QCLNEGFRunner.ExecutionConfiguration)
    return Dict{String,Any}(
        "strategy"=>_cfg_project(x.strategy),
        "solver_backend"=>_cfg_project(x.solver_backend),
        "julia_threads"=>_cfg_project(x.julia_threads),
        "blas_threads"=>_cfg_project(x.blas_threads),
        "fail_on_thread_mismatch"=>_cfg_project(x.fail_on_thread_mismatch),
        "automatic"=>_cfg_project(x.automatic),
    )
end
function _cfg_project(x::QCLNEGFRunner.ProgressOutputConfiguration)
    return Dict{String,Any}(
        "enabled"=>_cfg_project(x.enabled),
        "terminal"=>_cfg_project(x.terminal),
        "significant_digits"=>_cfg_project(x.significant_digits),
        "human_every"=>_cfg_project(x.human_every),
        "event_log_file"=>_cfg_project(x.event_log_file),
        "latest_snapshot_file"=>_cfg_project(x.latest_snapshot_file),
        "dashboard_file"=>_cfg_project(x.dashboard_file),
    )
end
function _cfg_project(x::QCLNEGFRunner.DeviceGeometryConfiguration)
    return Dict{String,Any}(
        "periods"=>_cfg_project(x.periods),
        "ridge_width"=>_cfg_project(x.ridge_width),
        "cavity_length"=>_cfg_project(x.cavity_length),
    )
end
function _cfg_project(x::QCLNEGFRunner.OutputConfiguration)
    return Dict{String,Any}(
        "directory"=>_cfg_project(x.directory),
        "checkpoint_prefix"=>_cfg_project(x.checkpoint_prefix),
        "resume"=>_cfg_project(x.resume),
        "fail_fast"=>_cfg_project(x.fail_fast),
        "save_full_state"=>_cfg_project(x.save_full_state),
        "save_csv"=>_cfg_project(x.save_csv),
        "save_plots"=>_cfg_project(x.save_plots),
        "live_visualization"=>_cfg_project(x.live_visualization),
        "snapshot_every_scba"=>_cfg_project(x.snapshot_every_scba),
        "snapshot_every_outer"=>_cfg_project(x.snapshot_every_outer),
        "progress"=>_cfg_project(x.progress),
        "report_directory"=>_cfg_project(x.report_directory),
        "save_expert_markdown"=>_cfg_project(x.save_expert_markdown),
        "save_comparison_csv"=>_cfg_project(x.save_comparison_csv),
        "save_comparison_plots"=>_cfg_project(x.save_comparison_plots),
        "device_geometry"=>_cfg_project(x.device_geometry),
        "debug_hdf5"=>_cfg_project(x.debug_hdf5),
        "light_max_space_points"=>_cfg_project(x.light_max_space_points),
        "light_max_energy_points"=>_cfg_project(x.light_max_energy_points),
        "light_max_momentum_points"=>_cfg_project(x.light_max_momentum_points),
        "light_max_snapshots"=>_cfg_project(x.light_max_snapshots),
    )
end
function _cfg_project(x::QCLNEGFRunner.ConvergenceStudyConfiguration)
    return Dict{String,Any}(
        "spatial_nodes"=>_cfg_project(x.spatial_nodes),
        "energy_nodes"=>_cfg_project(x.energy_nodes),
        "momentum_nodes"=>_cfg_project(x.momentum_nodes),
        "angular_nodes"=>_cfg_project(x.angular_nodes),
    )
end
function _cfg_project(x::QCLNEGFRunner.StudyMethodConfiguration)
    return Dict{String,Any}(
        "profile"=>_cfg_project(x.profile),
        "label"=>_cfg_project(x.label),
        "modifies_physics"=>_cfg_project(x.modifies_physics),
        "algorithm_family"=>_cfg_project(x.algorithm_family),
        "description"=>_cfg_project(x.description),
        "literature"=>_cfg_project(x.literature),
    )
end
function _cfg_project(x::QCLNEGFRunner.StudyConfiguration)
    return Dict{String,Any}(
        "mode"=>_cfg_project(x.mode),
        "voltages_per_period"=>_cfg_project(x.voltages_per_period),
        "temperatures"=>_cfg_project(x.temperatures),
        "comparison_profiles"=>_cfg_project(x.comparison_profiles),
        "reference_profile"=>_cfg_project(x.reference_profile),
        "methods"=>_cfg_project(x.methods),
        "repetitions"=>_cfg_project(x.repetitions),
        "calculate_optical_response"=>_cfg_project(x.calculate_optical_response),
        "photon_energy_min"=>_cfg_project(x.photon_energy_min),
        "photon_energy_max"=>_cfg_project(x.photon_energy_max),
        "photon_energy_points"=>_cfg_project(x.photon_energy_points),
        "optical_edge_tolerance"=>_cfg_project(x.optical_edge_tolerance),
        "convergence"=>_cfg_project(x.convergence),
    )
end
function _cfg_default_rule_sources()
    core_entry=pathof(QCLNEGFRunner.QCLNEGF)
    core_entry===nothing && _snapshot_error("projection", "unsupported_projection")
    core_root=dirname(core_entry)
    result=Dict{String,String}()
    for (owner,root,paths) in (
        ("Runner",_package_path("src"),("infrastructure/config/configuration.jl",)),
        ("Core",core_root,("domain/types.jl","domain/electron_electron.jl","domain/algorithm_options.jl",
            "numerics/optimized/production_contracts.jl","numerics/optimized/kernels.jl", "numerics/reference/scba.jl")))
        for path in paths
            file=joinpath(root,path)
            isfile(file) || _snapshot_error("projection", "unsupported_projection")
            result[owner*":src/"*path]=_snapshot_sha(read(file))
        end
    end
    return result
end

function _cfg_effective(configuration)
    # Each projection points to its actual owning loader rule, which can combine
    # inputs and constructor defaults. Histories are complete rule inputs, NOT
    # invented per-field assigning sources or equality-based default guesses.
    result=Dict{String,Any}()
    for (field,section,rule) in (
        (:physical,"physical","_parse_physical"),(:numerical,"numerical","_parse_numerical"),
        (:scales,"scales","_parse_scales"),(:scattering,"scattering","_parse_scattering"),
        (:solver,"solver","_parse_solver"),(:production,"production","_parse_production"),
        (:kernels,"kernel_construction","_parse_kernels"),(:algorithms,"algorithms","_parse_algorithms"),
        (:execution,"execution","_parse_execution"),(:output,"output","_parse_output"),
        (:study,"study","_parse_study"),(:physical_models,"physical_models","_parse_physical_models"),
        (:domain_adaptation,"domain_adaptation","_parse_domain_adaptation"))
        input_sections=section=="production" ? ("production","algorithms","execution") :
            section=="algorithms" ? ("algorithms","execution") :
            section=="scattering" ? ("scattering","physical") : (section,)
        histories=Dict(k=>copy(v) for (k,v) in configuration.provenance.sources
            if any(input->startswith(k,input*"."),input_sections))
        result[section]=Dict("used"=>_cfg_project(getproperty(configuration,field)),
            "origin"=>"owning_resolution_rule", "rule_source"=>"Runner:src/infrastructure/config/configuration.jl@sha256:"*
                _snapshot_sha(read(_package_path("src","infrastructure","config","configuration.jl")))*"#"*rule,
            "input_assigning_histories"=>histories)
    end
    return result
end

# Immutable storage deliberately has no unchecked one-argument constructor.
struct _ResolvedSnapshotToken end
"""Frozen declarative typed inputs. Use `resolved_snapshot_dict` for a defensive copy."""
struct ResolvedConfigurationSnapshot
    encoded::String
    ResolvedConfigurationSnapshot(encoded::String, ::_ResolvedSnapshotToken) = new(encoded)
end
_snapshot_error(path,message) = QCLNEGFRunner._configuration_error(path,message)
const _SNAPSHOT_SECTIONS = (
    (:physical,"physical"), (:numerical,"numerical"), (:scales,"scales"),
    (:scattering,"scattering"), (:solver,"solver"), (:production,"production"),
    (:kernels,"kernel_construction"), (:algorithms,"algorithms"), (:execution,"execution"),
    (:output,"output"), (:study,"study"), (:physical_models,"physical_models"),
    (:domain_adaptation,"domain_adaptation"))
const _MODEL_SECTIONS = ("physical","numerical","scales","scattering","solver",
    "kernel_construction","algorithms","physical_models","domain_adaptation")
const _MODEL_PRODUCTION = ("physics_markers","verify_fft_roundoff")
const _RESOLVED_SNAPSHOT_SCHEMA = "qcl-negf-resolved-configuration-v1"

function _snapshot_used(c)
    for name in (:event_sink,:checkpoint_request,:phase_request)
        getproperty(c.production,name)===nothing ||
            _snapshot_error("production."*String(name),"unsupported_snapshot_phase")
    end
    c.production.outer_iteration==0 || _snapshot_error("production.outer_iteration","unsupported_snapshot_phase")
    result=Dict(section=>_cfg_project(getproperty(c,field)) for (field,section) in _SNAPSHOT_SECTIONS)
    result["algorithms"]==result["production"]["algorithms"] ||
        _snapshot_error("production.algorithms","typed algorithms differ")
    return result
end
function _model_inputs(used,derived)
    inputs=Dict{String,Any}(key=>deepcopy(used[key]) for key in _MODEL_SECTIONS)
    inputs["production"]=Dict(key=>deepcopy(used["production"][key]) for key in _MODEL_PRODUCTION)
    inputs["numerical"]["η_seed"]=Dict("value"=>derived["effective_seed"]["effective_eV"],"unit"=>"eV")
    return Dict("scope"=>"stationary_transport_inputs_v1","inputs"=>inputs,
        "derived"=>Dict("effective_seed_eV"=>derived["effective_seed"]["effective_eV"]))
end
function _snapshot_model(c)
    seed=effective_seed_parameters(c.numerical,c.scales)
    derived=Dict("effective_seed"=>Dict(String(k)=>(v isa Symbol ? String(v) : v) for (k,v) in pairs(seed)))
    return _model_inputs(_snapshot_used(c),derived)
end

"""Capture validated typed inputs, units, owning rule origins and stationary model identity.

Replays the existing resolver to reject mutated raw/typed pairs. Performs no solve,
resource admission or runtime retuning. Origins record rule inputs, not guessed defaults.
"""
function resolved_configuration_snapshot(c::ResolvedRunConfiguration)::ResolvedConfigurationSnapshot
    used=_snapshot_used(c)
    raw=deepcopy(c.raw)
    provenance=deepcopy(c.provenance)
    replay=_resolve_configuration(raw,provenance)
    (c.name,c.description,c.classification)==(replay.name,replay.description,replay.classification) ||
        _snapshot_error("run","raw and typed metadata differ")
    isequal(used,_snapshot_used(replay)) || _snapshot_error("snapshot","raw and typed inputs differ")
    sections=_cfg_effective(c)
    seed=effective_seed_parameters(c.numerical,c.scales)
    derived=Dict("effective_seed"=>Dict(String(k)=>(v isa Symbol ? String(v) : v) for (k,v) in pairs(seed)))
    model=_model_inputs(used,derived)
    document=Dict{String,Any}("schema"=>_RESOLVED_SNAPSHOT_SCHEMA,
        "phase"=>"resolved_declarative_inputs","raw_configuration"=>raw,
        "sections"=>sections,"derived"=>derived,"default_rule_sources"=>_cfg_default_rule_sources(),
        "model_binding"=>Dict("encoding"=>"qcl-negf-canonical-bytes-v1",
            "scope"=>model["scope"],"sha256"=>bytes2hex(sha256(canonical_bytes(model)))))
    return ResolvedConfigurationSnapshot(YAML.write(document),_ResolvedSnapshotToken())
end

"""Return a fresh native metadata tree; large integers are tagged only by transport adapters."""
function resolved_snapshot_dict(s::ResolvedConfigurationSnapshot)::Dict{String,Any}
    return YAML.load(s.encoded;dicttype=Dict{String,Any})
end

_snapshot_pointer(key)=replace(replace(String(key),"~"=>"~0"),"/"=>"~1")
_snapshot_unit_atom(value)=value isa AbstractDict && length(value)==2 &&
    haskey(value,"value") && get(value,"unit",nothing) isa AbstractString
function _snapshot_changes(before,after,path="")
    isequal(before,after) && return Any[]
    if before isa AbstractDict && after isa AbstractDict &&
       !_snapshot_unit_atom(before) && !_snapshot_unit_atom(after)
        rows=Any[]
        for key in sort!(collect(union(Set(keys(before)),Set(keys(after)))))
            child=path*"/"*_snapshot_pointer(key)
            if haskey(before,key) && haskey(after,key)
                append!(rows,_snapshot_changes(before[key],after[key],child))
            else
                push!(rows,Dict("path"=>child,"before"=>deepcopy(get(before,key,Dict("status"=>"missing"))),
                    "after"=>deepcopy(get(after,key,Dict("status"=>"missing")))))
            end
        end
        return rows
    end
    return Any[Dict("path"=>path,"before"=>deepcopy(before),"after"=>deepcopy(after))]
end
function _controlled_parent(raw,parts;create=false)
    current=raw
    for part in parts[1:end-1]
        if !haskey(current,part)
            create || return nothing
            current[part]=Dict{String,Any}()
        end
        current=current[part]
        current isa AbstractDict || return nothing
    end
    return current
end
function _controlled_schema_path(parts)
    # Optional defaults need not occur in either raw input. Ask the same bundled
    # configuration schema, rather than maintaining another field/default list.
    root=QCLNEGFRunner._load_configuration_schema(QCLNEGFRunner.default_configuration_schema())
    node=root
    for part in parts
        while node isa AbstractDict && haskey(node,"\$ref")
            node=QCLNEGFRunner._resolve_local_schema_reference(root,node["\$ref"])
        end
        properties=node isa AbstractDict ? get(node,"properties",nothing) : nothing
        properties isa AbstractDict && haskey(properties,part) || return false
        node=properties[part]
    end
    return true
end
function _validate_controlled_paths(paths,base,candidate)
    normalized=String.(paths)
    for path in normalized
        occursin(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$",path) ||
            _snapshot_error(path,"invalid_controlled_path")
        parts=split(path,'.'); section=first(parts)
        (section in _MODEL_SECTIONS || (section=="production" && length(parts)>=2 && parts[2] in _MODEL_PRODUCTION)) ||
            _snapshot_error(path,"invalid_controlled_path")
        any(raw->begin
            parent=_controlled_parent(raw,parts)
            parent!==nothing && haskey(parent,last(parts))
        end,(base.raw,candidate.raw)) || _controlled_schema_path(parts) ||
            _snapshot_error(path,"invalid_controlled_path")
    end
    for (i,path) in enumerate(normalized), other in normalized[i+1:end]
        (path==other || startswith(path,other*".") || startswith(other,path*".")) &&
            _snapshot_error(path,"invalid_controlled_path: overlapping paths")
    end
    return sort!(normalized)
end

"""Compare effective inputs using controlled declarative paths and the same resolver.

The counterfactual applies only declared candidate inputs to the baseline, so derived
changes are explained without an independent field dependency map. No solve is run.
"""
function resolved_configuration_diff(base::ResolvedRunConfiguration,candidate::ResolvedRunConfiguration;
    controlled_paths::AbstractVector{<:AbstractString}=String[])::Dict{String,Any}
    a=resolved_snapshot_dict(resolved_configuration_snapshot(base))
    b=resolved_snapshot_dict(resolved_configuration_snapshot(candidate))
    paths=_validate_controlled_paths(controlled_paths,base,candidate)
    raw=deepcopy(base.raw)
    for path in paths
        parts=split(path,'.'); source=_controlled_parent(candidate.raw,parts)
        dest=_controlled_parent(raw,parts;create=true)
        dest===nothing && _snapshot_error(path,"invalid_controlled_counterfactual")
        if source!==nothing && haskey(source,last(parts))
            dest[last(parts)]=deepcopy(source[last(parts)])
        else
            pop!(dest,last(parts),nothing)
        end
    end
    counterfactual=try
        _resolve_configuration(raw,deepcopy(base.provenance))
    catch error
        error isa QCLNEGFRunner.ConfigurationError || rethrow()
        _snapshot_error("controlled_paths","invalid_controlled_counterfactual")
    end
    undeclared=_snapshot_changes(_snapshot_model(counterfactual),_snapshot_model(candidate))
    used(document)=Dict(k=>v["used"] for (k,v) in document["sections"])
    changes=_snapshot_changes(Dict("sections"=>used(a),"derived"=>a["derived"]),
        Dict("sections"=>used(b),"derived"=>b["derived"]))
    return Dict{String,Any}("schema"=>"qcl-negf-resolved-configuration-diff-v1",
        "base_model_sha256"=>a["model_binding"]["sha256"],
        "candidate_model_sha256"=>b["model_binding"]["sha256"],
        "controlled_paths"=>paths,"changes"=>changes,"undeclared_changes"=>undeclared,
        "comparable"=>isempty(undeclared))
end
