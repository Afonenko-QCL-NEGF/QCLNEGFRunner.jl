module ModelHelpCapture
using Test, QCLNEGF, QCLNEGFRunner, Unitful, SHA, YAML
const R=QCLNEGFRunner
const S=R.QCLScientificWorkflow
const ROOT=get(ENV,"QCL_MODEL_HELP_TEST_OUTPUT",mktempdir(;prefix="model-help-"))
mkpath(ROOT)
# Independent input oracle: mixed units deliberately differ from output units.
function fixture()
    raw=deepcopy(R.load_run_configuration(joinpath(@__DIR__,"../fixtures/research-inputs/model/reference-2019-70k.yaml")).raw)
    merge!(raw["physical"],Dict("lattice_temperature"=>"83 K","lo_temperature"=>"91 K",
        "interface_roughness_height"=>"0.00024 μm","interface_correlation_length"=>"0.0075 μm",
        "impurity_screening_wavenumber"=>"2.5e8 m^-1","lo_screening_wavenumber"=>"4e8 m^-1",
        "lo_phonon_energy"=>"0.037 eV"))
    # Entire constructor fixture is a declared small reference problem, not a
    # production scientific experience. Its P05 projection describes these same
    # physical/numerical/scattering/scales inputs; no acceptance tolerance changes.
    raw["numerical"]=Dict{String,Any}("spatial_nodes"=>48,"basis_states"=>3,"basis_periods"=>1,
        "energy_min"=>"-0.10 eV","energy_max"=>"0.28 eV","energy_nodes"=>49,"energy_trust_margin"=>"56 meV",
        "momentum_max"=>"0.45 nm^-1","momentum_nodes"=>5,"angular_nodes"=>8,
        "longitudinal_momentum_max"=>"6 nm^-1","longitudinal_momentum_nodes"=>25,"seed_broadening"=>"2 meV")
    raw["scattering"]=Dict{String,Any}(name=>false for name in ("lo_phonon","acoustic_phonon","ionized_impurity","interface_roughness","alloy_disorder"))
    configuration=R._resolve_configuration(raw,R.ConfigurationProvenance(String[],String[],Dict{String,Vector{String}}()))
    points=[S.ScientificPoint("P1","E1",83.,0.05,"main",1,nothing,:cold),
        S.ScientificPoint("P2","E1",97.,0.05,"main",2,nothing,:cold)]
    rows=[merge(S._point_dict(p),Dict("effective_inputs"=>S._point_passport(configuration,p))) for p in points]
    document=Dict{String,Any}("fingerprint"=>repeat("a",64),"scientific_fingerprint"=>repeat("b",64),
        "model_revision"=>"transport-contract-v2","points"=>rows,
        "executions"=>[Dict("id"=>"E1","point_ids"=>["P1","P2"])])
    bytes=Vector{UInt8}(codeunits(" \r\n"*sprint(R._light_json,document)*"\n"))
    capture=R._P05PlanCapture((:scientific_plan_v2,bytes,document,bytes2hex(sha256(bytes))))
    (;configuration,points,capture)
end
function actual(f,i)
    p=f.points[i]; resolved=S._point_resolved_configuration(f.configuration,p)
    # Typed Core construction only. No SCBA, Poisson, restore or solver is run.
    problem=build_problem(;physical=resolved.physical,numerical=resolved.numerical,scattering=resolved.scattering,
        scales=resolved.scales,physical_models=resolved.physical_models)
    model=S._snapshot_model(resolved)
    identity=Dict("execution_id"=>"E1","point_id"=>p.id,"attempt"=>"7",
        "plan_sha256"=>f.capture.plan_sha256,"model_sha256"=>bytes2hex(sha256(R.canonical_bytes(model))))
    (;p,problem,model,identity,options=ProductionOptions(;energy_chunk=23,worker_count=1))
end
# A missing producer yields the same observable absence as today's baseline.
function capture_if_available(args...;kw...)
    isdefined(S,:_model_help_capture!) || return nothing
    S._model_help_capture!(args...;kw...)
