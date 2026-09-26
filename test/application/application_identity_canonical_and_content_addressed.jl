module Suite_T013
include("../support/common.jl")
include("../support/application_runtime.jl")

@testset "Application identity: canonical and content-addressed" begin
    # Checks that dictionary order and host integer width cannot change a run
    # id, while a scientific input change necessarily creates a new id.
    left = Dict("b" => [1, 2], "a" => Dict("x" => 0.5))
    right = Dict("a" => Dict("x" => 0.5), "b" => Int32[1, 2])
    @test canonical_bytes(left) == canonical_bytes(right)
    @test content_id("run", left) == content_id("run", right)
    @test content_id("run", left) !=
          content_id("run", Dict("b" => [1, 3], "a" => Dict("x" => 0.5)))
    @test_throws ArgumentError canonical_bytes(Dict("bad" => Inf))

    plan, definition = application_fixture()
    # This is the internal scientific runtime identity, not the scheduler job ID.
    @test !isempty(definition.identity.run_id)
    @test !occursin(r"[/\\]", definition.identity.run_id)
    @test point_count(plan) == 8
    points = planned_points(plan, definition.identity.run_id)
    @test length(points) == 8
    @test allunique(getfield.(points, :point_id))
    @test first(points).coordinates == [
        "method.profile" => "exact",
        "operating.temperature_K" => 250.0,
        "operating.voltage_V" => 0.040,
    ]

    relabelled = RunDefinition(
        plan;
        scientific_identity = definition.scientific_identity,
        software_identity = definition.software_identity,
        labels = Dict("title" => "Different display title"),
    )
    @test relabelled.identity.run_id == definition.identity.run_id

    reordered_plan = NestedSweepPlan(
        "reference2019_validation",
        SweepLevel(
            "method",
            [SweepAxis("profile", ["low_rank", "exact"])],
            SweepLevel(
                "operating",
                [
                    SweepAxis("voltage_V", [0.060, 0.040]),
                    SweepAxis("temperature_K", [300.0, 250.0]),
                ],
                SweepLeaf("poisson_scba"),
            ),
        ),
    )
    reordered = RunDefinition(
        reordered_plan;
        scientific_identity = definition.scientific_identity,
        software_identity = definition.software_identity,
    )
    @test reordered.identity.run_id == definition.identity.run_id
    @test Set(
        getfield.(planned_points(reordered_plan, reordered.identity.run_id), :point_id),
    ) == Set(getfield.(points, :point_id))
    @test_throws ArgumentError NestedSweepPlan(
        "invalid",
        SweepLevel(
            "same",
            [SweepAxis("axis", [1])],
            SweepLevel("same", [SweepAxis("axis", [2])], SweepLeaf()),
        ),
    )
end

end # independent suite
