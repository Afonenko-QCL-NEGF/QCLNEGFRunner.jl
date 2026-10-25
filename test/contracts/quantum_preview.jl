module QuantumPreviewContract
using Test, SHA, LinearAlgebra, Unitful, YAML, QCLNEGFRunner
import QCLNEGF
const W=QCLNEGFRunner.QCLScientificWorkflow
json(x)=sprint(io->QCLNEGFRunner._light_json(io,x))

counts(;Nz=12,Nb=12,P=1,NE=201,Nk=3,Nqz=5,Nphi=4)=
    (N_z=Nz,N_b=Nb,P_basis=P,N_E=NE,N_k=Nk,N_qz=Nqz,N_φ=Nphi)
function tiny(;bias="0 mV",origin="0 nm",reference="0 eV",localization="real_space")
    base=load_run_configuration(joinpath(@__DIR__,"..","fixtures","configurations","studies-smoke.yaml"))
    raw=deepcopy(base.raw)
    raw["physical"]["layers"]=[Dict("thickness"=>"12 nm","material"=>"GaAs",
        "aluminium_fraction"=>0.0,"conduction_band_edge"=>"0.2 eV",
        "longitudinal_relative_mass"=>0.067,"transverse_relative_mass"=>0.067,
        "relative_permittivity"=>12.9,"doped"=>true)]
    merge!(raw["physical"],Dict("interfaces"=>["0 nm"],"voltage_per_period"=>bias,
        "field_bias"=>nothing,"position_origin"=>origin,"reference_energy"=>reference))
    merge!(raw["numerical"],Dict("spatial_nodes"=>12,"basis_states"=>12,"basis_periods"=>1,
        "energy_nodes"=>201,"momentum_nodes"=>3,"longitudinal_momentum_nodes"=>5,"angular_nodes"=>4))
    raw["algorithms"]["localization"]=localization
    QCLNEGFRunner._resolve_configuration(raw,base.provenance)
end

@testset "reference eligible engineering screen, never coarsened" begin
    ref=counts(Nz=198,Nb=5,P=3,NE=2401,Nk=61,Nqz=401,Nphi=64)
    catalog=counts(Nz=96,Nb=5,P=3,NE=30721,Nk=11,Nqz=81,Nphi=32)
    @test W._quantum_screen(ref)==Dict("Nz"=>198,"Nb"=>5,"P"=>3,"NE"=>2401,
        "Nk"=>61,"Nqz"=>401,"Nphi"=>64,"W"=>1386,"S"=>35,"A"=>3125,
        "screen_bytes"=>570928352)
    @test W._quantum_screen(catalog)["screen_bytes"]==191176864
    @test ref.N_z==198 && catalog.N_z==96
    for bad in (counts(Nz=1,Nb=1,P=768),counts(Nz=1,Nb=1,P=128),
        counts(Nb=33),counts(Nz=600,Nb=32,P=1),counts(Nk=100,Nb=32),
        counts(NE=65536),counts(P=typemax(Int)),counts(Nz=true),counts(Nb=1.0))
        called=Ref(false)
        config=(numerical=bad,)
        @test_throws W.QuantumPreviewRefusal W._quantum_basis_payload(config;
            grid_builder=(args...)->(called[]=true))
        @test !called[]
    end
    @test_throws W.QuantumPreviewRefusal W._quantum_screen_bytes(4096,256,12,12,3,225)
end

