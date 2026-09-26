module Suite_T014
include("../support/common.jl")
using HDF5
include("../support/application_runtime.jl")

@testset "Retention and viewer downsampling preserve durable data" begin
    # Scalar events are not downsampled by this API; only state snapshots and
    # the returned viewer series follow their separate declarative policies.
    policy = IterationRetentionPolicy(
        snapshot_mode = :stride,
        snapshot_stride = 10,
        keep_first = 2,
        keep_last = 2,
    )
    @test should_retain_snapshot(policy, 1; total = 100)
    @test should_retain_snapshot(policy, 20; total = 100)
    @test !should_retain_snapshot(policy, 21; total = 100)
    @test should_retain_snapshot(policy, 99; total = 100)
    @test retained_snapshot_count(policy, 100) == 13

    x = collect(1.0:1000.0)
    y = sin.(x ./ 20)
    y[477] = 12.0
    reduced = downsample_series(
        x,
        y,
        DisplayDownsamplingPolicy(max_points = 60, strategy = :lttb),
    )
    @test length(reduced.indices) == 60
    @test first(reduced.indices) == 1
    @test last(reduced.indices) == 1000
    @test 477 in reduced.indices

    plan, _ = application_fixture()
    model = DiskBudgetModel(
        checkpoint_payload_bytes = 10_000_000,
        event_bytes = 1_000,
        fixed_run_bytes = 50_000,
        safety_factor = 1.5,
    )
    estimate = estimate_disk(plan, model, policy; iterations_per_point = 100)
    @test estimate.point_count == 8
    @test estimate.snapshots_per_point == 13
    @test estimate.components["iteration_events"] == 800_000
    @test estimate.estimated_bytes == ceil(Int, estimate.subtotal_bytes * 1.5)
end

end # independent suite
