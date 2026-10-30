module FinalObservationsContractTests
using Test, QCLNEGFRunner, QCLNEGF, SHA
const R=QCLNEGFRunner
const INPUT_ROOT=mktempdir(;prefix="qcl-final-input-unit-",cleanup=false)
const FLAGS=QCLNEGF.ScatteringOptions(LO=false,acoustic=false,impurity=false,IFR=false,alloy=false)
const ORIGINAL_YAML="# original bytes\r\nname: configured_operating_points\r\nroot:\r\n  kind: level\r\n  name: temperature\r\n  axes: [{name: temperature_K, values: [70.0]}]\r\n  child:\r\n    kind: level\r\n    name: voltage\r\n    axes: [{name: voltage_per_period_V, values: [0.05]}]\r\n    child: {kind: leaf, name: poisson_scba}\r\n"
function model_preimage()
    inputs=Dict{String,Any}(name=>Dict{String,Any}() for name in
        ("physical","numerical","scales","solver","kernel_construction","algorithms","physical_models","domain_adaptation"))
    inputs["scattering"]=Dict(string(name)=>getfield(FLAGS,name) for name in fieldnames(typeof(FLAGS)))
    inputs["production"]=Dict("physics_markers"=>Dict(),"verify_fft_roundoff"=>false)
    Dict("scope"=>"stationary_transport_inputs_v1","inputs"=>inputs,"derived"=>Dict("effective_seed_eV"=>0.01))
