module QCLNEGFRunner
using LinearAlgebra
using Logging
using SHA
using FFTW
using Unitful
using YAML
import HDF5
import QCLNEGF
const REQUIRED_JULIA_VERSION = v"1.13.0"
VERSION == REQUIRED_JULIA_VERSION || error("QCLNEGFRunner requires Julia 1.13.0 exactly")
include("core_api.jl")
include("infrastructure/persistence/atomic_files.jl")
include("infrastructure/resources/package_paths.jl")
include("infrastructure/persistence/hdf5_backend.jl")
include("infrastructure/persistence/hdf5.jl")
include("infrastructure/telemetry/progress.jl")
include("infrastructure/persistence/light_results.jl")
include("presentation/expert_report.jl")
include("infrastructure/persistence/production_state.jl")
include("infrastructure/persistence/point_artifacts.jl")
include("infrastructure/persistence/physics_diagnostics.jl")
include("infrastructure/persistence/scientific_history.jl")
include("composition/production_solver_adapter.jl")
include("composition/production_workflow.jl")

module QCLConfiguration
using Unitful
import ..QCLDomain:
    AlgorithmOptions,
    DomainAdaptationPolicy,
    EnergyQuantity,
    LengthQuantity,
    TemperatureQuantity,
    NumericalParameters,
    PhysicalModelOptions,
    PhysicalParameters,
    ScaleSystem,
    ScatteringOptions,
    SolverOptions,
    scattering_options
import ..QCLNumerics: ProductionKernelOptions, ProductionOptions
include("application/configuration_types.jl")
export ConfigurationError,
    ConfigurationProvenance,
    AutomaticExecutionConfiguration,
    ExecutionConfiguration,
    ProgressOutputConfiguration,
    DeviceGeometryConfiguration,
    OutputConfiguration,
    ConvergenceStudyConfiguration,
    StudyMethodConfiguration,
    StudyConfiguration,
    ResolvedRunConfiguration,
    configuration_source,
    resolved_configuration_dict,
    physical_parameters,
    numerical_parameters,
    scattering_options,
    solver_options,
    production_options,
    algorithm_options
end # module QCLConfiguration
import .QCLConfiguration:
    ConfigurationError,
    ConfigurationProvenance,
    AutomaticExecutionConfiguration,
    ExecutionConfiguration,
    ProgressOutputConfiguration,
    DeviceGeometryConfiguration,
    OutputConfiguration,
    ConvergenceStudyConfiguration,
    StudyMethodConfiguration,
    StudyConfiguration,
    ResolvedRunConfiguration,
    configuration_source,
    resolved_configuration_dict,
    physical_parameters,
    numerical_parameters,
    scattering_options,
    solver_options,
    production_options,
    algorithm_options,
    _configuration_error
include("infrastructure/config/configuration.jl")
module QCLExecutionPolicy
import ..QCLDomain: AlgorithmOptions, NumericalParameters
import ..QCLNumerics:
    ProductionOptions, estimate_production_memory, with_production_options
import ..QCLConfiguration:
    AutomaticExecutionConfiguration,
    ConfigurationProvenance,
    ExecutionConfiguration,
    ResolvedRunConfiguration
include("application/resource_contract.jl")
include("application/auto_strategy.jl")
export HardwareProfile,
    ExecutionPlan,
    ExecutionEnvelope,
    execution_budget,
    default_hardware_profile,
    default_execution_envelope,
    execution_plan_candidates,
    select_execution_plan,
    resolve_execution_strategy
end # module QCLExecutionPolicy
import .QCLExecutionPolicy:
    HardwareProfile,
    ExecutionPlan,
    ExecutionEnvelope,
    execution_budget,
    default_hardware_profile,
    default_execution_envelope,
    execution_plan_candidates,
    select_execution_plan,
    resolve_execution_strategy,
    _auto_strategy_source,
    _execution_plan_provenance,
    _automatic_energy_chunk,
    _effective_memory_budget,
    _configured_production_estimate,
    _candidate_execution_plan,
    _configuration_with_execution_plan
include("infrastructure/resources/linux_resources.jl")

include("application/execution_calibration.jl")
include("infrastructure/resources/resource_reports.jl")
include("infrastructure/config/json_schema.jl")
include("infrastructure/config/configuration_contract.jl")
include("infrastructure/config/configuration_sources.jl")
include("composition/native_phase_telemetry.jl")
include("composition/configured_run.jl")
include("composition/configured_study.jl")
include("composition/application_runtime.jl")

