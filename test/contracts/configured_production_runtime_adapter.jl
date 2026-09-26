module Suite_T090
include("../support/common.jl")
using HDF5

@testset "Configured production runtime adapter" begin
    # Checks only orchestration contracts: the adapter must create a genuine
    # temperature -> voltage tree and one-point configurations without
    # allocating grids, scattering kernels, or running the solver.
    root = normpath(joinpath(TEST_ROOT, ".."))
    base = load_run_configuration(
        joinpath(root, "test", "fixtures", "configurations", "exact_cpu.yaml"),
    )
    @test QCLProductionPointRunner(base).configuration === base

    generic_runtime = join(
        vcat(
            [read(joinpath(root, "src", "composition", "application_runtime.jl"), String)],
            [
                read(joinpath(root, "src", "application", file), String) for
                file in ("contracts.jl", "events.jl", "coordinator.jl")
            ],
        ),
        "\n",
    )
    adapter_source =
        read(joinpath(root, "src", "composition", "production_runtime_adapter.jl"), String)
    configured_source =
        read(joinpath(root, "src", "composition", "configured_run.jl"), String)
    @test !occursin("run_from_configuration", generic_runtime)
    @test !occursin("NEGFProblem", generic_runtime)
    @test occursin("run_from_configuration", adapter_source)
    @test !occursin("reference2019-legacy-hdf5-reference", adapter_source)
    @test !occursin("_runtime_legacy_checkpoint", adapter_source)
    @test !occursin("legacy_dashboard", adapter_source)
    @test !occursin("MA/m^2", adapter_source)
    @test !occursin("progress_observer", configured_source)
    @test !occursin("configured_problem_observer", configured_source)
    @test occursin("solver_event_observer", configured_source)
    @test occursin(r"incompatible_checkpoint\s*=\s*:error", configured_source)
    @test !occursin("incompatible_checkpoint::Symbol", configured_source)

    study = StudyConfiguration(
        :sweep,
        typeof(1.0u"V")[0.040u"V", 0.060u"V"],
        typeof(1.0u"K")[200.0u"K", 300.0u"K"],
        String[],
        nothing,
        StudyMethodConfiguration[],
        1,
        base.study.calculate_optical_response,
        base.study.photon_energy_min,
        base.study.photon_energy_max,
        base.study.photon_energy_points,
        base.study.optical_edge_tolerance,
        ConvergenceStudyConfiguration(Int[], Int[], Int[], Int[]),
    )
    raw = deepcopy(base.raw)
    raw["study"]["mode"] = "sweep"
    raw["study"]["voltages_per_period"] = ["40 mV", "60 mV"]
    raw["study"]["temperatures"] = ["200 K", "300 K"]
    configuration = ResolvedRunConfiguration(
        base.name,
        base.description,
        base.classification,
        base.physical,
        base.numerical,
        base.scales,
        base.scattering,
        base.solver,
        base.production,
        base.kernels,
        base.algorithms,
        base.execution,
        base.output,
        study,
        base.provenance,
        raw,
    )

    plan = configured_nested_sweep_plan(configuration)
    @test point_count(plan) == 4
    definition = configured_nested_run_definition(configuration)
    points = planned_points(plan, definition.identity.run_id)
    @test first(points).coordinates ==
          ["temperature.temperature_K" => 200.0, "voltage.voltage_per_period_V" => 0.040]
    @test last(points).coordinates ==
          ["temperature.temperature_K" => 300.0, "voltage.voltage_per_period_V" => 0.060]
    @test definition.scientific_identity["solver_backend"] == "production"
    @test definition.scientific_identity["physical"]["type"] == "PhysicalParameters"
    field_unit = definition.scientific_identity["physical"]["fields"]["F_bias"]["unit"]
    @test field_unit isa String
    @test occursin("V", field_unit)
    @test definition.scientific_identity["production_validation"] ==
          Dict("verify_fft_roundoff" => configuration.production.verify_fft_roundoff)
    @test !haskey(definition.scientific_identity, "output")

    relocated_raw = deepcopy(raw)
    relocated_raw["output"]["directory"] = "another/device/path"
    relocated = ResolvedRunConfiguration(
        base.name,
        base.description,
        base.classification,
        base.physical,
        base.numerical,
        base.scales,
        base.scattering,
        base.solver,
        base.production,
        base.kernels,
        base.algorithms,
        base.execution,
        QCLNEGFRunner._output_with_directory(base.output, "another/device/path"),
        study,
        base.provenance,
        relocated_raw,
    )
    @test configured_nested_run_definition(relocated).identity.run_id ==
          definition.identity.run_id

    changed_output_raw = deepcopy(raw)
    changed_output_raw["output"]["save_csv"] = !base.output.save_csv
    changed_output = QCLNEGFRunner._resolve_configuration(changed_output_raw, base.provenance)
    @test configured_nested_run_definition(changed_output).identity.run_id !=
          definition.identity.run_id
    @test haskey(
        configured_nested_run_definition(configuration).software_identity,
        "completion_policy",
    )

    changed_validation_raw = deepcopy(raw)
    changed_validation_raw["production"]["verify_fft_roundoff"] =
        !base.production.verify_fft_roundoff
    changed_validation = ResolvedRunConfiguration(
        base.name,
        base.description,
        base.classification,
        base.physical,
        base.numerical,
        base.scales,
        base.scattering,
        base.solver,
        QCLNEGFRunner.with_production_options(
            base.production;
            verify_fft_roundoff = !base.production.verify_fft_roundoff,
        ),
        base.kernels,
        base.algorithms,
        base.execution,
        base.output,
        study,
        base.provenance,
        changed_validation_raw,
    )
    @test configured_nested_run_definition(changed_validation).identity.run_id !=
          definition.identity.run_id

    changed_numerical_raw = deepcopy(raw)
    changed_numerical_raw["numerical"]["energy_nodes"] = base.numerical.N_E + 2
    changed_numerical = ResolvedRunConfiguration(
        base.name,
        base.description,
        base.classification,
        base.physical,
        QCLNEGFRunner._numerical_with_axis(
            base.numerical,
            :energy_nodes,
            base.numerical.N_E + 2,
        ),
        base.scales,
        base.scattering,
        base.solver,
        base.production,
        base.kernels,
        base.algorithms,
        base.execution,
        base.output,
        study,
        base.provenance,
        changed_numerical_raw,
    )
    @test configured_nested_run_definition(changed_numerical).identity.run_id !=
          definition.identity.run_id

    # A stale/tampered raw tree used to be emitted even though content identity
    # and the solver used the typed fields. It must now fail before an existing
    # completed run can be selected by that identity.
    mismatched_raw = deepcopy(raw)
    mismatched_raw["numerical"]["energy_nodes"] = base.numerical.N_E + 2
    mismatched = ResolvedRunConfiguration(
        base.name,
        base.description,
        base.classification,
        base.physical,
        base.numerical,
        base.scales,
        base.scattering,
        base.solver,
        base.production,
        base.kernels,
        base.algorithms,
        base.execution,
        base.output,
        study,
        base.provenance,
        mismatched_raw,
    )
    @test_throws ArgumentError configured_nested_run_definition(mismatched)
    @test_throws ArgumentError QCLProductionPointRunner(mismatched)

    # Checks that the solver-facing adapter narrows the configured workflow to
    # exactly one point and writes only below the content-addressed point.
    runner = QCLProductionPointRunner(configuration)
    mktempdir() do directory
        point_configuration = QCLNEGFRunner._configured_point_configuration(
            runner,
            first(points),
            joinpath(directory, "artifacts"),
        )
        @test point_configuration.study.mode === :single
        @test point_configuration.study.temperatures == typeof(1.0u"K")[200.0u"K"]
        @test point_configuration.study.voltages_per_period == typeof(1.0u"V")[0.040u"V"]
        @test point_configuration.output.directory == joinpath(directory, "artifacts")
        @test isempty(point_configuration.study.comparison_profiles)
        @test isempty(point_configuration.study.methods)
    end

    record = ProductionSweepRecord(
        200.0,
        0.040,
        7.5e5,
        2.0e7,
        true,
        :converged,
        :strictly_converged,
        4,
        21,
        1_000_000,
        12.5,
        Dict(:dyson => 1.0e-9),
        "state.h5",
    )
    metadata = QCLNEGFRunner._runtime_point_metadata(record)
    @test metadata["convergence"]["scba_quality"] == "strictly_converged"
    @test metadata["observables"]["electron_flow_current_density"] ==
          Dict("value" => 2.0e3, "unit" => "A/cm^2")
    @test metadata["convergence"]["residuals"]["dyson"]["unit"] == "1"
    @test metadata["performance"]["estimated_peak_memory"]["unit"] == "byte"

    mktempdir() do directory
        output = joinpath(directory, "artifacts")
        mkpath(output)
        yaml_names = (
            "resolved_configuration",
            "execution_plan",
            "output_policy",
            "algorithm_manifest",
            "optimization_catalog",
            "configuration_provenance",
        )
        for name in yaml_names
            write(joinpath(output, "$name.yaml"), "fixture: true\n")
        end
        summary = joinpath(output, "sweep_summary.csv")
        progress = joinpath(output, "progress.csv")
        dashboard = joinpath(output, "live.html")
        checkpoint = joinpath(output, "state.h5")
        for path in (summary, progress, dashboard, checkpoint)
            write(path, "fixture")
        end
        optical = joinpath(output, "optical_T1_V1.csv")
        diagnostics = joinpath(output, "kernel_diagnostics.csv")
        write(optical, "energy_eV,gain_per_cm\n")
        write(diagnostics, "mechanism,error\n")
        fixture_result = (
            output_directory = output,
            sweep = (summary_path = summary,),
            progress_csv = progress,
            live_dashboard = dashboard,
        )
        fixture_record = ProductionSweepRecord(
            200.0,
            0.040,
            7.5e5,
            2.0e7,
            true,
            :converged,
            :strictly_converged,
            4,
            21,
            1_000_000,
            12.5,
            Dict(:dyson => 1.0e-9),
            checkpoint,
        )
        artifacts =
            QCLNEGFRunner._runtime_point_artifacts(fixture_result, fixture_record, directory)
        @test all(haskey(artifacts, name) for name in yaml_names)
        @test all(
            artifacts[name]["media_type"] == "application/yaml" for name in yaml_names
        )
        @test artifacts["checkpoint"]["media_type"] == "application/x-hdf5"
        @test artifacts["progress_dashboard"]["media_type"] == "text/html"
        @test artifacts["progress_events"]["media_type"] == "text/csv"
        @test artifacts["output:optical_T1_V1.csv"]["media_type"] == "text/csv"
        @test artifacts["output:kernel_diagnostics.csv"]["media_type"] == "text/csv"
        @test all(
            occursin(r"^[0-9a-f]{64}$", artifact["sha256"]) for
            artifact in values(artifacts)
        )
    end

    _, optical = QCLNEGFRunner._runtime_metric_trees(
        Dict(:gain_peak_per_cm => 18.0, :gain_peak_energy_eV => 0.0165),
    )
    @test optical["gain_peak_per_cm"]["unit"] == "cm^-1"
    @test optical["gain_peak_energy_eV"]["unit"] == "eV"
    @test_throws ArgumentError QCLNEGFRunner._runtime_metric_trees(
        Dict(:unclassified_metric => 1.0),
    )

    # Retention is opt-in. Restart tests explicitly request it while the
    # shipped configuration remains usable without heavy binary artifacts.
    @test !configuration.output.save_full_state
    @test !configuration.output.resume
    @test QCLNEGFRunner._runtime_checkpoint_path(configuration, "unused") === nothing
    checkpoint_raw = deepcopy(configuration.raw)
    checkpoint_raw["output"]["save_full_state"] = true
    checkpoint_raw["output"]["resume"] = true
    checkpoint_configuration =
        QCLNEGFRunner._resolve_configuration(checkpoint_raw, configuration.provenance)
    checkpoint_definition = configured_nested_run_definition(checkpoint_configuration)
    checkpoint_points = planned_points(
        configured_nested_sweep_plan(checkpoint_configuration),
        checkpoint_definition.identity.run_id,
    )

    # The canonical neutral SolverEvent stream is bridged synchronously into
    # real runtime physical spans and one durable scalar event per iteration.
    mktempdir() do directory
        runtime = QCLApplicationRuntime
        repository = FilesystemRunRepository(directory)
        runtime.initialize_run!(repository, checkpoint_definition)
        tracer = RuntimeTracer(repository, checkpoint_definition.identity.run_id)
        context = PointExecutionContext(
            checkpoint_definition,
            first(checkpoint_points),
            1,
            repository,
            YamlCheckpointCodec(),
            tracer,
            IterationRetentionPolicy(),
            nothing,
        )
        bridge = QCLNEGFRunner._RuntimeSolverEventBridge(context)
        observe(event) = QCLNEGFRunner._observe_runtime_solver_event!(bridge, event)
        observe(
            SolverEvent(:begin, :poisson, "Hartree", :running, 0, 2, SolverMetric[], ""),
        )
        observe(SolverEvent(:begin, :scba, "SCBA", :running, 0, 2, SolverMetric[], ""))
        observe(
            SolverEvent(
                :progress,
                :scba,
                "",
                :running,
                1,
                2,
                SolverMetric[
                    SolverMetric(:J, 200.0, "A/cm^2"),
                    SolverMetric(:r_Σ, 1.0e-4),
                    SolverMetric(:t_dyson, 0.25, "s"),
                ],
                "",
            ),
        )
        observe(SolverEvent(:end, :scba, "", :completed, 1, 2, SolverMetric[], ""))
        observe(
            SolverEvent(
                :progress,
                :poisson,
                "",
                :running,
                1,
                2,
                SolverMetric[SolverMetric(:r_P, 2.0e-5)],
                "",
            ),
        )
        observe(SolverEvent(:end, :poisson, "", :completed, 1, 2, SolverMetric[], ""))

        events = runtime.read_events(repository, checkpoint_definition.identity.run_id)
        iterations = filter(event -> event["event"] == "iteration", events)
        @test length(iterations) == 2
        scba_event =
            only(filter(event -> haskey(event["attributes"]["metrics"], "r_Σ"), iterations))
        scba_metrics = scba_event["attributes"]["metrics"]
        @test scba_metrics["current_A_per_cm2"] == 200.0
        @test scba_metrics["current_A_per_cm2_unit"] == "A/cm^2"
        @test scba_metrics["r_Σ_unit"] == "1"
        @test scba_metrics["t_dyson_unit"] == "s"
        @test any(
            event -> event["event"] == "span_start" && event["name"] == "Poisson",
            events,
        )
        @test any(
            event -> event["event"] == "span_start" && event["name"] == "SCBA",
            events,
        )
        @test_throws ArgumentError QCLNEGFRunner._runtime_progress_metrics(
            SolverMetric[SolverMetric(:J, 2.0, "MA/m^2")],
        )

        # Production runtime checkpoints use one contract: the generic
        # checksum envelope contains the current HDF5 payload directly.
        point_root = joinpath(
            runtime.run_directory(repository, checkpoint_definition.identity.run_id),
            "points",
            first(checkpoint_points).point_id,
        )
        output = joinpath(point_root, "artifacts")
        mkpath(output)
        checkpoint_path =
            QCLNEGFRunner._runtime_checkpoint_path(checkpoint_configuration, output)
        function current_hdf5_fixture(
            path;
            marker = "initial",
            schema = QCLNEGFRunner._CHECKPOINT_SCHEMA_VERSION,
        )
            HDF5.h5open(path, "w") do file
                metadata = HDF5.create_group(file, "metadata")
                HDF5.attributes(metadata)["package"] = QCLNEGFRunner._CHECKPOINT_PACKAGE
                HDF5.attributes(metadata)["contract_set"] = "qcl-negf.results.v1"
                HDF5.attributes(metadata)["schema_version"] = schema
                HDF5.attributes(metadata)["schema"] = "qcl-negf-checkpoint-v4"
                HDF5.attributes(metadata)["artifact_role"] = "recovery"
                HDF5.attributes(metadata)["fixture"] = marker
                convergence = HDF5.create_group(file, "convergence")
                QCLNEGFRunner._write_array(convergence, "scba", zeros(0, 18))
                QCLNEGFRunner._write_physical_markers!(convergence, SCBAIteration[])
                QCLNEGFRunner._write_psd_history!(convergence, SCBAIteration[])
            end
            return path
        end

        # A current but unenveloped artifact is not a recovery source.
        current_hdf5_fixture(checkpoint_path)
        codec = QCLNEGFRunner._runtime_production_checkpoint_codec()
        checkpoint_context = PointExecutionContext(
            checkpoint_definition,
            first(checkpoint_points),
            1,
            repository,
            codec,
            tracer,
            IterationRetentionPolicy(),
            nothing,
        )
        fresh = QCLNEGFRunner._runtime_prepare_checkpoint!(
            checkpoint_context,
            checkpoint_configuration,
            output,
        )
        @test !fresh.resume
        @test !isfile(checkpoint_path)

        current_hdf5_fixture(checkpoint_path; marker = "published")
        reference = QCLApplicationRuntime.checkpoint!(
            checkpoint_context,
            QCLNEGFRunner._RuntimeProductionCheckpointPayload(checkpoint_path);
            kind = QCLNEGFRunner._RUNTIME_PRODUCTION_CHECKPOINT_KIND,
            metadata = QCLNEGFRunner._runtime_checkpoint_metadata(nothing),
        )
        @test endswith(reference.payload_path, ".payload.h5")
        loaded = runtime.load_latest_checkpoint(
            repository,
            codec,
            checkpoint_definition.identity.run_id,
            first(checkpoint_points).point_id,
        )
        @test loaded.state isa QCLNEGFRunner._RuntimeProductionCheckpointPayload
        @test loaded.metadata["schema"] == runtime.RUNTIME_CHECKPOINT_SCHEMA
        @test loaded.metadata["payload_extension"] == "h5"
        @test loaded.reference.kind == QCLNEGFRunner._RUNTIME_PRODUCTION_CHECKPOINT_KIND
        @test loaded.metadata["metadata"]["payload_format"] ==
              QCLNEGFRunner._RUNTIME_PRODUCTION_CHECKPOINT_FORMAT
        @test loaded.metadata["metadata"]["payload_schema_version"] ==
              QCLNEGFRunner._CHECKPOINT_SCHEMA_VERSION

        # Only the verified payload is installed, replacing unrelated staging.
        write(checkpoint_path, "untrusted staging bytes")
        resumed_context = PointExecutionContext(
            checkpoint_definition,
            first(checkpoint_points),
            2,
            repository,
            codec,
            tracer,
            IterationRetentionPolicy(),
            loaded,
        )
        resumed = QCLNEGFRunner._runtime_prepare_checkpoint!(
            resumed_context,
            checkpoint_configuration,
            output,
        )
        @test resumed.resume
        @test QCLNEGFRunner._runtime_validate_current_hdf5_checkpoint(checkpoint_path) ==
              abspath(checkpoint_path)

        replacement = joinpath(output, "replacement.h5")
        current_hdf5_fixture(replacement; marker = "iteration-25")
        QCLNEGFRunner._atomic_replace_file(replacement, checkpoint_path)
        checkpoint_publisher = QCLNEGFRunner._RuntimeCheckpointPublisher(
            resumed_context;
            checkpoint_path,
            checkpoint_signature = resumed.signature,
        )
        checkpoint_begin =
            SolverEvent(:begin, :scba, "SCBA", :running, 0, 100, SolverMetric[], "")
        @test QCLNEGFRunner._runtime_publish_checkpoint!(
            checkpoint_publisher,
            checkpoint_begin,
        ) === nothing
        @test checkpoint_publisher.observed_signature == resumed.signature
        checkpoint_event =
            SolverEvent(:progress, :scba, "", :running, 25, 100, SolverMetric[], "")
        next_reference =
            QCLNEGFRunner._runtime_publish_checkpoint!(checkpoint_publisher, checkpoint_event)
        @test next_reference.generation == reference.generation + 1
        @test next_reference.kind == QCLNEGFRunner._RUNTIME_PRODUCTION_CHECKPOINT_KIND
        @test next_reference.iteration == 25

        old_schema_path = joinpath(output, "old-schema.h5")
        current_hdf5_fixture(old_schema_path; schema = "0.4")
        @test_throws CheckpointIntegrityError begin
            QCLNEGFRunner._runtime_read_production_checkpoint(old_schema_path)
        end

        unknown_state = QCLApplicationRuntime.LoadedCheckpoint(
            loaded.reference,
            Dict("schema" => "unknown"),
            loaded.metadata,
        )
        unknown_state_context = PointExecutionContext(
            checkpoint_definition,
            first(checkpoint_points),
            3,
            repository,
            codec,
            tracer,
            IterationRetentionPolicy(),
            unknown_state,
        )
        @test_throws CheckpointIntegrityError begin
            QCLNEGFRunner._runtime_prepare_checkpoint!(
                unknown_state_context,
                checkpoint_configuration,
                output,
            )
        end

        foreign_reference = QCLApplicationRuntime.CheckpointReference(
            reference.run_id,
            reference.point_id,
            reference.generation,
            reference.attempt,
            reference.payload_path,
            reference.metadata_path,
            reference.sha256,
            "unknown_reference",
            reference.iteration,
        )
        foreign = QCLApplicationRuntime.LoadedCheckpoint(
            foreign_reference,
            loaded.state,
            loaded.metadata,
        )
        foreign_context = PointExecutionContext(
            checkpoint_definition,
            first(checkpoint_points),
            4,
            repository,
            codec,
            tracer,
            IterationRetentionPolicy(),
            foreign,
        )
        @test_throws CheckpointIntegrityError begin
            QCLNEGFRunner._runtime_prepare_checkpoint!(
                foreign_context,
                checkpoint_configuration,
                output,
            )
        end
    end

    # A production call always writes a conservative disk estimate derived
    # from the resolved solver limits and array dimensions unless overridden.
    expected_iterations =
        (configuration.solver.max_poisson + 1) * configuration.solver.max_scba +
        configuration.solver.max_poisson
    @test QCLNEGFRunner._runtime_default_iterations_per_point(configuration) ==
          expected_iterations
    disk_model = QCLNEGFRunner._runtime_default_disk_model(configuration)
    @test disk_model.checkpoint_payload_bytes == 0
    @test disk_model.checkpoint_metadata_bytes > 0
    checkpoint_disk_model = QCLNEGFRunner._runtime_default_disk_model(checkpoint_configuration)
    @test checkpoint_disk_model.checkpoint_payload_bytes > 0
    @test checkpoint_disk_model.additional_artifacts_bytes_per_point >
          disk_model.additional_artifacts_bytes_per_point
    @test disk_model.additional_artifacts_bytes_per_point > 0

    # Checks fail-closed backend/mode selection rather than silently routing a
    # comparison campaign or the educational oracle through this adapter.
    educational_execution = ExecutionConfiguration(
        base.execution.strategy,
        :educational,
        base.execution.julia_threads,
        base.execution.blas_threads,
        base.execution.fail_on_thread_mismatch,
        base.execution.automatic,
    )
    educational = ResolvedRunConfiguration(
        base.name,
        base.description,
        base.classification,
        base.physical,
        base.numerical,
        base.scales,
        base.scattering,
        base.solver,
        base.production,
        base.kernels,
        base.algorithms,
        educational_execution,
        base.output,
        base.study,
        base.provenance,
        base.raw,
    )
    @test_throws ArgumentError QCLProductionPointRunner(educational)

    comparison_study = StudyConfiguration(
        :comparison,
        copy(base.study.voltages_per_period),
        copy(base.study.temperatures),
        ["exact_cpu"],
        "exact_cpu",
        [
            StudyMethodConfiguration(
                "exact_cpu",
                "Exact CPU",
                false,
                :exact_optimized,
                "constructor guard fixture",
                String[],
            ),
        ],
        1,
        base.study.calculate_optical_response,
        base.study.photon_energy_min,
        base.study.photon_energy_max,
        base.study.photon_energy_points,
        base.study.optical_edge_tolerance,
        base.study.convergence,
    )
    comparison = ResolvedRunConfiguration(
        base.name,
        base.description,
        :study,
        base.physical,
        base.numerical,
        base.scales,
        base.scattering,
        base.solver,
        base.production,
        base.kernels,
        base.algorithms,
        base.execution,
        base.output,
        comparison_study,
        base.provenance,
        base.raw,
    )
    @test_throws ArgumentError QCLProductionPointRunner(comparison)
end

end # independent suite
