using Test, QCLNEGF, QCLNEGFRunner
const R=QCLNEGFRunner
@testset "runner stages retain ownership and event context" begin
    events=SolverEvent[]; options=ProductionOptions(outer_iteration=2,event_sink=e->(push!(events,e);true))
    owned=R._runner_begin_stage(options,:point;label="p",iteration=1,total=3)
    @test owned
    @test R._runner_update_stage(options,:point;iteration=2,total=3,metrics=SolverMetric(:J,1.,"A/cm^2"))
    R._runner_end_stage(options,:point,owned;status=:failed,iteration=2,total=3,message="failure")
    @test getfield.(events,:action) == [:begin,:progress,:end]
    @test all(e->e.outer_iteration==2 && e.inner_iteration===nothing,events)
    @test events[2].metrics[1].value==1.
    @test events[3].status===:failed && events[3].message=="failure"
    R._runner_end_stage(options,:point,false;status=:failed)
    @test length(events)==3
    rejected=ProductionOptions(event_sink=e->false)
    @test !R._runner_begin_stage(rejected,:point)
    @test !R._runner_update_stage(rejected,:point)
end
