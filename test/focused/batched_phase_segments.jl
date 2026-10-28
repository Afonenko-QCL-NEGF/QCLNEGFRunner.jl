# Prepared package only: no Pkg, solve, completed-map, or infrastructure actions.
using QCLNEGFRunner, QCLNEGF, Test
expected=get(ENV,"QCL_P29_RUNNER","")
isabspath(expected) || error("Supply QCL_P29_RUNNER actual worktree")
@test realpath(dirname(pathof(QCLNEGFRunner)))==realpath(joinpath(expected,"src"))
repo=dirname(dirname(dirname(expected)))
@test realpath(dirname(pathof(QCLNEGF)))==realpath(joinpath(repo,"components","QCLNEGF.jl","src"))
println("Runner=",pathof(QCLNEGFRunner)," Core=",pathof(QCLNEGF));flush(stdout)
@testset "P29 package composition" begin
    @test isdefined(QCLNEGFRunner,:PhaseObservationPolicy)
end
@testset "P29 actual package scalar packet" begin
    include(joinpath(@__DIR__,"..","infrastructure","batched_phase_segments.jl"))
    include(joinpath(@__DIR__,"..","infrastructure","bounded_scalar_telemetry.jl"))
end
