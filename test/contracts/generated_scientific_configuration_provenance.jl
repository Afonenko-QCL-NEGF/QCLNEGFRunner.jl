module GeneratedScientificConfigurationProvenance
using Test
using YAML
using QCLNEGFRunner
const Workflow = QCLNEGFRunner.QCLScientificWorkflow

# Missing generated merge, merging the copied study, or dropping history must fail.
@testset "Generated configuration keeps truthful leaf origins without changing inputs" begin
    base_path = normpath(joinpath(@__DIR__, "..", "fixtures", "research-inputs", "model", "reference-2019-70k.yaml"))
    base = load_run_configuration(base_path)
    original_raw = deepcopy(base.raw)
    original_sources = deepcopy(base.provenance.sources)
    mktempdir() do directory
        definition_path = joinpath(directory, "generated.yaml")
        recipe = Dict{String,Any}(
            "schema" => "qcl-negf-study-v2", "kind" => "study", "id" => "generated-test",
            "configuration" => Dict("sources" => [base_path], "overrides" => Dict(
                "physical" => Dict("lattice_temperature" => "180 K", "lo_temperature" => "180 K"))),
            "axes" => Dict("temperatures" => Dict("values" => [200, 210], "unit" => "K"),
                "voltages" => Dict("values" => [50, 56], "unit" => "mV")),
        )
        YAML.write_file(definition_path, recipe)
        repository = Workflow.FilesystemScientificDefinitions()
        definition = Workflow.read_scientific_definition(repository, definition_path)
        variant = Workflow.ScientificVariant("warmer", "configured", Dict{String,Any}(
            "physical" => Dict{String,Any}("lattice_temperature" => "190 K", "lo_temperature" => "190 K")), String[], :numerical)
        inherited = Dict{String,Any}("physical" => Dict{String,Any}(
            "lattice_temperature" => "195 K", "lo_temperature" => "195 K"))
        configuration = Workflow.resolve_scientific_configuration(repository, definition, variant, inherited)
        raw = configuration.raw
        sources = configuration.provenance.sources
        for key in ("lattice_temperature", "lo_temperature")
            path = "physical." * key
            @test raw["physical"][key] == "200.0 K"
            @test sources[path] == [base_path, definition_path, definition_path * "#warmer",
                definition_path * "#inclusion", definition_path * "#generated:temperature-axis"]
            @test configuration_source(configuration, path) == definition_path * "#generated:temperature-axis"
        end
        expected = [
            ("run.name", "generated-test-warmer", "run-identity"),
            ("solver.convergence.mode", "research_continue", "convergence-policy"),
            ("study.mode", "single", "single-study"),
            ("study.voltages_per_period", ["0.05 V"], "single-study"),
            ("study.temperatures", ["200.0 K"], "single-study"),
            ("study.methods", Any[], "single-study"),
            ("study.reference_profile", nothing, "single-study"),
            ("study.comparison_profiles", Any[], "single-study"),
            ("study.repetitions", 1, "single-study"),
            ("study.calculate_optical_response", false, "single-study"),
            ("study.convergence.spatial_nodes", Int[], "single-study"),
            ("study.convergence.energy_nodes", Int[], "single-study"),
            ("study.convergence.momentum_nodes", Int[], "single-study"),
            ("study.convergence.angular_nodes", Int[], "single-study"),
            ("output.resume", false, "output-policy"),
            ("output.save_full_state", true, "output-policy"),
            ("output.save_csv", true, "output-policy"),
            ("output.save_plots", false, "output-policy"),
            ("output.live_visualization", false, "output-policy"),
            ("output.progress.terminal", false, "output-policy"),
            ("output.light_max_snapshots", 16, "output-policy"),
        ]
        for (path, value, reason) in expected
            actual = raw
            for key in split(path, '.')
                actual = actual[key]
            end
            @test isequal(actual, value)
            @test sources[path] == vcat(get(original_sources, path, String[]), [definition_path * "#generated:" * reason])
        end
        for section in ("numerical", "scattering")
            @test raw[section] == original_raw[section]
        end
        for (path, history) in original_sources
            if startswith(path, "numerical.") || startswith(path, "scattering.") ||
               path in ("study.photon_energy_min", "study.photon_energy_max", "study.photon_energy_points", "study.optical_edge_tolerance")
                @test sources[path] == history
            end
        end
        for key in ("photon_energy_min", "photon_energy_max", "photon_energy_points", "optical_edge_tolerance")
            @test raw["study"][key] == original_raw["study"][key]
        end
        @test base.raw == original_raw
        @test base.provenance.sources == original_sources
        reloaded_base = load_run_configuration(base_path)
        @test reloaded_base.raw == original_raw
        @test reloaded_base.provenance.sources == original_sources

        mapping_variant = Workflow.ScientificVariant("quantity", "configured", Dict{String,Any}(
            "physical" => Dict{String,Any}(key => Dict{String,Any}("value" => 190, "unit" => "K")
                for key in ("lattice_temperature", "lo_temperature"))), String[], :numerical)
        mapped = Workflow.resolve_scientific_configuration(repository, definition, mapping_variant, Dict{String,Any}())
        for key in ("lattice_temperature", "lo_temperature")
            path = "physical." * key
            @test mapped.raw["physical"][key] == "200.0 K"
            @test get(mapped.provenance.sources, path, nothing) == [definition_path * "#generated:temperature-axis"]
            @test configuration_source(mapped, path * ".value") === nothing
            @test configuration_source(mapped, path * ".unit") === nothing
        end

        # Public planning/freeze/load only: no execute_scientific_plan or operator.
        plan = resolve_scientific_plan(definition_path)
        frozen = scientific_plan_dict(plan)
        loaded = load_scientific_plan(frozen)
        @test length(loaded.executions) == 4
        for (restored, original) in zip(loaded.executions, plan.executions)
            @test restored.configuration.raw == original.configuration.raw
            @test restored.configuration.provenance.sources == original.configuration.provenance.sources
        end
        @test first(loaded.executions).configuration.provenance.sources["physical.lattice_temperature"] ==
            [base_path, definition_path, definition_path * "#generated:temperature-axis"]
        @test [p.temperature_K for p in loaded.points] == [200.0, 200.0, 210.0, 210.0]
    end
end
end