using .QCLApplicationRuntime
import .QCLApplicationRuntime: execute_point!

include("composition/production_runtime_adapter.jl")
include("application/reporting.jl")
include("infrastructure/config/report_templates.jl")
include("presentation/configured_report.jl")
include("composition/configured_execution.jl")
include("composition/scientific_workflow.jl")
using .QCLScientificWorkflow
export ScientificPlan,
    ScientificPoint,
    ScientificExecution,
    ScientificInclusion,
    ScientificPointResult,
    ScientificPolicies,
    ScientificOutputs,
    VoltageContinuation,
    resolve_scientific_plan,
    scientific_plan_dict,
    load_scientific_plan,
    execute_scientific_plan,
    postprocess_series,
    differential_conductance,
    render_saved_snapshot,
    write_scientific_plan,
    write_scientific_result,
    is_scientific_definition,
    configured_resource_plan

export FundamentalConstants,
    Layer,
    PhysicalParameters,
    NumericalParameters,
    SolverTolerances,
    DiagnosticQualityPolicy,
    ConvergencePolicy,
    ConvergenceAssessment,
    SolverOptions,
    ScatteringOptions,
    ScaleSystem,
    ModelGrids,
    MaterialProfiles,
    BasisData,
    KernelSet,
    NEGFProblem,
    GreenState,
    SelfEnergyFamily,
    SCBAIteration,
    SCBAPhysicsWitness,
    SCBAPhysicalMarkers,
    SCBAChannelMarker,
    SCBACollisionMarker,
    SCBAPhysicsMarkerPolicy,
    SCBAResult,
    SCBAMixerState,
    OuterIteration,
    NEGFSolution,
    ConvergenceReport

export CODATA,
    reference_parameters,
    baseline_numerics,
    reference_production_numerics,
    tutorial_numerics,
    baseline_options,
    reference_production_solver_options,
    tutorial_options,
    default_scattering,
    scba_convergence_assessment,
    poisson_convergence_assessment,
    scba_diagnostic_quality_assessment,
    scba_convergence_stagnated,
    scba_accepted,
    solution_quality,
    model_capabilities,
    inner_working_policy,
    scba_approximate_acceptance,
    build_grids,
    build_profiles,
    build_bdd_hamiltonian,
    build_localized_basis,
    build_basis,
    project_hamiltonians,
    build_shift_matrix,
    apply_energy_shift,
    build_kernels,
    impurity_kernel,
    interface_roughness_kernel,
    acoustic_kernel,
    alloy_kernel,
    lo_phonon_kernel,
    direct_hilbert_transform,
    retarded_self_energy,
    retarded_green,
    keldysh_green,
    greater_green,
    spectral_function,
    number_functional,
    normalize_lesser,
    build_poisson_matrix,
    solve_periodic_poisson,
    electron_density,
    sheet_density_matrix,
    state_populations,
    effective_levels,
    embedding_self_energy,
    boundary_flux,
    energy_resolved_current,
    bond_current,
    collision_balance,
    power_balance,
    spectral_maps,
    solve_scba,
    build_problem,
    solve,
    validate,
    validate_problem,
    validate_solution,
    save_checkpoint,
    load_checkpoint,
    physical_value,
    scaled_value

export EnergyShiftPlan,
    ProductionOptions,
    ProductionMemoryEstimate,
    SolverMetric,
    SolverEvent,
    ProductionKernelOptions,
    KernelInterpolationDiagnostic,
    ProductionKernelDiagnostics,
    ProductionCache,
    ProductionSweepRecord,
    ProductionSweepResult,
    OpticalResponse,
    build_shift_plan,
    apply_energy_shift!,
    estimate_production_memory,
    build_production_cache,
    production_static_contraction,
    fft_hilbert_transform,
    retarded_self_energy_fft,
    ProductionFFTHilbertPlan,
    production_fft_hilbert_transform,
    production_fft_workspace_bytes,
    ProductionResidualWorkspace,
    production_residual_suite,
    production_selfenergy_residual,
    solve_scba_production,
    solve_production,
    load_production_restart,
    run_production_sweep,
    save_production_summary,
    retarget_problem,
    retarget_production_cache,
    bare_bubble_optical_response,
    peak_gain,
    save_optical_response,
    save_kernel_diagnostics

