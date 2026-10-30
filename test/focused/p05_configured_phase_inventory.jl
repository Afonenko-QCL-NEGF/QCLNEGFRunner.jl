using Test, QCLNEGFRunner, QCLNEGF
const R=QCLNEGFRunner
@testset "mutable owned phase data is excluded from science artifact inventory" begin
    mktempdir() do run_root
        output=joinpath(run_root,"points","point","artifacts");mkpath(output)
        phase=joinpath(output,"progress","phases","session");mkpath(phase)
        write(joinpath(phase,"phase-current.json"),"pending")
        write(joinpath(phase,"segment-1.json"),"phase")
        write(joinpath(output,"science.txt"),"science")
        result=(output_directory=output,sweep=(summary_path="",),progress_csv="",live_dashboard="")
        record=QCLNEGF.ProductionSweepRecord(70.0,0.0,0.0,0.0,true,:converged,
            :strictly_converged,0,0,0,0.0,Dict{Symbol,Float64}(),"")
        artifacts=R._runtime_point_artifacts(result,record,run_root;phase_directory=phase)
        paths=[value["path"] for value in values(artifacts)]
        @test any(endswith(path,"science.txt") for path in paths)
        @test all(!occursin("/phases/session/",path) for path in paths)
    end
end
