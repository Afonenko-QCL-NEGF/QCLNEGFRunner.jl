module Suite_T053
include("../support/common.jl")
using HDF5

@testset "Fresh final acceptance rejects stale history and preserves physical gates" begin
    # A deliberately permissive algebraic fixture isolates acceptance labels;
    # it makes no quantitative claim about this small seeded physical state.
    problem = build_problem(
        numerical = tutorial_numerics(),
        scattering = ScatteringOptions(
            LO = false,
            acoustic = false,
            impurity = false,
            IFR = false,
            alloy = false,
        ),
    )
    U = zeros(problem.numerical.N_z)
    green, _ = QCLNEGFRunner._seed_green(problem, project_hamiltonians(problem, U))
    embedding, plus, minus = QCLNEGFRunner.embedding_self_energy(problem, green)
    inner = SCBAIteration(
        5,
        1e-12,
        1e-10,
        8e-4,
        7e-4,
        9e-5,
        1+9e-5,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        NaN,
        NaN,
        NaN,
        NaN,
        nothing,
        nothing,
    )
    scba = SCBAResult(
        green,
        Dict{Symbol,SelfEnergyFamily}(),
        embedding,
        plus,
        minus,
        [inner],
        false,
        :approximate,
        :approximate_fixed_point,
    )
    density = QCLNEGFRunner._electron_density_bar(problem, green.Gˡ)
    outer = OuterIteration(
        2,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        zeros(problem.numerical.N_b),
        density,
    )
    tolerances = SolverTolerances(;
        (
            name => name in (:r_K, :r_Σ) ? 1e-8 : 1e100 for
            name in fieldnames(SolverTolerances)
        )...,
    )
    quality = DiagnosticQualityPolicy(
        enabled = true,
        observable_threshold = 1e100,
        positivity_threshold = 1e100,
        causality_threshold = 1e100,
    )
    options = SolverOptions(
        tolerances = tolerances,
        convergence = ConvergencePolicy(
            mode = :adaptive_working,
            diagnostic_quality = quality,
        ),
    )
    provisional = NEGFSolution(
        problem,
        options,
        U,
        density,
        scba,
        [outer],
        Dict{Symbol,Any}(),
        ConvergenceReport(false, Dict{Symbol,Float64}(), String[]),
        false,
        :converged,
    )
    assessment = QCLNEGFRunner._final_quality_report(provisional, true)
    @test !assessment.converged
    # Small recorded history residuals cannot certify the freshly recomputed map,
    # even when the caller explicitly permits an approximate working band.
    @test !assessment.approximate
    @test !assessment.report.passed
    @test assessment.report.metrics[:r_K] > quality.keldysh_threshold ||
          assessment.report.metrics[:r_Σ] > quality.self_energy_threshold
    @test !scba.converged
    @test scba.status === :approximate
    @test !validate_solution(provisional).passed
    @test !QCLNEGFRunner._final_quality_report(provisional, false).approximate

    # The sum rule never adopts the approximate fixed-point tolerance. A
    # numerically stable SCBA state with deficient spectral weight is refused.
    blocked_limits = SolverTolerances(;
        (
            name=>name===:r_sum ? 0.0 : getfield(tolerances, name) for
            name in fieldnames(SolverTolerances)
        )...,
    )
    blocked_options =
        SolverOptions(tolerances = blocked_limits, convergence = options.convergence)
    blocked = NEGFSolution(
        problem,
        blocked_options,
        U,
        density,
        scba,
        [outer],
        Dict{Symbol,Any}(),
        provisional.report,
        false,
        :converged,
    )
    rejected = QCLNEGFRunner._final_quality_report(blocked, true)
    @test !rejected.converged && !rejected.approximate
    @test any(occursin("r_sum=", message) for message in rejected.report.messages)
    warning = QCLNEGFRunner._final_validation_warning(blocked, rejected)
    @test warning["code"] == "FINAL_VALIDATION_FAILED"
    @test occursin("r_sum=", warning["message"])
    @test warning["thresholds"]["r_sum"] == 0.0
    @test warning["metrics"]["r_sum"] > 0

    final = NEGFSolution(
        problem,
        blocked_options,
        U,
        density,
        scba,
        [outer],
        Dict{Symbol,Any}(:warnings=>[warning]),
        rejected.report,
        false,
        :validation_failed,
    )
    @test QCLNEGFRunner._solution_report_metrics(final)[:spectral_sum] ==
          rejected.report.metrics[:r_sum]
    mktempdir() do directory
        path=joinpath(directory, "analysis.h5")
        QCLNEGFRunner.save_analysis_physics(path, final)
        diagnostics = HDF5.h5open(path, "r") do file
            QCLNEGFRunner.YAML.load(
                String(read(file["diagnostics/validation_json"]));
                dicttype = Dict{String,Any},
            )
        end
        @test diagnostics["schema"] == "qcl-negf-validation-diagnostics-v1"
        @test diagnostics["evaluated"]
        @test !diagnostics["strict_passed"] && !diagnostics["approximate_passed"]
        sumrule = only(filter(row->row["metric"]=="r_sum", diagnostics["metrics"]))
        @test sumrule["value"] == rejected.report.metrics[:r_sum]
        @test sumrule["strict_threshold"] == sumrule["approximate_threshold"] == 0.0
        @test !sumrule["strict_passed"] && !sumrule["approximate_passed"]
        @test diagnostics["messages"] == rejected.report.messages
        @test isfile(path)
        @test !isfile(joinpath(directory, "validation.csv"))
    end
end

end # independent suite
