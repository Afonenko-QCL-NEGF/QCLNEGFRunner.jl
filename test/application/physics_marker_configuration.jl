module Suite_PhysicsMarkerConfiguration
include("../support/common.jl")
include("../support/configuration.jl")

@testset "Physical diagnostics are configurable without relaxing solver gates" begin
    base_path = joinpath(CONFIGURATION_ROOT, "base.yaml")
    base = load_run_configuration(base_path)
    @test base.production.physics_markers == SCBAPhysicsMarkerPolicy()
    mktempdir() do directory
        override = _write_test_file(
            joinpath(directory, "markers.yaml"),
            "production:\n  physics_markers:\n    cadence: 7\n    max_spectral_blocks: 128\n    relative_mode_weight_floor: 0\n",
        )
        configured = load_run_configuration([base_path, override])
        policy = configured.production.physics_markers
        @test policy.cadence == 7
        @test policy.max_spectral_blocks == 128
        @test policy.relative_mode_weight_floor == 0.0
        @test configured.solver.tolerances == base.solver.tolerances
        @test configured.algorithms == base.algorithms
        @test configured.numerical == base.numerical
        @test QCLNEGFRunner.with_production_options(configured.production; worker_count = 1).physics_markers ==
              policy
        for (index, declaration) in enumerate((
            "cadence: 0",
            "max_spectral_blocks: 0",
            "relative_mode_weight_floor: -0.1",
            "relative_mode_weight_floor: 1",
            "unknown_marker_option: true",
        ))
            invalid = _write_test_file(
                joinpath(directory, "invalid-$index.yaml"),
                "production:\n  physics_markers:\n    $declaration\n",
            )
            @test_throws ConfigurationError load_run_configuration([base_path, invalid])
        end
    end
end
end
