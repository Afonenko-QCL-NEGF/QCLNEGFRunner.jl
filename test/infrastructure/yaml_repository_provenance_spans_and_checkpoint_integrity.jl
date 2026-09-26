module Suite_T015
include("../support/common.jl")
using HDF5
include("../support/application_runtime.jl")

@testset "YAML repository, provenance, spans, and checkpoint integrity" begin
    # Checks immutable provenance, append-only typed events, separate physical
    # and software spans, aggregate core timing, and fail-closed payload hashes.
    _, definition = application_fixture()
    mktempdir() do directory
        repository = FilesystemRunRepository(directory)
        @test !initialize_run!(repository, definition)
        @test initialize_run!(repository, definition)

        provenance = Dict(
            "git" => Dict("commit" => repeat("b", 40)),
            "hardware" => Dict("threads" => 12),
        )
        path = write_provenance!(repository, definition.identity.run_id, provenance)
        @test isfile(path)
        @test write_provenance!(repository, definition.identity.run_id, provenance) == path
        @test_throws ArgumentError write_provenance!(
            repository,
            definition.identity.run_id,
            Dict("git" => "changed"),
        )

        clock = Ref(0)
        tracer = RuntimeTracer(
            repository,
            definition.identity.run_id;
            monotonic_clock_ns = () -> (clock[] += 1_000_000_000),
            wall_clock_seconds = () -> 1_700_000_000.0 + clock[] * 1e-9,
        )
        with_span(tracer, :software, "orchestration") do _
            with_span(tracer, :physical, "Dyson"; core = "dyson") do _
                nothing
            end
        end
        timing = flush_timing_summary!(tracer)
        @test timing["session_count"] == 1
        @test timing["cores"]["dyson"]["calls"] == 1
        events = read_events(repository, definition.identity.run_id)
        @test length(events) == 4
        @test Set(event["span_class"] for event in events) == Set(["software", "physical"])

        point = first(planned_points(definition.plan, definition.identity.run_id))
        write_point_result!(
            repository,
            definition.identity.run_id,
            point.point_id,
            Dict("metric" => NaN),
        )
        tagged_nan =
            read_point_result(repository, definition.identity.run_id, point.point_id)["metric"]
        @test tagged_nan["__reference2019_nonfinite_float__"] == "nan"
        checkpoint = save_runtime_checkpoint!(
            repository,
            YamlCheckpointCodec(),
            definition.identity.run_id,
            point.point_id,
            1,
            Dict("iteration" => 7, "U_H" => [1.0, 2.0]);
            iteration = 7,
        )
        loaded = load_latest_checkpoint(
            repository,
            YamlCheckpointCodec(),
            definition.identity.run_id,
            point.point_id,
        )
        @test loaded.reference.sha256 == checkpoint.sha256
        @test loaded.state["iteration"] == 7
        orphan = joinpath(dirname(checkpoint.payload_path), "000000000002.payload.yaml")
        open(orphan, "w") do stream
            write(stream, "orphan: true\n")
        end
        after_orphan = save_runtime_checkpoint!(
            repository,
            YamlCheckpointCodec(),
            definition.identity.run_id,
            point.point_id,
            1,
            Dict("iteration" => 8);
            iteration = 8,
        )
        @test after_orphan.generation == 3
        wrong_codec =
            CallbackCheckpointCodec("h5", (path, state) -> nothing, path -> nothing)
        @test_throws CheckpointIntegrityError load_latest_checkpoint(
            repository,
            wrong_codec,
            definition.identity.run_id,
            point.point_id,
        )
        open(after_orphan.payload_path, "a") do stream
            write(stream, "\ncorruption")
        end
        @test_throws CheckpointIntegrityError load_latest_checkpoint(
            repository,
            YamlCheckpointCodec(),
            definition.identity.run_id,
            point.point_id,
        )
    end
end

end # independent suite
