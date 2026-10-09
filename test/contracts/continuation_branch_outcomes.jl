module ContinuationBranchOutcomesFixture
using Test
@assert VERSION==v"1.13.0"
const ROOT=normpath(joinpath(@__DIR__,"../.."))
include(joinpath(ROOT,"src/application/scientific/contracts.jl"))
include(joinpath(ROOT,"src/application/scientific/voltage_continuation.jl"))
const helper=joinpath(ROOT,"src/application/scientific/branch_outcomes.jl")
@testset "S06 missing production boundary (RED)" begin
    @test isfile(helper)
end
include(helper)
function named_method(path,name)
    definitions=filter(Meta.parseall(read(path,String)).args) do e
        e isa Expr && e.head===:function && e.args[1] isa Expr && e.args[1].head===:call && e.args[1].args[1]===name
    end
    @assert length(definitions)==1
    Core.eval(@__MODULE__,only(definitions))
end
named_method(joinpath(ROOT,"src/infrastructure/persistence/light_results.jl"),:_light_json)
named_method(joinpath(ROOT,"src/infrastructure/scientific/snapshots.jl"),:_scientific_result_dict)
const points=[ScientificPoint("p$i","e1",300.0,0.1i,"up",i,i==1 ? nothing : "p$(i-1)",i==1 ? :cold : :predecessor) for i in 1:6]
const plan=(points=points,executions=[(id="e1",)])
const order=[p.id for p in points]
function row(i;attempt=1,status=:completed,quality=:strict,converged=true,assessment=nothing,warnings=Dict{String,Any}[],data=Dict{String,Any}("full_state"=>"sentinel-$i","result_commit"=>"commit-$i"))
    p=points[i];obs=assessment===nothing ? Dict{String,Any}() : Dict{String,Any}("scientific_assessment"=>assessment)
    ScientificPointResult(p.id,p.execution_id,attempt,(temperature_K=p.temperature_K,voltage_per_period_V=p.voltage_per_period_V,branch=p.branch,order=p.order),(kind="cold",source_point_id=nothing,checkpoint=nothing,fallback_reason=nothing),status,quality,converged,warnings,obs,data,Dict{String,Any}())
end
assessment(category="physical_and_algebraic",status="pass")=Dict{String,Any}("registry_version"=>"qcl-negf-acceptance-metadata-v1","stationary_candidate_accepted"=>status=="pass","iterative_converged"=>true,"fixed_hartree_converged"=>true,"physical_gates_passed"=>status=="pass","metrics"=>Dict("m"=>Dict("category"=>category,"status"=>status,"reason"=>"hand measurement")))
const eligible=(status=:converged,converged=true,quality=:strict,inner_status=:converged,inner_converged=true,inner_quality=:strictly_converged,certificate=true,reason=nothing)
const ineligible=merge(eligible,(status=:scba_max_iterations,converged=false,certificate=false,reason=:stationary_certificate_not_passed))
kinds(r,s=nothing,t=nothing;kw...)=first.(_continuation_failure_reasons(r,s,t;kw...))
@testset "Observed reasons preserve evidence" begin
    r=row(4;assessment=assessment());before=deepcopy(_scientific_result_dict(r))
    @test isempty(kinds(r,eligible,:converged))
    @test "iteration_not_converged" in kinds(r,ineligible,:scba_max_iterations)
    @test "iteration_not_converged" in kinds(r,nothing,:max_poisson_iterations_final_scba_converged)
    @test !("iteration_not_converged" in kinds(r,nothing,:validation_failed))
    @test "physical_gate_failed" in kinds(row(4;assessment=assessment("physical_and_algebraic","fail")))
    @test "iteration_not_converged" in kinds(row(4;assessment=assessment("nonlinear_fixed_point","fail")))
    for (status,want) in [("not_measured","assessment_unavailable"),("error","metadata_invalid")]
        found=kinds(row(4;assessment=assessment("physical_and_algebraic",status)))
        @test want in found
        @test !("physical_gate_failed" in found)
    end
    @test "assessment_unavailable" in kinds(row(4))
    @test "data_unavailable" in kinds(row(4;data=Dict{String,Any}()))
    @test "interrupted" in kinds(r;interruption=:paused)
    @test "data_unavailable" in kinds(r;artifact_error="sink failure")
    @test "process_failure" in kinds(row(4;warnings=[Dict{String,Any}("code"=>"POINT_FAILED","message"=>"actual exception")]))
    @test _scientific_result_dict(r)==before
