"""
    ConfigurationError

Error raised when a YAML manifest, merge, schema, unit, or cross-field
constraint is invalid.  Configuration errors are deliberately fail-closed:
an unknown key is never ignored.
"""
struct ConfigurationError <: Exception
    path::String
    message::String
end

function Base.showerror(io::IO, error::ConfigurationError)
    print(io, "configuration error at ", error.path, ": ", error.message)
end

_configuration_error(path, message) =
    throw(ConfigurationError(String(path), String(message)))

"""
Ordered manifests/files and the complete override history for every leaf in
the resolved YAML tree.  `sources[path]` is ordered from the first definition
to the winning definition.
"""
struct ConfigurationProvenance
    manifests::Vector{String}
    files::Vector{String}
    sources::Dict{String,Vector{String}}
end

"""Policy knobs used by the `auto_exact` E1 execution planner."""
struct AutomaticExecutionConfiguration
    memory_reserve_fraction::Float64
    minimum_memory_reserve_bytes::Int
    workspace_budget_fraction::Float64
    workspace_complex_arrays_per_energy_block::Int
    minimum_outer_parallel_threads::Int
    large_basis_threshold::Int
    minimum_energy_chunk::Int
    energy_chunk_alignment::Int
    blocks_per_worker::Int
    hilbert_columns_per_worker::Int
    energy_jobs_per_worker::Int
end

"""
Execution resources and the top-level solver implementation selection.
Production reductions are deterministic by contract and therefore are not a
configurable execution mode.

See [YAML run configurations](@ref yaml-run-configurations).
"""
struct ExecutionConfiguration
    strategy::Symbol
    solver_backend::Symbol
    julia_threads::Int
    blas_threads::Int
    fail_on_thread_mismatch::Bool
    automatic::AutomaticExecutionConfiguration
end

"""
Human and machine-readable progress stream configuration.

See [Production observability](@ref native-result-formats).
"""
struct ProgressOutputConfiguration
    enabled::Bool
    terminal::Bool
    significant_digits::Int
    human_every::Int
    event_log_file::Union{Nothing,String}
    latest_snapshot_file::Union{Nothing,String}
    dashboard_file::Union{Nothing,String}
end

"""
Device geometry used only for report-level current conversion.

See [YAML run configurations](@ref yaml-run-configurations).
"""
struct DeviceGeometryConfiguration
    periods::Int
    ridge_width::LengthQuantity
    cavity_length::LengthQuantity
end

"""
Output, restart, and live-visualization policy.

See [YAML run configurations](@ref yaml-run-configurations) and
[Production observability](@ref native-result-formats).
"""
struct OutputConfiguration
    directory::String
    checkpoint_prefix::String
    resume::Bool
    fail_fast::Bool
    save_full_state::Bool
    save_csv::Bool
    save_plots::Bool
    live_visualization::Bool
    snapshot_every_scba::Int
    snapshot_every_outer::Int
    progress::ProgressOutputConfiguration
    report_directory::String
    save_expert_markdown::Bool
    save_comparison_csv::Bool
    save_comparison_plots::Bool
    device_geometry::DeviceGeometryConfiguration
    debug_hdf5::Bool
    light_max_space_points::Int
    light_max_energy_points::Int
    light_max_momentum_points::Int
    light_max_snapshots::Int
end

# Source compatibility for callers constructing the previous output contract.
OutputConfiguration(args::Vararg{Any,16}) =
    OutputConfiguration(args..., false, 2048, 512, 64, 64)

"""
Explicit grid sizes varied by a convergence study.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
struct ConvergenceStudyConfiguration
    spatial_nodes::Vector{Int}
    energy_nodes::Vector{Int}
    momentum_nodes::Vector{Int}
    angular_nodes::Vector{Int}
end

"""
Report-facing metadata for one compared configuration profile.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
struct StudyMethodConfiguration
    profile::String
    label::String
    modifies_physics::Bool
    algorithm_family::Symbol
    description::String
    literature::Vector{String}
end

