module Suite_T038
include("../support/common.jl")
using HDF5
include("../support/configured_study.jl")

@testset "Explicit repeats retain physical state and separate timing statistics" begin
    # Legacy summary selects the first actual record. Spread/status disagreement
    # remains in a separate table and never constructs a median physical state.
    BN = QCLNEGFRunner
    function record(;
        current,
        wall,
        metric,
        status = :converged,
        converged = true,
        quality = :strictly_converged,
        checkpoint = "state.h5",
    )
        return ProductionSweepRecord(
            200.0,
            0.056,
            1.891e6,
            current,
            converged,
            status,
            quality,
            4,
            12,
            1024,
            wall,
            Dict{Symbol,Float64}(:current_continuity => metric, :gain_peak_per_cm => NaN),
            checkpoint,
        )
    end
    first_sweep = ProductionSweepResult(
        [record(current = 10.0, wall = 3.0, metric = 0.2)],
        "first.csv",
    )
    second_sweep = ProductionSweepResult(
        [record(current = 12.0, wall = 1.0, metric = 0.4)],
        "second.csv",
    )

    mktempdir() do temporary
        aggregate = BN._aggregate_sweep_repetitions(
            [first_sweep, second_sweep],
            joinpath(temporary, "aggregate"),
        )
        @test isfile(aggregate.summary_path)
        @test length(aggregate.records) == 1
        combined = only(aggregate.records)
        @test combined.current_A_per_m2 == 10.0
        @test combined.wall_seconds == 2.0
        @test combined.scba_quality == :strictly_converged
        @test combined.metrics[:current_continuity] ≈ 0.2
        @test isnan(combined.metrics[:gain_peak_per_cm])
        aggregation_path = joinpath(temporary, "aggregate", "repetition_aggregation.csv")
        @test isfile(aggregation_path)
        @test occursin("value_classification", first(readlines(aggregation_path)))
        loaded = load_method_run(
            MethodDescriptor(
                id = :aggregate,
                label = "aggregate",
                structure_id = "reference design",
                physics_signature = "full",
                modifies_physics = false,
                algorithm_family = :exact_optimized,
            ),
            aggregate.summary_path,
        )
        @test only(loaded.points).current_A_per_m2 == 10.0
        @test only(loaded.points).scba_quality == :strictly_converged
        @test only(loaded.points).metrics[:current_continuity] ≈ 0.2

        mismatched_status = ProductionSweepResult(
            [
                record(
                    current = 12.0,
                    wall = 1.0,
                    metric = 0.4,
                    status = :max_iterations,
                    converged = false,
                    quality = :unresolved,
                ),
            ],
            "bad.csv",
        )
        disagreement = BN._aggregate_sweep_repetitions(
            [first_sweep, mismatched_status],
            joinpath(temporary, "bad"),
        )
        disagreed_record = only(disagreement.records)
        @test disagreed_record.converged
        @test disagreed_record.status == :converged
        @test disagreed_record.scba_quality == :strictly_converged
        @test disagreed_record.checkpoint == "state.h5"
        disagreement_csv =
            read(joinpath(temporary, "bad", "repetition_aggregation.csv"), String)
        @test occursin("converged;max_iterations", disagreement_csv)
        @test occursin("strictly_converged;unresolved", disagreement_csv)

        finite = ProductionSweepResult(
            [
                record(
                    current = 12.0,
                    wall = 1.0,
                    metric = 0.4,
                    status = :max_iterations,
                    converged = false,
                    quality = :unresolved,
                ),
            ],
            "finite.csv",
        )
        nonfinite = ProductionSweepResult(
            [
                record(
                    current = NaN,
                    wall = NaN,
                    metric = NaN,
                    status = :max_iterations,
                    converged = false,
                    quality = :unresolved,
                ),
            ],
            "nonfinite.csv",
        )
        mixed = BN._aggregate_sweep_repetitions(
            [finite, nonfinite],
            joinpath(temporary, "mixed"),
        )
        @test only(mixed.records).status == :max_iterations
        @test only(mixed.records).current_A_per_m2 == 12.0
        @test occursin(
            "mixed_finite_nonfinite",
            read(joinpath(temporary, "mixed", "repetition_aggregation.csv"), String),
        )
        @test_throws ArgumentError BN._aggregate_sweep_repetitions(
            ProductionSweepResult[],
            joinpath(temporary, "empty"),
        )

        rows = NamedTuple[(
            axis = :energy_nodes,
            nodes = 41,
            reference_nodes = 49,
            temperature_K = 200.0,
            voltage_per_period_V = 0.056,
            metric = :current_A_per_m2,
            reference_value = 10.0,
            candidate_value = 9.5,
            absolute_error = 0.5,
            relative_error = 0.05,
            reference_status = :converged,
            candidate_status = :max_iterations,
            reference_scba_quality = :strictly_converged,
            candidate_scba_quality = :approximate_fixed_point,
            pair_converged = false,
        )]
        csv, markdown =
            BN._write_convergence_report(joinpath(temporary, "convergence"), rows)
        @test isfile(csv)
        @test isfile(markdown)
        @test occursin("absolute_error", first(readlines(csv)))
        @test occursin("energy_nodes", read(markdown, String))
        @test occursin("0.05", read(csv, String))
        @test occursin("strictly_converged/approximate_fixed_point", read(markdown, String))
    end
end

end # independent suite
