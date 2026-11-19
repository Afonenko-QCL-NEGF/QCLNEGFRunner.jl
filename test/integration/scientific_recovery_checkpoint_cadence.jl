module ScientificRecoveryCheckpointCadence
include("../support/common.jl")
using HDF5, SHA, YAML

const Runner = QCLNEGFRunner

function recovery_plan(directory)
    examples = normpath(joinpath(TEST_ROOT, "..", "examples", "config"))
    definition = YAML.load_file(joinpath(examples, "stationary-smoke.yaml"))
    configuration = definition["configuration"]
    configuration["sources"] = [joinpath(examples, "reference-2019-70k.yaml")]
    overrides = configuration["overrides"]
    overrides["solver"] = Dict(
        "maximum_scba_iterations" => 5,
        "maximum_poisson_iterations" => 1,
        "convergence" => Dict(
            "required_consecutive_scba_passes" => 99,
            "diagnostic_quality" => Dict("enabled" => false),
        ),
    )
    overrides["scattering"] = Dict(
        name => false for name in (
            "lo_phonon", "acoustic_phonon", "ionized_impurity", "interface_roughness", "alloy_disorder",
        )
    )
    overrides["output"]["save_full_state"] = true
    overrides["production"] = Dict(
        "checkpoint_every_scba" => 2,
        "physics_markers" => Dict("cadence" => 11),
    )
    definition_path = joinpath(directory, "definition.yaml")
    YAML.write_file(definition_path, definition)
    return resolve_scientific_plan(definition_path)
end

function checkpoint_contents(path)
    return h5open(path, "r") do file
        state = file["state_dimensionless"]
        (Runner._read_complex(state, "GR"), Runner._read_complex(state, "GL"))
    end
end

function scba_history(path)
    return h5open(path, "r") do file
        Dict(name => read(file["scba/" * name]) for name in keys(file["scba"]))
    end
end

@testset "Recovery cadence preserves scientific trajectory and analysis provenance" begin
    mktempdir() do directory
        plan = recovery_plan(directory)
        config = only(plan.executions).configuration
        storage = Runner._configured_storage_observers(config, directory)
        @test storage.request((stage = :scba, iteration = 1, outer_iteration = 1), 1, 1) === :none
        @test storage.request((stage = :scba, iteration = 2, outer_iteration = 1), 1, 1) === :state_only

        root = mkpath(joinpath(directory, "paused"))
        pause = joinpath(mkpath(joinpath(root, "control")), "pause.json")
        write(pause, "{}")
        paused = execute_scientific_plan(plan, root)
        @test paused["status"] == "paused"
        saved = only(paused["points"])
        @test saved["data"]["resume_kind"] == "checkpoint"
        paused_commit = Runner.verify_point_artifacts(joinpath(root, saved["data"]["result_commit"]))
        @test paused_commit["restart_coordinates"]["last_inner"] == 1
        @test paused_commit["analysis_coordinates"]["last_inner"] == 1
        rm(pause)

        plan_path = joinpath(directory, "plan.json")
        open(io -> write_scientific_plan(io, plan), plan_path, "w")
        exit_code = redirect_stdout(devnull) do
            Runner.main(["run-plan", plan_path, root])
        end
        @test exit_code == 0
        resumed = YAML.load_file(joinpath(root, "series_result.json"))
        @test resumed["status"] == "completed_with_warnings"
        point = only(resumed["points"])
        @test point["status"] == "completed"
        @test point["attempt"] == 2
        @test !point["converged"]
        @test [attempt["status"] for attempt in resumed["attempt_history"]] == ["paused", "completed"]

        terminal_path = joinpath(root, point["data"]["result_commit"])
        artifacts = dirname(dirname(terminal_path))
        first = joinpath(artifacts, "generation-000001", "commit.json")
        first_commit = Runner.verify_point_artifacts(first)
        @test first_commit["analysis_coordinates"]["last_inner"] == 2
        @test !haskey(first_commit, "science_parent_commit")
        h5open(joinpath(dirname(first), "analysis.h5"), "r") do file
            markers = Runner._read_physical_markers(file["diagnostics"], 2)
            @test markers[1] !== nothing
            @test markers[2] === nothing
            @test read(file["diagnostics/physical_markers/available"]) == Int8[1, 0]
        end
        h5open(joinpath(dirname(first), "physics.h5"), "r") do file
            @test read(file["convergence/physical_markers/available"]) == Int8[1, 0]
        end
        second = joinpath(artifacts, "generation-000002", "commit.json")
        second_commit = Runner.verify_point_artifacts(second)
        @test second_commit["restart_coordinates"]["last_inner"] == 4
        @test second_commit["science_parent_commit"]["path"] == relpath(first, artifacts)
        @test second_commit["science_parent_commit"]["sha256"] == bytes2hex(open(sha256, first))
        @test !isfile(joinpath(dirname(second), "analysis.h5"))

        reference_root = joinpath(directory, "uninterrupted")
        uninterrupted = execute_scientific_plan(plan, reference_root)
        reference = only(uninterrupted["points"])
        @test String(reference["quality"]) == point["quality"]
        @test checkpoint_contents(joinpath(root, point["data"]["full_state"])) ==
              checkpoint_contents(joinpath(reference_root, reference["data"]["full_state"]))
        reference_path = joinpath(reference_root, reference["data"]["result_commit"])
        history = scba_history(joinpath(dirname(terminal_path), "history.h5"))
        @test history["sequence"] == history["iteration"] == collect(1:5)
        @test isequal(history, scba_history(joinpath(dirname(reference_path), "history.h5")))
        h5open(joinpath(dirname(terminal_path), "history.h5"), "r") do file
            @test read(file["physical_markers/available"]) == Int8[1, 0, 0, 0, 1]
        end
        terminal = Runner.verify_point_artifacts(terminal_path)
        @test !terminal["scientific_accepted"]
    end
end
end