end
const F=fixture()
const A=actual(F,1)
@testset "eight actual passed inputs, independent units and raw passport" begin
    f=F; a=A
    directory=joinpath(ROOT,"eight","executions","E1","P1","attempt-7");mkpath(directory)
    budget=isdefined(S,:_ModelHelpBudget) ? S._ModelHelpBudget(2) : nothing
    got=capture_if_available(budget,directory,a.problem,a.options,f.capture,a.p,a.identity)
    path=joinpath(directory,"model-help-inputs.json")
    @test isfile(path)
    if isfile(path)
        doc=YAML.load_file(path); leaves=Dict(x["path"]=>x for x in doc["inputs"])
        @test length(leaves)==8
        @test got.sha256==bytes2hex(sha256(read(path)))
        expected=Dict("production.energy_chunk"=>(23,"1"),"physical.lattice_temperature"=>(83.,"K"),
            "physical.lo_temperature"=>(83.,"K"),"physical.interface_roughness_height"=>(0.24,"nm"),
            "physical.interface_correlation_length"=>(7.5,"nm"),"physical.impurity_screening_wavenumber"=>(0.25,"nm^-1"),
            "physical.lo_screening_wavenumber"=>(0.4,"nm^-1"),"physical.lo_phonon_energy"=>(37.,"meV"))
        for (path,(value,unit)) in expected
            leaf=leaves[path]; @test leaf["used"]["status"]=="known"
            @test leaf["used"]["atom"]["value"]≈value rtol=4eps(Float64)
            @test leaf["used"]["atom"]["unit"]==unit
            @test leaf["declared"]==Dict("status"=>"unknown","atom"=>nothing)
            @test leaf["assigning"]==Dict("status"=>"unknown","kind"=>"unknown","source"=>nothing,"rule"=>nothing)
            @test leaf["effective_origin"]==Dict("status"=>"unknown","steps"=>[])
        end
        # Independent P05 projection: explicit known canonical SI units, not the new helper.
        physical=a.model["inputs"]["physical"]
        for (key,expected,unit) in (("Tᴸ",83.,"K"),("Tᴸᴼ",83.,"K"),("Δᴵᶠᴿ",2.4e-10,"m"),
            ("Λᴵᶠᴿ",7.5e-9,"m"),("q_s",2.5e8,"m^-1"),("qᴸᴼ_s",4e8,"m^-1"),("ħωᴸᴼ",0.037,"eV"))
            @test physical[key]["value"]≈expected rtol=4eps(Float64)
            @test physical[key]["unit"]==unit
        end
        @test doc["context"]["configuration_hash"]==f.capture.document["points"][1]["effective_inputs"]["configuration_hash"]
        @test doc["context"]["attempt"]==7
        @test doc["origin_bindings"]==[] && doc["phase"]=="solver_input"
        @test f.capture.bytes[1:3]==UInt8[0x20,0x0d,0x0a]
        @test bytes2hex(sha256(f.capture.bytes))==f.capture.plan_sha256
    end
end
function directory(name,point="P1")
    path=joinpath(ROOT,name,"executions","E1",point,"attempt-7");mkpath(path);path
end
function capture(name;budget=S._ModelHelpBudget(2),hook=stage->nothing,mirror=nothing,a=A)
    dir=directory(name,a.p.id)
    S._model_help_capture!(budget,dir,a.problem,a.options,F.capture,a.p,a.identity;hook,mirror)