end
raw(i=4;attempt=1)=Dict{String,Any}("id"=>"p$i","execution_id"=>"e1","attempt"=>attempt,"converged"=>true,"coordinates"=>Dict{String,Any}("temperature_K"=>300.0,"voltage_per_period_V"=>0.1i,"branch"=>"up","order"=>i),"warnings"=>Any[],"assessment"=>Dict("opaque"=>true),"data"=>Dict("full_state"=>"sentinel"))
function refusal(document,prefix)
    original=deepcopy(document);counters=zeros(Int,3)
    error=try
        _scientific_validate_raw_source_rows(plan,document)
        counters .+=1 # simulated coercion/collapse/publication after actual guard
        nothing
    catch e;e;end
    @test error isa ArgumentError
    @test startswith(sprint(showerror,error),"ArgumentError: scientific_source_$prefix:")
    @test ncodeunits(error.msg)<=2048
    @test counters==[0,0,0]
    @test isequal(document,original)
end
@testset "Raw boundary before coercion/collapse/publication" begin
    for field in ("attempt","order"), value in (true,1.0,"1",0)
        r=raw();field=="order" ? (r["coordinates"][field]=value) : (r[field]=value)
        refusal(Dict("points"=>[r]),"invalid")
    end
    for value in (0,1,"true")
        r=raw();r["converged"]=value;refusal(Dict("points"=>[r]),"invalid")
    end
    for field in ("id","execution_id","attempt","converged","coordinates")
        r=raw();delete!(r,field);refusal(Dict("points"=>[r]),"unavailable")
    end
    for field in ("temperature_K","voltage_per_period_V","branch","order")
        r=raw();delete!(r["coordinates"],field);refusal(Dict("points"=>[r]),"unavailable")
    end
    for (field,value) in [("temperature_K",true),("temperature_K",301.0),("voltage_per_period_V",false),("voltage_per_period_V",0.5),("branch","down"),("order",5)]
        r=raw();r["coordinates"][field]=value;refusal(Dict("points"=>[r]),"invalid")
    end
    for field in ("id","execution_id")
        r=raw();r[field]="foreign";refusal(Dict("points"=>[r]),"invalid")
    end
    r=raw();r["coordinates"]["extra"]=1;refusal(Dict("points"=>[r]),"invalid")
    refusal(Dict("points"=>[raw(),raw()]),"invalid")
    for field in ("warnings","assessment","data")
        r=raw();r[field]=["different"];refusal(Dict("points"=>[raw()],"attempt_history"=>[r]),"invalid")
    end
    r=raw();r["data"]=Dict("nonfinite"=>Inf);refusal(Dict("points"=>[r]),"invalid")
    refusal(Dict("points"=>nothing),"unavailable")
    refusal(Dict("points"=>[raw()],"attempt_history"=>false),"invalid")
    for document in (Dict("points"=>[raw()]),Dict("points"=>[raw()],"attempt_history"=>[Dict(reverse(collect(raw())))]),Dict("points"=>[raw(attempt=2)],"attempt_history"=>[raw(attempt=1)]))
        before=deepcopy(document)
        @test _scientific_validate_raw_source_rows(plan,document)===nothing
        @test isequal(document,before)
    end