@testset "N12 absolute energy, discrete sine and normalization independent oracle" begin
    config=tiny()
    payload=W._quantum_basis_payload(config)
    @test payload["dimensions"]["Nz"]==payload["dimensions"]["Nb"]==12
    @test payload["semantics"]["localization"]=="real_space"
    @test payload["semantics"]["hartree"]=="zero"
    @test payload["semantics"]["interperiod_hopping"]=="excluded"
    dx=payload["dx_nm"]; @test dx≈1.0 rtol=8eps(Float64)
    # Authoritative physical constants, independent FD spectrum/sine formula;
    # not a second eigen of the production Hamiltonian.
    hbar=Float64(ustrip(u"J*s",QCLNEGF.CODATA.ħ))
    m0=Float64(ustrip(u"kg",QCLNEGF.CODATA.m₀))
    elementary_charge=Float64(ustrip(u"C",QCLNEGF.CODATA.e))
    t=hbar^2/(2*0.067*m0*(1e-9)^2)/elementary_charge
    want=[0.2+2t*(1-cos(j*pi/13)) for j in 1:12]
    @test payload["energy_eV"]≈want rtol=1e-12
    realpsi=reduce(hcat,payload["psi_real"]); imagpsi=reduce(hcat,payload["psi_imag"])
    # Wire is z-major [Nz][Nb], convert back without transposing physical order.
    psi=permutedims(realpsi+im*imagpsi)
    for state in 1:12
        sine=[sqrt(2/13)*sin(g*state*pi/13) for g in 1:12]
        @test abs(dot(sine,psi[:,state]))≈1 rtol=1e-12
        @test sum(abs2,psi[:,state])*dx≈1 rtol=1e-12
        pivot=argmax(abs.(psi[:,state]))
        @test abs(imag(psi[pivot,state]))<1e-12 && real(psi[pivot,state])>0
    end
    @test maximum(payload["diagnostics"]["norm_error"])<1e-12
end

@testset "point bias and gauge are not rewritten" begin
    @test_throws Exception tiny(bias="-1 mV")
    base=W._quantum_basis_payload(tiny(bias="1 mV"))
    moved=W._quantum_basis_payload(tiny(bias="1 mV",origin="1 nm"))
    @test moved["energy_eV"].-base["energy_eV"]≈fill(0.001/12,12) atol=1e-12
    @test reduce(vcat,moved["density_per_nm"])≈reduce(vcat,base["density_per_nm"]) atol=1e-10
    reference=W._quantum_basis_payload(tiny(reference="0.1 eV"))
    zero=W._quantum_basis_payload(tiny())
    @test reference["energy_eV"]≈zero["energy_eV"] atol=1e-12
    for method in ("none","pzp")
        config=tiny(localization=method)
        @test W._quantum_basis_payload(config)["semantics"]["localization"]==method
    end
end

@testset "mixed face and degenerate block use independent invariant oracles" begin
    H=QCLNEGF.build_bdd_hamiltonian(zeros(2),[0.1,0.2],1.0,0.5)
    @test H[1,2]≈-0.5*2/(0.1+0.2) rtol=1e-14
    Q=ComplexF64[1 0;0 1;0 0]; U=ComplexF64[1 1;-1 1]/sqrt(2)
    @test Q*Q'≈(Q*U)*(Q*U)' atol=1e-14
    @test vec(sum(abs2,Q;dims=2))≈vec(sum(abs2,Q*U;dims=2)) atol=1e-14
    @test abs2.(Q[:,1])!=abs2.((Q*U)[:,1])
end

@testset "bounded response is atomic and byte-identical" begin
    response=Dict("schema"=>"qcl-negf.quantum-preview.v1","status"=>"unavailable")
    mktempdir() do root
        path=joinpath(root,"preview.json")
        stdout=IOBuffer(); W.write_quantum_preview(stdout,response;output=path)
        @test read(path)==take!(stdout)
        @test readdir(root)==["preview.json"]
        @test_throws W.QuantumPreviewRefusal W.write_quantum_preview(IOBuffer(),response;output=path)
        @test_throws W.QuantumPreviewRefusal W._quantum_json(Dict("x"=>repeat("a",2*1024^2)))
    end
end
end