end
@testset "safe scalars retain sign and never infer origins" begin
    @test F.configuration.production.energy_chunk==64
    @test A.options.energy_chunk==23
    for value in (NaN,Inf,-Inf,BigFloat(1))
        @test S._model_help_atom(value,"K")==Dict("status"=>"unknown","atom"=>nothing)
    end
    for value in (true,9007199254740992)
        @test S._model_help_atom(value,"1";integer=true)==Dict("status"=>"unknown","atom"=>nothing)
    end
    zero=S._model_help_atom(-0.0,"nm"); @test signbit(zero["atom"]["value"])
    zero_raw=deepcopy(F.configuration.raw);zero_raw["physical"]["interface_roughness_height"]="-0.0 nm"
    zero_physical=R._resolve_configuration(zero_raw,R.ConfigurationProvenance(String[],String[],Dict{String,Vector{String}}())).physical
    p=A.problem;zero_problem=NEGFProblem(zero_physical,p.numerical,p.scattering,p.scales,p.grids,p.profiles,p.basis,
        p.kernels,p.W₊ᴱᵖ,p.W₋ᴱᵖ,p.W₊ᴸᴼ,p.W₋ᴸᴼ,p.energy_shift_discretization,p.models)
    zero_leaf=only(filter(x->x["path"]=="physical.interface_roughness_height",S._model_help_inputs(zero_problem,A.options)))
    @test signbit(zero_leaf["used"]["atom"]["value"])
    @test signbit(YAML.load(sprint(R._light_json,zero_leaf))["used"]["atom"]["value"])
    raw=sprint(R._light_json,zero); @test signbit(YAML.load(raw)["atom"]["value"])
    unsafe=merge(A,(;options=R.with_production_options(A.options;energy_chunk=typemax(Int))))
    got=capture("unsafe-chunk";a=unsafe)
    doc=YAML.load_file(got.path)
    @test doc["inputs"][1]["used"]==Dict("status"=>"unknown","atom"=>nothing)
    @test unsafe.options.energy_chunk==typemax(Int)
    # A distinct LO temperature catches accidental reuse of Tᴸ in the adapter.
    p=A.problem; other=NEGFProblem(F.configuration.physical,p.numerical,p.scattering,p.scales,p.grids,p.profiles,p.basis,
        p.kernels,p.W₊ᴱᵖ,p.W₋ᴱᵖ,p.W₊ᴸᴼ,p.W₋ᴸᴼ,p.energy_shift_discretization,p.models)
    leaves=Dict(x["path"]=>x for x in S._model_help_inputs(other,A.options))
    @test leaves["physical.lo_temperature"]["used"]["atom"]["value"]==91.
    @test leaves["physical.lattice_temperature"]["used"]["atom"]["value"]==83.
    for value in (64,23)
        opts=R.with_production_options(A.options;energy_chunk=value)
        doc=S._model_help_inputs(A.problem,opts)
        @test all(x->x["declared"]["status"]==x["assigning"]["status"]==x["effective_origin"]["status"]=="unknown",doc)
    end
end
@testset "admission precedes encode and every copy; terminal credits" begin
    for budget in (S._ModelHelpBudget(0),S._ModelHelpBudget(1;bytes=1),S._ModelHelpBudget(1;work_bytes=1))
        stages=Symbol[]
        @test capture("denied-"*string(length(readdir(ROOT)));budget,hook=s->push!(stages,s))===nothing
        @test isempty(stages)
    end
    budget=S._ModelHelpBudget(1); first=capture("one-point";budget)
    @test first!==nothing
    stages=Symbol[]
    @test capture("second-denied";budget,hook=s->push!(stages,s))===nothing
    @test isempty(stages)
    @test budget.bytes==8*1024^2-first.bytes
    @test budget.work_bytes==6*8*1024^2-4*first.bytes
    @test_throws S._ModelHelpUnavailable S._model_help_admit!(S._ModelHelpBudget(1),65537,false)
    budget=S._ModelHelpBudget(10001)
    S._model_help_admit!(budget,1,false)
    @test budget.entries==9999
