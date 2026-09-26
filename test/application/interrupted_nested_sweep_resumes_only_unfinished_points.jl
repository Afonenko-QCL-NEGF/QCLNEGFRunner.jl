module Suite_T017
include("../support/common.jl")
using HDF5
include("../support/application_runtime.jl")

@testset "Interrupted nested sweep resumes only unfinished points" begin
    # Simulates a scheduler interruption after a committed iteration snapshot.
    # On resume, point 1 is skipped, point 2 receives the verified state, and
    # the not-yet-started point 3 executes normally. Results are hierarchical
    # YAML rather than CSV key/value rows.
    plan = NestedSweepPlan(
        "resume_test",
        SweepLevel("operating", [SweepAxis("bias_index", [1, 2, 3])], SweepLeaf("solve")),
    )
    definition = RunDefinition(
        plan;
        scientific_identity = Dict("physics" => "test-invariant"),
        software_identity = Dict("source" => repeat("c", 64)),
    )
    points = planned_points(plan, definition.identity.run_id)

    mktempdir() do directory
        repository = FilesystemRunRepository(directory)
        calls = Dict(1 => 0, 2 => 0, 3 => 0)
        first_runner = FunctionPointRunner() do context
            bias = Int(Dict(context.point.coordinates)["operating.bias_index"])
            calls[bias] += 1
            with_span(context.tracer, :physical, "SCBA_map"; core = "scba_map") do _
                record_iteration!(
                    context,
                    1,
                    10,
                    Dict("residual" => 1e-2);
                    state = Dict("bias" => bias, "iteration" => 1),
                )
            end
            bias == 2 && throw(SweepInterrupted("synthetic scheduler stop"))
            return PointExecutionResult(
                :completed;
                metadata = Dict("physical" => Dict("current_A_per_cm2" => 100.0 * bias)),
            )
        end

        budget = DiskBudgetModel(checkpoint_payload_bytes = 2048)
        @test_throws SweepInterrupted run_sweep!(
            repository,
            definition,
            first_runner;
            retention = IterationRetentionPolicy(snapshot_mode = :all),
            provenance = Dict("campaign" => "test"),
            disk_model = budget,
            iterations_per_point = 10,
        )
        @test calls == Dict(1 => 1, 2 => 1, 3 => 0)
        @test read_point_status(
            repository,
            definition.identity.run_id,
            points[1].point_id,
        )["status"] == "completed"
        @test read_point_status(
            repository,
            definition.identity.run_id,
            points[2].point_id,
        )["status"] == "interrupted"

        # Model a hard process kill: no catch/finally could replace `running`.
        stale =
            read_point_status(repository, definition.identity.run_id, points[2].point_id)
        stale["status"] = "running"
        stale["message"] = "simulated hard kill"
        write_point_status!(
            repository,
            definition.identity.run_id,
            points[2].point_id,
            stale,
        )

        saw_resume = Ref(false)
        second_runner = FunctionPointRunner() do context
            bias = Int(Dict(context.point.coordinates)["operating.bias_index"])
            calls[bias] += 1
            if bias == 2
                @test context.resume_checkpoint !== nothing
                @test context.resume_checkpoint.state["bias"] == 2
                @test context.resume_checkpoint.state["iteration"] == 1
                saw_resume[] = true
            end
            point_root = point_workspace_directory(
                context.repository,
                context.definition.identity.run_id,
                context.point.point_id,
            )
            artifact_path = joinpath(point_root, "artifacts", "state.txt")
            mkpath(dirname(artifact_path))
            write(artifact_path, "retained state for bias $bias\n")
            run_root = run_workspace_directory(
                context.repository,
                context.definition.identity.run_id,
            )
            artifact = Dict{String,Any}(
                "path" => replace(relpath(artifact_path, run_root), '\\' => '/'),
                "media_type" => "text/plain",
                "bytes" => filesize(artifact_path),
                "sha256" => file_sha256(artifact_path),
                "integrity_required" => true,
            )
            return PointExecutionResult(
                :completed;
                metadata = Dict("physical" => Dict("current_A_per_cm2" => 100.0 * bias)),
                artifacts = Dict("state" => artifact),
            )
        end
        summary = run_sweep!(
            repository,
            definition,
            second_runner;
            retention = IterationRetentionPolicy(snapshot_mode = :all),
            provenance = Dict("campaign" => "test"),
            resume = true,
            session_provenance = Dict("device" => "remote-server"),
            disk_model = budget,
            iterations_per_point = 10,
        )
        @test saw_resume[]
        @test calls == Dict(1 => 1, 2 => 2, 3 => 1)
        @test summary.status == :completed
        @test summary.completed == 3
        @test summary.skipped_completed == 1

        point_result =
            read_point_result(repository, definition.identity.run_id, points[2].point_id)
        @test point_result["result"]["physical"]["current_A_per_cm2"] == 200.0
        @test point_result["artifacts"]["state"]["integrity_required"]
        run_result = read_run_result(repository, definition.identity.run_id)
        @test run_result["result_format"] == "hierarchical_yaml"
        @test run_result["counts"]["completed"] == 3
        @test isfile(
            joinpath(
                run_directory(repository, definition.identity.run_id),
                "disk_estimate.yaml",
            ),
        )
        if Sys.isunix()
            run_status_path = joinpath(
                run_directory(repository, definition.identity.run_id),
                "status.yaml",
            )
            @test (stat(run_status_path).mode & 0o777) == 0o640
        end

        events = read_events(repository, definition.identity.run_id)
        @test any(event -> event["event"] == "point_skipped", events)
        @test any(event -> event["event"] == "point_recovered", events)
        @test any(event -> event["event"] == "iteration", events)
        @test any(event -> event["span_class"] == "physical", events)
        @test any(
            event ->
                event["event"] == "run_start" &&
                get(event["attributes"], "session_provenance", Dict()) ==
                Dict("device" => "remote-server"),
            events,
        )

        # Completed-result resume is a certificate for every artifact that
        # opted into integrity verification, not only for result.yaml.
        retained = joinpath(
            point_workspace_directory(
                repository,
                definition.identity.run_id,
                points[2].point_id,
            ),
            "artifacts",
            "state.txt",
        )
        write(retained, "tampered\n")
        never_called = FunctionPointRunner(
            _ -> error("completed points must be verified before runner invocation"),
        )
        @test_throws ArtifactIntegrityError run_sweep!(
            repository,
            definition,
            never_called;
            resume = true,
            provenance = Dict("campaign" => "test"),
        )

        completed_result_path = joinpath(
            run_directory(repository, definition.identity.run_id),
            "points",
            points[1].point_id,
            "result.yaml",
        )
        open(completed_result_path, "a") do stream
            write(stream, "\n# modified after completion\n")
        end
        never_run = FunctionPointRunner(_ -> error("must be skipped"))
        @test_throws ArgumentError run_sweep!(
            repository,
            definition,
            never_run;
            provenance = Dict("campaign" => "test"),
            resume = true,
        )
    end
end

end # independent suite
