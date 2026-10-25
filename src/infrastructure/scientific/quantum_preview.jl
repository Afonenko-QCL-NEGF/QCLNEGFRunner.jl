# Basis-only diagnostic. Core owns operators/normalization; no solver state exists here.
import QCLNEGF
const QUANTUM_PREVIEW_POLICY="quantum-preview-reference-v1"
const QUANTUM_PREVIEW_REVISION=1
const QUANTUM_PLAN_BYTES=1024^2
const QUANTUM_REQUEST_BYTES=1536*1024
const QUANTUM_RESPONSE_BYTES=2*1024^2
const QUANTUM_SCREEN_BYTES=1024^3
struct QuantumPreviewRefusal <: Exception
    code::String
    actual::Any
    allowed::Any
end
_quantum_refuse(code,actual=nothing,allowed=nothing)=throw(QuantumPreviewRefusal(code,actual,allowed))
function _quantum_count(value;minimum=1)
    value isa Integer && !(value isa Bool) && minimum<=value<=typemax(Int) ||
        _quantum_refuse("invalid_dimension",string(value),"integer >= $minimum")
    return Int(value)
end
function _quantum_bound(code,actual,allowed)
    actual<=allowed || _quantum_refuse(code,actual,allowed)
    actual
end
function _quantum_screen_bytes(W,S,Nz,Nb,Nk,A)
    mul=Base.checked_mul; add=Base.checked_add
    terms=(64*1024^2,mul(256,mul(W,W)),mul(128,mul(W,S)),mul(192,mul(S,S)),
        mul(128,mul(Nz,Nz)),mul(128,mul(Nz,Nb)),mul(256,mul(Nb,Nb)),
        mul(32,mul(Nk,mul(Nb,Nb))),mul(128,A))
    bytes=foldl(add,terms)
    _quantum_bound("screen_bytes_limit",bytes,QUANTUM_SCREEN_BYTES)
end
function _quantum_screen(n)
    try
        Nz=_quantum_count(n.N_z); Nb=_quantum_count(n.N_b); P=_quantum_count(n.P_basis)
        NE=_quantum_count(n.N_E); Nk=_quantum_count(n.N_k)
        Nqz=_quantum_count(n.N_qz); Nphi=_quantum_count(n.N_φ)
        mul=Base.checked_mul; add=Base.checked_add
        periods=add(mul(2,P),1); W=mul(periods,Nz); S=mul(periods,Nb)
        _quantum_bound("window_limit",W,1536)
        _quantum_bound("subspace_limit",S,256); _quantum_bound("subspace_window_limit",S,W)
        _quantum_bound("basis_limit",Nb,min(Nz,32))
        _quantum_bound("spatial_basis_limit",mul(Nz,Nb),16384)
        _quantum_bound("momentum_basis_limit",mul(Nk,mul(Nb,Nb)),65536)
        A=foldl(add,(NE,Nqz,Nphi,Nk,Nz)); _quantum_bound("axes_limit",A,65536)
        bytes=_quantum_screen_bytes(W,S,Nz,Nb,Nk,A)
        return Dict("Nz"=>Nz,"Nb"=>Nb,"P"=>P,"NE"=>NE,"Nk"=>Nk,"Nqz"=>Nqz,
            "Nphi"=>Nphi,"W"=>W,"S"=>S,"A"=>A,"screen_bytes"=>bytes)
    catch error
        error isa OverflowError || rethrow()
        _quantum_refuse("dimension_overflow")
    end
end
function _quantum_raw_screen(data)
    executions=get(data,"executions",nothing); points=get(data,"points",nothing)
    executions isa AbstractVector && points isa AbstractVector || _quantum_refuse("invalid_plan")
    _quantum_bound("executions_limit",length(executions),64)
    _quantum_bound("points_limit",length(points),256)
    all(point->point isa AbstractDict,points) || _quantum_refuse("invalid_plan")
    for execution in executions
        execution isa AbstractDict || _quantum_refuse("invalid_plan")
        raw=get(execution,"resolved_configuration",nothing)
        raw isa AbstractDict || _quantum_refuse("invalid_plan")
        physical=get(raw,"physical",nothing); n=get(raw,"numerical",nothing)
        physical isa AbstractDict && n isa AbstractDict || _quantum_refuse("invalid_plan")
        layers=get(physical,"layers",nothing)
        layers isa AbstractVector && all(layer->layer isa AbstractDict,layers) || _quantum_refuse("invalid_plan")
        _quantum_bound("layers_limit",length(layers),256)
        _quantum_screen((N_z=n["spatial_nodes"],N_b=n["basis_states"],P_basis=n["basis_periods"],
            N_E=n["energy_nodes"],N_k=n["momentum_nodes"],N_qz=n["longitudinal_momentum_nodes"],N_φ=n["angular_nodes"]))
    end
