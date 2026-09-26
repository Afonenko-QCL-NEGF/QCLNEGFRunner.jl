module Suite_T039
include("../support/common.jl")
include("../support/configured_study.jl")

@testset "Diagnostic invocation failure isolation" begin
    BN = QCLNEGFRunner
    configuration_root = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))
    diagnostics = load_run_configuration(
        joinpath(configuration_root, "studies-method_diagnostics.yaml"),
    )
    @test !diagnostics.output.fail_fast
    exact = load_run_configuration(joinpath(configuration_root, "exact_cpu.yaml"))
    mktempdir() do temporary
        configured = BN._method_configuration(diagnostics, exact, temporary)
        @test !configured.output.fail_fast
        captured = BN._run_diagnostic_invocation(
            configured;
            invocation_kind = :method_repetition,
            identity = "synthetic",
            runner = _ -> error("synthetic diagnostic failure"),
        )
        @test isfile(captured.failure_path)
        @test isfile(captured.sweep.summary_path)
        failed = only(captured.sweep.records)
        @test !failed.converged
        @test failed.status == :execution_failed
        @test failed.scba_quality == :invalid
        failure_csv = read(captured.failure_path, String)
        @test occursin("synthetic diagnostic failure", failure_csv)
        @test occursin("execution_failed,invalid", failure_csv)

        @test_throws InterruptException BN._run_diagnostic_invocation(
            configured;
            invocation_kind = :method_repetition,
            identity = "interrupt",
            runner = _ -> throw(InterruptException()),
        )
    end

    pilot_study =
        load_run_configuration(joinpath(configuration_root, "studies-pilot_reference.yaml"))
    @test !pilot_study.output.fail_fast
    naive = load_run_configuration(joinpath(configuration_root, "naive_oracle.yaml"))
    mktempdir() do temporary
        configured = BN._method_configuration(pilot_study, naive, temporary)
        @test !configured.output.fail_fast
        captured = BN._run_diagnostic_invocation(
            configured;
            invocation_kind = :method_repetition,
            identity = "pilot-default",
            runner = _ -> error("pilot point failed; keep the study running"),
        )
        @test isfile(captured.failure_path)
        @test only(captured.sweep.records).status == :execution_failed
        @test only(captured.sweep.records).scba_quality == :invalid
        @test !only(captured.sweep.records).converged
    end
    mktempdir() do temporary
        configured = BN._method_configuration(
            pilot_study,
            naive,
            temporary;
            overrides = Dict{String,Any}("output" => Dict{String,Any}("fail_fast" => true)),
        )
        @test configured.output.fail_fast
        @test configured.raw["output"]["fail_fast"]
        @test !pilot_study.output.fail_fast
        @test !pilot_study.raw["output"]["fail_fast"]
        @test_throws ErrorException BN._run_diagnostic_invocation(
            configured;
            invocation_kind = :method_repetition,
            identity = "strict",
            runner = _ -> error("fail immediately"),
        )
        @test !isfile(joinpath(temporary, "diagnostic_failure.csv"))
    end
end

end # independent suite
