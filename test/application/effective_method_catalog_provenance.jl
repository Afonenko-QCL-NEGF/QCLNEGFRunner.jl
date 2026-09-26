module Suite_T040
include("../support/common.jl")
using HDF5
include("../support/configured_study.jl")

@testset "Effective method catalog provenance" begin
    BN = QCLNEGFRunner
    configuration_root = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))
    study_directory = joinpath(configuration_root, "studies-smoke.yaml")
    root = BN._find_profile_root(study_directory)
    study = load_run_configuration(study_directory)
    profiles = Dict(
        profile => load_run_configuration(BN._profile_directory(root, profile)) for
        profile in study.study.comparison_profiles
    )

    mktempdir() do temporary
        summaries = Dict{String,String}()
        effective = Dict{String,ResolvedRunConfiguration}()
        for (index, metadata) in pairs(study.study.methods)
            method_output = joinpath(temporary, "method_$(index)")
            configuration =
                BN._method_configuration(study, profiles[metadata.profile], method_output)
            effective[metadata.profile] = configuration
            sweep = ProductionSweepResult(
                [
                    ProductionSweepRecord(
                        200.0,
                        0.056,
                        1.891e6,
                        10.0,
                        true,
                        :converged,
                        :strictly_converged,
                        2,
                        5,
                        2048,
                        Float64(index),
                        Dict{Symbol,Float64}(:current_continuity => 1e-8),
                        "state.h5",
                    ),
                ],
                joinpath(method_output, "sweep_summary.csv"),
            )
            mkpath(method_output)
            save_production_summary(sweep.summary_path, sweep)
            summaries[metadata.profile] = sweep.summary_path
        end
        catalog = BN._method_catalog(
            joinpath(temporary, "method_catalog.csv"),
            study,
            summaries,
            effective,
        )
        runs = load_method_catalog(catalog)
        @test getfield.(getfield.(runs, :descriptor), :id) == [:naive_oracle, :exact_cpu]
        @test length(unique(run.descriptor.physics_signature for run in runs)) == 1
        comparison = compare_method_runs(runs; reference_id = :naive_oracle)
        @test !isempty(comparison.rows)
        @test all(!row.modifies_physics for row in comparison.rows)

        # The catalog must derive structure_id from each effective method,
        # not stamp every row with the study profile's structure.
        different_structure = copy(effective)
        exact_configuration = effective["exact_cpu.yaml"]
        reordered_physical = _study_replace_field(
            exact_configuration.physical,
            :layers,
            reverse(copy(exact_configuration.physical.layers)),
        )
        different_structure["exact_cpu.yaml"] =
            _study_replace_configuration(exact_configuration; physical = reordered_physical)
        structure_catalog = BN._method_catalog(
            joinpath(temporary, "method_catalog_different_structure.csv"),
            study,
            summaries,
            different_structure,
        )
        structure_runs = load_method_catalog(structure_catalog)
        @test length(unique(run.descriptor.structure_id for run in structure_runs)) == 2
        @test_throws ArgumentError compare_method_runs(
            structure_runs;
            reference_id = :naive_oracle,
        )

        # A non-structural physical parameter keeps structure_id but changes
        # physics_signature, so an allegedly computational method is rejected.
        different_physics = copy(effective)
        temperature_changed = _study_replace_field(
            exact_configuration.physical,
            :Tᴸ,
            _study_changed_quantity(exact_configuration.physical.Tᴸ),
        )
        different_physics["exact_cpu.yaml"] = _study_replace_configuration(
            exact_configuration;
            physical = temperature_changed,
        )
        physics_catalog = BN._method_catalog(
            joinpath(temporary, "method_catalog_different_physics.csv"),
            study,
            summaries,
            different_physics,
        )
        physics_runs = load_method_catalog(physics_catalog)
        @test length(unique(run.descriptor.structure_id for run in physics_runs)) == 1
        @test length(unique(run.descriptor.physics_signature for run in physics_runs)) == 2
        @test_throws ArgumentError compare_method_runs(
            physics_runs;
            reference_id = :naive_oracle,
        )
    end
end

end # independent suite
