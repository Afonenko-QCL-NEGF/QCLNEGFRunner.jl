module Suite_T046
include("../support/common.jl")
using HDF5

@testset "Failed methods remain visible beside completed methods" begin
    BN = QCLNEGFRunner
    fixture = joinpath(TEST_ROOT, "fixtures", "expert_report")
    reference, completed, _ =
        BN.load_method_catalog(joinpath(fixture, "method_catalog.csv"))
    mktempdir() do directory
        summary = joinpath(directory, "failed.csv")
        record = BN.ProductionSweepRecord(
            200.0,
            0.05,
            NaN,
            NaN,
            false,
            :execution_failed,
            :invalid,
            0,
            0,
            0,
            0.01,
            Dict{Symbol,Float64}(),
            "",
        )
        BN.save_production_summary(summary, BN.ProductionSweepResult([record], summary))
        descriptor = BN.MethodDescriptor(
            id = :failed,
            label = "Failed calculation",
            structure_id = reference.descriptor.structure_id,
            physics_signature = reference.descriptor.physics_signature,
            modifies_physics = false,
            algorithm_family = :exact_optimized,
            description = "Failure before SCBA\nretained for diagnostic coverage.",
        )
        failed = BN.load_method_run(descriptor, summary)
        comparison =
            BN.compare_method_runs([reference, failed, completed]; reference_id = :direct)
        paths = BN.save_expert_report(directory, comparison)
        _, points = BN._read_report_csv(paths.points_csv)
        failed_points = filter(row -> row["method_id"] == "failed", points)
        @test length(points) == 5
        @test length(failed_points) == 1
        @test only(failed_points)["status"] == "execution_failed"
        @test only(failed_points)["scba_quality"] == "invalid"
        @test only(failed_points)["quality"] == "invalid"
        @test length(filter(row -> row.candidate_id === :threaded, comparison.rows)) == 6
        @test all(
            row -> !row.candidate_converged,
            filter(row -> row.candidate_id === :failed, comparison.rows),
        )
        markdown = read(paths.markdown, String)
        @test occursin("| `failed` | 1 | 0 | 0 | 0 | 1 |", markdown)
        @test occursin("| `failed` | exact computational | 0 |", markdown)
        @test occursin("| `threaded` | exact computational | 2 |", markdown)
    end
end

end # independent suite
