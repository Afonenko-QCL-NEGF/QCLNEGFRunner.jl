module Suite_T034
include("../support/common.jl")
include("../support/configured_report_templates.jl")

@testset "Method-validation template wraps existing expert evidence" begin
    mktempdir() do directory
        configuration = load_run_configuration(
            joinpath(TEST_ROOT, "fixtures", "configurations", "studies-smoke.yaml"),
        )
        report_directory = joinpath(directory, "expert_report")
        mkpath(report_directory)
        artifacts = Dict(
            "expert_report.md" => "# Existing detailed report\n",
            "method_comparison.csv" => "method_id,error\n",
            "method_points.csv" => "method_id,converged\nexact,true\n",
            "convergence_report.md" => "# Existing convergence report\n",
            "convergence.csv" => "axis,pair_converged\nenergy_nodes,false\n",
            "method_catalog.csv" => "method_id,label\n",
        )
        for (name, contents) in artifacts
            write(joinpath(report_directory, name), contents)
        end
        result = ProductionStudyResult(
            configuration,
            joinpath(report_directory, "method_catalog.csv"),
            (
                markdown = joinpath(report_directory, "expert_report.md"),
                comparison_csv = joinpath(report_directory, "method_comparison.csv"),
                points_csv = joinpath(report_directory, "method_points.csv"),
            ),
            joinpath(report_directory, "convergence.csv"),
            joinpath(report_directory, "convergence_report.md"),
            directory,
        )
        template = load_configured_report_template(
            joinpath(
                TEST_ROOT,
                "fixtures",
                "presentation",
                "report",
                "method_validation.yaml",
            ),
        )
        report = render_configured_report(template, result)
        @test report == joinpath(report_directory, "method_validation.md")
        text = read(report, String)
        @test occursin("[Expert method report](expert_report.md)", text)
        @test occursin("[Convergence report](convergence_report.md)", text)
        @test occursin("[Pointwise method comparison](method_comparison.csv)", text)
        @test occursin("workflow\\_completed\\_with\\_warnings", text)
        @test !occursin("workflow\\_completed\\_all\\_points\\_converged", text)
        @test occursin("- Converged convergence pairs: `0`", text)
        @test occursin("incomplete convergence pairs: 1 of 1", text)
        @test occursin("does not re-implement numerical analysis", text)

        # Inner approximate SCBA plus an unresolved outer point remains an
        # incomplete method point, not successful overall approximate acceptance.
        write(
            result.method_report.points_csv,
            "method_id,converged,status,scba_quality\nexact,false,max_scba,approximate_fixed_point\n",
        )
        incomplete_text = read(render_configured_report(template, result), String)
        @test occursin("workflow\\_completed\\_with\\_incomplete\\_points", incomplete_text)
        @test occursin("- Approximate method points: `0`", incomplete_text)
        @test occursin("Incomplete method points: 1 of 1", incomplete_text)
    end
end

end # independent suite
