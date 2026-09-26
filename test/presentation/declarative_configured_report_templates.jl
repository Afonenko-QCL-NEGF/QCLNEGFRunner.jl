module Suite_T032
include("../support/common.jl")
include("../support/configured_report_templates.jl")

@testset "Declarative configured report templates" begin
    BN = QCLNEGFRunner
    root = normpath(joinpath(TEST_ROOT, ".."))
    standard_path =
        joinpath(root, "test", "fixtures", "presentation", "report", "standard.yaml")
    validation_path = joinpath(
        root,
        "test",
        "fixtures",
        "presentation",
        "report",
        "method_validation.yaml",
    )
    standard = load_configured_report_template(standard_path)
    validation = load_configured_report_template(validation_path)

    # The report YAML is the sole source of ordering and output names.
    @test standard.id == "standard"
    @test standard.sections == [
        :configuration,
        :provenance,
        :convergence,
        :current_density,
        :hartree_potential,
        :wavefunctions,
        :performance,
    ]
    @test standard.output == "report.md"
    @test occursin(r"^[0-9a-f]{64}$", standard.source_sha256)
    @test validation.output == "method_validation.md"
    @test :physical_equivalence in validation.sections

    parsed = configured_report_arguments([
        "config/base",
        "experiment.yaml",
        "--report-template",
        standard_path,
    ])
    @test parsed.configuration_sources == ["config/base", "experiment.yaml"]
    @test parsed.report_template == standard_path
    @test configured_report_arguments(["config/base"]).report_template === nothing
    @test_throws ArgumentError configured_report_arguments(String[])
    @test_throws ArgumentError configured_report_arguments([
        "--report-template",
        standard_path,
    ])
    @test_throws ArgumentError configured_report_arguments([
        "config/base",
        "--report-template",
        standard_path,
        "late.yaml",
    ])

    mktempdir() do output
        expected = [
            "Resolved configuration" => "resolved_configuration.yaml",
            "Algorithm manifest" => "algorithm_manifest.yaml",
            "Optimization catalog" => "optimization_catalog.yaml",
            "Configuration provenance" => "configuration_provenance.yaml",
            "Execution plan" => "execution_plan.yaml",
            "Output policy" => "output_policy.yaml",
        ]
        for (_, filename) in expected
            write(joinpath(output, filename), "fixture: true\n")
        end
        artifacts = BN._configured_run_provenance_artifacts(output)
        @test [artifact.label for artifact in artifacts] == first.(expected)
        @test basename.([artifact.path for artifact in artifacts]) == last.(expected)
        @test all(artifact -> artifact.media_type == "application/yaml", artifacts)
    end

    mktempdir() do directory
        function invalid_template(name, contents)
            path = joinpath(directory, name)
            write(path, contents)
            return path
        end
        @test_throws ConfigurationError load_configured_report_template(
            invalid_template(
                "unknown.yaml",
                """
id: invalid
label: Invalid
sections: [not_a_section]
image_policy: links
output: report.md
""",
            ),
        )
        @test_throws ConfigurationError load_configured_report_template(
            invalid_template(
                "duplicate.yaml",
                """
id: invalid
label: Invalid
sections: [configuration, configuration]
image_policy: links
output: report.md
""",
            ),
        )
        @test_throws ConfigurationError load_configured_report_template(
            invalid_template(
                "duplicate-key.yaml",
                """
id: first
id: second
label: Invalid
sections: [configuration]
image_policy: links
output: report.md
""",
            ),
        )
        @test_throws ConfigurationError load_configured_report_template(
            invalid_template(
                "escape.yaml",
                """
id: invalid
label: Invalid
sections: [configuration]
image_policy: links
output: ../report.md
""",
            ),
        )
        @test_throws ConfigurationError load_configured_report_template(
            invalid_template(
                "nonportable.yaml",
                """
id: invalid
label: Invalid
sections: [configuration]
image_policy: links
output: C:report.md
""",
            ),
        )
    end
end

end # independent suite