end
@testset "ID upsert retains prefix and future rows" begin
    rows=[row(1),row(2),row(3),row(5)];prefix=copy(rows[1:3]);future=rows[4]
    _upsert_scientific_point!(rows,row(4;status=:failed),order)
    @test [r.id for r in rows]==["p1","p2","p3","p4","p5"]
    @test rows[1:3]==prefix && rows[5]===future
    _upsert_scientific_point!(rows,row(4;attempt=2,
        data=Dict{String,Any}("full_state"=>"sentinel-4-attempt2","result_commit"=>"commit-4-attempt2")),order)
    @test rows[4].attempt==2 && length(rows)==5
    dup=[row(1),row(1)];before=copy(dup)
    @test_throws ArgumentError _upsert_scientific_point!(dup,row(4),order)
    @test dup==before
    @test_throws ArgumentError _upsert_scientific_point!(rows,row(6),order[1:5])
end
const cases=Any[]
@testset "Declared routing and causal attempts" begin
    for mode in (:independent,:strict), fallback in (:stop_branch,:skip,:cold_start)
        policy=VoltageContinuation(mode,fallback)
        @test _continuation_branch_action(policy,nothing,true)===:continue
        @test _continuation_branch_action(policy,nothing,false)===(mode===:independent ? :continue : fallback===:cold_start ? :cold_fallback_declared : :skip_declared)
    end
    for kind in ("process_failure","iteration_not_converged","physical_gate_failed","interrupted","data_unavailable","assessment_unavailable","metadata_invalid")
        rows=ScientificPointResult[];calls=String[];cause=nothing;latched=false
        for i in 1:6
            admitted=i==1 || _continuation_branch_action(VoltageContinuation(:strict),cause,i<=4)===:continue
            if admitted
                push!(calls,"p$i")
                result=i==4 ? row(i;status=:failed,quality=:invalid,converged=false) : row(i)
                if i==4
                    cause=result;latched=true
                    push!(result.warnings,_continuation_reason_record("BRANCH_STOPPED",kind,result,"hand cause"))
                end
            else
                result=row(i;status=:skipped,quality=:not_evaluated,converged=false,data=Dict{String,Any}("full_state"=>nothing,"state_absence_reason"=>"solver_not_run"))
                push!(result.warnings,_continuation_reason_record("DEPENDENCY_UNAVAILABLE",kind,cause,"hand cause"))
            end
            _upsert_scientific_point!(rows,result,order)
        end
        @test calls==["p1","p2","p3","p4"] && latched
        @test rows[5].quality===:not_evaluated && rows[6].data["full_state"]===nothing
        execution=Dict{String,Any}("id"=>"e1","definition_id"=>"d1","variant_id"=>"v1","method_id"=>"m1","point_ids"=>order,"purpose"=>"research","operation"=>"stationary","repetition"=>1,"label"=>"fixture")
        frozen=Dict{String,Any}("schema"=>"qcl-negf-scientific-plan-v2","model_revision"=>"transport-contract-v2","root_definition_id"=>"d1","name"=>"fixture","fingerprint"=>repeat("a",64),"scientific_fingerprint"=>repeat("b",64),"computation_count"=>6,"executions"=>[execution],"points"=>[Dict("id"=>p.id,"execution_id"=>p.execution_id,"temperature_K"=>p.temperature_K,"voltage_per_period_V"=>p.voltage_per_period_V,"branch"=>p.branch,"order"=>p.order,"predecessor_id"=>p.predecessor_id) for p in points])
        snapshot=Dict{String,Any}("schema"=>"qcl-negf-series-result-v3","contract_set"=>"qcl-negf.results.v1","root_definition_id"=>"d1","name"=>"fixture","plan_fingerprint"=>repeat("a",64),"plan_scientific_fingerprint"=>repeat("b",64),"executions"=>[execution],"points"=>_scientific_result_dict.(rows),"attempt_history"=>_scientific_result_dict.(rows))
        for i in (4,6)
            expected=Dict("code"=>i==4 ? "BRANCH_STOPPED" : "DEPENDENCY_UNAVAILABLE","scope"=>"branch","reason_kind"=>kind,"source_execution_id"=>"e1","source_point_id"=>"p4","source_attempt"=>1,"message"=>"hand cause")
            @test rows[i].warnings[1]==expected
            push!(cases,Dict{String,Any}("record"=>rows[i].warnings[1],"plan"=>frozen,"owner_point"=>_scientific_result_dict(rows[i]),"owner_execution"=>execution,"source_points"=>snapshot,"expected"=>expected))
        end
    end
    old=row(4;attempt=1,status=:completed,assessment=assessment("physical_and_algebraic","fail"));before=deepcopy(_scientific_result_dict(old))
    history=[old];current=[row(1),row(2),row(3),old,row(5;status=:skipped,quality=:not_evaluated)]
    _upsert_scientific_point!(current,row(4;attempt=2),order)
    @test _scientific_result_dict(history[1])==before && history[1].attempt==1
    @test current[4]===old && current[4].attempt==1
    @test _usable_voltage_state(eligible,:strict) && !_usable_voltage_state(ineligible,:strict)
