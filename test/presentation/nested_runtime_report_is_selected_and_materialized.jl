module Suite_T033
include("../support/common.jl")
include("../support/configured_report_templates.jl")

@testset "Nested runtime report is selected and materialized" begin
    # A fake completed coordinator summary is enough: the renderer must reuse
    # its hierarchical YAML artifacts and must not invoke physics or numerics.
    mktempdir() do directory
        result_path = joinpath(directory, "result.yaml")
        YAML.write_file(
            result_path,
            Dict("status" => "incomplete", "counts" => Dict("completed" => 1)),
        )
        for (name, value) in (
            "run.yaml" => Dict("run_id" => "run-" * repeat("a", 64)),
            "provenance.yaml" => Dict("source" => "fixture"),
            "core_timing.yaml" => Dict("cores" => Dict()),
            "disk_estimate.yaml" => Dict("estimated_bytes" => 1000),
        )
            YAML.write_file(joinpath(directory, name), value)
        end
        summary = SweepRunSummary(
            "run-" * repeat("a", 64),
            :incomplete,
            2,
            1,
            1,
            0,
            0,
            0,
            result_path,
        )
        template = load_configured_report_template(
            joinpath(
                TEST_ROOT,
                "..",
                "test",
                "fixtures",
                "presentation",
                "report",
                "standard.yaml",
            ),
        )
        report = render_configured_report(template, summary)
        @test report == joinpath(directory, "report.md")
        text = read(report, String)
        @test occursin("Template: `standard`", text)
        @test occursin("Template SHA-256: `$(template.source_sha256)`", text)
        @test occursin("Status: `incomplete`", text)
        @test occursin("[Hierarchical run result](result.yaml)", text)
        @test occursin("[Core timing](core_timing.yaml)", text)
        positions = map(
            section -> findfirst("## $section", text),
            [
                "Configuration",
                "Provenance",
                "Convergence",
                "Current density",
                "Hartree potential",
                "Wavefunctions and localized states",
                "Performance",
            ],
        )
        @test all(position -> position !== nothing, positions)
        @test issorted(first.(positions))
        @test !occursin("## Physical equivalence", text)
        unsupported = ConfiguredReportTemplate(
            "manual",
            "Manual",
            [:configuration],
            :inline,
            "manual.md",
            template.source,
            template.source_sha256,
        )
        @test_throws ArgumentError render_configured_report(unsupported, summary)
    end
end

end # independent suite
