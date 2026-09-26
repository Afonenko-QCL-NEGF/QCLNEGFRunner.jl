module Suite_T026
include("../support/common.jl")
using HDF5
include("../support/configuration_schema_scattering_domain.jl")

@testset "Draft 2020-12 configuration contract" begin
    base = load_run_configuration(joinpath(_SCHEMA_CONFIG_ROOT, "base.yaml"))
    base_mapping = resolved_configuration_dict(base)
    @test QCLNEGFRunner.validate_configuration_schema(base_mapping) === base_mapping

    unexpected = resolved_configuration_dict(base)
    unexpected["version"] = 1
    version_error = try
        QCLNEGFRunner.validate_configuration_schema(unexpected)
        nothing
    catch error
        error
    end
    @test version_error isa ConfigurationError
    @test occursin("unknown key", sprint(showerror, version_error))

    bool_as_integer = resolved_configuration_dict(base)
    bool_as_integer["numerical"]["energy_nodes"] = true
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(bool_as_integer)

    wrong_dimension = resolved_configuration_dict(base)
    wrong_dimension["physical"]["lattice_temperature"] = "200 eV"
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(wrong_dimension)

    invalid_tail_window = resolved_configuration_dict(base)
    invalid_tail_window["solver"]["validation_windows"]["energy_tail_fraction"] = 1.0
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(
        invalid_tail_window,
    )
    @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
        invalid_tail_window,
        base.provenance,
    )

    invalid_stagnation_window = resolved_configuration_dict(base)
    invalid_stagnation_window["solver"]["convergence"]["stagnation_window"] = 3
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(
        invalid_stagnation_window,
    )
    @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
        invalid_stagnation_window,
        base.provenance,
    )

    invalid_consecutive_passes = resolved_configuration_dict(base)
    invalid_consecutive_passes["solver"]["convergence"]["required_consecutive_scba_passes"] =
        0
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(
        invalid_consecutive_passes,
    )
    @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
        invalid_consecutive_passes,
        base.provenance,
    )

    inconsistent_stagnation = resolved_configuration_dict(base)
    inconsistent_stagnation["solver"]["convergence"]["stagnation_window"] = 0
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(
        inconsistent_stagnation,
    )
    @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
        inconsistent_stagnation,
        base.provenance,
    )

    invalid_diagnostic_threshold = resolved_configuration_dict(base)
    invalid_diagnostic_threshold["solver"]["convergence"]["diagnostic_quality"]["keldysh"] =
        0.0
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(
        invalid_diagnostic_threshold,
    )
    @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
        invalid_diagnostic_threshold,
        base.provenance,
    )

    without_diagnostic_quality = resolved_configuration_dict(base)
    delete!(without_diagnostic_quality["solver"]["convergence"], "diagnostic_quality")
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(
        without_diagnostic_quality,
    )
    @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
        without_diagnostic_quality,
        base.provenance,
    )

    without_convergence_policy = resolved_configuration_dict(base)
    delete!(without_convergence_policy["solver"], "convergence")
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(
        without_convergence_policy,
    )
    @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
        without_convergence_policy,
        base.provenance,
    )

    alloy_without_material = resolved_configuration_dict(base)
    alloy_without_material["scattering"]["alloy_disorder"] = true
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(
        alloy_without_material,
    )

    alloy_with_material = deepcopy(alloy_without_material)
    alloy_with_material["physical"]["alloy_potential"] = "0.6 eV"
    alloy_with_material["physical"]["primitive_cell_volume"] = "4.5e-29 m^3"
    @test QCLNEGFRunner.validate_configuration_schema(alloy_with_material) ===
          alloy_with_material

    function rejects_study_contract(candidate)
        @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(candidate)
        @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
            candidate,
            base.provenance,
        )
    end

    multiple_single_voltages = resolved_configuration_dict(base)
    multiple_single_voltages["study"]["voltages_per_period"] = ["40 mV", "60 mV"]
    rejects_study_contract(multiple_single_voltages)

    multiple_single_temperatures = resolved_configuration_dict(base)
    multiple_single_temperatures["study"]["temperatures"] = ["200 K", "300 K"]
    rejects_study_contract(multiple_single_temperatures)

    ignored_profiles = resolved_configuration_dict(base)
    ignored_profiles["study"]["comparison_profiles"] = ["exact_cpu"]
    rejects_study_contract(ignored_profiles)

    ignored_repetition = resolved_configuration_dict(base)
    ignored_repetition["study"]["repetitions"] = 2
    rejects_study_contract(ignored_repetition)

    ignored_convergence = resolved_configuration_dict(base)
    ignored_convergence["study"]["convergence"]["energy_nodes"] = [101]
    rejects_study_contract(ignored_convergence)

    whitespace_name = resolved_configuration_dict(base)
    whitespace_name["run"]["name"] = " \t "
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(whitespace_name)
    @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
        whitespace_name,
        base.provenance,
    )

    for bad_path in (
        "/absolute/events.yaml",
        "../escape.yaml",
        ".",
        "progress/../events.yaml",
        "progress\\events.yaml",
        "C:\\events.yaml",
    )
        nonportable = resolved_configuration_dict(base)
        nonportable["output"]["progress"]["event_log_file"] = bad_path
        @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(nonportable)
        @test_throws ConfigurationError QCLNEGFRunner._resolve_configuration(
            nonportable,
            base.provenance,
        )
    end

    mislabeled = resolved_configuration_dict(base)
    mislabeled["algorithms"]["kernel_build"] = "tabulated"
    label_error = try
        QCLNEGFRunner.validate_configuration_schema(mislabeled)
        nothing
    catch error
        error
    end
    @test label_error isa ConfigurationError
    @test occursin("constant value", sprint(showerror, label_error))

    unlocalized = resolved_configuration_dict(base)
    unlocalized["run"]["classification"] = "controlled_numerical"
    unlocalized["algorithms"]["localization"] = "none"
    @test QCLNEGFRunner.validate_configuration_schema(unlocalized) === unlocalized

    exact_full_rank = resolved_configuration_dict(base)
    exact_full_rank["algorithms"]["contraction"] = "low_rank"
    exact_full_rank["algorithms"]["low_rank"]["relative_tolerance"] = 0.0
    exact_full_rank["algorithms"]["low_rank"]["maximum_rank"] = 0
    @test QCLNEGFRunner.validate_configuration_schema(exact_full_rank) === exact_full_rank

    rank_capped = deepcopy(exact_full_rank)
    rank_capped["algorithms"]["low_rank"]["maximum_rank"] = 8
    @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_schema(rank_capped)

    base_file=joinpath(_SCHEMA_CONFIG_ROOT, "base.yaml")
    document=QCLNEGFRunner.validate_configuration_source(base_file)
    @test document isa QCLNEGFRunner.ValidatedConfigurationDocument
    @test isempty(document.provenance.manifests)
    @test length(document.provenance.files)==1
    @test document.data["numerical"]["energy_nodes"]==2401
    mktempdir() do temporary
        override=joinpath(temporary, "override.yaml")
        write(override, "numerical:\n  energy_nodes: 1201\n")
        overlaid=QCLNEGFRunner.load_configuration_source(base_file, override)
        @test overlaid.numerical.N_E==1201
        @test overlaid.physical.layers==base.physical.layers
        @test overlaid.physical.F_bias==base.physical.F_bias
        @test endswith(
            configuration_source(overlaid, "numerical.energy_nodes"),
            "override.yaml",
        )
        manifest=joinpath(temporary, "manifest.yaml")
        write(manifest, "extends: []\nfiles: []\n")
        @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_source(manifest)
        @test_throws ConfigurationError QCLNEGFRunner.validate_configuration_source(temporary)
    end
end
end