end
# Review regressions exercise production upsert, not file presence/caller text.
# Wrong immutable replacement, locator copying or causal attempt admission must fail.
@testset "Review immutable final and attempt ownership regressions" begin
    final=row(4;attempt=3,assessment=assessment("physical_and_algebraic","fail"))
    before=deepcopy(_scientific_result_dict(final))
    rows=[row(1),row(2),row(3),final]
    cancelled=row(4;attempt=3,status=:cancelled,quality=:not_evaluated,converged=false,
                  data=Dict{String,Any}("full_state"=>nothing,"state_absence_reason"=>"solver_did_not_publish_a_final_state"))
    _upsert_scientific_point!(rows,cancelled,order)
    @test _scientific_result_dict(rows[4])==before
    @test rows[4].status===:completed && rows[4].attempt==3
    old=row(4;attempt=1,status=:paused,quality=:unconverged,converged=false,
            assessment=assessment("physical_and_algebraic","not_measured"))
    oldbefore=deepcopy(_scientific_result_dict(old));rows=[old]
    failed=row(4;attempt=2,status=:failed,quality=:invalid,converged=false,
               assessment=deepcopy(old.observables["scientific_assessment"]),data=deepcopy(old.data))
    @test_throws ArgumentError _upsert_scientific_point!(rows,failed,order)
    @test _scientific_result_dict(rows[1])==oldbefore
    source=row(4;attempt=3,assessment=assessment("physical_and_algebraic","fail"))
    owner=row(5;attempt=1,status=:skipped,quality=:not_evaluated,converged=false,
              data=Dict{String,Any}("full_state"=>nothing,"state_absence_reason"=>"solver_not_run"))
    push!(owner.warnings,_continuation_reason_record("DEPENDENCY_UNAVAILABLE","physical_gate_failed",source,"actual source3"))
    rows=[source]
    @test_throws ArgumentError _upsert_scientific_point!(rows,owner,order)
    @test [r.id for r in rows]==["p4"]
    # Campaign stop for a preloaded completed point of another execution.
    e2=ScientificPointResult("p6","e2",4,points[6] |> p->(temperature_K=p.temperature_K,voltage_per_period_V=p.voltage_per_period_V,branch=p.branch,order=p.order),
        final.initialization,:completed,:unconverged,false,Dict{String,Any}[],deepcopy(final.observables),Dict{String,Any}("full_state"=>"e2-final","result_commit"=>"e2-commit"),Dict{String,Any}())
    e2before=deepcopy(_scientific_result_dict(e2));rows=[row(1;status=:failed),e2]
    stopped=ScientificPointResult(e2.id,e2.execution_id,5,e2.coordinates,e2.initialization,:skipped,:not_evaluated,false,
        Dict{String,Any}[],Dict{String,Any}(),Dict{String,Any}("full_state"=>nothing,"state_absence_reason"=>"solver_not_run"),Dict{String,Any}())
    _upsert_scientific_point!(rows,stopped,order)
    @test _scientific_result_dict(rows[2])==e2before
