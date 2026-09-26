module ScientificCommandLine
include("../support/common.jl")
using YAML
@testset "Frozen-plan CLI in an isolated process" begin
    root = normpath(joinpath(TEST_ROOT, ".."))
    script = joinpath(root, "scripts", "scientific_workflow.jl")
    source = joinpath(root, "examples", "config", "operator-algebra.yaml")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script plan $source --max-runs 1`
    output = read(command, String)
    plan = YAML.load(output)
    @test plan["schema"] == "qcl-negf-scientific-plan-v2"
    @test length(plan["executions"]) == 1
    @test length(plan["points"]) == 1
end
end
