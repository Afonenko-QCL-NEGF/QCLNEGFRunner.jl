module PauseCLIArchiveBudget
using Test
const ConfigurationError=ArgumentError
const calls=Any[]
_light_json(io,data)=nothing
function verify_pause_receipt(root,execution_id,attempt;archive_byte_budget=64*1024^3)
    push!(calls,(root,execution_id,attempt,archive_byte_budget))
    return Dict("status"=>"paused")
end
verify_stop_receipt(args...;kwargs...)=verify_pause_receipt(args...;kwargs...)
include("../../src/cli.jl")
@testset "Stop verifiers accept one finite archive budget without losing required scope" begin
    for command in ("verify-pause","verify-stop")
        @test main([command,"/fixture-output","--attempt","2","--archive-byte-budget","1234","--execution-id","e"])==0
    end
    @test length(calls)==2
    @test all(call->call==("/fixture-output","e",2,1234),calls)
    @test main(["verify-pause","/fixture-output","--attempt","2","--archive-byte-budget","1234"])==2
    @test main(["verify-stop","/fixture-output","--attempt","2","--execution-id","e","--archive-byte-budget","1","--archive-byte-budget","2"])==2
end
end
