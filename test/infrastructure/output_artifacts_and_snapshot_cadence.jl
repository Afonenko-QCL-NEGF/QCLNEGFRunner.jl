module Suite_T068
include("../support/common.jl")
using HDF5

@testset "Output artifacts and snapshot cadence" begin
    BN = QCLNEGFRunner
    configuration_root = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))
    base = load_run_configuration(joinpath(configuration_root, "base.yaml"))

    @test basename(BN._production_checkpoint_name("results", "custom", 2, 7)) ==
          "custom_T2_V7.h5"
    @test_throws ArgumentError BN._production_checkpoint_name("results", "../escape", 1, 1)

    labels = ["study", "point", "Poisson", "SCBA"]
    snapshot(iteration; event = :progress, total = 100) = ProgressSnapshot(
        iteration,
        event,
        [:study, :point, :poisson, :scba],
        labels,
        iteration,
        total,
        iteration / total,
        1.0,
        :running,
        "",
        ProgressMetric[],
    )
    @test BN._persist_progress_snapshot(base.output, snapshot(1; event = :begin))
    @test !BN._persist_progress_snapshot(base.output, snapshot(24))
    @test BN._persist_progress_snapshot(base.output, snapshot(25))
    @test BN._persist_progress_snapshot(base.output, snapshot(100))

    outer = ProgressSnapshot(
        1,
        :progress,
        [:study, :point, :poisson],
        ["study", "point", "Poisson"],
        3,
        100,
        0.03,
        1.0,
        :running,
        "",
        ProgressMetric[],
    )
    @test BN._persist_progress_snapshot(base.output, outer)

    no_csv_raw = deepcopy(base.raw)
    no_csv_raw["output"]["save_csv"] = false
    no_csv = BN._resolve_configuration(no_csv_raw, base.provenance)
    mktempdir() do directory
        BN._save_configuration_provenance(directory, no_csv)
        @test isfile(joinpath(directory, "resolved_configuration.yaml"))
        @test isfile(joinpath(directory, "output_policy.yaml"))
        @test isfile(joinpath(directory, "algorithm_manifest.yaml"))
        @test isfile(joinpath(directory, "optimization_catalog.yaml"))
        @test isfile(joinpath(directory, "configuration_provenance.yaml"))
        for legacy in (
            "algorithm_manifest.csv",
            "optimization_catalog.csv",
            "configuration_provenance.csv",
        )
            @test !isfile(joinpath(directory, legacy))
        end
        policy = BN.YAML.load_file(joinpath(directory, "output_policy.yaml"))
        @test policy["schema"] == "qcl-negf-report-v1"
        @test policy["package"] == "QCLNEGFRunner"
        @test policy["package_version"] == string(Base.pkgversion(BN))
        @test policy["fields"]["save_csv"]["value"] == false
        @test policy["fields"]["save_plots"]["status"] ==
              "request_for_optional_plotting_frontend_not_core_solver"
        @test policy["fields"]["device_geometry"]["status"] ==
              "report_only_never_enters_poisson_or_scba"
    end
    mktempdir() do directory
        BN._save_configuration_provenance(directory, base)
        manifest = BN.YAML.load_file(joinpath(directory, "algorithm_manifest.yaml"))
        @test manifest["package_version"] == string(Base.pkgversion(BN))
        @test manifest["algorithms"]["solver_backend"] == "production"
        catalog = BN.YAML.load_file(joinpath(directory, "optimization_catalog.yaml"))
        identifiers = getindex.(catalog["optimizations"], "id")
        @test "selected_inversion" in identifiers
        @test "distributed_energy_momentum" in identifiers
        provenance = BN.YAML.load_file(joinpath(directory, "configuration_provenance.yaml"))
        first_path = first(sort!(collect(keys(provenance["fields"]))))
        @test haskey(provenance["fields"][first_path], "source_chain")
        @test haskey(provenance["fields"][first_path], "winning_source")
        @test !haskey(provenance["fields"][first_path], "override_count")
    end
end

end # independent suite
