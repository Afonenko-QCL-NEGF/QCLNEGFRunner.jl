module ScientificResourceContracts
using Test
using YAML
using QCLNEGFRunner

@testset "Adaptive scientific memory is reserved before raw model allocation" begin
    base=load_run_configuration(
        normpath(
            joinpath(@__DIR__, "..", "fixtures", "configurations", "studies-smoke.yaml"),
        ),
    )
    repository=QCLNEGFRunner.QCLScientificWorkflow.FilesystemScientificDefinitions()
    estimate(config) =
        QCLNEGFRunner.QCLScientificWorkflow.scientific_memory_estimate(repository, config)
    raw=resolved_configuration_dict(base)
    cap=2base.numerical.N_E+1
    raw["domain_adaptation"]=Dict{String,Any}(
        "mode"=>"expand_energy_window",
        "maximum_expansions"=>1,
        "maximum_energy_nodes"=>cap,
        "growth_fraction"=>0.5,
        "tail_threshold"=>1e-6,
    )
    adaptive=QCLNEGFRunner._resolve_configuration(raw, base.provenance)
    reserved=estimate(adaptive)
    @test reserved>estimate(base)
    @test reserved>4cap^2*sizeof(Float64) # raw dense shift storage alone
    unlimited=(
        memory_budget_bytes = typemax(Int),
        hardware = (
            total_memory_bytes = typemax(Int),
            available_memory_bytes = typemax(Int),
        ),
    )
    reservation=QCLNEGFRunner.QCLScientificWorkflow._scientific_memory_reservation(
        adaptive,
        unlimited,
    )
    @test reservation["estimated_peak_bytes"]==reserved
    @test reservation["maximum_energy_nodes"]==cap
    limited=(
        memory_budget_bytes = typemax(Int),
        hardware = (total_memory_bytes = typemax(Int), available_memory_bytes = reserved-1),
    )
    @test_throws ArgumentError QCLNEGFRunner.QCLScientificWorkflow._scientific_memory_reservation(
        adaptive,
        limited,
    )
    raw["domain_adaptation"]["maximum_expansions"]=0
    inactive=QCLNEGFRunner._resolve_configuration(raw, base.provenance)
    @test estimate(inactive)==estimate(base)
    raw["domain_adaptation"]["maximum_expansions"]=1
    raw["domain_adaptation"]["maximum_energy_nodes"]=4cap+1
    larger=QCLNEGFRunner._resolve_configuration(raw, base.provenance)
    @test estimate(larger)>reserved
end
@testset "Admission failure stops later children before preparation" begin
    root=normpath(joinpath(@__DIR__, "..", ".."))
    mktempdir() do directory
        failing=Dict{String,Any}(
            "schema"=>"qcl-negf-study-v2",
            "kind"=>"study",
            "id"=>"resource-denied",
            "axes"=>Dict(
                "temperatures"=>Dict("values"=>[70], "unit"=>"K"),
                "voltages"=>Dict("values"=>[56], "unit"=>"mV"),
            ),
            "configuration"=>Dict(
                "sources"=>[joinpath(root, "test", "fixtures", "research-inputs", "model", "reference-2019-70k.yaml")],
                "overrides"=>Dict(
                    "execution"=>Dict(
                        "auto"=>Dict("minimum_memory_reserve_bytes"=>typemax(Int)÷2),
                    ),
                ),
            ),
            "policies"=>Dict("on_child_failure"=>"stop"),
        )
        YAML.write_file(joinpath(directory, "denied.yaml"), failing)
        YAML.write_file(
            joinpath(directory, "meta.yaml"),
            Dict(
                "schema"=>"qcl-negf-study-v2",
                "kind"=>"meta",
                "id"=>"admission-stop",
                "includes"=>[
                    "denied.yaml",
                    joinpath(root, "test", "fixtures", "research-inputs", "studies", "operator-a.yaml"),
                ],
            ),
        )
        plan=resolve_scientific_plan(joinpath(directory, "meta.yaml"))
        output=joinpath(directory, "output")
        result=execute_scientific_plan(plan, output)
        @test result["status"]=="failed"
        @test result["points"][1]["status"]===:failed
        @test result["points"][2]["status"]===:skipped
        @test !isdir(joinpath(output, "executions", "execution-2"))
    end
end

end
