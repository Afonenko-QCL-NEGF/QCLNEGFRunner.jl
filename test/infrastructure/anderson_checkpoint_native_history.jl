module AndersonCheckpointNativeHistory
include("../support/common.jl")
using HDF5
include("../support/native_physics_fixture.jl")
struct DeliberateCheckpointStop <: Exception end

@testset "Anderson accepted-boundary restart retains the iteration trajectory" begin
    fixture=native_physics_fixture(; energy_nodes = 33)
    problem=fixture.problem
    algorithms=AlgorithmOptions(mixing = :anderson, anderson_history_depth = 3)
    production=ProductionOptions(
        algorithms = algorithms,
        parallel_backend = :blas,
        worker_count = 1,
        # Both trajectories measure every state. Checkpoint callbacks force
        # diagnostics as well, so unequal cadence would compare missing data
        # with additional observations rather than compare solver trajectories.
        physics_markers = SCBAPhysicsMarkerPolicy(cadence = 1),
        checkpoint_every_scba = 1,
        checkpoint_every_outer = 0,
        progress_every_scba = 0,
        progress_every_outer = 0,
    )
    options=SolverOptions(
        max_scba = 5,
        max_poisson = 1,
        convergence = ConvergencePolicy(
            required_consecutive_scba_passes = 99,
            stagnation_window = 0,
            stagnation_relative_improvement = 0.0,
        ),
    )
    uninterrupted=solve_scba_production(
        problem,
        fixture.Uᴴ;
        options,
        production_options = production,
    )
    @test length(uninterrupted.history)==5
    @test all(row->row.physical_markers!==nothing, uninterrupted.history)
    mktempdir() do directory
        checkpoint=joinpath(directory, "restart.h5")
        function interrupt(state)
            last(state.history).ν==3 || return
            snapshot=NEGFSolution(
                problem,
                options,
                fixture.Uᴴ,
                QCLNEGFRunner._electron_density_bar(problem, state.green.Gˡ),
                state,
                OuterIteration[],
                Dict{Symbol,Any}(),
                fixture.report,
                false,
                :running_scba,
            )
            save_checkpoint(checkpoint, snapshot; include_kernels = true, algorithms)
            throw(DeliberateCheckpointStop())
        end
        @test_throws DeliberateCheckpointStop solve_scba_production(
            problem,
            fixture.Uᴴ;
            options,
            production_options = production,
            iteration_callback = interrupt,
        )
        restored=load_production_restart(
            checkpoint,
            problem;
            algorithms,
            solver_options = options,
        )
        @test restored.scba.mixer_state.method==:anderson
        @test all(row->row.witness!==nothing, restored.scba.history)
        @test all(row->row.physical_markers!==nothing, restored.scba.history)
        for index in eachindex(restored.scba.history)
            actual=restored.scba.history[index].witness
            expected=uninterrupted.history[index].witness
            @test all(
                field->isequal(getfield(actual, field), getfield(expected, field)),
                fieldnames(QCLNEGFRunner.SCBAPhysicsWitness)[1:10],
            )
        end
        @test first(restored.scba.history).witness.matrices==first(uninterrupted.history).witness.matrices
        witness=last(restored.scba.history).witness
        @test !isempty(witness.matrices)
        @test witness.matrices["Gn_normalized_dimensionless"] ==
              -im .* QCLNEGFRunner._matrix_block(
            restored.scba.green.Gˡ,
            witness.energy_index,
            witness.momentum_index,
        )
        @test !isempty(restored.scba.mixer_state.states)
        @test length(restored.scba.mixer_state.states)==length(
            restored.scba.mixer_state.residuals,
        )
        continued=solve_scba_production(
            problem,
            restored.Uᴴ;
            options,
            production_options = production,
            initial = restored.scba,
            resume_iterations = true,
        )
        @test continued.green.Gᴿ==uninterrupted.green.Gᴿ
        @test continued.green.Gˡ==uninterrupted.green.Gˡ
        @test continued.embedding_plus.Σˡ==uninterrupted.embedding_plus.Σˡ
        @test isequal(
            [
                Tuple(getfield(row, f) for f in fieldnames(SCBAIteration) if f!==:witness)
                for row in continued.history
            ],
            [
                Tuple(getfield(row, f) for f in fieldnames(SCBAIteration) if f!==:witness)
                for row in uninterrupted.history
            ],
        )
    end
end

