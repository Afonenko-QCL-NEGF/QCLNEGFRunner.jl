module Suite_T024
include("../support/common.jl")
include("../support/configuration.jl")

@testset "Canonical file merge order and fail-closed validation" begin
    base=joinpath(CONFIGURATION_ROOT, "base.yaml")
    mktempdir() do temporary
        first_file=_write_test_file(
            joinpath(temporary, "first.yaml"),
            "production:\n  energy_chunk: 17\noutput:\n  directory: results/first\n",
        )
        second_file=_write_test_file(
            joinpath(temporary, "second.yaml"),
            "production:\n  energy_chunk: 23\noutput:\n  directory: results/second\n",
        )
        merged=load_run_configuration([base, first_file, second_file])
        @test merged.production.energy_chunk==23
        @test merged.output.directory=="results/second"
        @test length(merged.provenance.sources["production.energy_chunk"])==3
        @test isempty(merged.provenance.manifests)
        @test endswith(
            configuration_source(merged, "production.energy_chunk"),
            "second.yaml",
        )
        reverse=load_run_configuration([base, second_file, first_file])
        @test reverse.production.energy_chunk==17
        @test reverse.output.directory=="results/first"
        invalid=[
            "physical:\n  undocumented_magic_parameter: 42\n",
            "physical:\n  lattice_temperature: '200 eV'\n",
            "output:\n  progress:\n    event_log_file: ../outside.csv\n",
            "algorithms:\n  retarded_real_part: drop\n",
            "output:\n  directory: results/a\n  directory: results/b\n",
            "algorithms:\n  localization: legacy_pzp\n",
        ]
        for (i, text) in enumerate(invalid)
            file=_write_test_file(joinpath(temporary, "invalid-$i.yaml"), text)
            @test_throws ConfigurationError load_run_configuration([base, file])
        end
        incomplete=_write_test_file(
            joinpath(temporary, "incomplete.yaml"),
            "run: {name: x}\n",
        )
        @test_throws ConfigurationError load_run_configuration(incomplete)
        manifest=_write_test_file(
            joinpath(temporary, "manifest.yaml"),
            "extends: []\nfiles: [first.yaml]\n",
        )
        @test_throws ConfigurationError load_run_configuration(manifest)
        @test_throws ConfigurationError load_run_configuration(temporary)
    end
    @test_throws ConfigurationError load_run_configuration(
        joinpath(CONFIGURATION_ROOT, "not-present.yaml"),
    )
end
end
