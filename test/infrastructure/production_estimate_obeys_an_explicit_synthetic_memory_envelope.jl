module Suite_T079
include("../support/common.jl")
using HDF5
include("../support/production_backend.jl")

@testset "Production estimate obeys an explicit synthetic memory envelope" begin
    synthetic_capacity_bytes = 24 * 1024^3
    synthetic_budget_bytes = synthetic_capacity_bytes * 7 ÷ 8
    production = ProductionOptions(
        memory_budget_bytes = synthetic_budget_bytes,
        energy_chunk = 128,
        hilbert_columns = 32,
    )
    estimate = estimate_production_memory(
        baseline_numerics(),
        4;
        dense_mechanism_count = 3,
        options = production,
    )
    @test estimate.resident_bytes > 0
    @test estimate.peak_bytes ≥ estimate.resident_bytes
    @test estimate.peak_bytes < synthetic_capacity_bytes
    @test estimate.memory_budget_bytes == synthetic_budget_bytes
    @test estimate.kernel_flops_per_candidate > 1e9
    @test haskey(estimate.breakdown, :fft_workspace)
    @test estimate.breakdown[:dense_shift_matrices_in_problem] == 0
    @test estimate.breakdown[:compact_shift_operators_in_problem] ==
          4 * baseline_numerics().N_E * (2sizeof(Int) + 2sizeof(Float64))
    @test estimate.breakdown[:energy_shift_plans] ==
          4 * baseline_numerics().N_E * (2sizeof(Int) + 2sizeof(Float64))

    strict = ProductionOptions(memory_budget_bytes = 1)
    @test_throws ArgumentError QCLNEGFRunner._preflight_production_memory(
        tutorial_numerics(),
        default_scattering(),
        strict,
    )

    small = tutorial_numerics()
    overflowing = NumericalParameters(
        N_z = small.N_z,
        N_b = small.N_b,
        P_basis = small.P_basis,
        E_min = small.E_min,
        E_max = small.E_max,
        N_E = typemax(Int),
        M_E = small.M_E,
        k_max = small.k_max,
        N_k = small.N_k,
        N_φ = small.N_φ,
        qz_max = small.qz_max,
        N_qz = small.N_qz,
        η_seed = small.η_seed,
    )
    @test_throws OverflowError estimate_production_memory(
        overflowing,
        1;
        dense_mechanism_count = 1,
        lo_kernel = :dense,
        options = ProductionOptions(),
    )
end

end # independent suite