end
@testset "Cold suffix, interruption and recovery assumptions" begin
    strict=VoltageContinuation(:strict,:cold_start)
    rows=[row(1),row(2),row(3)];prefix=copy(rows);calls=String[]
    source=row(4;attempt=1,status=:completed,quality=:unconverged,converged=false,
               assessment=assessment("physical_and_algebraic","fail"))
    _upsert_scientific_point!(rows,source,order)
    latch=true
    @test _continuation_branch_action(strict,source,false)===:cold_fallback_declared
    push!(calls,"p5:cold_fallback")
    _upsert_scientific_point!(rows,row(5),order)
    @test _continuation_branch_action(strict,source,_usable_voltage_state(eligible,:strict))===:continue
    push!(calls,"p6:predecessor")
    _upsert_scientific_point!(rows,row(6),order)
    @test calls==["p5:cold_fallback","p6:predecessor"] && latch
    @test rows[1:3]==prefix && rows[4]===source
    @test _continuation_branch_action(VoltageContinuation(:independent),nothing,false)===:continue
    # Stop/recovery verification are supplied engineering assumptions; no native proof.
    verified_recovery=true;confirmed_stop=true;new_attempt=2;completed_final=false
    @test verified_recovery && confirmed_stop && new_attempt>source.attempt && !completed_final
    recovery_calls=["p4:2","p5:2"]
    recovery_source=row(4;attempt=1,status=:paused,quality=:unconverged,converged=false)
    recovery_rows=[prefix...,recovery_source]
    retained=[recovery_source];before=deepcopy(_scientific_result_dict(recovery_source))
    _upsert_scientific_point!(recovery_rows,row(4;attempt=2,
        data=Dict{String,Any}("full_state"=>"new-attempt2-state","result_commit"=>"new-attempt2-commit")),order)
    @test recovery_calls==["p4:2","p5:2"] && recovery_rows[1:3]==prefix && recovery_rows[4].attempt==2
    @test _scientific_result_dict(retained[1])==before
    for status in (:paused,:cancelled)
        operational=row(4;status,quality=:not_evaluated,converged=false)
        @test "interrupted" in kinds(operational;interruption=status)
        @test status in (:paused,:cancelled) # root keeps operational carrier
    end
    # Historical cause attempt1 remains exact on owner attempt2, immediate predecessor p5.
    base=deepcopy(cases[2]);owner=row(6;attempt=2,status=:skipped,quality=:not_evaluated,converged=false,
        data=Dict{String,Any}("full_state"=>nothing,"state_absence_reason"=>"solver_not_run"))
    warning=_continuation_reason_record("DEPENDENCY_UNAVAILABLE","process_failure",source,"historical cause")
    push!(owner.warnings,warning)
    owner_dict=_scientific_result_dict(owner)
    owner_dict["initialization"]=(kind="unavailable_predecessor",source_point_id="p5",checkpoint=nothing,fallback_reason=nothing)
    base["record"]=warning;base["owner_point"]=owner_dict
    base["expected"]=Dict("code"=>"DEPENDENCY_UNAVAILABLE","scope"=>"branch","reason_kind"=>"process_failure","source_execution_id"=>"e1","source_point_id"=>"p4","source_attempt"=>1,"message"=>"historical cause")
    base["source_points"]["points"][6]=owner_dict
    push!(base["source_points"]["attempt_history"],owner_dict)
    @test warning["source_attempt"]==1 && owner.attempt==2
    push!(cases,base)
    legacy=Dict{String,Any}(deepcopy(base));legacy_warning=Dict("code"=>"DEPENDENCY_UNAVAILABLE","scope"=>"branch","message"=>"unknown legacy text")
    legacy["record"]=legacy_warning;legacy["expected"]=nothing
    push!(cases,legacy)
    @test length(cases)==16
