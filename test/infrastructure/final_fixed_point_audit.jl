module FinalFixedPointAuditTransport
include("../support/common.jl")
using HDF5
using SHA
include("../support/native_physics_fixture.jl")
const BN=QCLNEGFRunner
retained_fixture_allowed(path)=path=="/tmp/qcl-SCI05-C08-RUNNER-7/tmp/producer-fixture"

# Independent literal format fixture, no Core record builder/product encoder.
# Measurements are manufactured; no physical convergence or solve is claimed.
measure(value=0.0)=Dict{String,Any}("status"=>"measured","value"=>value,"nonfinite"=>nothing,"reason"=>nothing)
absent()=Dict{String,Any}("status"=>"not_applicable","value"=>nothing,"nonfinite"=>nothing,"reason"=>"no_previous_inner_iteration")
identity()=Dict{String,Any}("execution_id"=>"fixture-execution","point_id"=>"fixture-point",
    "attempt"=>2,"plan_fingerprint"=>repeat("a",64),"state_id"=>"fixture-state","state_sequence"=>3)
function literal_template()
    witness=Dict{String,Any}("status"=>"measured","e_index"=>1,"k_index"=>1,
        "numerator_F"=>measure(),"D_F"=>measure(1.0),"GR_F"=>measure(1.0),
        "identity_F"=>measure(1.0),"denominator"=>measure(2.0),"ratio"=>measure())
    norm=Dict{String,Any}("numerator_F"=>measure(),"scale_F"=>measure(),
        "denominator"=>measure(1e-14),"ratio"=>measure(),"floor"=>1e-14)
    context=Dict{String,Any}("status"=>"unknown","reason"=>"missing_executed_context",
        "unknown_fields"=>["backend","energy_shift","hilbert","contraction","kernel_build",
            "embedding","embedding_periods","E0_eV","L0_m","lambda_P","map_kernels_shared_with_solver"],
        "electron_electron_mode"=>"none","enabled_scattering"=>String[],
        "independent_physics_oracle"=>false,"state_alignment"=>"unknown",
        "alignment_reason"=>"producer_precondition_unverified","source_owner_role"=>"physics.full",
        "source_paths"=>Dict("U"=>"/state_dimensionless/UH","n"=>"/state_dimensionless/density",
            "GR"=>"/state_dimensionless/GR","GL"=>"/state_dimensionless/GL",
            "GG"=>"/state_dimensionless/GG","A"=>"/state_dimensionless/A"))
    for name in context["unknown_fields"]
        context[name]=nothing
    end
    return Dict{String,Any}(
        "schema"=>"qcl-negf-final-fixed-point-audit-v1","record_status"=>"measured",
        "reason"=>nothing,"detail"=>"Синтетический transport fixture","detail_truncated"=>false,
        "shape"=>Dict("NE"=>1,"Nk"=>1,"Nb"=>1),
        "units"=>Dict("native"=>"1","energy_scale"=>"eV","length_scale"=>"m","index"=>"1-based"),
        "context"=>context,"history"=>Dict("inner_last"=>1,"inner_previous"=>nothing,
            "outer_last"=>1,"previous_lambda"=>absent()),
        "dyson"=>Dict("ratio"=>measure(),"global_abs_F"=>measure(),"max_abs_F"=>measure(),
            "ratio_witness"=>deepcopy(witness),"absolute_witness"=>deepcopy(witness)),
        "spectral"=>deepcopy(norm),"keldysh"=>deepcopy(norm),
        "selfenergy"=>Dict("rows"=>[Dict{String,Any}("family"=>f,"component"=>c,
            (key=>measure(key=="denominator" ? 1e-14 : 0.0) for key in
                ("numerator_F","scale_F","denominator","ratio"))...) for
                f in ("embedding_total","embedding_plus","embedding_minus") for c in ("R","L","G")],
            "winner"=>Dict("family"=>"embedding_total","component"=>"R"),"max_ratio"=>measure(),"floor"=>1e-14),
        "charge"=>Dict{String,Any}((name=>measure(value) for (name,value) in (
            "target_sheet"=>1.0,"stored_raw_sheet"=>1.0,"normalized_sheet"=>1.0,
            "candidate_raw_sheet"=>1.0,"stored_lambda"=>1.0,"candidate_lambda"=>1.0,
            "stored_constraint"=>0.0,"candidate_constraint"=>0.0,"normalized_residual"=>0.0))...,
            "lambda_change"=>absent()),
        "poisson"=>Dict(name=>measure(value) for (name,value) in (
            "residual_ratio"=>0.0,"residual_numerator_F"=>0.0,"rhs_F"=>0.0,
            "additive_floor"=>1e-14,"denominator"=>1e-14,"border_scale"=>1.0,
            "zeta_signed"=>0.0,"neutrality_signed"=>0.0,"neutrality_abs"=>0.0,
            "target_sheet"=>1.0,"neutrality_ratio"=>0.0,"rU_max"=>0.0)))
