module Suite_T035
include("../support/common.jl")
include("../support/configured_report_templates.jl")

@testset "Method-validation report survives isolated phase failures" begin
    mktempdir() do directory
        configuration = load_run_configuration(
            joinpath(TEST_ROOT, "fixtures", "configurations", "studies-smoke.yaml"),
        )
        result = ProductionStudyResult(
            configuration,
            "",
            (markdown = "", comparison_csv = "", points_csv = ""),
            "",
            "",
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
        @test report == joinpath(
            directory,
            configuration.output.report_directory,
            "method_validation.md",
        )
        text = read(report, String)
        @test occursin("workflow\\_incomplete\\_failed\\_phases", text)
        @test occursin(
            "Unavailable diagnostic phases: method comparison, grid convergence",
            text,
        )
        @test occursin("Method points: `0`", text)
        @test occursin("Convergence pairs: `0`", text)
    end
end

end # independent suite