module QuantumPreviewTransportContract
using Test, SHA, YAML, QCLNEGFRunner
using ..QuantumPreviewContract: tiny
const W=QCLNEGFRunner.QCLScientificWorkflow
json(x)=sprint(io->QCLNEGFRunner._light_json(io,x))
function fixture(f;config=tiny())
    mktempdir() do root
        YAML.write_file(joinpath(root,"tiny.yaml"),config.raw)
        study=Dict("schema"=>"qcl-negf-study-v2","kind"=>"study","id"=>"quantum-tiny",
            "configuration"=>Dict("sources"=>["tiny.yaml"]),
            "axes"=>Dict("temperatures"=>Dict("values"=>[70],"unit"=>"K"),
                "voltages"=>Dict("values"=>[0,1],"unit"=>"mV")),
            "policies"=>Dict("scba_to_poisson"=>"strict_fail_fast","voltage"=>Dict("mode"=>"independent")))
        path=joinpath(root,"study.yaml"); YAML.write_file(path,study)
        plan=resolve_scientific_plan(path;maximum_solver_runs=2)
        # Independent voltage policy legitimately creates one execution per bias.
        # Select the declared 0mV/70K case explicitly; retain the whole plan.
        point=only(filter(p->p.voltage_per_period_V==0.0 && p.temperature_K==70.0,plan.points))
        execution=only(filter(e->e.id==point.execution_id,plan.executions))
        @test point.id in execution.point_ids
        @test Set((p.voltage_per_period_V,p.temperature_K) for p in plan.points)==Set([(0.0,70.0),(0.001,70.0)])
        raw=json(scientific_plan_dict(plan))
        request=Dict("schema"=>"qcl-negf.quantum-preview-request.v1","plan"=>raw,
            "plan_sha256"=>bytes2hex(sha256(raw)),"expected_runner_source_id"=>"runner-fixture",
            "expected_core_source_id"=>"core-fixture","execution_id"=>execution.id,
            "point_id"=>point.id,"variant_id"=>execution.variant_id,"budget_policy_id"=>"quantum-preview-reference-v1")
        f((;root,plan,raw,request))
    end
end
@testset "reference model and actual catalog policy pass preallocation unchanged" begin
    model=joinpath(@__DIR__,"..","fixtures","research-inputs","model","reference-2019-70k.yaml")
    reference=load_run_configuration(model)
    raw=deepcopy(reference.raw)
    # This existing checked-in policy is byte-identical to Research408's actual
    # catalog analytical policy; do not substitute only a smaller grid tuple.
    policy_path=joinpath(@__DIR__,"..","..","examples","config","analytical-diagnostic.yaml")
    policy=YAML.load_file(policy_path;dicttype=Dict{String,Any})
    sources=deepcopy(reference.provenance.sources)
    QCLNEGFRunner._deep_merge!(raw,policy,sources,policy_path)
    provenance=QCLNEGFRunner.ConfigurationProvenance(copy(reference.provenance.manifests),
        vcat(reference.provenance.files,[policy_path]),sources)
    catalog=QCLNEGFRunner._resolve_configuration(raw,provenance)
    for (config,width,bytes) in ((reference,1386,570928352),(catalog,672,191176864))
        fixture(;config) do x
            data=W._configurator_json(x.raw;maximum=1024^2)
            before=json(data)
            W._quantum_raw_screen(data)
            @test json(data)==before
            @test all(e->e.configuration.numerical.N_z==config.numerical.N_z,x.plan.executions)
            @test W._quantum_screen(config.numerical)["W"]==width
            @test W._quantum_screen(config.numerical)["screen_bytes"]==bytes
            @test W.load_scientific_plan(data).fingerprint==x.plan.fingerprint
        end
    end