@testset "Lossless history exceeds old 3896-row quota across outer loops and resume" begin
    fixture=native_physics_fixture(; energy_nodes = 33)
    mktempdir() do directory
        identity=Dict{String,Any}("point_id"=>"p", "execution_id"=>"e", "attempt"=>1)
        scba_count=Ref(0)
        outer_count=Ref(0)
        recorder=QCLNEGFRunner.ScientificHistoryRecorder(
            joinpath(directory, "attempt-1"),
            identity,
            scba_count,
            outer_count;
            clock_ns = ()->UInt64(0),
        )
        row(i) = SCBAIteration(
            i,
            1e-3,
            1e-4,
            1e-5,
            1e-4,
            1e-4,
            1.0,
            0.0,
            0.0,
            0.0,
            NaN,
            NaN,
            3.0,
            1.0,
            1.0,
            1.0,
            NaN,
            nothing,
            nothing,
        )
        for (outer, limit) in ((1, 2000), (2, 1897)), inner = 1:limit
            QCLNEGFRunner.record_scientific_history!(
                recorder,
                :scba,
                outer,
                row(inner),
                fixture.problem,
            )
        end
        @test scba_count[]==3897
        @test !hasproperty(recorder, :scba_budget)
        QCLNEGFRunner.flush_scientific_history!(recorder)
        # A resumed attempt continues immutable sequence numbers; previous rows
        # are retained even though the new attempt starts its own segment index.
        stored_scba, stored_outer=QCLNEGFRunner.scientific_history_counts(directory)
        @test (stored_scba, stored_outer)==(3897, 0)
        resumed_identity=merge(identity, Dict("attempt"=>2))
        resumed=QCLNEGFRunner.ScientificHistoryRecorder(
            joinpath(directory, "attempt-2"),
            resumed_identity,
            Ref(stored_scba),
            Ref(stored_outer);
            clock_ns = ()->UInt64(0),
        )
        for inner = 1898:1900
            QCLNEGFRunner.record_scientific_history!(
                resumed,
                :scba,
                2,
                row(inner),
                fixture.problem,
            )
        end
        QCLNEGFRunner.flush_scientific_history!(resumed)
        paths=QCLNEGFRunner.scientific_history_sources(directory)
        @test length(paths)==5
        consolidated=QCLNEGFRunner.consolidate_scientific_history(
            joinpath(directory, "history.h5"),
            paths,
        )
        HDF5.h5open(consolidated, "r") do file
            @test read(file["scba/sequence"])==collect(1:3900)
            @test read(file["scba/outer_iteration"])==vcat(fill(1, 2000), fill(2, 1900))
            @test read(file["scba/iteration"])==vcat(collect(1:2000), collect(1:1900))
            @test all(isnan, read(file["scba/r_Jchange"]))
            @test read_attribute(file["metadata"], "scba_rows")==3900
        end
    end
end

@testset "Live history index exposes only durable closed segments on elapsed cadence" begin
    fixture=native_physics_fixture(; energy_nodes = 33)
    mktempdir() do directory
        identity=Dict{String,Any}(
            "point_id"=>"p",
            "execution_id"=>"e",
            "attempt"=>1,
            "plan_fingerprint"=>"f",
        )
        tick=Ref(UInt64(0))
        recorder=QCLNEGFRunner.ScientificHistoryRecorder(
            directory,
            identity,
            Ref(0),
            Ref(0);
            clock_ns = ()->tick[],
        )
        row=SCBAIteration(
            1,
            1e-3,
            1e-4,
            1e-5,
            1e-4,
            1e-4,
            1.0,
            0.0,
            0.0,
            0.0,
            NaN,
            NaN,
            3.0,
            1.0,
            1.0,
            1.0,
            NaN,
            nothing,
            nothing,
        )
        QCLNEGFRunner.record_scientific_history!(recorder, :scba, 1, row, fixture.problem)
        pointer=joinpath(directory, "history", "index.json")
        @test !isfile(pointer)
        tick[]=UInt64(31_000_000_000)
        QCLNEGFRunner.record_scientific_history!(recorder, :scba, 1, row, fixture.problem)
        index=QCLNEGFRunner.YAML.load_file(pointer)
        @test index["schema"]=="qcl-negf-scientific-history-index-v2"
        @test index["identity"]==identity
        @test index["generation"]==1
        @test index["scba_rows"]==2
        segment=only(index["segments"])
        path=joinpath(dirname(pointer), segment["path"])
        @test segment["bytes"]==filesize(path)
        @test segment["sha256"]==bytes2hex(open(QCLNEGFRunner.sha256, path))
        HDF5.h5open(path, "r") do file
            @test read(file["scba/sequence"])==[1, 2]
        end
        QCLNEGFRunner.flush_scientific_history!(recorder)
        @test QCLNEGFRunner.YAML.load_file(pointer)==index
    end
end
end
