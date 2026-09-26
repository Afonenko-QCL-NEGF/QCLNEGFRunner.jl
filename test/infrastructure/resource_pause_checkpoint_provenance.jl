module ResourcePauseCheckpointProvenance
include("../support/common.jl")
include("../support/native_physics_fixture.jl")
const S = QCLNEGFRunner.QCLScientificWorkflow
@testset "Pressure before a resumed attempt commits keeps verified source identity" begin
    seed = native_physics_fixture(; energy_nodes = 17)
    options = SolverOptions(max_scba = 1, max_poisson = 1)
    state = solve_scba_production(
        seed.problem,
        seed.Uᴴ;
        options,
        production_options = ProductionOptions(
            parallel_backend = :blas,
            worker_count = 1,
            progress_every_scba = 0,
            progress_every_outer = 0,
        ),
    )
    fixture = NEGFSolution(
        seed.problem,
        options,
        seed.Uᴴ,
        QCLNEGFRunner._electron_density_bar(seed.problem, state.green.Gˡ),
        state,
        OuterIteration[],
        Dict{Symbol,Any}(:restart_contract => state.restart_contract),
        seed.report,
        false,
        :running_scba,
    )
    mktempdir() do root
        first_directory = joinpath(root, "attempt-1")
        identity = Dict{String,Any}(
            "point_id"=>"point",
            "execution_id"=>"execution",
            "plan_fingerprint"=>"frozen-physics",
            "attempt"=>1,
        )
        commit_path = QCLNEGFRunner.commit_point_artifacts(first_directory, fixture; identity)
        commit = QCLNEGFRunner.verify_point_artifacts(commit_path)
        next_directory = joinpath(root, "attempt-2")
        data = S._scientific_pause_data(
            root,
            next_directory,
            commit_path,
            2;
            resource_pressure = true,
        )
        @test data["checkpoint_source_attempt"] == 1
        @test data["recovery_origin"] == "last_committed_before_resource_pause"
        @test data["pause_reason"] == "resource_pressure"
        @test data["artifact_root"] == "attempt-2"
        @test data["full_state"] ==
              relpath(joinpath(dirname(commit_path), "physics.h5"), root)
        old = (attempt = 2, status = :paused, data = data)
        point = (id = "point", execution_id = "execution")
        @test isnothing(
            S._scientific_validate_checkpoint_identity(
                commit,
                old,
                point,
                "frozen-physics",
            ),
        )
        # The next attempt loads the same canonical physical state, carrying the
        # explicit source attempt through the actual restart reader.
        restart =
            load_production_restart(joinpath(root, data["full_state"]), fixture.problem)
        @test restart.scba.green.Gˡ == fixture.scba.green.Gˡ
        @test QCLNEGFRunner.verify_point_artifacts(commit_path)["identity"]["attempt"] == 1
        @test_throws ArgumentError S._scientific_validate_checkpoint_identity(
            commit,
            (attempt = 2, status = :completed, data = data),
            point,
            "frozen-physics",
        )
        @test_throws ArgumentError S._scientific_validate_checkpoint_identity(
            commit,
            old,
            (id = "another-point", execution_id = "execution"),
            "frozen-physics",
        )
        @test_throws ArgumentError S._scientific_pause_data(
            root,
            next_directory,
            commit_path,
            2,
        )
        cold = S._scientific_pause_data(
            root,
            next_directory,
            nothing,
            2;
            resource_pressure = true,
        )
        @test cold["resume_kind"] == "cold_start"
        @test !haskey(cold, "full_state") && !haskey(cold, "checkpoint_source_attempt")
        current = S._scientific_pause_data(
            root,
            first_directory,
            commit_path,
            1;
            resource_pressure = true,
        )
        @test !haskey(current, "checkpoint_source_attempt")
    end
end
end