end
@testset "closed immutable publication, no clobber, failure and cancellation" begin
    for stage in (:sync,:close,:link)
        dir=directory("fault-"*string(stage)); budget=S._ModelHelpBudget(1)
        hook=s->s===stage && throw(SystemError("injected "*string(stage),5))
        @test capture("fault-"*string(stage);budget,hook)===nothing
        @test isempty(readdir(dir))
        @test budget.entries==0
    end
    dir=directory("no-clobber");path=joinpath(dir,"model-help-inputs.json");write(path,"prior immutable bytes")
    @test capture("no-clobber")===nothing
    @test read(path,String)=="prior immutable bytes"
    @test readdir(dir)==["model-help-inputs.json"]
    for stage in (:before_encode,:sync,:link)
        cancelled=Ref(false)
        hook=s->if s===stage
            cancelled[]=true;throw(InterruptException())
        elseif s===:close && cancelled[]
            throw(SystemError("secondary close",5))
        end
        @test_throws InterruptException capture("cancel-"*string(stage);hook)
        @test isempty(readdir(directory("cancel-"*string(stage))))
    end
    hook=s->s===:sync ? throw(ErrorException("fatal invariant")) : nothing
    @test_throws ErrorException capture("fatal";hook)
    @test isempty(readdir(directory("fatal")))
    # A durable target may remain when the own-temporary cleanup sync fails;
    # no success receipt may escape that uncertainty.
    @test capture("cleanup-sync";hook=s->s===:cleanup_sync && throw(SystemError("cleanup fsync",5)))===nothing
    @test isfile(joinpath(directory("cleanup-sync"),"model-help-inputs.json"))
    @test_throws InterruptException capture("cancel-cleanup";hook=s->s===:cleanup_sync && throw(InterruptException()))
    @test isfile(joinpath(directory("cancel-cleanup"),"model-help-inputs.json"))
    # A source directory alias is refused before any file write.
    target=joinpath(ROOT,"outside");mkdir(target)
    dir=directory("alias");rm(dir);symlink(target,dir)
    @test capture("alias")===nothing
    @test isempty(readdir(target))
end
@testset "directory close uncertainty is optional; primary cancellation survives" begin
    birth()=R._NativeCaptureBirth(Any[(;fd=Cint(-1))],Dict{String,String}(),nothing,false)
    @test_throws S._ModelHelpUnavailable S._model_help_close_birth(birth(),nothing)
    @test S._model_help_close_birth(birth(),InterruptException())===nothing
end
@testset "native only exact help bytes in a fresh original namespace" begin
    job=joinpath(ROOT,"original-job");mkdir(job)
    mirror=R._native_help_mirror(job,joinpath(ROOT,"native-science"))
    @test mirror!==nothing
    try
        got=capture("mirror-source";mirror)
        @test got!==nothing && got.mirrored
        mirrored=joinpath(job,"result","executions","E1","P1","attempt-7","model-help-inputs.json")
        @test read(got.path)==read(mirrored)
        @test got.sha256==bytes2hex(sha256(read(mirrored)))
        @test readdir(dirname(mirrored))==["model-help-inputs.json"]
        @test R._native_help_mirror(job,joinpath(ROOT,"native-science"))===nothing
        stages=Symbol[];budget=S._ModelHelpBudget(1;work_bytes=1)
        @test capture("mirror-denied";mirror,budget,hook=s->push!(stages,s))===nothing
        @test isempty(stages)
        # A competing symlink inside the owned namespace cannot escape it.
        mkdir(joinpath(ROOT,"mirror-outside")); symlink(joinpath(ROOT,"mirror-outside"),joinpath(mirror.root,"E2"))
        @test_throws S._ModelHelpUnavailable S._model_help_publish!(mirror.root,UInt8[1];children=("E2","P2","attempt-7"))
        @test isempty(readdir(joinpath(ROOT,"mirror-outside")))
    finally
        R._close_native_help_mirror(mirror,nothing)
    end
    unknown=joinpath(ROOT,"unknown-job");mkpath(joinpath(unknown,"result","executions"))
    write(joinpath(unknown,"result","executions","unrelated.bin"),"untouched synthetic sentinel")
    @test R._native_help_mirror(unknown,joinpath(ROOT,"elsewhere"))===nothing
    @test readdir(joinpath(unknown,"result","executions"))==["unrelated.bin"]