end
@testset "exact frozen membership, bounded request and absent delivery refuses without arrays" begin
    fixture() do x
        before=read(joinpath(x.root,"tiny.yaml"))
        response=W.quantum_preview(json(x.request),"runner-fixture","core-fixture")
        @test response["status"]=="unavailable"
        @test response["reason"]=="runtime_source_binding_unavailable"
        @test response["identity"]["plan_sha256"]==bytes2hex(sha256(x.raw))
        @test response["identity"]["point_passport"]["axes_applied"]===true
        @test response["payload"]===nothing && response["plan_changed"]===false
        # DTO-only integration with actual pure Core N12 data. This deliberately
        # does not claim that the production delivery verifier admitted a child.
        payload=W._quantum_basis_payload(tiny())
        artifact=W._quantum_artifact(x.request,response["identity"],payload)
        wire=W._quantum_json(artifact)
        decoded=W._configurator_json(wire;maximum=2*1024^2)
        @test decoded["schema"]=="qcl-negf.quantum-preview.v1"
        @test decoded["payload"]["shape"]==[12,12]
        @test length(decoded["payload"]["psi_real"])==12
        @test all(length(row)==12 for row in decoded["payload"]["psi_real"])
        @test decoded["assessment"]==Dict("SCBA"=>"not_performed","Poisson"=>"not_performed","scientific"=>"not_assessed")
        @test decoded["measurements"]["peak_bytes"]===nothing
        @test decoded["identity"]["plan_sha256"]==x.request["plan_sha256"]
        @test artifact["preview_id"]!=W._quantum_artifact(merge(x.request,Dict("point_id"=>last(x.plan.points).id)),response["identity"],payload)["preview_id"]
        @test decoded["payload_sha256"]!=decoded["preview_id"]
        @test before==read(joinpath(x.root,"tiny.yaml"))
        # Literal structural negatives must refuse before even the source port.
        config=only(filter(e->e["id"]==x.request["execution_id"],W._configurator_json(x.raw;maximum=1024^2)["executions"]))["resolved_configuration"]
        malformed=(
            Dict("executions"=>[1],"points"=>[]),
            Dict("executions"=>[Dict("resolved_configuration"=>1)],"points"=>[]),
            Dict("executions"=>[Dict("resolved_configuration"=>Dict("physical"=>1,"numerical"=>Dict()))],"points"=>[]),
            Dict("executions"=>[Dict("resolved_configuration"=>Dict("physical"=>Dict("layers"=>[]),"numerical"=>1))],"points"=>[]),
            Dict("executions"=>[Dict("resolved_configuration"=>Dict("physical"=>Dict("layers"=>1),"numerical"=>Dict()))],"points"=>[]),
            Dict("executions"=>[Dict("resolved_configuration"=>Dict("physical"=>Dict("layers"=>[1]),"numerical"=>config["numerical"]))],"points"=>[]),
            Dict("executions"=>[],"points"=>[1]),
            Dict("executions"=>Dict(),"points"=>[]),
            Dict("executions"=>[],"points"=>Dict()))
        for data in malformed
            raw=json(data); request=merge(x.request,Dict("plan"=>raw,"plan_sha256"=>bytes2hex(sha256(raw))))
            probes=Ref(0)
            bad=W.quantum_preview(json(request),"runner-fixture","core-fixture";
                runtime_verifier=(args...)->(probes[]+=1))
            @test bad["status"]=="error" && bad["reason"]=="invalid_plan"
            @test bad["payload"]===nothing && bad["plan_changed"]===false
            @test probes[]==0
            @test ncodeunits(W._quantum_json(bad))<=2*1024^2
        end
        for change in (Dict("plan_sha256"=>"0"^64),Dict("point_id"=>"foreign"),
            Dict("execution_id"=>"foreign"),Dict("variant_id"=>"foreign"),
            Dict("expected_runner_source_id"=>"foreign"),Dict("budget_policy_id"=>"quantum-preview-small-v1"),
            Dict("source_binding_file"=>"/private/forbidden"),Dict("plan"=>" "^(1024^2+1)))
            bad=W.quantum_preview(json(merge(x.request,change)),"runner-fixture","core-fixture")
            @test bad["status"]=="error" && bad["payload"]===nothing
        end
        for key in ("fingerprint","scientific_fingerprint")
            data=W._configurator_json(x.raw;maximum=1024^2);data[key]="0"^64
            raw=json(data);request=merge(x.request,Dict("plan"=>raw,"plan_sha256"=>bytes2hex(sha256(raw))))
            @test W.quantum_preview(json(request),"runner-fixture","core-fixture")["status"]=="error"
        end
        duplicate=replace(json(x.request),"\"schema\":"=>"\"schema\":null,\"schema\":";count=1)
        @test W.quantum_preview(duplicate,"runner-fixture","core-fixture")["status"]=="error"
        input=joinpath(x.root,"request.json");output=joinpath(x.root,"preview.json")
        capture=joinpath(x.root,"stdout.json");write(input,json(x.request))
        status=open(input) do source
            open(capture,"w") do destination
                redirect_stdin(source) do
                    redirect_stdout(destination) do
                        QCLNEGFRunner.main(["quantum-preview","--runner-source-id","runner-fixture",
                            "--core-source-id","core-fixture","--output",output])
                    end
                end
            end
        end
        @test status==2 && read(output)==read(capture)
    end