end

@testset "Literal final audit transport guards" begin
    template=literal_template()
    actual=identity()
    record=BN._final_audit_record(template,actual;bind=true)
    @test record["state_identity"]==actual
    @test !haskey(template,"state_identity")
    @test record["dyson"]["ratio"]["value"]===0.0
    @test record["detail"]=="Синтетический transport fixture"
    @test BN._final_audit_record(record,actual)==record
    for (key,value) in (("attempt",true),("state_sequence",3.0),("plan_fingerprint",repeat("A",64)))
        wrong=merge(actual,Dict(key=>value))
        @test_throws ArgumentError BN._final_audit_record(template,wrong;bind=true)
    end
    for key in ("attempt","state_sequence")
        boundary=merge(actual,Dict(key=>9007199254740991))
        @test BN._final_audit_record(template,boundary;bind=true)["state_identity"][key]===9007199254740991
        overflow=merge(actual,Dict(key=>9007199254740992))
        @test_throws ArgumentError BN._final_audit_record(template,overflow;bind=true)
    end
    for key in keys(actual)
        missing=copy(actual); delete!(missing,key)
        @test_throws ArgumentError BN._final_audit_record(template,missing;bind=true)
        wrong=copy(actual)
        wrong[key]=key in ("attempt","state_sequence") ? actual[key]+1 : key=="plan_fingerprint" ? repeat("b",64) : "other"
        @test_throws ArgumentError BN._final_audit_record(record,wrong)
    end
    for change in (x->(x["units"]["native"]="eV"),x->(x["schema"]="wrong"),
            x->(x["record_status"]="passed"),x->(x["detail"]=repeat("я",257)),
            x->(x["record_status"]="unavailable";x["reason"]="map_unavailable"),
            x->(x["dyson"]["ratio"]["value"]=NaN),
            x->(x["dyson"]["ratio"]["status"]="unavailable"),
            x->(x["dyson"]["ratio"]["nonfinite"]="+inf"))
        bad=deepcopy(template); change(bad)
        @test_throws ArgumentError BN._final_audit_record(bad,actual;bind=true)
    end
    negativezero=deepcopy(template); negativezero["dyson"]["ratio"]["value"]=-0.0
    @test !signbit(BN._final_audit_record(negativezero,actual;bind=true)["dyson"]["ratio"]["value"])
    tagged=deepcopy(template)
    tagged["record_status"]="partial_error"; tagged["reason"]="measurement_error"
    tagged["dyson"]["ratio"]=Dict("status"=>"error","value"=>nothing,"nonfinite"=>"nan","reason"=>"nonfinite_measurement")
    @test BN._final_audit_record(tagged,actual;bind=true)["dyson"]["ratio"]["nonfinite"]=="nan"
    @test !BN._final_audit_equal(Dict("value"=>false),Dict("value"=>0))
    @test !BN._final_audit_equal(Dict("value"=>1),Dict("value"=>1.0))
    # Independent transport bounds, not a schema engine.
    @test_throws ArgumentError BN._final_audit_transport_value(Dict(string(i)=>0 for i in 1:1025))
    @test_throws ArgumentError BN._final_audit_transport_value(repeat("x",65537))
    oversized=deepcopy(template)
    for i in 1:150; oversized["context"]["padding$i"]=repeat("x",512); end
    @test_throws ArgumentError BN._final_audit_record(oversized,actual;bind=true)
    deep=0
    for _ in 1:11; deep=Any[deep]; end
    @test_throws ArgumentError BN._final_audit_transport_value(deep)