end
# Execute the actual production restore/solve dispatch AST. Only public numerical
# boundaries are fake; the actual typed arguments and real capture are retained.
module Boundary
import ..ModelHelpCapture: R,S
const target=Ref("")
module PublicCore
restore_exact_state(problem,state;kwargs...)=state.boundary===:failed ? throw(ArgumentError("restore rejected")) :
    (;problem,options=kwargs[:production_options])
restore_completed_solution(restored;kwargs...)=(;completed=true,restored)
end
const QCLNEGF=PublicCore
load_exact_solver_state(parent)=parent
const _model_help_capture! = S._model_help_capture!
solve_adaptive_production(problem;kwargs...)=(;problem,
    options=haskey(kwargs,:restart) ? kwargs[:restart].options : kwargs[:production_options],
    snapshot=read(target[]))
end
function dispatch_expression()
    tree=Meta.parseall(read(joinpath(dirname(dirname(pathof(R))),"src/composition/scientific_execution.jl"),String))
    selected=Dict{Symbol,Expr}()
    function visit(x)
        x isa Expr || return
        if x.head===:(=) && x.args[1] in (:parent_state,:restored,:solution,:kernel_binding)
            if x.args[1]===:parent_state && x.args[2] isa Expr && x.args[2].head===:if
                selected[:parent_state]=x
            elseif x.args[1]===:restored && x.args[2] isa Expr && x.args[2].head===:if
                selected[:restored]=x
            elseif x.args[1]===:solution && x.args[2] isa Expr && x.args[2].head===:if
                selected[:solution]=x
            elseif x.args[1]===:kernel_binding && x.args[2] isa Expr && x.args[2].head===:if
                selected[:kernel_binding]=x
            end
        end
        foreach(visit,x.args)
    end
    visit(tree)
    Expr(:block,selected[:kernel_binding],selected[:parent_state],selected[:restored],selected[:solution],:(return solution))
end
Core.eval(Boundary,:(function enter(problem,runtime_options,plan_binding,point,identity,directory,help_budget,
    model_help_mirror,parent_checkpoint,config,exact_capture,cache,previous,event_sink,callbacks)
    $(dispatch_expression())
end))
@testset "actual public solve boundary after successful restore only" begin
    b=actual(F,2)
    for (name,a,parent) in (("fresh",A,nothing),("resume",b,(;boundary=:scba)),
        ("final",A,(;boundary=:final)),("failed-restore",A,(;boundary=:failed)))
        dir=directory("entry-"*name,a.p.id);Boundary.target[]=joinpath(dir,"model-help-inputs.json")
        args=(a.problem,a.options,F.capture,a.p,a.identity,dir,S._ModelHelpBudget(2),nothing,parent,
            F.configuration,
            (;execution=nothing),nothing,nothing,nothing,(;checkpoint_context_sink=nothing,history_observer=nothing))
        if name=="failed-restore"
            @test_throws ArgumentError Boundary.enter(args...)
        else
            got=Boundary.enter(args...)
            if name in ("fresh","resume")
                @test got.problem===a.problem && got.options===a.options
                doc=YAML.load(String(got.snapshot))
                @test doc["context"]["point_id"]==a.p.id
                @test only(filter(x->x["path"]=="physical.lattice_temperature",doc["inputs"]))["used"]["atom"]["value"]==(name=="fresh" ? 83. : 97.)
                @test doc["context"]["attempt"]==7
            else
                @test got.completed
            end
        end
        @test isfile(Boundary.target[])==(name in ("fresh","resume"))
    end
    broken=deepcopy(F.capture.document);broken["points"][1]["effective_inputs"]["configuration_hash"]="bad"
    cap=R._P05PlanCapture((F.capture.kind,F.capture.bytes,broken,F.capture.plan_sha256))
    @test_throws ArgumentError S._model_help_capture!(S._ModelHelpBudget(1),directory("corrupt-passport"),A.problem,A.options,cap,A.p,A.identity)
end
end
