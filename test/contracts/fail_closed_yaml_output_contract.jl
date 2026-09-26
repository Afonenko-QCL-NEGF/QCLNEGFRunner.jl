module Suite_T067
include("../support/common.jl")
using HDF5

@testset "Fail-closed YAML output contract" begin
    BN = QCLNEGFRunner
    configuration_root = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))
    base = load_run_configuration(joinpath(configuration_root, "base.yaml"))
    smoke = load_run_configuration(joinpath(configuration_root, "studies-smoke.yaml"))
    native_progress=BN._configured_progress_paths("results", base.output)
    @test native_progress.event_log==joinpath("results", "progress", "events.jsonl")
    @test native_progress.latest==joinpath("results", "progress", "progress.yaml")

    function resolve_with(mutate!::Function, configuration)
        raw = deepcopy(configuration.raw)
        mutate!(raw)
        return BN._resolve_configuration(raw, configuration.provenance)
    end

    @test_throws ConfigurationError resolve_with(base) do raw
        raw["output"]["progress"]["event_log_file"] = "progress/timings.csv"
    end
    @test_throws ConfigurationError resolve_with(base) do raw
        raw["output"]["progress"]["latest_snapshot_file"] = "progress/progress.yaml"
    end

    custom_prefix = resolve_with(base) do raw
        raw["output"]["checkpoint_prefix"] = "reference2019-2026.state"
    end
    @test custom_prefix.output.checkpoint_prefix == "reference2019-2026.state"
    no_single_run_plots = resolve_with(base) do raw
        raw["output"]["save_plots"] = false
    end
    @test !no_single_run_plots.output.save_plots
    for invalid in ("../state", "sub/state", "state.h5?", "_state", "")
        @test_throws ConfigurationError resolve_with(base) do raw
            raw["output"]["checkpoint_prefix"] = invalid
        end
    end

    @test !base.output.save_full_state
    @test !base.output.debug_hdf5
    @test_throws ConfigurationError resolve_with(base) do raw
        raw["output"]["save_full_state"] = false
        raw["output"]["resume"] = true
    end
    @test_throws ConfigurationError resolve_with(base) do raw
        raw["output"]["save_full_state"] = false
        raw["output"]["resume"] = false
        raw["production"]["checkpoint_every_scba"] = 1
    end
    no_state = resolve_with(base) do raw
        raw["output"]["save_full_state"] = false
        raw["output"]["resume"] = false
        raw["production"]["checkpoint_every_scba"] = 0
        raw["production"]["checkpoint_every_outer"] = 0
    end
    @test !no_state.output.save_full_state
    @test !no_state.output.resume
    debug_only = resolve_with(base) do raw
        raw["output"]["debug_hdf5"] = true
    end
    @test debug_only.output.debug_hdf5 && !debug_only.output.save_full_state

    @test_throws ConfigurationError resolve_with(base) do raw
        raw["output"]["progress"]["enabled"] = false
    end
    @test_throws ConfigurationError resolve_with(base) do raw
        raw["output"]["live_visualization"] = true
        raw["output"]["progress"]["dashboard_file"] = nothing
    end
    @test_throws ConfigurationError resolve_with(base) do raw
        raw["output"]["live_visualization"] = false
        raw["output"]["progress"]["latest_snapshot_file"] = nothing
    end
    progress_disabled = resolve_with(base) do raw
        raw["output"]["live_visualization"] = false
        raw["output"]["snapshot_every_scba"] = 0
        raw["output"]["snapshot_every_outer"] = 0
        raw["output"]["progress"]["enabled"] = false
    end
    @test BN._configured_progress_paths("results", progress_disabled.output) ==
          (event_log = "", dashboard = "", latest = "")

    @test_throws ConfigurationError resolve_with(smoke) do raw
        raw["output"]["save_csv"] = false
    end
    @test_throws ConfigurationError resolve_with(smoke) do raw
        raw["output"]["save_expert_markdown"] = false
    end
    @test_throws ConfigurationError resolve_with(smoke) do raw
        raw["output"]["save_comparison_csv"] = false
    end
    @test_throws ConfigurationError resolve_with(smoke) do raw
        raw["output"]["save_plots"] = false
        raw["output"]["save_comparison_plots"] = true
    end
end

end # independent suite