end

@testset "Required candidate gates cannot disappear in stationary summary" begin
    fixture=native_physics_fixture(;energy_nodes=9)
    required=(:r_D_candidate,:r_A_candidate,:r_lambda_candidate,:r_K,:r_Σ,:r_λ,
        :r_P,:r_U,:r_n,:r_J,:r_power)
    for key in required; fixture.report.metrics[key]=0.0; end
    @test BN._physical_certification_data(fixture)["stationary"]["status"]=="passed"
    for key in (:r_D_candidate,:r_A_candidate,:r_lambda_candidate)
        delete!(fixture.report.metrics,key)
        @test BN._physical_certification_data(fixture)["stationary"]["status"]=="not_evaluated"
        fixture.report.metrics[key]=Inf
        @test BN._physical_certification_data(fixture)["stationary"]["status"]=="failed"
        fixture.report.metrics[key]=0.0
    end
    fixture.observables[:final_fixed_point_audit]=literal_template()
    for (section,name) in (("dyson","ratio"),("spectral","ratio"),("charge","candidate_constraint"))
        measurement=fixture.observables[:final_fixed_point_audit][section][name]
        measurement["status"]="unavailable" # finite zero is deliberately inconsistent
        @test BN._physical_certification_data(fixture)["stationary"]["status"]!="passed"
        measurement["status"]="error"
        @test BN._physical_certification_data(fixture)["stationary"]["status"]=="failed"
        measurement["status"]="measured"
    end
end

function mutated_bundle_check(mutate,parent,source;reject=true)
    # Change a copied owner, then refresh its actual bytes/SHA. This distinguishes
    # binding/presence failures from the unrelated existing checksum gate.
    mktempdir(parent;prefix="transport-control-") do temporary
        root=joinpath(temporary,"bundle")
        cp(dirname(source),root)
        path=joinpath(root,"commit.json")
        commit=BN.YAML.load_file(path;dicttype=Dict{String,Any})
        mutate(commit,root)
        # A mutated full owner also changes the independently checked nested
        # recovery reference. Refresh that payload before hashing its declaration.
        for artifact in commit["artifacts"]
            artifact["schema"]=="qcl-negf-recovery-reference-v1" || continue
            reference_path=joinpath(root,artifact["path"])
            reference=BN.YAML.load_file(reference_path;dicttype=Dict{String,Any})
            owner=joinpath(root,reference["payload"]["path"])
            reference["payload"]["bytes"]=filesize(owner)
            reference["payload"]["sha256"]=bytes2hex(open(sha256,owner))
            open(reference_path,"w") do io; BN._light_json(io,reference); end
            @test BN._verify_recovery_reference(reference_path,reference)==owner
        end
        for artifact in commit["artifacts"]
            owner=joinpath(root,artifact["path"])
            artifact["bytes"]=filesize(owner)
            artifact["sha256"]=bytes2hex(open(sha256,owner))
        end
        open(path,"w") do io; BN._light_json(io,commit); end
        if reject
            @test_throws ArgumentError BN.verify_point_artifacts(path)
        else
            @test BN.verify_point_artifacts(path)["identity"]==commit["identity"]
        end
    end
end

function add_recovery_hdf!(document,root;with_final_audit)
    # Real native recovery role in an archive, separate from recovery.json.
    # Reuse tiny native tables, with literal checkpoint-v4 role/schema headers.
    recovery_path=joinpath(root,"recovery.h5")
    cp(joinpath(root,"physics.h5"),recovery_path)
    h5open(recovery_path,"r+") do file
        metadata=file["metadata"]
        for (name,value) in (("schema","qcl-negf-checkpoint-v4"),("artifact_role","recovery"))
            HDF5.delete_attribute(metadata,name)
            HDF5.attributes(metadata)[name]=value
        end
        with_final_audit || HDF5.delete_object(file,"diagnostics/final_fixed_point_audit")
        @test read_attribute(metadata,"schema")=="qcl-negf-checkpoint-v4"
        @test read_attribute(metadata,"artifact_role")=="recovery"
        @test haskey(file,"diagnostics/final_fixed_point_audit")==with_final_audit
    end
    declaration=deepcopy(only(filter(a->a["role"]=="physics.full",document["artifacts"])))
    declaration["role"]="recovery"
    declaration["schema"]="qcl-negf-checkpoint-v4"
    declaration["path"]="recovery.h5"
    push!(document["artifacts"],declaration)
