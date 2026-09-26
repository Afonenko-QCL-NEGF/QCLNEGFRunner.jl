module Suite_T016
include("../support/common.jl")
using HDF5
include("../support/application_runtime.jl")

@testset "Fresh point verifies artifacts before completed status" begin
    plan = NestedSweepPlan("fresh_integrity", SweepLeaf("solve"))
    definition = RunDefinition(
        plan;
        scientific_identity = Dict("physics" => "integrity-fixture"),
        software_identity = Dict("source" => repeat("d", 64)),
    )
    mktempdir() do directory
        repository = FilesystemRunRepository(directory)
        runner = FunctionPointRunner() do _
            PointExecutionResult(
                :completed;
                artifacts = Dict(
                    "missing" => Dict{String,Any}(
                        "path" => "points/missing/artifacts/state.h5",
                        "media_type" => "application/x-hdf5",
                        "bytes" => 123,
                        "sha256" => repeat("0", 64),
                        "integrity_required" => true,
                    ),
                ),
            )
        end
        @test_throws ArtifactIntegrityError run_sweep!(repository, definition, runner)
        point = first(planned_points(plan, definition.identity.run_id))
        @test read_point_status(repository, definition.identity.run_id, point.point_id)["status"] ==
              "failed"
        @test_throws ArtifactIntegrityError verify_result_artifacts!(
            repository,
            definition.identity.run_id,
            Dict("untyped" => "points/unverified/state.h5"),
        )
    end
end

end # independent suite
