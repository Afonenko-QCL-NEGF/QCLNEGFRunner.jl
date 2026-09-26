module Suite_T044
include("../support/common.jl")

@testset "Stored-method expert comparison" begin
    BN = QCLNEGFRunner
    @test BN._human_identifier("short") == "short"
    long_identifier = repeat("abcdef", 20)
    abbreviated_identifier = BN._human_identifier(long_identifier)
    @test length(abbreviated_identifier) == 37
    @test startswith(abbreviated_identifier, first(long_identifier, 24))
    @test endswith(abbreviated_identifier, last(long_identifier, 12))
    fixture = joinpath(TEST_ROOT, "fixtures", "expert_report")
    catalog = joinpath(fixture, "method_catalog.csv")
    runs = BN.load_method_catalog(catalog)

    @test length(runs) == 3
    @test getfield.(getfield.(runs, :descriptor), :id) == [:direct, :threaded, :local_sigma]
    @test length(runs[1].points) == 2
    @test runs[1].points[1].memory_kind == :estimated
    @test runs[2].points[1].memory_kind == :measured
    @test runs[1].points[1].scba_quality == :strictly_converged
    @test runs[3].points[2].scba_quality == :approximate_fixed_point
    @test runs[3].points[2].status == :max_scba
    @test !runs[3].points[2].converged
    @test runs[1].points[1].metrics[:current_continuity] == 2e-8

    mktempdir() do directory
        missing_quality = joinpath(directory, "missing-quality.csv")
        lines = readlines(runs[1].summary_path)
        rows_without_quality = String[]
        for line in lines
            fields = split(line, ',')
            deleteat!(fields, 7)
            push!(rows_without_quality, join(fields, ','))
        end
        write(missing_quality, join(rows_without_quality, '\n') * "\n")
        @test_throws ArgumentError BN.load_method_run(runs[1].descriptor, missing_quality)

        contradictory = joinpath(directory, "contradictory-quality.csv")
        contradictory_lines = copy(lines)
        fields = String.(split(contradictory_lines[2], ','))
        fields[7] = "approximate_fixed_point"
        contradictory_lines[2] = join(fields, ',')
        write(contradictory, join(contradictory_lines, '\n') * "\n")
        @test_throws ArgumentError BN.load_method_run(runs[1].descriptor, contradictory)
    end

    comparison = BN.compare_method_runs(runs; reference_id = :direct)
    @test comparison.structure_id == "reference2019-2019"
    @test comparison.reference_id == :direct
    @test length(comparison.rows) == 12 # 2 methods × 2 points × 3 metrics
    current_rows = filter(row -> row.metric === :current_A_per_m2, comparison.rows)
    @test length(current_rows) == 4
    threaded = filter(row -> row.candidate_id === :threaded, current_rows)
    @test all(row -> !row.modifies_physics, threaded)
    @test maximum(row -> something(row.relative_error, Inf), threaded) < 2e-15
    @test threaded[1].speedup ≈ 120 / 42
    @test threaded[1].memory_ratio == 3_600_000_000 / 4_800_000_000
    local_rows = filter(row -> row.candidate_id === :local_sigma, current_rows)
    @test all(row -> row.modifies_physics, local_rows)
    @test local_rows[1].relative_error ≈ 0.025
    @test !local_rows[2].candidate_converged
    @test local_rows[2].candidate_scba_quality == :approximate_fixed_point

    bad_descriptor = BN.MethodDescriptor(
        id = :mislabelled,
        label = "bad exact claim",
        structure_id = "reference2019-2019",
        physics_signature = "different-physics",
        modifies_physics = false,
        algorithm_family = :exact_optimized,
    )
    bad_run = BN.MethodRun(bad_descriptor, runs[2].points, "bad.csv")
    @test_throws ArgumentError BN.compare_method_runs(
        [runs[1], bad_run];
        reference_id = :direct,
    )

    wrong_structure_descriptor = BN.MethodDescriptor(
        id = :other,
        label = "other structure",
        structure_id = "not-reference2019",
        physics_signature = "reference2019-grid-a-full-kernels",
        modifies_physics = false,
        algorithm_family = :exact_optimized,
    )
    wrong_structure = BN.MethodRun(wrong_structure_descriptor, runs[2].points, "other.csv")
    @test_throws ArgumentError BN.compare_method_runs(
        [runs[1], wrong_structure];
        reference_id = :direct,
    )

    mktempdir() do directory
        generated = BN.generate_expert_report(
            catalog,
            directory;
            reference_id = :direct,
            title = "Fixture reference design comparison",
        )
        @test generated.comparison.reference_id == :direct
        @test all(isfile, values(generated.paths))
        markdown = read(generated.paths.markdown, String)
        @test occursin("Fixture reference design comparison", markdown)
        @test occursin("computational only", markdown)
        @test occursin("**physics changed**", markdown)
        @test occursin("physics-first test suite", markdown)
        @test occursin("current continuity", markdown)
        @test occursin("Approximate overall", markdown)
        # An approximately settled inner SCBA does not certify the outer point.
        @test occursin("| `local_sigma` | 2 | 1 | 0 | 1 | 0 |", markdown)
        @test occursin("`approximate_fixed_point`", markdown)
        @test occursin("Reference J (A/cm²)", markdown)
        @test occursin("| 1200.0 |", markdown)
        @test !occursin("Reference J (A/m²)", markdown)
        comparison_lines = readlines(generated.paths.comparison_csv)
        @test length(comparison_lines) == 13
        @test occursin("reference_scba_quality", first(comparison_lines))
        @test occursin("candidate_scba_quality", first(comparison_lines))
        @test occursin("1.862645149230957e-9", join(comparison_lines, '\n'))
        point_header = first(readlines(generated.paths.points_csv))
        @test occursin("scba_quality", point_header)
        @test occursin("metric_charge_neutrality", point_header)
        @test occursin("metric_current_continuity", point_header)

        controlled_descriptor = BN.MethodDescriptor(
            id = :controlled,
            label = "controlled numerical",
            structure_id = "reference2019-2019",
            physics_signature = "reference2019-grid-a-full-kernels",
            modifies_physics = false,
            algorithm_family = :controlled_approximation,
        )
        controlled_run =
            BN.MethodRun(controlled_descriptor, runs[2].points, "controlled.csv")
        controlled_comparison =
            BN.compare_method_runs([runs[1], controlled_run]; reference_id = :direct)
        controlled_paths =
            BN.save_expert_report(joinpath(directory, "controlled"), controlled_comparison)
        @test occursin("controlled numerical", read(controlled_paths.markdown, String))

        # Explicit overall approximate acceptance has its own coverage count,
        # but remains excluded from strictly converged accuracy comparisons.
        approximate_summary = joinpath(directory, "overall-approximate.csv")
        approximate_lines = readlines(runs[3].summary_path)
        fields = String.(split(approximate_lines[3], ','))
        status_column = findfirst(==("status"), split(first(approximate_lines), ','))
        fields[status_column] = "approximate"
        approximate_lines[3] = join(fields, ',')
        write(approximate_summary, join(approximate_lines, '\n') * "\n")
        approximate_run = BN.load_method_run(runs[3].descriptor, approximate_summary)
        approximate_comparison =
            BN.compare_method_runs([runs[1], approximate_run]; reference_id = :direct)
        approximate_paths = BN.save_expert_report(
            joinpath(directory, "approximate"),
            approximate_comparison,
        )
        approximate_markdown = read(approximate_paths.markdown, String)
        @test occursin("| `local_sigma` | 2 | 1 | 1 | 0 | 0 |", approximate_markdown)
        @test !approximate_run.points[2].converged
        @test all(
            row -> !row.candidate_converged,
            filter(
                row ->
                    row.voltage_per_period_V ==
                    approximate_run.points[2].voltage_per_period_V,
                approximate_comparison.rows,
            ),
        )
    end

    @test_throws ArgumentError BN.MethodDescriptor(
        id = :bad,
        label = "bad",
        structure_id = "reference2019",
        physics_signature = "x",
        modifies_physics = false,
        algorithm_family = :unknown,
    )
end

end # independent suite