end
@testset "same source labels cannot replace actual closure/project/rules proof" begin
    output="/nix/store/"*"a"^32*"-synthetic-only"
    root=joinpath(output,"share","qcl-negf")
    actual=(runner=joinpath(root,"components","QCLNEGFRunner.jl"),
        core=joinpath(root,"components","QCLNEGF.jl"),project=joinpath(root,"julia","Project.toml"),
        manifest=joinpath(root,"julia","Manifest.toml"))
    files=Dict(actual.project=>"synthetic project",actual.manifest=>"synthetic manifest")
    rules=Dict{String,String}()
    for (owner,relative) in W.QUANTUM_RULES
        text=string(owner,":",relative," synthetic only")
        files[joinpath(getfield(actual,owner),relative)]=text
        rules[string(owner,":",relative)]=bytes2hex(sha256(text))
    end
    record=(release_id="synthetic-only",solver_executable=joinpath(output,"bin","qcl-negf"),
        runner_source_id="runner-fixture",core_source_id="core-fixture",solver_output=output,
        source_graph_sha256="b"^64,julia_manifest_sha256=bytes2hex(sha256(files[actual.manifest])),
        drv_path=output*".drv",nar_hash="sha256-synthetic-only",context_sha256="c"^64)
    read_small=path->Vector{UInt8}(codeunits(files[path]))
    verifier=(expected,observed)->begin
        @test expected==(runner_source_id="runner-fixture",core_source_id="core-fixture")
        record # Explicit synthetic delivery double, no native installed claim.
    end
    view=W._quantum_runtime_source("runner-fixture","core-fixture";
        verifier,probe=()->actual,read_small)
    @test view["manifest_sha256"]==record.julia_manifest_sha256
    @test view["rule_sha256"]==rules
    @test_throws W.QuantumPreviewRefusal W._quantum_runtime_source("runner-fixture","core-fixture")
    for changed in (merge(actual,(runner="/wrong/Runner",)),merge(actual,(core="/wrong/Core",)),
        merge(actual,(project="/wrong/Project.toml",)),merge(actual,(manifest="/wrong/Manifest.toml",)))
        @test_throws W.QuantumPreviewRefusal W._quantum_runtime_source("runner-fixture","core-fixture";
            verifier,probe=()->changed,read_small)
    end
    for changed in (merge(record,(julia_manifest_sha256="0"^64,)),merge(record,(solver_executable="/wrong/solver",)),
        merge(record,(runner_source_id="foreign",)),
        (runner_source_id="runner-fixture",core_source_id="core-fixture"))
        @test_throws W.QuantumPreviewRefusal W._quantum_runtime_source("runner-fixture","core-fixture";
            verifier=(args...)->changed,probe=()->actual,read_small)
    end
    # The existing delivery owner, not a neighbouring rule SHA, verifies NAR,
    # compiled image/build association and context digest before returning a port value.
    refused=(args...)->W._quantum_refuse("runtime_source_mismatch")
    @test_throws W.QuantumPreviewRefusal W._quantum_runtime_source("runner-fixture","core-fixture";
        verifier=refused,probe=()->actual,read_small)
end
end