end
@testset "Exact prior selection and terminal retention seam" begin
    old=row(4;attempt=1,status=:paused,converged=false,
            assessment=assessment("physical_and_algebraic","not_measured"))
    oldbefore=deepcopy(_scientific_result_dict(old));current=[row(1),row(2),row(3),old]
    prefix=copy(current[1:3]);history=[old]
    prior=_continuation_current_attempt_row(current,"p4","e1",2)
    @test prior===nothing
    @test _continuation_current_attempt_row(current,"p4","foreign",1)===nothing
    fresh=row(4;attempt=2,status=:failed,quality=:invalid,converged=false,
              data=Dict{String,Any}("full_state"=>nothing,"state_absence_reason"=>"solver_did_not_publish_a_final_state"))
    _upsert_scientific_point!(current,fresh,order)
    _continuation_record_history!(history,fresh)
    @test current[1:3]==prefix && current[4].attempt==2
    @test isempty(current[4].observables) && !haskey(current[4].data,"result_commit")
    @test _scientific_result_dict(history[1])==oldbefore
    final=row(4;attempt=3,assessment=assessment("physical_and_algebraic","fail"))
    current=[row(1),row(2),row(3),final];history=ScientificPointResult[]
    retained=_continuation_current_attempt_row(current,"p4","e1",3)
    _continuation_record_history!(history,retained)
    _continuation_record_history!(history,retained)
    @test length(history)==1 && history[1]===final && current[4]===final
    @test current[4].status===:completed && current[4].data["result_commit"]=="commit-4"
    # Subsequent generic resume admits no current-point retry and no failed seed.
    dispatches=String[]
    current[4].status===:completed || push!(dispatches,"p4")
    _continuation_branch_action(VoltageContinuation(:strict),final,false)===:continue && push!(dispatches,"p5")
    @test isempty(dispatches)
    compatible=_continuation_unrun_attempt(1,final,nothing)
    @test compatible==3
    @test_throws ArgumentError _continuation_unrun_attempt(1,final,2)
    base=deepcopy(cases[2]);source=row(4;attempt=3,status=:completed,quality=:unconverged,converged=false,assessment=assessment("physical_and_algebraic","fail"))
    owner=row(6;attempt=compatible,status=:skipped,quality=:not_evaluated,converged=false,
              data=Dict{String,Any}("full_state"=>nothing,"state_absence_reason"=>"solver_not_run"))
    warning=_continuation_reason_record("DEPENDENCY_UNAVAILABLE","physical_gate_failed",source,"actual source3")
    push!(owner.warnings,warning)
    ownerdict=_scientific_result_dict(owner)
    ownerdict["initialization"]=(kind="unavailable_predecessor",source_point_id="p5",checkpoint=nothing,fallback_reason=nothing)
    base["record"]=warning;base["owner_point"]=ownerdict
    base["expected"]=Dict("code"=>"DEPENDENCY_UNAVAILABLE","scope"=>"branch","reason_kind"=>"physical_gate_failed","source_execution_id"=>"e1","source_point_id"=>"p4","source_attempt"=>3,"message"=>"actual source3")
    base["source_points"]["points"][4]=_scientific_result_dict(source)
    base["source_points"]["points"][6]=ownerdict
    base["source_points"]["attempt_history"]=[_scientific_result_dict(source),ownerdict]
    boundrows=[source]
    _upsert_scientific_point!(boundrows,owner,order)
    @test boundrows[2].attempt==3 && boundrows[2].warnings[1]["source_attempt"]==3
    push!(cases,base)
    @test length(cases)==17
end
# Parse caller source without evaluation/import; production placement is independently reviewed.
@testset "Production caller parses" begin
    @test Meta.parseall(read(joinpath(ROOT,"src/composition/scientific_execution.jl"),String)) isa Expr
end
open(only(ARGS),"w") do io;_light_json(io,Dict("cases"=>cases));println(io);end
@test filesize(only(ARGS))<=256*1024
end
