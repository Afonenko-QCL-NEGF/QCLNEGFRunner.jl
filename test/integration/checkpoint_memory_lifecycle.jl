module CheckpointMemoryLifecycle
include("../support/common.jl")
include("../support/native_physics_fixture.jl")
using HDF5
using YAML

function write_accounting(
    group;
    current,
    file = 0,
    inactive_file = 0,
    shmem = 0,
    file_dirty = 0,
    file_writeback = 0,
    file_mapped = 0,
)
    write(joinpath(group, "memory.current"), string(current))
    open(joinpath(group, "memory.stat"), "w") do io
        for (name, value) in
            pairs((; file, inactive_file, shmem, file_dirty, file_writeback, file_mapped))
            println(io, name, " ", value)
        end
    end
end

@testset "Ordinary phases retain external controls without a software fit claim" begin
    mktempdir() do root
        group=mkpath(joinpath(root,"group"))
        write(joinpath(group,"memory.max"),"1000")
        request=(name=:test,iteration=1,memory_burst_bytes=200,task_width=1)
        for current in (700,900)
            write(joinpath(group,"memory.current"),string(current))
            @test isnothing(QCLNEGFRunner._native_phase_memory_permit!(root,[group],request))
            admission=QCLNEGFRunner._NATIVE_PHASE_ADMISSIONS[root]
            @test admission==Dict("memory_admission_mode"=>"external_controls_not_predicted_fit")
            @test !isfile(joinpath(root,"resource-pressure.json"))
        end
        pop!(QCLNEGFRunner._NATIVE_PHASE_ADMISSIONS,root,nothing)
    end
end