export AbstractProductionKernel,
    LiteralProductionKernel,
    DenseProductionKernel,
    MomentumIndependentProductionKernel,
    LowRankProductionKernel

export AlgorithmOptions,
    OptimizationDescriptor, optimization_catalog, algorithm_impact, algorithm_manifest

export ProgressMetric,
    ProgressSnapshot,
    ProgressReporter,
    latest_progress,
    compact_number,
    current_density_A_per_cm2,
    begin_progress_stage!,
    update_progress!,
    end_progress_stage!,
    save_progress_snapshot,
    save_progress_dashboard,
    MethodDescriptor,
    MethodPoint,
    MethodRun,
    MethodComparisonRow,
    ExpertComparison,
    load_method_run,
    load_method_catalog,
    compare_method_runs,
    save_expert_report,
    generate_expert_report,
    plot_method_comparison

export build_kernels_production, build_problem_production

export ConfigurationError,
    ConfigurationProvenance,
    AutomaticExecutionConfiguration,
    ExecutionConfiguration,
    ProgressOutputConfiguration,
    DeviceGeometryConfiguration,
    OutputConfiguration,
    ConvergenceStudyConfiguration,
    StudyMethodConfiguration,
    StudyConfiguration,
    ResolvedRunConfiguration,
    load_run_configuration,
    configuration_source,
    resolved_configuration_dict,
    physical_parameters,
    numerical_parameters,
    scattering_options,
    solver_options,
    production_options,
    algorithm_options

export ConfiguredProblem,
    ConfiguredRunResult,
    configuration_output_directory,
    configure_execution!,
    build_configured_problem,
    run_from_configuration

export HardwareProfile,
    ExecutionPlan,
    ExecutionCalibrationSample,
    ExecutionCalibrationReport,
    probe_hardware,
    execution_plan_candidates,
    select_execution_plan,
    calibrate_execution_plan,
    resolve_execution_strategy,
    hardware_profile_dict,
    execution_plan_dict,
    execution_calibration_dict,
    save_execution_plan,
    save_hardware_profile,
    save_execution_calibration,
    save_resource_diagnostics

export DEFAULT_CONFIGURATION_SCHEMA,
    default_configuration_schema,
    ValidatedConfigurationDocument,
    validate_configuration_schema,
    validate_configuration_source,
    load_configuration_source

export ScatteringValidationError,
    AbstractScatteringPhysicalModel,
    LOPhononModel,
    AcousticPhononModel,
    IonizedImpurityModel,
    InterfaceRoughnessModel,
    AlloyDisorderModel,
    scattering_id,
    scattering_models,
    validate_scattering_model,
    scattering_selection_evidence_class,
    AbstractScatteringKernelBackend,
    LiteralScatteringKernelBackend,
    ExactParallelScatteringKernelBackend,
    TabulatedScatteringKernelBackend,
    ScatteringNumericalPlan,
    scattering_numerical_plan,
    scattering_evidence_class,
    scattering_backend_evidence_class,
    build_scattering_kernel_set,
    ScatteringAssemblyContext,
    ScatteringAssemblyResult,
    ScatteringKernelBuild,
    validate_scattering_context,
    validate_scattering_kernel_set,
    assemble_scattering_kernels,
    build_configured_scattering_problem

export QCLApplicationRuntime,
    SweepAxis,
    AbstractSweepSpec,
    SweepLeaf,
    SweepLevel,
    NestedSweepPlan,
    SweepPoint,
    point_count,
    planned_points,
    foreach_sweep_point,
    RunIdentity,
    RunDefinition,
    derive_run_identity,
    IterationRetentionPolicy,
    DisplayDownsamplingPolicy,
    DiskBudgetModel,
    DiskEstimate,
    estimate_disk,
    AbstractRunRepository,
    FilesystemRunRepository,
    AbstractCheckpointCodec,
    YamlCheckpointCodec,
    CallbackCheckpointCodec,
    CheckpointIntegrityError,
    ArtifactIntegrityError,
    RuntimeTracer,
    AbstractPointRunner,
    FunctionPointRunner,
    PointExecutionContext,
    PointExecutionResult,
    SweepRunSummary,
    run_sweep!,
    checkpoint!,
    record_iteration!,
    verify_result_artifacts!