end

function native_roundtrip(directory)
    fixture=native_physics_fixture(;energy_nodes=9)
    template=literal_template()
    template["shape"]=Dict("NE"=>9,"Nk"=>3,"Nb"=>2)
    # Literal values describe format testing; ensure witness normalization matches Nb.
    for name in ("ratio_witness","absolute_witness")
        template["dyson"][name]["identity_F"]=measure(sqrt(2.0))
        template["dyson"][name]["denominator"]=measure(1.0+sqrt(2.0))
    end
    fixture.observables[:final_fixed_point_audit]=template
    supplied=identity(); delete!(supplied,"state_id"); delete!(supplied,"state_sequence")
    path=BN.commit_point_artifacts(directory,fixture;identity=supplied,storage_class=:archive,analysis=true)
    commit=BN.verify_point_artifacts(path)
    record=commit["stationary_assessment"]["final_fixed_point_audit"]
    @test record["state_identity"]==Dict(key=>commit["identity"][key] for key in keys(identity()))
    @test !haskey(template,"state_identity")
    for owner in ("physics.h5","analysis.h5")
        role=owner=="analysis.h5" ? "physics.analysis" : "physics.full"
        h5open(joinpath(dirname(path),owner),"r") do file
            group=file["diagnostics/final_fixed_point_audit"]
            @test read_attribute(group,"schema")=="qcl-negf-final-fixed-point-audit-v1"
            dataset=group["record_json"]
            dtype=HDF5.datatype(dataset)
            try
                @test !HDF5.API.h5t_is_variable_str(dtype)
                @test HDF5.API.h5t_get_cset(dtype)==HDF5.API.H5T_CSET_UTF8
                @test 1<=sizeof(dtype)<=65536
                @test ndims(dataset)==0
            finally; close(dtype); end
            @test read_attribute(dataset,"units")=="1"
            @test read_attribute(dataset,"logical_axis_order")=="scalar"
            @test read_attribute(dataset,"description")=="Versioned final fixed-point raw measurement record"
            for (parent,name) in ((group,"schema"),(dataset,"units"),(dataset,"logical_axis_order"),(dataset,"description"))
                attr=HDF5.open_attribute(parent,name)
                kind=HDF5.datatype(attr)
                try
                    @test !HDF5.API.h5t_is_variable_str(kind)
                    @test HDF5.API.h5t_get_cset(kind)==HDF5.API.H5T_CSET_UTF8
                    @test 1<=sizeof(kind)<=65536
                finally; close(kind); close(attr); end
            end
            @test BN.YAML.load(String(read(dataset));dicttype=Dict{String,Any})==record
            changed=deepcopy(commit)
            delete!(changed["stationary_assessment"],"final_fixed_point_audit")
            @test_throws ArgumentError BN._verify_final_audit_pair(file,changed;role)
            changed=deepcopy(commit)
            changed["stationary_assessment"]["final_fixed_point_audit"]["charge"]["normalized_sheet"]["value"]=2.0
            @test_throws ArgumentError BN._verify_final_audit_pair(file,changed;role)
            for key in ("attempt","state_sequence","plan_fingerprint")
                changed=deepcopy(commit)
                changed["identity"][key]=key=="plan_fingerprint" ? repeat("b",64) : commit["identity"][key]+1
                @test_throws ArgumentError BN._verify_final_audit_pair(file,changed;role)
            end
        end
    end
    # F2: analysis copy is optional, while a present contradictory copy is corrupt.
    mutated_bundle_check(directory,path;reject=false) do _,root
        h5open(joinpath(root,"analysis.h5"),"r+") do file
            HDF5.delete_object(file,"diagnostics/final_fixed_point_audit")
        end
    end
    mutated_bundle_check(directory,path) do document,root
        changed=deepcopy(document["stationary_assessment"]["final_fixed_point_audit"])
        changed["charge"]["normalized_sheet"]["value"]=2.0
        h5open(joinpath(root,"analysis.h5"),"r+") do file
            HDF5.delete_object(file,"diagnostics/final_fixed_point_audit")
            BN._write_final_audit!(file,changed)
        end
    end
    # F6: enclosing archive scope never makes a native recovery payload final.
    # Both controls retain canonical full+commit record and valid native4 tables;
    # declaration bytes/SHA are computed by mutated_bundle_check after the edit.
    mutated_bundle_check(directory,path;reject=false) do document,root
        add_recovery_hdf!(document,root;with_final_audit=false)
    end
    mutated_bundle_check(directory,path) do document,root
        add_recovery_hdf!(document,root;with_final_audit=true)
    end
    # F3: removing the legacy top-level marker must not disable native binding.
    # In each mutant both records and declared artifact identity remain healthy.
    for (owner,identity_key) in (("physics.h5","point_identity_json"),("analysis.h5","identity_json"))
        mutated_bundle_check(directory,path;reject=false) do document,_
            delete!(document,"state_id")
        end
        for key in (nothing,"attempt","state_sequence","plan_fingerprint")
            mutated_bundle_check(directory,path) do document,root
                delete!(document,"state_id")
                h5open(joinpath(root,owner),"r+") do file
                    metadata=file["metadata"]
                    stale=BN.YAML.load(String(read(metadata[identity_key]));dicttype=Dict{String,Any})
                    HDF5.delete_object(metadata,identity_key)
                    if key!==nothing
                        stale[key]=key=="plan_fingerprint" ? repeat("b",64) : stale[key]+1
                        metadata[identity_key]=sprint(BN._light_json,stale)
                    end
                end
            end
        end
    end
    recovery=BN.commit_point_artifacts(directory,fixture;identity=supplied,algorithms=AlgorithmOptions(),analysis=true)
    recovered=BN.verify_point_artifacts(recovery)
    @test !haskey(recovered["stationary_assessment"],"final_fixed_point_audit")
    h5open(joinpath(dirname(recovery),"physics.h5"),"r") do file
        @test !haskey(file,"diagnostics/final_fixed_point_audit")
    end
    # F1: JSON null is a present malformed key, never legacy/recovery absence.
    mutated_bundle_check(directory,recovery) do document,_
        document["stationary_assessment"]["final_fixed_point_audit"]=nothing
    end
    delete!(fixture.observables,:final_fixed_point_audit)
    legacy=BN.commit_point_artifacts(joinpath(directory,"legacy"),fixture;identity=supplied,storage_class=:archive,analysis=false)
    @test !haskey(BN.verify_point_artifacts(legacy)["stationary_assessment"],"final_fixed_point_audit")
    mutated_bundle_check(directory,legacy) do document,_
        document["stationary_assessment"]["final_fixed_point_audit"]=nothing
    end
    fixture.observables[:acceptance_measurement_context]=Dict("backend"=>"production")
    @test_throws ArgumentError BN._bound_final_audit(fixture,identity();final_state=true)
    @test BN._bound_final_audit(fixture,identity();final_state=false)===nothing
    return path
end

@testset "Actual native writer and semantic commit readback" begin
    # Coordinator may retain only this exact owned synthetic output for call8.
    # Unset by default: no durable fixture outside the test's temporary directory.
    retained=get(ENV,"QCL_SCI05_RUNNER_FIXTURE_ROOT","")
    @test retained_fixture_allowed("/tmp/qcl-SCI05-C08-RUNNER-7/tmp/producer-fixture")
    @test !retained_fixture_allowed("/tmp/qcl-sci05-runner-portable-fixture")
    @test !retained_fixture_allowed("/tmp/qcl-SCI05-C08-RUNNER-7/tmp/producer-fixture/other")
    if isempty(retained)
        mktempdir(native_roundtrip)
    else
        retained_fixture_allowed(retained) || error("unexpected synthetic fixture output")
        !ispath(retained) || error("synthetic fixture output already exists")
        mkpath(retained)
        path=native_roundtrip(retained)
        open(joinpath(retained,"fixture-source.txt"),"w") do io
            println(io,"Runner base 9378396a3681c1eddf2c62f16674834fc4465583 + frozen SCI05 writer patch")
            println(io,"Manufactured storage fixture; no scientific solve or convergence claim")
            println(io,path)
        end
    end
end
end