@testset "Real checkpoint, test-owned interruption, exact restart, next checkpoint" begin
    fixture=native_physics_fixture(; energy_nodes = 33)
    options=SolverOptions(
        max_scba = 5,
        max_poisson = 1,
        convergence = ConvergencePolicy(
            required_consecutive_scba_passes = 99,
            stagnation_window = 0,
            stagnation_relative_improvement = 0.0,
        ),
    )
    base=ProductionOptions(
        parallel_backend = :blas,
        worker_count = 1,
        checkpoint_every_scba = 1,
        checkpoint_every_outer = 0,
        progress_every_scba = 0,
        progress_every_outer = 0,
        physics_markers = SCBAPhysicsMarkerPolicy(cadence = 1),
    )
    uninterrupted=solve_scba_production(
        fixture.problem,
        fixture.Uᴴ;
        options,
        production_options = base,
    )
    mktempdir() do root
        group=mkpath(joinpath(root, "group"))
        machine=mkpath(joinpath(root, "machine"))
        write(joinpath(group, "memory.max"), "100000000")
        write_accounting(group; current = 1000000)
        saved=Ref{Union{Nothing,String}}(nothing)
        visited=Int[]
        snapshot(state) = NEGFSolution(
            fixture.problem,
            options,
            fixture.Uᴴ,
            QCLNEGFRunner._electron_density_bar(fixture.problem, state.green.Gˡ),
            state,
            OuterIteration[],
            Dict{Symbol,Any}(:restart_contract=>state.restart_contract),
            fixture.report,
            false,
            :running_scba,
        )
        proc = mkpath(joinpath(root, "proc", "self"))
        write(joinpath(proc, "cgroup"), "0::/group")
        identity=Dict("run_id"=>"run","execution_id"=>"execution","point_id"=>"point",
            "attempt"=>"1","branch_id"=>"branch","model_sha256"=>"a"^64,"plan_sha256"=>"b"^64)
        observer=QCLNEGFRunner._start_phase_observer(joinpath(machine,"phases");artifact_root=root,
            identity,source_session="interruption",policy=QCLNEGFRunner._normal_phase_policy(256),capacity_events=256)
        primary=nothing
        try
            production=QCLNEGFRunner.with_production_options(
                base;
                phase_request = QCLNEGFRunner._native_phase_request(machine; proc_root = dirname(proc), cgroup_root = root),
                phase_timing = true,
                event_sink = event->QCLNEGFRunner._record_native_phase!(observer, event),
            )
            interruption=ErrorException("test-owned interruption after iteration 3")
            function checkpoint_then_interrupt(state)
                iteration=last(state.history).ν
                push!(visited, iteration)
                if iteration==2
                    saved[]=QCLNEGFRunner.commit_point_artifacts(
                        joinpath(root, "attempt-1"),
                        snapshot(state),
                    )
                elseif iteration==3
                    # An explicit fixture interruption, not resource admission.
                    throw(interruption)
                end
            end
            caught=try
                solve_scba_production(
                    fixture.problem,
                    fixture.Uᴴ;
                    options,
                    production_options = production,
                    iteration_callback = checkpoint_then_interrupt,
                )
                nothing
            catch error
                error
            end
            @test caught===interruption
            @test 3 in visited
            first_commit=QCLNEGFRunner.verify_point_artifacts(saved[])
            @test first_commit["restart_coordinates"]["last_inner"]==2
            @test first_commit["restart_coordinates"]["outer_iteration"]==1
            @test first_commit["restart_coordinates"]["domain_revision"]==0
            restored=load_production_restart(
                joinpath(dirname(saved[]), "physics.h5"),
                fixture.problem;
                solver_options = options,
            )
            write_accounting(group; current = 1000000)
            final_commit=Ref{Union{Nothing,String}}(nothing)
            resumed=solve_scba_production(
                fixture.problem,
                restored.Uᴴ;
                options,
                production_options = production,
                initial = restored.scba,
                consume_initial = true,
                resume_iterations = true,
                iteration_callback = state->begin
                    if last(state.history).ν==4
                        final_commit[]=QCLNEGFRunner.commit_point_artifacts(
                            joinpath(root, "attempt-2"),
                            snapshot(state),
                        )
                    end
                end,
            )
            @test resumed.green.Gᴿ==uninterrupted.green.Gᴿ
            @test resumed.green.Gˡ==uninterrupted.green.Gˡ
            @test [row.ν for row in resumed.history]==collect(1:5)
            @test QCLNEGFRunner.verify_point_artifacts(final_commit[])["restart_coordinates"]["last_inner"]==4
            @test QCLNEGFRunner._NATIVE_PHASE_ADMISSIONS[machine]==
                Dict("memory_admission_mode"=>"external_controls_not_predicted_fit")
            @test !isfile(joinpath(machine,"resource-pressure.json"))
        catch error
            primary=error
            rethrow()
        finally
            try
                QCLNEGFRunner._close_phase_observer!(observer)
                done=timedwait(()->istaskdone(observer.task),10;pollint=.01)==:ok
                @test done
                if done
                    fetch(observer.task) # task failure is distinct from task completion
                    @test !observer.failed[] # the worker reports caught IO failure here
                    lock(QCLNEGFRunner._PHASE_RESIDENCY_LOCK) do
                        QCLNEGFRunner._phase_reap_locked!()
                    end
                end
            catch secondary
                primary===nothing && rethrow()
                @error "Observer teardown failed after primary fixture failure" exception=(secondary,catch_backtrace())
            finally
                pop!(QCLNEGFRunner._NATIVE_PHASE_ADMISSIONS,machine,nothing)
            end
        end
    end
end

@testset "Reused serialization slabs preserve ragged multidimensional values" begin
    mktempdir() do root
        for shape in ((131073, 3), (31, 13, 7, 3), (3, 5, 2, 7, 3, 11))
            values=reshape(ComplexF64.(1:prod(shape), -(1:prod(shape))), shape)
            HDF5.h5open(joinpath(root, "slabs.h5"), "w") do file
                QCLNEGFRunner._write_complex(file, "array", values)
            end
            HDF5.h5open(joinpath(root, "slabs.h5"), "r") do file
                @test QCLNEGFRunner._read_complex(file, "array")==values
            end
        end
    end
end
end
