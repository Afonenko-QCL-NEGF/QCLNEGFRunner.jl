module UnifiedScientificOutput
include("../support/common.jl")
const S=QCLNEGFRunner.QCLScientificWorkflow
@testset "Scientific output has one archive, recovery and telemetry authority" begin
    policy=S._parse_scientific_outputs(Dict("archive"=>Dict("full_final"=>true,"optical"=>true),
        "recovery"=>Dict("retain_generations"=>2,"byte_budget"=>4096,"reserve_bytes"=>32),
        "telemetry"=>Dict("enabled"=>false,"buffer_events"=>4)))
    @test policy.full_state
    @test policy.optical
    @test policy.recovery.byte_budget==4096
    @test !policy.telemetry.enabled
    @test_throws ArgumentError S._parse_scientific_outputs(Dict("archive"=>Dict("full_final"=>false)))
end
end