export QCLProductionPointRunner,
    configured_nested_sweep_plan,
    configured_nested_run_definition,
    run_configured_nested_sweep

export ProductionStudyResult,
    run_comparison_study, run_convergence_study, run_production_study

export ConfiguredExecutionResult,
    DEFAULT_MAXIMUM_SOLVER_RUNS, planned_solver_runs, execute_configured_run

export ConfiguredReportTemplate,
    ConfiguredReportArtifact,
    ConfiguredReportSection,
    ConfiguredReportContext,
    AbstractConfiguredReportRenderer,
    MarkdownConfiguredReportRenderer,
    CONFIGURED_REPORT_SECTIONS,
    configured_report_arguments,
    load_configured_report_template,
    configured_report_context,
    render_configured_report

"""
Plot the band/Hartree profile, density, and localized basis envelopes.

See [Debug and final visualization](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/13_visualization.md),
[the reference design profile](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/02_reference2019.md), and
[the localized basis](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/05_basis.md).
"""
function plot_band_profile end
"""
Plot the local spectral or occupied spectral map of a solution.

See [Green functions and density](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/07_greens.md) and
[Debug and final visualization](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/13_visualization.md).
"""
function plot_spectral_map end
"""
Plot all stored inner and outer fixed-point residual histories.

See [the inner SCBA loop](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/09_scba.md),
[the outer Poisson loop](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/10_poisson.md), and
[Verification](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/12_validation.md).
"""
function plot_convergence end
"""
Plot the energy-resolved outgoing electron-flow current.

See [Observables and balances](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/11_observables.md) and
[Debug and final visualization](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/13_visualization.md).
"""
function plot_current_spectrum end
"""
Plot `log10(cond(Dᴿ(E,k)))` to expose loss of Float64 digits.

See [the retarded Dyson equation](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/07_greens.md) and
[Debug and final visualization](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/13_visualization.md).
"""
function plot_conditioning end
"""
Plot a field-periodic analogue of QCL Fig. 3(a) from a final solution.

See [Production plotting](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md) and
[the reference design structure passport](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/02_reference2019.md).
"""
function plot_reference_figure3a end
"""
Plot current-density and derived active-region I--V sweep curves.

See [Production plotting](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md) and
[Observables and balances](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/11_observables.md).
"""
function plot_reference_iv end
"""
Plot the trusted and edge-contaminated optical-response points.

See [Optical response](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/18_optical_response.md) and
[Production plotting](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/theory/19_production.md).
"""
function plot_reference_gain end
"""
Save the optional CairoMakie figures for a completed configured study.

See [Expert comparison workflow](@ref expert-comparison-workflow).
"""
function save_production_study_plots end

export plot_band_profile,
    plot_spectral_map,
    plot_convergence,
    plot_current_spectrum,
    plot_conditioning,
    plot_reference_figure3a,
    plot_reference_iv,
    plot_reference_gain,
    save_production_study_plots

