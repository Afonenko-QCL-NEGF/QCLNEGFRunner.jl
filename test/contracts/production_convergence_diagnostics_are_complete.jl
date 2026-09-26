module Suite_T061
include("../support/common.jl")
using HDF5
include("../support/numerical_convergence.jl")

@testset "Production convergence diagnostics are complete" begin
    events = SolverEvent[]
    production = ProductionOptions(event_sink = event -> begin
        push!(events, event)
        true
    end)
    assessment = ConvergenceAssessment(true, false, :r_Σ, 9.5e4, [:r_K, :r_Σ, :r_λ])
    diagnostic = ConvergenceAssessment(true, true, :r_Σ, 0.96, Symbol[])
    QCLNEGFRunner._emit_scba_progress(
        production,
        1600,
        1600;
        rD = 2e-16,
        rA = 3e-15,
        rK = 8.9e-4,
        rΣ = 9.6e-4,
        rλ = 3.3e-5,
        rPSD = 0.0,
        rcaus = 0.0,
        rround = 2e-16,
        rJchange = 2e-6,
        rpopulation = 3e-6,
        current = 1.42e7,
        fixed_point = assessment,
        positivity_witness = QCLNEGFRunner._PositivityWitness(
            :spectral,
            2,
            3,
            0.0,
            1.0,
            1e-14,
            0.0,
        ),
        assessment,
        convergence_streak = 0,
        diagnostic,
        diagnostic_quality_streak = 3,
        quality = :approximate_fixed_point,
        dyson_seconds = 1.0,
        candidate_seconds = 7.0,
        residual_seconds = 8.0,
        observables_seconds = 1.0,
        mixing_seconds = 0.0,
        total_seconds = 18.0,
    )
    event = only(events)
    metrics = Dict(metric.name => metric.value for metric in event.metrics)
    @test metrics[:fixed_point_limiting_gate] == "r_Σ"
    @test metrics[:psd_matrix_kind] == "spectral"
    @test metrics[:psd_energy_index] == 2
    @test metrics[:psd_momentum_index] == 3
    @test metrics[:psd_block_norm_scaled] == 1.0
    @test metrics[:limiting_gate] == "r_Σ"
    @test metrics[:limiting_ratio] == 9.5e4
    @test metrics[:failed_gate_count] == 3
    @test metrics[:convergence_streak] == 0
    @test metrics[:diagnostic_quality] == "approximate_fixed_point"
    @test metrics[:diagnostic_quality_enabled]
    @test metrics[:diagnostic_quality_streak] == 3
    for name in (
        :r_D,
        :r_A,
        :r_K,
        :r_Σ,
        :r_λ,
        :r_PSD,
        :r_caus,
        :r_roundoff,
        :r_Jchange,
        :r_population,
    )
        @test haskey(metrics, name)
    end
end

end # independent suite