"""
Operating points and comparison/report controls for one reproducible run.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
struct StudyConfiguration
    mode::Symbol
    voltages_per_period::Vector{typeof(1.0u"V")}
    temperatures::Vector{TemperatureQuantity}
    comparison_profiles::Vector{String}
    reference_profile::Union{Nothing,String}
    methods::Vector{StudyMethodConfiguration}
    repetitions::Int
    calculate_optical_response::Bool
    photon_energy_min::EnergyQuantity
    photon_energy_max::EnergyQuantity
    photon_energy_points::Int
    optical_edge_tolerance::Float64
    convergence::ConvergenceStudyConfiguration
end

"""
    ResolvedRunConfiguration

Fully resolved, unit-checked run description.  Physical and numerical values
are converted to the same strongly typed objects accepted by the educational
and production APIs.  `algorithms` is a validated [`AlgorithmOptions`](https://github.com/AfonenkoA/QCLNEGF.jl/blob/main/docs/src/api/public.md)
object and is also embedded in `production.algorithms`.
`raw` is retained only for reporting and reproducibility, never as a source of
unchecked solver inputs.

See [YAML run configurations](@ref yaml-run-configurations).
"""
struct ResolvedRunConfiguration
    name::String
    description::String
    classification::Symbol
    physical::PhysicalParameters
    numerical::NumericalParameters
    scales::ScaleSystem
    scattering::ScatteringOptions
    solver::SolverOptions
    production::ProductionOptions
    kernels::ProductionKernelOptions
    algorithms::AlgorithmOptions
    execution::ExecutionConfiguration
    output::OutputConfiguration
    study::StudyConfiguration
    provenance::ConfigurationProvenance
    raw::Dict{String,Any}
    physical_models::PhysicalModelOptions
    domain_adaptation::DomainAdaptationPolicy
end

# Source compatibility for the 0.9 typed in-memory constructor.
ResolvedRunConfiguration(args::Vararg{Any,16}) =
    ResolvedRunConfiguration(args..., PhysicalModelOptions(), DomainAdaptationPolicy())
ResolvedRunConfiguration(args::Vararg{Any,17}) =
    ResolvedRunConfiguration(args..., DomainAdaptationPolicy())

"""
    configuration_source(configuration, dotted_path)

Return the winning YAML file for `dotted_path`, or `nothing` when the path is
not a leaf in the resolved tree.

See [YAML run configurations](@ref yaml-run-configurations).
"""
function configuration_source(
    configuration::ResolvedRunConfiguration,
    dotted_path::AbstractString,
)
    history = get(configuration.provenance.sources, String(dotted_path), nothing)
    return history === nothing || isempty(history) ? nothing : last(history)
end

"""Return a defensive copy of the validated, deeply merged
[YAML configuration](@ref yaml-run-configurations)."""
resolved_configuration_dict(configuration::ResolvedRunConfiguration) =
    deepcopy(configuration.raw)

"""Return physical input selected by a
[YAML run configuration](@ref yaml-run-configurations)."""
physical_parameters(configuration::ResolvedRunConfiguration) = configuration.physical
"""Return the grid selected by a
[YAML run configuration](@ref yaml-run-configurations)."""
numerical_parameters(configuration::ResolvedRunConfiguration) = configuration.numerical
"""Return scattering channels selected by a
[YAML run configuration](@ref yaml-run-configurations)."""
scattering_options(configuration::ResolvedRunConfiguration) = configuration.scattering
"""Return SCBA/Poisson controls from a
[YAML run configuration](@ref yaml-run-configurations)."""
solver_options(configuration::ResolvedRunConfiguration) = configuration.solver
"""Return production controls from a
[YAML run configuration](@ref yaml-run-configurations)."""
production_options(configuration::ResolvedRunConfiguration) = configuration.production
"""Return the selection described by the
[Optimization decision tree](https://github.com/AfonenkoA/QCLNEGF.jl/blob/main/docs/src/theory/20_optimization_decision_tree.md)."""
algorithm_options(configuration::ResolvedRunConfiguration) = configuration.algorithms
