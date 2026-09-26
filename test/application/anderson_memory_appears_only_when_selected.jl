module Suite_T006
include("../support/common.jl")
include("../support/algorithm_modes.jl")

@testset "Anderson memory appears only when selected" begin
    numerical = tutorial_numerics()
    linear = ProductionOptions(algorithms = AlgorithmOptions(mixing = :linear))
    anderson = ProductionOptions(
        algorithms = AlgorithmOptions(mixing = :anderson, anderson_history_depth = 2),
    )
    linear_estimate = estimate_production_memory(
        numerical,
        4;
        dense_mechanism_count = 3,
        options = linear,
    )
    anderson_estimate = estimate_production_memory(
        numerical,
        4;
        dense_mechanism_count = 3,
        options = anderson,
    )
    @test linear_estimate.breakdown[:anderson_history] == 0
    @test anderson_estimate.breakdown[:anderson_history] > 0
    @test anderson_estimate.peak_bytes > linear_estimate.peak_bytes
end

end # independent suite
