module Suite_T036
include("../support/common.jl")
include("../support/configured_study.jl")

@testset "Configured production-study orchestration" begin
    BN = QCLNEGFRunner
    configuration_root = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))
    study_directory = joinpath(configuration_root, "studies-smoke.yaml")
    root = BN._find_profile_root(study_directory)
    study = load_run_configuration(study_directory)
    naive = load_run_configuration(BN._profile_directory(root, "naive_oracle.yaml"))
    exact = load_run_configuration(BN._profile_directory(root, "exact_cpu.yaml"))
    base = load_run_configuration(BN._profile_directory(root, "base.yaml"))

    @testset "complete, exact study signatures" begin
        structure = BN._structure_signature(study)
        physics = BN._physics_signature(study)
        @test startswith(structure, "reference design-structure-v2:")
        @test startswith(physics, "reference design-physics-v2:")
        @test structure == BN._structure_signature(study)
        @test physics == BN._physics_signature(study)
        @test_throws ArgumentError BN._signature_value(Dict(:unknown => 1))

        # Regression for the former total-thickness-only structure id: layer
        # order changes the device even though the compact period length is
        # bit-for-bit identical.
        reordered_layers = copy(study.physical.layers)
        reordered_layers[1], reordered_layers[2] = reordered_layers[2], reordered_layers[1]
        reordered_physical = _study_replace_field(study.physical, :layers, reordered_layers)
        reordered = _study_replace_configuration(study; physical = reordered_physical)
        original_length = sum(BN._metres(layer.d) for layer in study.physical.layers)
        reordered_length = sum(BN._metres(layer.d) for layer in reordered.physical.layers)
        @test original_length == reordered_length
        @test BN._structure_signature(reordered) != structure

        # Every typed physical input participates in the physics signature.
        # `nextfloat` mutations also prove that report formatting no longer
        # collapses close, distinct Float64 values.
        for field in fieldnames(PhysicalParameters)
            physical_fixture = study.physical
            # Alloy energy and volume form a validated pair. Start from a
            # complete pair so each field can be perturbed independently.
            if field in (:ΔV_alloy, :Ω₀) && physical_fixture.ΔV_alloy === nothing
                values = Any[
                    getfield(physical_fixture, name) for
                    name in fieldnames(PhysicalParameters)
                ]
                values[findfirst(==(:ΔV_alloy), fieldnames(PhysicalParameters))] = 1.0u"eV"
                values[findfirst(==(:Ω₀), fieldnames(PhysicalParameters))] = 1e-28u"m^3"
                physical_fixture = PhysicalParameters(values...)
            end
            fixture_signature = BN._physics_signature(
                _study_replace_configuration(study; physical = physical_fixture),
            )
            changed_value = _study_distinct_physical_value(physical_fixture, field)
            changed_physical = _study_replace_field(physical_fixture, field, changed_value)
            changed = _study_replace_configuration(study; physical = changed_physical)
            @test BN._physics_signature(changed) != fixture_signature
        end

        for field in (:layers, :N_dop²ᴰ, :z₀, :interfaces)
            changed_physical = _study_replace_field(
                study.physical,
                field,
                _study_distinct_physical_value(study.physical, field),
            )
            changed = _study_replace_configuration(study; physical = changed_physical)
            @test BN._structure_signature(changed) != structure
        end

        for field in fieldnames(Layer)
            layer = study.physical.layers[1]
            changed_layer = _study_replace_field(
                layer,
                field,
                _study_distinct_layer_value(layer, field),
            )
            changed_layers = copy(study.physical.layers)
            changed_layers[1] = changed_layer
            changed_physical = _study_replace_field(study.physical, :layers, changed_layers)
            changed = _study_replace_configuration(study; physical = changed_physical)
            @test BN._structure_signature(changed) != structure
            @test BN._physics_signature(changed) != physics
        end

        temperature_changed = _study_replace_field(
            study.physical,
            :Tᴸ,
            _study_changed_quantity(study.physical.Tᴸ),
        )
        temperature_configuration =
            _study_replace_configuration(study; physical = temperature_changed)
        @test BN._structure_signature(temperature_configuration) == structure
        @test BN._physics_signature(temperature_configuration) != physics

        for field in fieldnames(ScatteringOptions)
            scattering = _study_replace_field(
                study.scattering,
                field,
                !getfield(study.scattering, field),
            )
            changed = _study_replace_configuration(study; scattering = scattering)
            @test BN._physics_signature(changed) != physics
        end

        for (field, replacement) in (
            (
                :retarded_real_part,
                study.algorithms.retarded_real_part === :kramers_kronig ? :drop :
                :kramers_kronig,
            ),
            (
                :self_energy_structure,
                study.algorithms.self_energy_structure === :full ? :diagonal : :full,
            ),
            (
                :transverse_momentum,
                study.algorithms.transverse_momentum === :resolved ? :averaged : :resolved,
            ),
        )
            algorithms = _study_replace_field(study.algorithms, field, replacement)
            changed = _study_replace_configuration(study; algorithms = algorithms)
            @test BN._physics_signature(changed) != physics
        end

        # Computational implementation choices are intentionally absent from
        # the physical-model identity.
        alternative_hilbert = study.algorithms.hilbert === :fft ? :direct : :fft
        algorithms = _study_replace_field(study.algorithms, :hilbert, alternative_hilbert)
        computational = _study_replace_configuration(study; algorithms = algorithms)
        @test BN._physics_signature(computational) == physics
        @test BN._structure_signature(computational) == structure
        @test BN._physics_signature(naive) == BN._physics_signature(exact)
        @test BN._structure_signature(naive) == BN._structure_signature(exact)
    end

    @test BN._profile_directory(root, "exact_cpu.yaml") ==
          realpath(joinpath(root, "exact_cpu.yaml"))
    @test_throws ArgumentError BN._profile_directory(root, root)
    @test_throws ArgumentError BN._profile_directory(root, "..")
    @test_throws ArgumentError BN._profile_directory(root, "does_not_exist")

    for (metadata, profile) in zip(study.study.methods, (naive, exact))
        @test BN._validate_method_metadata(metadata, profile) === profile
    end
    exact_metadata =
        only(filter(method -> method.profile == "exact_cpu.yaml", study.study.methods))
    false_physics = StudyMethodConfiguration(
        exact_metadata.profile,
        exact_metadata.label,
        true,
        exact_metadata.algorithm_family,
        exact_metadata.description,
        exact_metadata.literature,
    )
    wrong_family = StudyMethodConfiguration(
        exact_metadata.profile,
        exact_metadata.label,
        false,
        :direct_reference,
        exact_metadata.description,
        exact_metadata.literature,
    )
    @test_throws ArgumentError BN._validate_method_metadata(false_physics, exact)
    @test_throws ArgumentError BN._validate_method_metadata(wrong_family, exact)
    nested_study = StudyMethodConfiguration(
        "studies-smoke.yaml",
        "nested study",
        false,
        :exact_optimized,
        "invalid nesting",
        String[],
    )
    @test_throws ArgumentError BN._validate_method_metadata(nested_study, study)

    mktempdir() do temporary
        configured = BN._method_configuration(study, naive, joinpath(temporary, "naive"))
        # Case overrides are resolved through the configuration parser. Physical
        # values must be identical, without requiring reuse of array identity.
        for field in fieldnames(PhysicalParameters)
            @test isequal(
                getfield(configured.physical, field),
                getfield(study.physical, field),
            )
        end
        @test BN._structure_signature(configured) == BN._structure_signature(study)
        @test BN._physics_signature(configured) == BN._physics_signature(study)
        @test configured.numerical === study.numerical
        @test configured.solver === study.solver
        @test configured.kernels === naive.kernels
        @test configured.algorithms === naive.algorithms
        @test configured.production.algorithms === configured.algorithms
        @test configured.production.memory_budget_bytes ==
              study.production.memory_budget_bytes
        @test configured.production.phase_timing == study.production.phase_timing
        @test configured.production.phase_timing != base.production.phase_timing
        @test configured.execution.solver_backend == :educational
        @test configured.execution.julia_threads == study.execution.julia_threads
        @test configured.execution.julia_threads != naive.execution.julia_threads
        @test configured.execution.blas_threads == study.execution.blas_threads
        @test configured.study.mode == :sweep
        @test isempty(configured.study.methods)
        @test isempty(configured.study.convergence.spatial_nodes)
        @test isempty(configured.raw["study"]["convergence"]["spatial_nodes"])
        @test configured.raw["numerical"]["spatial_nodes"] == configured.numerical.N_z
        @test configured.raw["production"]["phase_timing"] ==
              configured.production.phase_timing
        @test endswith(configuration_source(configured, "run.name"), "configured_study.jl")
        @test endswith(
            configuration_source(configured, "execution.solver_backend"),
            "naive_oracle.yaml",
        )

        reparsed =
            BN._resolve_configuration(deepcopy(configured.raw), configured.provenance)
        @test reparsed.name == configured.name
        @test reparsed.numerical == configured.numerical
        @test reparsed.algorithms == configured.algorithms
        @test reparsed.execution.solver_backend == configured.execution.solver_backend
        @test reparsed.study.mode == configured.study.mode

        screening = BN._method_configuration(
            study,
            naive,
            joinpath(temporary, "screening");
            overrides = Dict{String,Any}(
                "physical" =>
                    Dict{String,Any}("impurity_screening_wavenumber" => "0.10 nm^-1"),
            ),
        )
        @test screening.physical.q_s ≈ 0.10u"nm^-1"
        @test screening.classification == :physics_changing
        @test BN._structure_signature(screening) == BN._structure_signature(study)
        @test BN._physics_signature(screening) != BN._physics_signature(study)
        @test configured.physical.q_s == study.physical.q_s
        @test configured.raw["physical"] == study.raw["physical"]
        for field in filter(!=(:q_s), fieldnames(PhysicalParameters))
            @test isequal(
                getfield(screening.physical, field),
                getfield(study.physical, field),
            )
        end

        refined_numerical = BN._numerical_with_axis(configured.numerical, :energy_nodes, 55)
        refined = BN._configuration_with_numerical(
            configured,
            refined_numerical,
            joinpath(temporary, "refined"),
            "refined",
        )
        @test refined.numerical.N_E == 55
        @test refined.raw["numerical"]["energy_nodes"] == 55
        @test endswith(
            configuration_source(refined, "numerical.energy_nodes"),
            "configured_study.jl",
        )
        @test configuration_source(refined, "numerical.spatial_nodes") ==
              configuration_source(configured, "numerical.spatial_nodes")
        refined_reparsed =
            BN._resolve_configuration(deepcopy(refined.raw), refined.provenance)
        @test refined_reparsed.numerical == refined.numerical
        @test_throws ArgumentError BN._numerical_with_axis(
            configured.numerical,
            :not_an_axis,
            5,
        )
    end
end

end # independent suite
