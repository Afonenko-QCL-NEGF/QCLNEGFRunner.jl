module Suite_T029
include("../support/common.jl")

@testset "Unified configured execution budget" begin
    project_root = normpath(joinpath(TEST_ROOT, ".."))
    config_root = joinpath(project_root, "test", "fixtures", "configurations")
    single = load_run_configuration(joinpath(config_root, "exact_cpu.yaml"))
    reference =
        load_run_configuration(joinpath(config_root, "studies-pilot_reference.yaml"))
    production =
        load_run_configuration(joinpath(config_root, "studies-pilot_production.yaml"))

    @test DEFAULT_MAXIMUM_SOLVER_RUNS == 16
    @test planned_solver_runs(single) == 1
    @test planned_solver_runs(reference) == 2
    @test planned_solver_runs(production) == 3
    @test QCLNEGFRunner._check_solver_run_budget(single, 1) == 1
    @test QCLNEGFRunner._check_solver_run_budget(reference, 2) == 2
    @test QCLNEGFRunner._check_solver_run_budget(production, 3) == 3
    @test_throws ArgumentError QCLNEGFRunner._check_solver_run_budget(single, 0)
    @test_throws ArgumentError QCLNEGFRunner._check_solver_run_budget(reference, 1)
    @test_throws ArgumentError QCLNEGFRunner._check_solver_run_budget(production, 2)

    # Exercise the public resource-planning contract. CLI behavior is covered
    # separately by the fresh-process plan entrypoint scenario.
    bounded_source = joinpath(config_root, "naive_oracle.yaml")
    resource = configured_resource_plan(
        load_run_configuration(bounded_source),
        bounded_source;
        run_benchmark = false,
    )
    @test resource.plan isa ExecutionPlan
    @test 0 <= resource.plan.worker_count <= resource.plan.contraction_jobs
    @test resource.campaign["resolved_case_count"] >= 1
    @test resource.campaign["maximum_estimated_peak_bytes"] > 0
    @test resource.calibration.mode === :analytical
    mktempdir() do directory
        report = joinpath(directory, "resources.json")
        save_resource_diagnostics(
            report,
            resource.plan;
            calibration = resource.calibration,
            campaign = resource.campaign,
        )
        @test isfile(report)
        @test filesize(report) > 0
    end

end

end # independent suite