end
function input_recorder(name;bytes=Vector{UInt8}(codeunits(ORIGINAL_YAML)),model=model_preimage())
    directory=joinpath(INPUT_ROOT,name);mkdir(directory)
    identity=Dict("run_id"=>"run","execution_id"=>"exec","point_id"=>"point","attempt"=>"1","branch_id"=>"branch",
        "model_sha256"=>bytes2hex(sha256(R.canonical_bytes(model))),"plan_sha256"=>bytes2hex(sha256(bytes)))
    missing()=Dict("state"=>"not_measured","reason"=>"constructor_only","evidence"=>nothing)
    status=Dict{String,Any}("process"=>Dict("state"=>"running","exit_code"=>nothing,"reason"=>nothing),
        (key=>missing() for key in ("convergence","physics","discretization","experimental"))...)
    provenance=Dict("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),"components"=>Any[])
    R.ScientificHistoryRecorder(directory;artifact_root=INPUT_ROOT,identity,source_epoch="epoch",provenance,status,maximum_scba_rows=3)
end
publish(r;bytes=Vector{UInt8}(codeunits(ORIGINAL_YAML)),model=model_preimage(),kwargs...)=
    R.publish_final_point_request!(r;plan_bytes=bytes,model_preimage=model,temperature_K=70.0,
        voltage_per_period_V=0.05,scattering_requested=FLAGS,kind=:nested_sweep,maximum_metadata_bytes=16*1024^2,kwargs...)

@testset "Frozen original YAML and canonical P03 model have distinct immutable refs" begin
    r=input_recorder("healthy");request=publish(r)
    @test request.kind===:nested_sweep
    @test read(joinpath(INPUT_ROOT,request.plan_ref["path"]))==Vector{UInt8}(codeunits(ORIGINAL_YAML))
    @test request.plan_ref["sha256"]==r.identity["plan_sha256"]
    @test request.model_ref["sha256"]!=r.identity["model_sha256"]
    envelope=R._p04_parse(read(joinpath(INPUT_ROOT,request.model_ref["path"]),String))
    @test envelope["contract_set"]=="qcl-negf.results.v2"
    @test envelope["configuration"]==model_preimage()
    @test envelope["configuration_hash"]==r.identity["model_sha256"]
    @test publish(r).plan_ref==request.plan_ref
    @test !ispath(joinpath(r.directory,"current.json"))
    @test !ispath(joinpath(r.directory,"recovery","current.json"))
    wrong=model_preimage();wrong["derived"]["effective_seed_eV"]=0.02
    @test_throws ArgumentError publish(r;model=wrong)
end

@testset "Nested YAML safety precedes expansion and construction" begin
    bad=("name: first\nname: second\nroot: {kind: leaf, name: x}\n",
        "name: test\nroot: &a [*a]\n", "name: test\nroot: !evil anything\n",
        "name: test\nroot: {<<: {kind: leaf}, name: x}\n",
        "name: test\nroot: {kind: leaf, name: x}\n---\nname: second\n",
        "name: test\nroot: {kind: level, name: x, axes: [{name: y, values: [.nan]}], child: {kind: leaf, name: z}}\n",
        "1: test\nroot: {kind: leaf, name: x}\n")
    for (i,text) in enumerate(bad)
        bytes=Vector{UInt8}(codeunits(text));r=input_recorder("unsafe-$(i)";bytes)
        @test_throws ArgumentError publish(r;bytes)
        @test !ispath(joinpath(r.directory,"inputs"))
    end
end

# Public positional constructors deliberately carry asymmetric, literal payloads.
# They qualify transport only, not an accepted numerical solution.
function literal_snapshot(;missing_effective=false,g_s=2,status=:scba_invalid_candidate)
    z,e,k,b=5,7,3,2
    scalar=Float64[-0.0,Inf,-Inf,reinterpret(Float64,0x7ff8000000000002),1.25]
    realarray(dims...)=reshape(Float64.(1:prod(dims)),dims...)
    function complexarray(dims...)
        out=reshape(ComplexF64[complex(i,-2i-0.25) for i in 1:prod(dims)],dims...)
        out[1]=complex(reinterpret(Float64,0x7ff8000000000002),-0.0)
        out[2]=complex(Inf,reinterpret(Float64,0x7ff8000000000003))
        out[3]=complex(-Inf,0.0);out
    end
    context=FinalObservationContext((z,e,k,b),0,repeat("1",64),repeat("2",64),copy(scalar),
        realarray(z),realarray(e),realarray(e),realarray(k),realarray(k),realarray(z),realarray(e),realarray(k),
        Int64[0,1],BitVector([true,false,true,false,true,false,true]),FinalObservationScales(-0.0,1e-9,Inf),
        FinalObservationInputs(1.,0.05,70.,70.,0.,2.,1.,0.,3e-9,g_s),FLAGS,(),(),PhysicalModelOptions(),
        AlgorithmOptions(),:nodal_linear,:pzp,:stationary_field_periodic_embedding,:orthonormal_finite_projected,
        :scaled_E0_plus_E_ref,:k0_ascending_spatial_first_max_real_positive)
    optional(x)=missing_effective ? nothing : x
    views=StoredFinalObservations(copy(scalar),realarray(z),realarray(z),realarray(z),realarray(z),
        realarray(e,z),realarray(e,k),realarray(e,k),realarray(b),optional(realarray(b)),complexarray(z,b),
        optional(complexarray(z,b)),optional(complexarray(b,b)),complexarray(b,b),optional(complexarray(b,b)),
        reinterpret(Float64,0x7ff8000000000003),-0.0)
    kinds=(:spectral,:occupied,:unoccupied,:broadening,:raw_occupied,:raw_unoccupied)
    integrals=MatrixIntegralDiagnostics(complexarray(k,b,b),realarray(k,b),realarray(e,k),realarray(6,k),
        (0,1,2,3,4,5),(0,0,1,2,3,4),(0,0,0,0,0,0),e*k,(-0.0,Inf,-Inf,NaN,5.))
    witnesses=ntuple(i->PositivityWitness(:measured,kinds[i],i,1,-0.0,Inf,0.,NaN,1.,2.,3.,4.,5.),6)
    positivity=PositivityDiagnostics(3,kinds,witnesses,0.1,ntuple(Float64,6),ntuple(_->false,6),:momentum_energy,integrals)
    summary=FinalScientificSummary(status,:invalid,false,"registry",false,false,false,false,nothing,:not_measured,"fixture",0)
    issues=missing_effective ? Tuple(FinalObservationIssue(name,:error,:eigensystem_failed,"literal failure") for name in
        (:effective_levels_eV,:effective_wavefunctions_per_sqrt_nm,:effective_transform,:effective_density_matrix_per_m2)) : ()
    identity=ExactRestartIdentity(UInt16(1),ntuple(UInt8,32),ntuple(UInt8,32),ntuple(UInt8,32))
    FinalObservationSnapshot(:produced,identity,ntuple(UInt8,32),context,views,
        SolutionMetricDiagnostics(Dict(:z=>Inf,:a=>-0.0),Dict(:z=>1.,:a=>2.),nothing),positivity,summary,Dict{String,Any}(),nothing,nothing,issues)
end
@testset "Literal new record mapping keeps 26 views and 4 integral owners" begin
    snapshot=literal_snapshot()
    arrays=Pair{String,Any}[]
    context,views=R._p05_view_records(snapshot,arrays)
    @test length(arrays)==26
    @test context["dimensions"]==Dict("Nz"=>"5","NE"=>"7","Nk"=>"3","Nb"=>"2")
    @test context["x_scaled"]["dataset"]=="/final_observations/arrays/x_scaled"
    @test context["inputs"]["g_s"]==Dict("kind"=>"integer","type"=>"Int64","decimal"=>"2")
    @test context["scales"]["E0_eV"]["bits"]=="8000000000000000"
    @test views["sheet_density_matrix_per_m2"]["axes"]==["state","state_prime"]
    @test views["effective_transform"]["coordinate_fields"]==["state_index","state_index"]
    @test views["spatial_energy_density_per_eV_m3"]["shape"]==["7","5"]
    @test views["localized_wavefunctions_per_sqrt_nm"]["units"]=="nm^-1/2"
    @test views["current_density_A_per_m2"]["bits"]=="7ff8000000000003"
    @test views["sheet_density_per_m2"]["bits"]=="8000000000000000"
    @test all(last(pair)===getfield(hasproperty(snapshot.context,Symbol(last(split(first(pair),'/')))) ? snapshot.context : snapshot.views,Symbol(last(split(first(pair),'/')))) for pair in arrays)
    diagarrays=Pair{String,Any}[];metrics,positivity=R._p05_diagnostic_records(snapshot,diagarrays)
    @test length(diagarrays)==4
    @test [row["name"] for row in metrics["summary_metrics"]]==["a","z"]
    @test metrics["summary_metrics"][1]["value"]["bits"]=="8000000000000000"
    @test positivity["data"]["integrals"]["negative_energy_integral_scaled"]["axes"]==["matrix_kind","k"]
    @test positivity["data"]["integrals"]["spectral_integral"]["shape"]==["3","2","2"]
    for gs in (0,1,2,typemax(Int64))
        c,_=R._p05_view_records(literal_snapshot(;g_s=gs),Pair{String,Any}[])
        @test c["inputs"]["g_s"]["decimal"]==string(gs)
    end
    for gs in (-1,typemin(Int64))
        @test_throws ArgumentError R._p05_view_records(literal_snapshot(;g_s=gs),Pair{String,Any}[])
    end
    arrays=Pair{String,Any}[];_,nullable=R._p05_view_records(literal_snapshot(;missing_effective=true),arrays)
    @test length(arrays)==22
    @test nullable["effective_transform"]===nothing
end

@testset "Scientific frozen plan closes existing nested envelope" begin
    W=R.QCLScientificWorkflow
    source=joinpath(@__DIR__,"..","fixtures","configurations","resource-proposal-study.yaml")
    plan=scientific_plan_dict(resolve_scientific_plan(source));point=first(plan["points"])
    identity=Dict("point_id"=>point["id"],"execution_id"=>point["execution_id"],"model_sha256"=>point["effective_inputs"]["model_sha256"])
    ref(schema,media,path)=Dict("path"=>path,"bytes"=>"0","sha256"=>repeat("a",64),"media_type"=>media,"schema"=>schema)
    request=FinalPointRequest(;plan_ref=ref("qcl-negf-scientific-plan-v2","application/json","p.json"),
        model_ref=ref("qcl-negf-resolved-configuration-v3","application/json","m.json"),
        temperature_K=Float64(point["temperature_K"]),voltage_per_period_V=Float64(point["voltage_per_period_V"]),scattering_requested=FLAGS,kind=:scientific_plan_v2)
    @test R._p05_plan(plan,identity,request)===plan
    for mutate in (p->(p["model_revision"]="invented"),p->(p["inclusions"][1]["extra"]=1),
            p->(p["executions"][1]["extra"]=1),p->(p["points"][1]["effective_inputs"]["extra"]=1),
            p->(p["resources"]=Dict()),p->(p["nodes"][1]["stage_id"]="new"),
            p->(p["executions"][1]["resolved_snapshot"]["phase"]="new"))
        bad=deepcopy(plan);mutate(bad)
        @test_throws ArgumentError R._p05_plan(bad,identity,request)
    end
end

@testset "Julia native 26+4 storage preserves every logical cell and rejects corruption" begin
    snapshot=literal_snapshot();r=input_recorder("literal-native")
    arrays=Pair{String,Any}[];context,views=R._p05_view_records(snapshot,arrays)
    declaration=Dict("context"=>context,"views"=>views)
    # Transport-only signed extrema; not an owning Core-produced coordinate claim.
    snapshot.context.state_index[:]=[typemin(Int64),typemax(Int64)]
    reference=R._p05_write_analysis!(r,"literal","final_observations",declaration,arrays,64*1024^2,stage->nothing)
    path=joinpath(INPUT_ROOT,reference["path"])
    R.h5open(path,"r") do file
        for (dataset,expected) in arrays
            raw=read(file,dataset)
            actual=ndims(raw)==1 ? raw : permutedims(raw,reverse(1:ndims(raw)))
            if eltype(expected)===Bool
                @test UInt8.(actual)==UInt8.(expected)
            else
                @test reinterpret(UInt8,vec(actual))==reinterpret(UInt8,vec(expected))
            end
        end
    end
    da=Pair{String,Any}[];metrics,positivity=R._p05_diagnostic_records(snapshot,da)
    diag=Dict("positivity"=>positivity)
    dr=R._p05_write_analysis!(r,"literal","final_diagnostics",diag,da,64*1024^2,stage->nothing)
    R.h5open(joinpath(INPUT_ROOT,dr["path"]),"r") do file
        for (dataset,expected) in da
            actual=permutedims(read(file,dataset),reverse(1:ndims(expected)))
            @test reinterpret(UInt8,vec(actual))==reinterpret(UInt8,vec(expected))
        end
    end
    for (index,mutate) in enumerate((
            file->(file["extra"]=Int64[1]),
            file->begin meta=file["metadata"];R.HDF5.delete_attribute(meta,"representation");R.HDF5.attributes(meta)["representation"]="wrong";close(meta);end,
            file->begin R.HDF5.delete_object(file,"final_observations/arrays/wX");file["final_observations/arrays/wX"]=Float32[1,2,3,4,5];end,
            file->begin R.HDF5.delete_object(file,"final_observations/arrays/wX");file["final_observations/arrays/wX"]=ones(4);end,
            file->R.HDF5.create_external(file,"evil",path,"/metadata"),
            file->begin R.HDF5.API.h5l_create_soft("/metadata",file,"evil",R.HDF5.API.H5P_DEFAULT,R.HDF5.API.H5P_DEFAULT);end,
            file->begin R.HDF5.delete_object(file,"final_observations/arrays/wX");
                d=R.HDF5.create_dataset(file,"final_observations/arrays/wX",Float64,(5,);chunk=(5,),filters=R.HDF5.Filters.Fletcher32());write(d,ones(5));close(d);end,
            file->begin R.HDF5.delete_object(file,"final_observations/arrays/wX");
                t=R.HDF5.Datatype(R.HDF5.API.h5t_copy(R.HDF5.API.H5T_IEEE_F64BE));d=R.HDF5.create_dataset(file,"final_observations/arrays/wX",t,(5,));write(d,ones(5));close(d);close(t);end,
            file->begin R.HDF5.delete_object(file,"final_observations/arrays/wX");
                d=R.HDF5.create_external_dataset(file,"final_observations/arrays/wX",joinpath(r.directory,"unread.raw"),Float64,(5,));close(d);end,
            file->begin R.HDF5.delete_object(file,"final_observations/arrays/wX");
                space=R.HDF5.dataspace((5,));t=R.HDF5.datatype(Float64)
                d=R.HDF5.create_dataset(file,"final_observations/arrays/wX",t,space;virtual=[R.HDF5.VirtualMapping(space,"unread.h5","/source",space)])
                close(d);close(t);close(space);end,
            file->begin R.HDF5.delete_object(file,"final_observations/arrays/wX");
                d=R.HDF5.create_dataset(file,"final_observations/arrays/wX",Float64,(5,);chunk=(5,),filters=R.HDF5.Filters.ScaleOffset(0,2));write(d,ones(5));close(d);end,
            file->begin R.HDF5.delete_object(file,"final_observations/arrays/sheet_density_matrix_per_m2");
                t=R.HDF5.Datatype(R.HDF5.API.h5t_create(R.HDF5.API.H5T_COMPOUND,16))
                R.HDF5.API.h5t_insert(t,"r",8,R.HDF5.API.H5T_IEEE_F64LE);R.HDF5.API.h5t_insert(t,"i",0,R.HDF5.API.H5T_IEEE_F64LE)
                d=R.HDF5.create_dataset(file,"final_observations/arrays/sheet_density_matrix_per_m2",t,(2,2));close(d);close(t);end,
            file->begin R.HDF5.delete_object(file,"final_observations/declaration_json");
                t=R.HDF5.datatype(String);space=R.HDF5.dataspace(())
                d=R.HDF5.create_dataset(file,"final_observations/declaration_json",t,space);close(d);close(t);close(space);end,
            file->begin R.HDF5.delete_object(file,"final_observations/declaration_json");g=R.create_group(file,"final_observations/declaration_json");close(g);end,
            file->(R.HDF5.attributes(file)["unknown"]="hidden")))
        copy=joinpath(r.directory,"corrupt-$(index).h5");cp(path,copy)
        R.h5open(mutate,copy,"r+")
        ref=R._p04_ref(INPUT_ROOT,copy,"qcl-negf-physics-analysis-v5";media="application/x-hdf5")
        @test_throws ArgumentError R._p05_read_analysis(INPUT_ROOT,ref,r.identity,r.invocation,"final_observations",Ref(64*1024^2))
    end
    @test_throws ArgumentError R._p05_read_analysis(INPUT_ROOT,reference,r.identity,r.invocation,"final_observations",Ref(10))
    wrong=deepcopy(reference);wrong["sha256"]=repeat("0",64)
    @test_throws ArgumentError R._p05_read_analysis(INPUT_ROOT,wrong,r.identity,r.invocation,"final_observations",Ref(64*1024^2))
end

@testset "Input caps, safe quoted syntax and immutable conflicts precede publication" begin
    bytes=Vector{UInt8}(codeunits(replace(ORIGINAL_YAML,"# original bytes"=>"# innocent !tag &anchor *alias characters")))
    r=input_recorder("quoted-innocent";bytes)
    @test publish(r;bytes).plan_ref["sha256"]==bytes2hex(sha256(bytes))
    @test_throws ArgumentError R._p05_yaml(Vector{UInt8}(codeunits("name: test\nroot: [\n")),1024^2)
    @test_throws ArgumentError R._p05_yaml(Vector{UInt8}(codeunits(ORIGINAL_YAML)),100)
    @test_throws ArgumentError R._p05_parse("["*join(fill("0",100),',')*"]",Ref(10000))
    @test_throws OverflowError R._p05_mul(typemax(Int),2)
    request=publish(r;bytes)
    modelpath=joinpath(INPUT_ROOT,request.model_ref["path"])
    original=read(modelpath);write(modelpath,vcat(original,UInt8[0x20]))
    @test_throws ArgumentError publish(r;bytes)
    @test !ispath(joinpath(r.directory,"current.json"))
    r2=input_recorder("immutable-symlink");reference=publish(r2).plan_ref
    target=joinpath(INPUT_ROOT,reference["path"]);mv(target,target*"-original");symlink(target*"-original",target)
    @test_throws ArgumentError publish(r2)
end

@testset "Original scientific JSON publishes actual P03 point preimage" begin
    W=R.QCLScientificWorkflow
    plan=resolve_scientific_plan(joinpath(@__DIR__,"..","fixtures","configurations","resource-proposal-study.yaml"))
    point=first(plan.points);execution=only(filter(e->e.id==point.execution_id,plan.executions))
    configuration=W._point_resolved_configuration(execution.configuration,point)
    preimage=W._snapshot_model(configuration)
    raw=Vector{UInt8}(codeunits(sprint(write_scientific_plan,plan)))
    directory=joinpath(INPUT_ROOT,"actual-scientific");mkdir(directory)
    identity=Dict("run_id"=>"run","execution_id"=>point.execution_id,"point_id"=>point.id,"attempt"=>"1","branch_id"=>"branch",
        "model_sha256"=>bytes2hex(sha256(R.canonical_bytes(preimage))),"plan_sha256"=>bytes2hex(sha256(raw)))
    missing()=Dict("state"=>"not_measured","reason"=>"constructor_only","evidence"=>nothing)
    status=Dict{String,Any}("process"=>Dict("state"=>"running","exit_code"=>nothing,"reason"=>nothing),
        (n=>missing() for n in ("convergence","physics","discretization","experimental"))...)
    r=ScientificHistoryRecorder(directory;artifact_root=INPUT_ROOT,identity,source_epoch="epoch",provenance=Dict(
        "format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),"components"=>Any[]),status,maximum_scba_rows=3)
    request=publish_final_point_request!(r;plan_bytes=raw,model_preimage=preimage,temperature_K=Float64(point.temperature_K),
        voltage_per_period_V=Float64(point.voltage_per_period_V),scattering_requested=configuration.scattering,kind=:scientific_plan_v2,
        maximum_metadata_bytes=64*1024^2)
    @test read(joinpath(INPUT_ROOT,request.plan_ref["path"]))==raw
    budget=Ref(64*1024^2);model=R._p05_input_ref(INPUT_ROOT,request.model_ref,budget)
    @test model["configuration"]==preimage
    @test model["configuration_hash"]==identity["model_sha256"]
    @test request.model_ref["sha256"]!=identity["model_sha256"]
    @test !ispath(joinpath(directory,"current.json"))
end
@testset "Quoted YAML syntax is data; UTF-8 and depth remain bounded" begin
    text="name: test\nroot: {kind: level, name: level, axes: [{name: values, values: [\"!tag &anchor *alias\"]}], child: {kind: leaf, name: end}}\n"
    value=R._p05_yaml(Vector{UInt8}(codeunits(text)),2*1024^2)
    @test R._p05_nested_plan(value)===value
    @test value["root"]["axes"][1]["values"]==["!tag &anchor *alias"]
    @test_throws ArgumentError R._p05_yaml(UInt8[0xff],1024)
    @test_throws ArgumentError R._p05_yaml(Vector{UInt8}(codeunits("root: "*"["^257*"0"*"]"^257)),4*1024^2)
    for number in (".Inf","-.inf",".NaN")
        @test_throws ArgumentError R._p05_yaml(Vector{UInt8}(codeunits("number: "*number)),1024^2)
    end
end
@testset "Non-wire audit keeps closed nested producer keys" begin
    measure()=Dict("status"=>"unavailable","value"=>nothing,"nonfinite"=>nothing,"reason"=>"map_unavailable")
    context=Dict{String,Any}(n=>nothing for n in ("status","reason","unknown_fields","backend","energy_shift","hilbert","contraction","kernel_build","embedding",
        "electron_electron_mode","embedding_periods","enabled_scattering","E0_eV","L0_m","lambda_P","map_kernels_shared_with_solver","independent_physics_oracle",
        "state_alignment","alignment_reason","source_owner_role","source_paths"))
    context["source_paths"]=Dict(n=>"/source/"*n for n in ("U","n","GR","GL","GG","A"))
    context["status"]="unknown";context["reason"]="missing_executed_context"
    context["unknown_fields"]=String[];context["enabled_scattering"]=String[]
    context["independent_physics_oracle"]=false;context["source_owner_role"]="physics.full"
    witness()=Dict{String,Any}("status"=>"unavailable","e_index"=>nothing,"k_index"=>nothing,
        (n=>measure() for n in ("numerator_F","D_F","GR_F","identity_F","denominator","ratio"))...)
    norm()=Dict{String,Any}("floor"=>1e-14,(n=>measure() for n in ("numerator_F","scale_F","denominator","ratio"))...)
    audit=Dict{String,Any}("schema"=>"qcl-negf-final-fixed-point-audit-v1","record_status"=>"unavailable","reason"=>"map_unavailable","detail"=>"fixture",
        "detail_truncated"=>false,"shape"=>Dict("NE"=>7,"Nk"=>3,"Nb"=>2),"units"=>Dict("native"=>"1","energy_scale"=>"eV","length_scale"=>"m","index"=>"1-based"),
        "context"=>context,"history"=>Dict("inner_last"=>1,"inner_previous"=>nothing,"outer_last"=>nothing,"previous_lambda"=>measure()),
        "dyson"=>Dict("ratio"=>measure(),"global_abs_F"=>measure(),"max_abs_F"=>measure(),"ratio_witness"=>witness(),"absolute_witness"=>witness()),
        "spectral"=>norm(),"keldysh"=>norm(),"selfenergy"=>Dict("rows"=>Any[],"winner"=>nothing,"max_ratio"=>measure(),"floor"=>1e-14),
        "charge"=>Dict(n=>measure() for n in ("target_sheet","stored_raw_sheet","normalized_sheet","candidate_raw_sheet","stored_lambda","candidate_lambda","stored_constraint","candidate_constraint","normalized_residual","lambda_change")),
        "poisson"=>Dict(n=>measure() for n in ("residual_ratio","residual_numerator_F","rhs_F","additive_floor","denominator","border_scale","zeta_signed","neutrality_signed","neutrality_abs","target_sheet","neutrality_ratio","rU_max")))
    @test R._p05_audit_shape(audit)===nothing
    for mutate in (a->(a["context"]["extra"]=1),a->(a["charge"]["extra"]=measure()),a->(a["spectral"]["ratio"]["extra"]="bad"))
        bad=deepcopy(audit);mutate(bad)
        @test_throws ArgumentError R._p05_audit_shape(bad)
    end
end
@testset "Unavailable positivity and error sentinel preserve raw cause without display indexing" begin
    snapshot=literal_snapshot()
    issue=FinalObservationIssue(:positivity,:error,:positivity_measurement_failed,"literal failure: original detail")
    missing=FinalObservationSnapshot(snapshot.source_mode,snapshot.identity,snapshot.terminal_integrity,snapshot.context,snapshot.views,
        snapshot.metrics,nothing,snapshot.summary,snapshot.assessment,nothing,nothing,(issue,))
    arrays=Pair{String,Any}[];_,wire=R._p05_diagnostic_records(missing,arrays)
    @test isempty(arrays)
    @test wire==Dict("status"=>"error","reason"=>"positivity_measurement_failed: literal failure: original detail","data"=>nothing)
    @test R._p05_issues(missing.issues)==[Dict("target"=>"positivity","status"=>"error","reason"=>"positivity_measurement_failed","detail"=>"literal failure: original detail")]
    display=R._light_positivity_data(missing;status=:invalid_candidate,quality=:invalid)
    @test Set(keys(display))==Set(("status","reason","matrices"))
    p=snapshot.positivity
    error=PositivityWitness(:error,:none,0,0,NaN,Inf,-0.0,NaN,Inf,Inf,Inf,Inf,NaN)
    mixed=PositivityDiagnostics(p.metric_version,p.matrix_kinds,(error,p.witnesses[2:end]...),p.strict_ratio_limit,
        p.strict_absolute_limits_scaled,(false,p.strict_threshold_satisfied[2:end]...),p.scan_order,p.integrals)
    failed=FinalObservationSnapshot(snapshot.source_mode,snapshot.identity,snapshot.terminal_integrity,snapshot.context,snapshot.views,
        snapshot.metrics,mixed,snapshot.summary,snapshot.assessment,nothing,nothing,())
    _,raw=R._p05_diagnostic_records(failed,Pair{String,Any}[])
    @test raw["data"]["witnesses"][1]["energy_index"]["decimal"]=="0"
    @test raw["data"]["witnesses"][1]["floor"]["bits"]=="8000000000000000"
    @test R._light_positivity_data(failed;status=:invalid_candidate,quality=:invalid)["matrices"]===nothing
end
end