export inner_working_policy, effective_seed_parameters, solution_scientific_assessment
export AbstractCheckpointCodec,
    AbstractConfiguredReportRenderer,
    AbstractPointRunner,
    AbstractProductionKernel,
    AbstractRunRepository,
    AbstractScatteringKernelBackend,
    AbstractScatteringPhysicalModel,
    AbstractSweepSpec,
    AcousticPhononModel,
    AlgorithmOptions,
    AlloyDisorderModel,
    ArtifactIntegrityError,
    AutomaticExecutionConfiguration,
    BasisData,
    QCLApplicationRuntime,
    QCLProductionPointRunner,
    CODATA,
    CONFIGURED_REPORT_SECTIONS,
    CallbackCheckpointCodec,
    ChargeConstraintDiagnostics,
    CheckpointIntegrityError,
    ConfigurationError,
    ConfigurationProvenance,
    ConfiguredExecutionResult,
    ConfiguredProblem,
    ConfiguredReportArtifact,
    ConfiguredReportContext,
    ConfiguredReportSection,
    ConfiguredReportTemplate,
    ConfiguredRunResult,
    ConvergenceAssessment,
    ConvergencePolicy,
    ConvergenceReport,
    ConvergenceStudyConfiguration,
    DEFAULT_CONFIGURATION_SCHEMA,
    DEFAULT_MAXIMUM_SOLVER_RUNS,
    DenseProductionKernel,
    DeviceGeometryConfiguration,
    DiagnosticQualityPolicy,
    DiskBudgetModel,
    DiskEstimate,
    DisplayDownsamplingPolicy,
    DomainAdaptationPolicy,
    ElectronElectronOptions,
    EnergyShiftPlan,
    ExactParallelScatteringKernelBackend,
    ExecutionCalibrationReport,
    ExecutionCalibrationSample,
    ExecutionConfiguration,
    ExecutionPlan,
    ExpertComparison,
    FilesystemRunRepository,
    FixedPointAuditCandidate,
    FunctionPointRunner,
    FundamentalConstants,
    GreenState,
    HardwareProfile,
    InterfaceRoughnessModel,
    IonizedImpurityModel,
    IterationRetentionPolicy,
    KernelInterpolationDiagnostic,
    KernelSet,
    LOKineticState,
    LOPhononModel,
    Layer,
    LiteralProductionKernel,
    LiteralScatteringKernelBackend,
    LowRankProductionKernel,
    MarkdownConfiguredReportRenderer,
    MaterialProfiles,
    MethodComparisonRow,
    MethodDescriptor,
    MethodPoint,
    MethodRun,
    ModelGrids,
    MomentumIndependentProductionKernel,
    NEGFProblem,
    NEGFSolution,
    NestedSweepPlan,
    NumericalParameters,
    OpticalResponse,
    OptimizationDescriptor,
    OuterIteration,
    OutputConfiguration,
    PSD_METRIC_VERSION,
    PhysicalModelOptions,
    PhysicalParameters,
    PointExecutionContext,
    PointExecutionResult,
    ProductionCache,
    ProductionFFTHilbertPlan,
    ProductionKernelDiagnostics,
    ProductionKernelOptions,
    ProductionMemoryEstimate,
    ProductionOptions,
    ProductionResidualWorkspace,
    ProductionStudyResult,
    ProductionSweepRecord,
    ProductionSweepResult,
    ProgressMetric,
    ProgressOutputConfiguration,
    ProgressReporter,
    ProgressSnapshot,
    RepresentationCoverage,
    ResearchContinuationDecision,
    ResearchTrendPolicy,
    ResidualTrend,
    ResolvedRunConfiguration,
    RunDefinition,
    RunIdentity,
    RuntimeTracer,
    SCBAIteration,
    SCBAPhysicsWitness,
    SCBAPhysicalMarkers,
    SCBAChannelMarker,
    SCBACollisionMarker,
    SCBAPhysicsMarkerPolicy,
    SCBAResult,
    SCBAStopDecision,
    ScaleSystem,
    ScatteringAssemblyContext,
    ScatteringAssemblyResult,
    ScatteringKernelBuild,
    ScatteringNumericalPlan,
    ScatteringOptions,
    ScatteringValidationError,
    SelfEnergyFamily,
    SolverEvent,
    SolverMetric,
    SolverOptions,
    SolverTolerances,
    StudyConfiguration,
    StudyMethodConfiguration,
    SweepAxis,
    SweepLeaf,
    SweepLevel,
    SweepPoint,
    SweepRunSummary,
    TabulatedScatteringKernelBackend,
    ValidatedConfigurationDocument,
    YamlCheckpointCodec,
    acoustic_kernel,
    algorithm_impact,
    algorithm_manifest,
    algorithm_options,
    alloy_kernel,
    apply_energy_shift,
    apply_energy_shift!,
    assemble_scattering_kernels,
    bare_bubble_optical_response,
    baseline_numerics,
    baseline_options,
    begin_progress_stage!,
    bond_current,
    reference_parameters,
    reference_production_numerics,
    reference_production_solver_options,
    boundary_flux,
    build_basis,
    build_bdd_hamiltonian,
    build_configured_problem,
    build_configured_scattering_problem,
    build_grids,
    build_kernels,
    build_kernels_production,
    build_localized_basis,
    build_poisson_matrix,
    build_problem,
    build_problem_production,
    build_production_cache,
    build_profiles,
    build_scattering_kernel_set,
    build_shift_matrix,
    build_shift_plan,
    calibrate_execution_plan,
    certify_solution,
    charge_constraint_diagnostics,
    checkpoint!,
    collision_balance,
    compact_number,
    compare_method_runs,
    configuration_output_directory,
    configuration_source,
    configure_execution!,
    configured_nested_run_definition,
    configured_nested_sweep_plan,
    configured_report_arguments,
    configured_report_context,
    configured_resource_plan,
    current_density_A_per_cm2,
    default_configuration_schema,
    default_scattering,
    derive_run_identity,
    direct_hilbert_transform,
    effective_levels,
    electron_density,
    embedding_self_energy,
    end_progress_stage!,
    energy_resolved_current,
    estimate_disk,
    estimate_production_memory,
    execute_configured_run,
    execution_calibration_dict,
    execution_plan_candidates,
    execution_plan_dict,
    expand_energy_window,
    fft_hilbert_transform,
    foreach_sweep_point,
    fresh_fixed_point_metrics,
    generate_expert_report,
    greater_green,
    hardware_profile_dict,
    impurity_kernel,
    interface_roughness_kernel,
    keldysh_green,
    latest_progress,
    lo_kinetic_state,
    lo_phonon_kernel,
    load_checkpoint,
    load_configuration_source,
    load_configured_report_template,
    load_method_catalog,
    load_method_run,
    load_production_restart,
    load_run_configuration,
    lorentzian_window_weight,
    measured_representation_coverage,
    model_capabilities,
    normalize_lesser,
    number_functional,
    numerical_parameters,
    optimization_catalog,
    peak_gain,
    physical_model_identity,
    physical_parameters,
    physical_value,
    planned_points,
    planned_solver_runs,
    plot_band_profile,
    plot_reference_figure3a,
    plot_reference_gain,
    plot_reference_iv,
    plot_conditioning,
    plot_convergence,
    plot_current_spectrum,
    plot_method_comparison,
    plot_spectral_map,
    point_count,
    poisson_convergence_assessment,
    power_balance,
    probe_hardware,
    production_fft_hilbert_transform,
    production_fft_workspace_bytes,
    production_options,
    production_residual_suite,
    production_selfenergy_residual,
    production_static_contraction,
    project_hamiltonians,
    psd_error_budget,
    record_iteration!,
    render_configured_report,
    representation_coverage,
    research_continuation_decision,
    residual_trend,
    resolve_execution_strategy,
    resolve_physical_models,
    resolved_configuration_dict,
    retarded_green,
    retarded_self_energy,
    retarded_self_energy_fft,
    retarget_problem,
    retarget_production_cache,
    run_comparison_study,
    run_configured_nested_sweep,
    run_convergence_study,
    run_from_configuration,
    run_production_study,
    run_production_sweep,
    run_sweep!,
    save_checkpoint,
    save_execution_calibration,
    save_execution_plan,
    save_expert_report,
    save_hardware_profile,
    save_kernel_diagnostics,
    save_optical_response,
    save_production_study_plots,
    save_production_summary,
    save_progress_dashboard,
    save_progress_snapshot,
    save_resource_diagnostics,
    scaled_value,
    scattering_backend_evidence_class,
    scattering_evidence_class,
    scattering_id,
    scattering_models,
    scattering_numerical_plan,
    scattering_options,
    scattering_selection_evidence_class,
    scba_accepted,
    scba_approximate_acceptance,
    scba_convergence_assessment,
    scba_convergence_stagnated,
    scba_diagnostic_quality_assessment,
    scba_iteration_decision,
    select_execution_plan,
    sheet_density_matrix,
    solution_quality,
    solve,
    solve_adaptive_production,
    solve_periodic_poisson,
    solve_production,
    solve_scba,
    solve_scba_production,
    solver_options,
    spatial_energy_density,
    spectral_function,
    spectral_maps,
    state_populations,
    transverse_kinetic_energy,
    tutorial_numerics,
    tutorial_options,
    update_progress!,
    validate,
    validate_configuration_schema,
    validate_configuration_source,
    validate_problem,
    validate_scattering_context,
    validate_scattering_kernel_set,
    validate_scattering_model,
    validate_solution,
    verify_result_artifacts!


function __init__()
    # Keep the exported String binding compatible without freezing a builder path
    # into package images. Loaders resolve their default via the runtime accessor.
    global DEFAULT_CONFIGURATION_SCHEMA = default_configuration_schema()
end

include("composition/scratch_execution.jl")
include("cli.jl")
export execute_scientific_plan_staged, stage_result_tree, main
end # module QCLNEGFRunner