end

# Kept separate so the tiny independent arithmetic oracle does not need a plan,
# runtime delivery record, NEGFProblem, Green matrix, kernel or output directory.
function _quantum_basis_payload(config;grid_builder=QCLNEGF.build_grids)
    dims=_quantum_screen(config.numerical) # Must precede every Core allocation.
    p=QCLNEGF.resolve_physical_models(config.physical,config.physical_models)
    n=config.numerical; s=config.scales; localization=config.algorithms.localization
    localization in (:pzp,:none,:real_space) || _quantum_refuse("unsupported_localization")
    config.physical_models.dispersion in (:parabolic,:kane_inplane) ||
        _quantum_refuse("unsupported_dispersion")
    grids=grid_builder(p,n,s)
    first(grids.κ)==0 || _quantum_refuse("nonzero_first_momentum")
    profiles=QCLNEGF.build_profiles(p,n,s,grids)
    basis=QCLNEGF.build_basis(p,n,s,grids,profiles;localization)
    # At k0 both supported transverse models contribute exactly zero. Use the
    # actual Core pure overload: same onsite/window seam diagonals, no T±.
    h=QCLNEGF.project_hamiltonians(basis,grids,profiles,p,s,zeros(n.N_z))
    h0=Matrix(view(h,1,:,:))
    residual=norm(h0-h0')/(norm(h0)+QCLNEGF._EFFECTIVE_HAMILTONIAN_NORM_FLOOR)
    residual<=QCLNEGF._EFFECTIVE_HAMILTONIAN_HERMITICITY_LIMIT ||
        _quantum_refuse("nonhermitian_projected_hamiltonian")
    decomposition=eigen(Hermitian(h0))
    V=copy(decomposition.vectors); spatial=basis.χ*V
    for state in axes(spatial,2)
        pivot=argmax(abs.(view(spatial,:,state))); amplitude=spatial[pivot,state]
        if abs(amplitude)>0
            phase=conj(amplitude)/abs(amplitude)
            spatial[:,state].*=phase; V[:,state].*=phase
        end
    end
    L0_nm=s.L₀_m*1e9; dx_nm=grids.wˣ[1]*L0_nm
    psi=spatial./sqrt(L0_nm); density=abs2.(psi)
    Eref=Float64(ustrip(u"eV",p.E_ref))
    energies=decomposition.values.*s.E₀_eV .+ Eref
    eigen_residual=norm(h0*V-V*Diagonal(decomposition.values))/(norm(h0)+QCLNEGF._EFFECTIVE_HAMILTONIAN_NORM_FLOOR)
    norms=vec(sum(density;dims=1)).*dx_nm
    all(isfinite,energies) && all(isfinite,psi) && all(isfinite,density) && all(isfinite,norms) &&
        isfinite(dx_nm) && dx_nm>0 && all(isfinite,grids.x.*L0_nm) &&
        all(isfinite,(residual,eigen_residual,basis.r_orth,basis.r_eigen)) ||
        _quantum_refuse("nonfinite_output")
    # Explicit z-major rows: the generic light JSON writer flattens matrices.
    rows(matrix)=[[matrix[z,state] for state in axes(matrix,2)] for z in axes(matrix,1)]
    return Dict{String,Any}(
        "dimensions"=>dims,"shape"=>[n.N_z,n.N_b],"energy_eV"=>energies,
        "z_nm"=>grids.x.*L0_nm,"dx_nm"=>dx_nm,
        "psi_real"=>rows(real.(psi)),"psi_imag"=>rows(imag.(psi)),"density_per_nm"=>rows(density),
        "band_edge_eV"=>profiles.Eᶜ.*s.E₀_eV .+ Eref,
        "numerical_inputs"=>deepcopy(config.raw["numerical"]),
        "scattering_inputs"=>deepcopy(config.raw["scattering"]),
        "physical_model_inputs"=>deepcopy(get(config.raw,"physical_models",Dict{String,Any}())),
        "units"=>Dict("energy"=>"eV","z"=>"nm","psi"=>"nm^-1/2","density"=>"nm^-1"),
        "semantics"=>Dict("scope"=>"bare_onsite_k0","hartree"=>"zero","kappa"=>0,
            "interperiod_hopping"=>"excluded","basis_field"=>"zero",
            "band_overlay"=>"zero-field material conduction band; no Hartree or bias tilt",
            "window_boundary"=>"Dirichlet","central_block"=>"same_window_seam_face_diagonals",
            "localization"=>String(localization),"dispersion"=>String(config.physical_models.dispersion),
            "pzp"=>"central-column selection, cell restriction, Lowdin; only when configured",
            "phase"=>"largest spatial amplitude real positive",
            "degeneracy"=>"individual wavefunctions and densities not unique; compare whole-block projector or summed density",
            "normalization"=>"discrete sum(dx_nm*density_per_nm)=1",
            "doping"=>"recorded, no Hartree generated","bias_V_per_m"=>Float64(ustrip(u"V/m",p.F_bias)),
            "temperature_K"=>Float64(ustrip(u"K",p.Tᴸ)),"position_origin_nm"=>Float64(ustrip(u"nm",p.z₀)),
            "reference_energy_eV"=>Eref,"L0_nm"=>L0_nm,"E0_eV"=>s.E₀_eV),
        "diagnostics"=>Dict("hermiticity_residual"=>residual,"eigen_residual"=>eigen_residual,
            "basis_orthogonality_residual"=>basis.r_orth,"basis_eigen_residual"=>basis.r_eigen,
            "norm_error"=>abs.(norms.-1),"acceptance"=>"diagnostic_only"))
end

# Existing delivery must supply the graph→drv/output/NAR/Manifest/loaded-package
# verification. Neither request labels nor neighbouring source hashes prove it.
# This fail-closed port is intentional until that owning delivery seam is bound;
# no standalone binding file, environment protocol or approval flag is created.
_quantum_delivery_unavailable(expected,actual)=
    _quantum_refuse("runtime_source_binding_unavailable")
# Existing root-published release record is the authority, never the process env.
const QUANTUM_RELEASE_FILE="/var/lib/qcl-negf-admin/runtime/release.json"
const QUANTUM_CONTEXT_KEYS=("release_id","solver_executable","solver_output","nar_hash","drv_path",
    "source_graph_sha256","julia_manifest_sha256","runner_source_id","core_source_id","context_sha256")
function _quantum_sorted_ascii_json(value)
    io=IOBuffer()
    function write_value(x)
        if x isa AbstractString
            all(c->' '<=c<='\x7e' && c!='"' && c!='\\',x) || _quantum_refuse("runtime_source_mismatch")
            print(io,'"',x,'"')
        elseif x isa AbstractDict
            all(k->k isa AbstractString,keys(x)) || _quantum_refuse("runtime_source_mismatch")
            print(io,'{')
            for (i,key) in enumerate(sort!(collect(keys(x))))
                i>1 && print(io,','); write_value(key); print(io,':'); write_value(x[key])
            end
            print(io,'}')
        elseif x isa AbstractVector
            print(io,'[')
            for (i,item) in enumerate(x)
                i>1 && print(io,','); write_value(item)
            end
            print(io,']')
        else
            _quantum_refuse("runtime_source_mismatch")
        end
    end
    write_value(value); String(take!(io))
end
function _quantum_root_record()
    path=QUANTUM_RELEASE_FILE
    for parent in ("/","/var","/var/lib","/var/lib/qcl-negf-admin","/var/lib/qcl-negf-admin/runtime")
        s=lstat(parent)
        isdir(s) && !islink(s) && s.uid==0 && (s.mode & 0o022)==0 ||
            _quantum_refuse("runtime_source_binding_unavailable")
    end
    before=lstat(path)
    isfile(before) && !islink(before) && before.uid==0 && (before.mode & 0o022)==0 && before.size<=65536 ||
        _quantum_refuse("runtime_source_binding_unavailable")
    raw=open(path,"r") do io
        opened=stat(fd(io))
        (opened.device,opened.inode)==(before.device,before.inode) || _quantum_refuse("runtime_source_binding_unavailable")
        bytes=read(io,65537)
        after=stat(fd(io))
        (opened.size,opened.mtime,opened.uid,opened.mode)==(after.size,after.mtime,after.uid,after.mode) ||
            _quantum_refuse("runtime_source_binding_unavailable")
        bytes
    end
    length(raw)<=65536 || _quantum_refuse("runtime_source_binding_unavailable")
    record=_configurator_json(String(raw);maximum=65536)
    profile="/nix/var/nix/profiles/qcl-negf-application"
    application=get(record,"application_path",nothing); solver=get(record,"solver_executable",nothing)
    application isa AbstractString && solver isa AbstractString || _quantum_refuse("runtime_source_mismatch")
    realpath(profile)==application && realpath(profile*"-solver")==dirname(dirname(solver)) ||
        _quantum_refuse("runtime_source_mismatch")
    record
end
function _quantum_delivery_context(expected,actual;environment=ENV,read_record=_quantum_root_record)
    get(environment,"QCL_NEGF_QUANTUM_RUNTIME_RELEASE_FILE",nothing)==QUANTUM_RELEASE_FILE ||
        _quantum_refuse("runtime_source_binding_unavailable")
    raw=get(environment,"QCL_NEGF_QUANTUM_RUNTIME_CONTEXT",nothing)
    raw isa AbstractString && ncodeunits(raw)<=8192 || _quantum_refuse("runtime_source_binding_unavailable")
    supplied=_configurator_json(raw;maximum=8192)
    record=read_record()
    record isa AbstractDict && get(record,"ready",nothing)===true || _quantum_refuse("runtime_source_binding_unavailable")
    context=get(record,"quantum_runtime_context",nothing)
    context isa AbstractDict && Set(keys(context))==Set(QUANTUM_CONTEXT_KEYS) && supplied==context ||
        _quantum_refuse("runtime_source_mismatch")
    all(v->v isa AbstractString && 1<=ncodeunits(v)<=512,values(context)) || _quantum_refuse("runtime_source_mismatch")
    c=Dict(k=>v for (k,v) in context if k!="context_sha256")
    _cfg_sha(_quantum_sorted_ascii_json(c))==context["context_sha256"]==get(environment,"QCL_NEGF_QUANTUM_RUNTIME_CONTEXT_SHA256",nothing) ||
        _quantum_refuse("runtime_source_mismatch")
    for (field,env) in (("release_id","QCL_NEGF_RELEASE_ID"),("solver_executable","QCL_NEGF_SOLVER_EXECUTABLE"))
        context[field]==get(record,field,nothing)==get(environment,env,nothing) || _quantum_refuse("runtime_source_mismatch")
    end
    context["runner_source_id"]==expected.runner_source_id && context["core_source_id"]==expected.core_source_id ||
        _quantum_refuse("runtime_source_mismatch")
    graph=get(record,"sources",nothing); build=get(record,"solver_build",nothing); closures=get(record,"closures",nothing)
    graph isa AbstractDict && Set(keys(graph))==Set(("format","revision","components")) &&
        get(graph,"format",nothing)=="qcl-negf.git-graph.v1" &&
        get(graph,"revision",nothing) isa AbstractString && occursin(r"^[0-9a-f]{40}$",graph["revision"]) ||
        _quantum_refuse("runtime_source_mismatch")
    rows=graph["components"]
    rows isa AbstractVector && 1<=length(rows)<=64 || _quantum_refuse("runtime_source_mismatch")
    refs=Dict{String,String}()
    for row in rows
        row isa AbstractDict && Set(keys(row))==Set(("path","revision","url")) || _quantum_refuse("runtime_source_mismatch")
        for (key,pattern) in (("path",r"^components/[A-Za-z0-9][A-Za-z0-9.-]*$"),("revision",r"^[0-9a-f]{40}$"),
            ("url",r"^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$"))
            row[key] isa AbstractString && ncodeunits(row[key])<=256 && occursin(pattern,row[key]) || _quantum_refuse("runtime_source_mismatch")
        end
        haskey(refs,row["path"]) && _quantum_refuse("runtime_source_mismatch")
        refs[row["path"]]=row["revision"]
    end
    get(refs,"components/QCLNEGFRunner.jl",nothing)==context["runner_source_id"] &&
        get(refs,"components/QCLNEGF.jl",nothing)==context["core_source_id"] &&
        _cfg_sha(_quantum_sorted_ascii_json(graph))==context["source_graph_sha256"] || _quantum_refuse("runtime_source_mismatch")
    build isa AbstractDict && Set(keys(build))==Set(("source_graph_sha256","julia_manifest_sha256","drv_path","output_path")) ||
        _quantum_refuse("runtime_source_mismatch")
    for (b,c) in (("source_graph_sha256","source_graph_sha256"),("julia_manifest_sha256","julia_manifest_sha256"),
        ("drv_path","drv_path"),("output_path","solver_output"))
        build[b]==context[c] || _quantum_refuse("runtime_source_mismatch")
    end
    closures isa AbstractVector && 1<=length(closures)<=64 || _quantum_refuse("runtime_source_mismatch")
    matches=filter(r->r isa AbstractDict && get(r,"path",nothing)==context["solver_output"],closures)
    length(matches)==1 && get(only(matches),"narHash",nothing)==context["nar_hash"] || _quantum_refuse("runtime_source_mismatch")
    NamedTuple{Tuple(Symbol.(QUANTUM_CONTEXT_KEYS))}(Tuple(context[k] for k in QUANTUM_CONTEXT_KEYS))
end
const QUANTUM_RULES=(
    (:runner,"src/infrastructure/config/configuration.jl"),
    (:runner,"src/application/scientific/planning.jl"),
    (:runner,"src/infrastructure/scientific/snapshots.jl"),
    (:runner,"src/infrastructure/scientific/quantum_preview.jl"),
    (:core,"src/numerics/reference/grids.jl"),(:core,"src/numerics/reference/basis.jl"),
    (:core,"src/numerics/reference/hamiltonian.jl"),(:core,"src/numerics/reference/model_operators.jl"),
    (:core,"src/physics/observables.jl"),(:core,"src/domain/numerical_invariants.jl"))
function _quantum_loaded_runtime()
    project=Base.active_project()
    project===nothing && _quantum_refuse("runtime_source_binding_unavailable")
    return (runner=realpath(pkgdir(QCLNEGFRunner)),core=realpath(pkgdir(QCLNEGF)),
        project=realpath(project),manifest=realpath(joinpath(dirname(project),"Manifest.toml")))
end
function _quantum_read_small(path)
    bytes=open(path,"r") do io
        read(io,2*1024^2+1)
    end
    length(bytes)<=2*1024^2 || _quantum_refuse("runtime_source_file_limit")
    bytes
end
function _quantum_runtime_source(runner_source_id,core_source_id;
    verifier=_quantum_delivery_context,probe=_quantum_loaded_runtime,read_small=_quantum_read_small)
    verifier===_quantum_delivery_unavailable && _quantum_refuse("runtime_source_binding_unavailable")
    try
        return _quantum_runtime_checked(runner_source_id,core_source_id,verifier,probe,read_small)
    catch failure
        failure isa Union{Base.IOError,Base.SystemError} || rethrow()
        _quantum_refuse("runtime_source_binding_unavailable")
    end
end
function _quantum_runtime_checked(runner_source_id,core_source_id,verifier,probe,read_small)
    # verifier is an owning delivery port, never taken from stdin. It must have
    # verified existing release/build graph→drv/output/NAR/compiled-image binding.
    actual=probe()
    record=verifier((runner_source_id=runner_source_id,core_source_id=core_source_id),actual)
    record isa NamedTuple || _quantum_refuse("runtime_source_binding_unavailable")
    required=(:release_id,:solver_executable,:solver_output,:nar_hash,:drv_path,
        :source_graph_sha256,:julia_manifest_sha256,:runner_source_id,:core_source_id,:context_sha256)
    Set(keys(record))==Set(required) || _quantum_refuse("runtime_source_binding_unavailable")
    record.runner_source_id==runner_source_id && record.core_source_id==core_source_id ||
        _quantum_refuse("runtime_source_mismatch")
    output=record.solver_output
    output isa AbstractString && occursin(r"^/nix/store/[a-z0-9]{32}-[^/]+$",output) ||
        _quantum_refuse("runtime_source_mismatch")
    runtime=joinpath(output,"share","qcl-negf")
    wanted=(runner=joinpath(runtime,"components","QCLNEGFRunner.jl"),
        core=joinpath(runtime,"components","QCLNEGF.jl"),
        project=joinpath(runtime,"julia","Project.toml"),manifest=joinpath(runtime,"julia","Manifest.toml"))
    actual==wanted || _quantum_refuse("runtime_source_mismatch")
    record.solver_executable==joinpath(output,"bin","qcl-negf") || _quantum_refuse("runtime_source_mismatch")
    _resource_string(record.release_id)
    for key in (:source_graph_sha256,:julia_manifest_sha256,:context_sha256)
        _resource_sha(getfield(record,key))
    end
    record.drv_path isa AbstractString && startswith(record.drv_path,"/nix/store/") &&
        endswith(record.drv_path,".drv") && record.nar_hash isa AbstractString &&
        1<=ncodeunits(record.nar_hash)<=256 || _quantum_refuse("runtime_source_mismatch")
    project_sha256=_cfg_sha(read_small(actual.project))
    _cfg_sha(read_small(actual.manifest))==record.julia_manifest_sha256 || _quantum_refuse("runtime_source_mismatch")
    rules=Dict{String,String}(); total=0
    for (owner,relative) in QUANTUM_RULES
        bytes=read_small(joinpath(getfield(actual,owner),relative))
        total=Base.checked_add(total,length(bytes)); _quantum_bound("runtime_source_file_limit",total,2*1024^2)
        rules[string(owner,":",relative)]=_cfg_sha(bytes)
    end
    return Dict("runner_source_id"=>runner_source_id,"core_source_id"=>core_source_id,
        "source_graph_sha256"=>record.source_graph_sha256,"manifest_sha256"=>record.julia_manifest_sha256,
        "project_sha256"=>project_sha256,"release_id"=>record.release_id,"context_sha256"=>record.context_sha256,
        "nar_hash"=>record.nar_hash,"derivation_id_sha256"=>_cfg_sha(record.drv_path),
        "rule_sha256"=>rules,"compiled_binding"=>"verified_by_owning_delivery_port")
end

function _quantum_request(bytes,runner_source_id,core_source_id)
    _resource_string(runner_source_id); _resource_string(core_source_id)
    request=_configurator_json(bytes;maximum=QUANTUM_REQUEST_BYTES)
    _cfg_keys(request,("schema","plan","plan_sha256","expected_runner_source_id","expected_core_source_id",
        "execution_id","point_id","variant_id","budget_policy_id"))
    request["schema"]=="qcl-negf.quantum-preview-request.v1" || _quantum_refuse("unsupported_request")
    request["budget_policy_id"]==QUANTUM_PREVIEW_POLICY || _quantum_refuse("unsupported_budget_policy")
    request["expected_runner_source_id"]==runner_source_id &&
        request["expected_core_source_id"]==core_source_id || _quantum_refuse("source_id_mismatch")
    plan=request["plan"]
    plan isa AbstractString && ncodeunits(plan)<=QUANTUM_PLAN_BYTES || _quantum_refuse("plan_limit")
    _resource_sha(request["plan_sha256"])==_cfg_sha(plan) || _quantum_refuse("plan_sha256_mismatch")
    for key in ("execution_id","point_id","variant_id")
        request[key] isa AbstractString || _quantum_refuse("invalid_selector")
        _scientific_identity(String(request[key]),key)
    end
    return request
end

function quantum_preview(bytes::AbstractString,runner_source_id::AbstractString,core_source_id::AbstractString;
    runtime_verifier=_quantum_delivery_context)
    identity=Dict{String,Any}()
    try
        request=_quantum_request(bytes,runner_source_id,core_source_id)
        data=_configurator_json(request["plan"];maximum=QUANTUM_PLAN_BYTES)
        identity=Dict{String,Any}("request_sha256"=>_cfg_sha(bytes),"plan_sha256"=>request["plan_sha256"],
            "fingerprint"=>get(data,"fingerprint",nothing),"scientific_fingerprint"=>get(data,"scientific_fingerprint",nothing),
            "execution_id"=>request["execution_id"],"point_id"=>request["point_id"],"variant_id"=>request["variant_id"],
            "runner_source_id"=>runner_source_id,"core_source_id"=>core_source_id)
        _quantum_raw_screen(data)
        plan=load_scientific_plan(data) # Owning fingerprints, passports, membership.
        execution=only(filter(e->e.id==request["execution_id"],plan.executions))
        point=only(filter(p->p.id==request["point_id"] && p.execution_id==execution.id,plan.points))
        execution.variant_id==request["variant_id"] || _quantum_refuse("variant_mismatch")
        identity["point_passport"]=_point_passport(execution.configuration,point)
        identity["runtime"]=_quantum_runtime_source(runner_source_id,core_source_id;verifier=runtime_verifier)
        Threads.nthreads(:default)==1 && Threads.ngcthreads()==1 && BLAS.get_num_threads()==1 &&
            get(ENV,"OMP_NUM_THREADS",nothing)=="1" || _quantum_refuse("runtime_threads_mismatch")
        config=_resolve_configuration(_point_resolved_raw(execution.configuration,point),execution.configuration.provenance)
        payload=_quantum_basis_payload(config)
        return _quantum_artifact(request,identity,payload)
    catch error
        known=error isa Union{QuantumPreviewRefusal,ConfiguratorRefusal,ArgumentError,
            QCLNEGFRunner.ConfigurationError,KeyError,TypeError,InexactError,OverflowError,DomainError}
        known || rethrow()
        code=error isa QuantumPreviewRefusal ? error.code :
            error isa ConfiguratorRefusal ? error.code : "invalid_plan_or_configuration"
        return Dict("schema"=>"qcl-negf.quantum-preview.v1",
            "status"=>startswith(code,"runtime_") ? "unavailable" : "error",
            "identity"=>identity,"budget_policy_id"=>QUANTUM_PREVIEW_POLICY,"policy_revision"=>QUANTUM_PREVIEW_REVISION,
            "reason"=>code,"actual"=>error isa QuantumPreviewRefusal ? error.actual : nothing,
            "allowed"=>error isa QuantumPreviewRefusal ? error.allowed : nothing,
            "plan_changed"=>false,"payload"=>nothing)
    end
end

function _quantum_artifact(request,identity,payload)
    preview_id=_cfg_sha(canonical_bytes(Dict("request"=>request,"policy_revision"=>QUANTUM_PREVIEW_REVISION)))
    return Dict("schema"=>"qcl-negf.quantum-preview.v1","status"=>"available","preview_id"=>preview_id,
        "identity"=>identity,"budget_policy_id"=>QUANTUM_PREVIEW_POLICY,"policy_revision"=>QUANTUM_PREVIEW_REVISION,
        "payload"=>payload,"payload_sha256"=>_cfg_sha(canonical_bytes(payload)),
        "payload_digest_encoding"=>"qcl-negf-canonical-bytes-v1",
        "limits"=>Dict("request_bytes"=>QUANTUM_REQUEST_BYTES,"plan_bytes"=>QUANTUM_PLAN_BYTES,
            "response_bytes"=>QUANTUM_RESPONSE_BYTES,"screen_bytes"=>QUANTUM_SCREEN_BYTES,
            "execution_seconds"=>180,"cleanup_seconds"=>5,"cpu"=>1,"memory_bytes"=>2*1024^3,
            "swap_bytes"=>0,"pids"=>64,"enforcement"=>"external admitted launcher required"),
        "assessment"=>Dict("SCBA"=>"not_performed","Poisson"=>"not_performed","scientific"=>"not_assessed"),
        "measurements"=>Dict("elapsed_seconds"=>nothing,"peak_bytes"=>nothing,
            "reason"=>"requires_external_full_invocation_measurement"))
end

mutable struct _QuantumJSONIO <: IO
    buffer::IOBuffer
end
Base.isopen(io::_QuantumJSONIO)=isopen(io.buffer)
Base.iswritable(::_QuantumJSONIO)=true
function Base.unsafe_write(io::_QuantumJSONIO,p::Ptr{UInt8},n::UInt)
    n<=QUANTUM_RESPONSE_BYTES-position(io.buffer) || _quantum_refuse("response_limit")
    Base.unsafe_write(io.buffer,p,n)
end
function Base.write(io::_QuantumJSONIO,b::UInt8)
    position(io.buffer)<QUANTUM_RESPONSE_BYTES || _quantum_refuse("response_limit")
    write(io.buffer,b)
end
function _quantum_json(response)
    io=_QuantumJSONIO(IOBuffer()); _light_json(io,response); write(io,UInt8('\n'))
    return String(take!(io.buffer))
end
function write_quantum_preview(io::IO,response;output=nothing)
    text=_quantum_json(response)
    if output!==nothing
        target=abspath(output)
        !ispath(target) && !islink(target) && isdir(dirname(target)) &&
            !any(islink(p) for p in splitpath_ancestors(target)) || _quantum_refuse("output_not_new")
        _observability_atomic_text(target,destination->write(destination,text))
    end
    write(io,text)
    nothing
end
