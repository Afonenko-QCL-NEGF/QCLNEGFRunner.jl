module Suite_T031
include("../support/common.jl")

@testset "Per-case campaign RAM planning uses effective method overrides" begin
    BN = QCLNEGFRunner
    root = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))
    configuration = load_run_configuration(joinpath(root, "studies-pilot_reference.yaml"))
    raw = deepcopy(configuration.raw)
    raw["study"]["methods"] = [deepcopy(first(raw["study"]["methods"]))]
    raw["study"]["comparison_profiles"] = [raw["study"]["methods"][1]["profile"]]
    raw["study"]["reference_profile"] = raw["study"]["methods"][1]["profile"]
    raw["study"]["repetitions"] = 2
    raw["study"]["methods"][1]["overrides"] = Dict{String,Any}(
        "numerical" => Dict{String,Any}("energy_nodes" => 241, "basis_states" => 4),
        "scattering" => Dict{String,Any}("lo_phonon" => false),
    )
    resolved = BN._resolve_configuration(raw, configuration.provenance)
    cases = BN._configured_resource_cases(resolved, root)
    @test length(cases) == 1
    @test only(cases).configuration.numerical.N_E == 241
    @test only(cases).configuration.numerical.N_b == 4
    @test !only(cases).configuration.scattering.LO
    @test sum(case.runs for case in cases) == planned_solver_runs(resolved) == 2
    memory = 24 * 1024^3
    hardware = HardwareProfile(
        2,
        2,
        memory,
        memory,
        "test-blas",
        memory,
        typemax(Int),
        typemax(Int),
        0,
        2,
        Inf,
        "test",
        "test",
        "test",
    )
    resource = BN._configured_execution_resource_plan(resolved, root; hardware)
    effective, _ = resolve_execution_strategy(only(cases).configuration; hardware)
    expected =
        BN._configured_production_estimate(effective, effective.production).peak_bytes
    @test resource.campaign["maximum_estimated_peak_bytes"] == expected
    @test only(resource.campaign["cases"])["numerical"]["energy_nodes"] == 241
    @test resource.campaign["planned_solver_runs"] == 2
    @test resource.calibration.mode == :analytical
end

end # independent suite
