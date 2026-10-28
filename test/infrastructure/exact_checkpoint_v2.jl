module ExactCheckpointV2Tests
using QCLNEGFRunner, QCLNEGF, Test, SHA, Unitful, LinearAlgebra
const R04=QCLNEGFRunner
const C04=QCLNEGF
const P04_ROOT=isempty(get(ENV,"QCL_P04_TEST_ROOT","")) ? mktempdir(;prefix="qcl-p04-exact-",cleanup=false) : abspath(ENV["QCL_P04_TEST_ROOT"])
include("../support/exact_persistence_fixture.jl")
@testset "Explicit native5 pointer and aggregate metadata admission" begin
    f=p04_exact_fixture();r=p04_recorder("pointer-bridge")
    R04.record_scientific_history!(r,p04_snapshot(f))
    checkpoint=R04.commit_exact_checkpoint!(r,f.problem,f.state;f.bind...,status=p04_status())
    reference=R04.checkpoint_reference(checkpoint)
    @testset "Selected pointer capability" begin
        selected=R04.open_exact_checkpoint(P04_ROOT,"pointer-bridge/current.json";
            expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2)
        @test R04.checkpoint_reference(selected)==reference
        R04.record_scientific_history!(r,p04_row(2;sequence=12,outer=f.state.progress.current_outer))
        R04.flush_scientific_history!(r)
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,"pointer-bridge/current.json";
            expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2)
        recovery=R04.open_exact_checkpoint(P04_ROOT,"pointer-bridge/recovery/current.json";
            expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2)
        @test R04.checkpoint_reference(recovery)==reference
        @test R04.load_exact_solver_state(selected).integrity==f.state.integrity
    end
    @testset "Pointer identity, format, selection and mutable-path barriers" begin
        pointer=R04._p04_parse(read(joinpath(P04_ROOT,"pointer-bridge/recovery/current.json"),String))
        for name in keys(p04_identity())
            expected=p04_identity();expected[name]=name in ("model_sha256","plan_sha256") ? repeat("c",64) : name=="attempt" ? "2" : "other"
            @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,"pointer-bridge/recovery/current.json";
                expected_identity=expected,maximum_metadata_bytes=4*1024^2)
        end
        for (name,mutator) in (
                ("generation",p->(p["generation"]="99")),("generation-lf",p->(p["generation"]="1\n")),
                ("unknown",p->(p["unknown"]=nothing)),("missing",p->delete!(p,"generation")),
                ("schema",p->(p["schema"]="qcl-negf.artifact-pointer.v2")),
                ("contract",p->(p["contract_set"]="qcl-negf.results.v1")),
                ("media",p->(p["manifest"]["media_type"]="text/plain")),
                ("manifest-schema",p->(p["manifest"]["schema"]="other")),
                ("missing-manifest",p->(p["manifest"]["path"]="absent.json")),
                ("manifest-hash",p->(p["manifest"]["sha256"]=repeat("0",64))))
            value=deepcopy(pointer);mutator(value);path=p04_pointer_fixture("pointer-"*name,value)
            @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,path;
                expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2)
        end
        value=deepcopy(pointer);value["identity"]["point_id"]="other"
        path=p04_pointer_fixture("pointer-manifest-identity",value)
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,path;
            expected_identity=value["identity"],maximum_metadata_bytes=4*1024^2)
        independent=p04_forge(checkpoint,"pointer-independent-sequence";
            declaration_mutator=d->(d["state_sequence"]="17"),manifest_mutator=m->(m["state_sequence"]="17"))
        value=deepcopy(pointer);value["manifest"]=independent["manifest"]
        path=p04_pointer_fixture("pointer-sequence-not-generation",value)
        @test R04.checkpoint_reference(R04.open_exact_checkpoint(P04_ROOT,path;
            expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2))==independent
        for path in ("absent-pointer.json","../current.json","/absolute.json","windows\\pointer.json","bad\0pointer.json")
            @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,path;
                expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2)
        end
        for budget in (0,-1,true,big(typemax(Int))+1)
            @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,"pointer-bridge/recovery/current.json";
                expected_identity=p04_identity(),maximum_metadata_bytes=budget)
        end
        path=p04_pointer_fixture("pointer-whitespace",pointer)
        open(io->print(io,"\n \t"),joinpath(P04_ROOT,path),"a")
        @test R04.checkpoint_reference(R04.open_exact_checkpoint(P04_ROOT,path;
            expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2))==reference
        duplicate="{\"generation\":\"1\","*R04._p04_json(pointer)[2:end]
        path=joinpath(P04_ROOT,"pointer-duplicate.json");write(path,duplicate)
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,"pointer-duplicate.json";
            expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2)
        symlink(joinpath(P04_ROOT,"pointer-bridge/recovery/current.json"),joinpath(P04_ROOT,"pointer-link.json"))
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,"pointer-link.json";
            expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2)
        symlink(joinpath(P04_ROOT,"pointer-bridge/recovery"),joinpath(P04_ROOT,"pointer-directory-link"))
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,"pointer-directory-link/current.json";
            expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2)
        path=p04_pointer_fixture("pointer-rebind",pointer);previous=R04._p04_read_observer[];replaced=Ref(false)
        R04._p04_read_observer[]=(kind,file,bytes)->begin
            if kind===:metadata && file==joinpath(P04_ROOT,reference["manifest"]["path"]) && !replaced[]
                temporary=joinpath(P04_ROOT,"pointer-replacement.json")
                cp(joinpath(P04_ROOT,path),temporary);mv(temporary,joinpath(P04_ROOT,path);force=true);replaced[]=true
            end
        end
        try
            @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,path;
                expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2)
            @test replaced[]
        finally;R04._p04_read_observer[]=previous;end
    end
    @testset "Native JSON belongs to the same metadata allowance" begin
        previous=R04._p04_read_observer[];reads=Any[]
        R04._p04_read_observer[]=(kind,path,bytes)->push!(reads,(kind,path,bytes))
        try
            opened=R04.open_exact_checkpoint(P04_ROOT,reference;maximum_metadata_bytes=4*1024^2)
            @test R04.checkpoint_reference(opened)==reference
        finally;R04._p04_read_observer[]=previous;end
        file_json=sum(event[3] for event in reads if event[1]===:metadata)
        @test file_json>0
        # The published reader debits only JSON FileRefs and incorrectly accepts this exact sum.
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,reference;maximum_metadata_bytes=file_json)
        total=p04_metadata_bytes(reads)
        @test total>file_json
        @test R04.checkpoint_reference(R04.open_exact_checkpoint(P04_ROOT,reference;maximum_metadata_bytes=total))==reference
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,reference;maximum_metadata_bytes=total-1)
        budget=Ref(total)
        @test R04.checkpoint_reference(R04._p04_open_exact_checkpoint(realpath(P04_ROOT),reference,budget))==reference
        @test budget[]==0
        path="pointer-bridge/recovery/current.json"
        _,reads=p04_reads(()->R04.open_exact_checkpoint(P04_ROOT,path;
            expected_identity=p04_identity(),maximum_metadata_bytes=4*1024^2))
        pointer_total=p04_metadata_bytes(reads)
        @test count(event->event[1]===:metadata && event[2]==joinpath(P04_ROOT,reference["manifest"]["path"]),reads)==2
        @test pointer_total==total+filesize(joinpath(P04_ROOT,path))+parse(Int,reference["manifest"]["bytes"])
        @test R04.checkpoint_reference(R04.open_exact_checkpoint(P04_ROOT,path;
            expected_identity=p04_identity(),maximum_metadata_bytes=pointer_total))==reference
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,path;
            expected_identity=p04_identity(),maximum_metadata_bytes=pointer_total-1)
        target=R04._p04_parse(checkpoint.declaration_json)["witness_targets"][1]
        _,reads=p04_reads(()->R04._p04_original_record(P04_ROOT,target["locator"],target["row_key"],Dict{String,Any}(),Ref(4*1024^2)))
        native=sum(event[3] for event in reads if event[1]===:scalar_json)
        budget=Ref(native);previous=R04._p04_read_observer[];observed=Symbol[]
        R04._p04_read_observer[]=(kind,file,bytes)->push!(observed,kind)
        try
            @test_throws ArgumentError R04._p04_original_record(P04_ROOT,target["locator"],target["row_key"],Dict{String,Any}(),budget)
            @test budget[]==0 && !(:record_json in observed) && !(:array in observed)
        finally;R04._p04_read_observer[]=previous;end
    end
    @testset "JSON size growth is refused by the bounded read" begin
        path=joinpath(P04_ROOT,"growing-json.json");write(path,"{\"a\":1}")
        ref=R04._p04_ref(P04_ROOT,path,"qcl-negf.result-manifest.v1");budget=Ref(filesize(path))
        previous=R04._p04_read_observer[]
        R04._p04_read_observer[]=(kind,file,bytes)->kind===:metadata && file==path && open(io->print(io,repeat(" ",32)),path,"a")
        try
            @test_throws ArgumentError R04._p04_read_json_ref(P04_ROOT,ref,budget)
            @test budget[]==0 # only the captured seven bytes were read/debited, not the growing tail
        finally;R04._p04_read_observer[]=previous;end
    end
    @testset "Fixed scalar metadata capability before JSON allocation" begin
        path=joinpath(P04_ROOT,"fixed-json-budget.h5")
        R04.HDF5.h5open(path,"w") do file
            file["scalar"]="{\"a\":1}";file["wrong-class"]=UInt8(1)
            dtype=R04.HDF5.datatype("{\"a\":1}")
            try;close(R04.HDF5.create_dataset(file,"wrong-rank",dtype,(1,)))
            finally;close(dtype);end
        end
        R04.HDF5.h5open(path,"r") do file
            budget=Ref(7)
            @test R04._p04_read_scalar_json(file,"scalar",budget,path)==Dict("a"=>1)
            @test budget[]==0
            @test_throws ArgumentError R04._p04_read_scalar_json(file,"scalar",Ref(6),path)
            for name in ("wrong-class","wrong-rank")
                @test_throws ArgumentError R04._p04_read_scalar_json(file,name,Ref(1000),path)
            end
        end
    end
end

@testset "Selected original RowKey binds public Core snapshot metadata" begin
    f=p04_exact_fixture();r=p04_recorder("row-projection")
    R04.record_scientific_history!(r,p04_snapshot(f))
    checkpoint=R04.commit_exact_checkpoint!(r,f.problem,f.state;f.bind...,status=p04_status())
    healthy=R04.open_exact_checkpoint(P04_ROOT,R04.checkpoint_reference(checkpoint);maximum_metadata_bytes=4*1024^2)
    @test R04.load_exact_solver_state(healthy).integrity==f.state.integrity
    integer(n)=Dict("kind"=>"integer","type"=>"Int64","decimal"=>string(n))
    for (name,value) in (("domain_revision",integer(1)),("discretization_id","other-grid"),
            ("basis_id","other-basis"),("stage",Dict("kind"=>"symbol","value"=>"outer")),
            ("outer_iteration",integer(3)),("inner_iteration",integer(2)))
        forged=p04_forge_record(checkpoint,"row-projection-"*name,record->(record["core"]["fields"][name]=value))
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,forged;maximum_metadata_bytes=4*1024^2)
    end
    for (name,mutator) in (
            ("core-type",record->(record["core"]["type"]="SCBAIteration")),
            ("core-envelope",record->(record["core"]["unknown"]=nothing)),
            ("core-field",record->(record["core"]["fields"]["unknown"]=nothing)),
            ("missing-identity",record->delete!(record["core"]["fields"],"basis_id")),
            ("malformed-identity",record->(record["core"]["fields"]["inner_iteration"]["decimal"]="1\n")),
            ("owner",record->(record["identity"]["attempt"]="9")),
            ("epoch",record->(record["invocation"]["source_epoch"]="other")),
            ("ordinal",record->(record["stream_ordinal"]="2")),
            ("action",record->(record["core"]["fields"]["action"]["value"]="witness_update")),
            ("target",record->(record["target"]=deepcopy(R04._p04_parse(checkpoint.declaration_json)["witness_targets"][1]))))
        forged=p04_forge_record(checkpoint,"row-projection-"*name,mutator)
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,forged;maximum_metadata_bytes=4*1024^2)
    end
    # A real outer-stage append has a nullable inner identity; no SCBA-null surrogate.
    r=p04_recorder("row-projection-outer");outer=p04_row(;stage=:outer)
    R04.record_scientific_history!(r,outer);pin=R04.flush_scientific_history!(r)
    page=R04._p04_parse(read(joinpath(P04_ROOT,pin["head"]["path"]),String))
    leaf=Dict(k=>page["artifacts"][end][k] for k in ("path","bytes","sha256","media_type","schema"))
    locator=Dict("source_identity"=>r.identity,"source_epoch"=>r.invocation["source_epoch"],
        "append_ordinal"=>"1","leaf"=>leaf,"row_offset"=>"0")
    record=R04._p04_original_record(P04_ROOT,locator,R04._p04_row_key(outer),Dict{String,Any}(),Ref(4*1024^2))
    @test record["row_key"]["stage"]["value"]=="outer"
    @test record["row_key"]["inner_iteration"]===record["core"]["fields"]["inner_iteration"]===nothing
end

@testset "Exact v2 API rejects fabricated checkpoint references" begin
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,Dict();maximum_metadata_bytes=1024)
end

@testset "Closed failed full state and uncertain terminal pointer reconciliation" begin
    f=p04_final_fixture();status=p04_status()
    status["process"]=Dict("state"=>"failed","exit_code"=>1,"reason"=>"manufactured_invalid_state")
    @test C04.validate_exact_state(f.problem,f.state;f.bind...)===nothing
    r=p04_recorder("closed-final");R04.record_scientific_history!(r,p04_snapshot(f))
    checkpoint=R04.commit_exact_checkpoint!(r,f.problem,f.state;f.bind...,status,closed=true)
    @test r.closed
    opened=R04.open_exact_checkpoint(P04_ROOT,R04.checkpoint_reference(checkpoint);maximum_metadata_bytes=4*1024^2)
    @test R04.load_exact_solver_state(opened).integrity==f.state.integrity
    @test_throws ArgumentError R04.record_scientific_history!(r,p04_row(;sequence=10))
    @test_throws ArgumentError R04.flush_scientific_history!(r)
    r=p04_recorder("closed-final-fault");R04.record_scientific_history!(r,p04_snapshot(f))
    @test_throws ErrorException R04.commit_exact_checkpoint!(r,f.problem,f.state;f.bind...,status,closed=true,
        publication_hook=at->at===:recovery_pointer_published && error("manufactured terminal pointer fault"))
    @test R04.flush_scientific_history!(r)["records"]=="1"
    @test r.closed
    @test r.status==status
    @test_throws ArgumentError R04.record_scientific_history!(r,p04_row(;sequence=10))
end

@testset "Append/checkpoint do not replay prior payloads" begin
    f=p04_exact_fixture();r=p04_recorder("no-prefix")
    R04.record_scientific_history!(r,p04_snapshot(f))
    R04.flush_scientific_history!(r)
    for sequence in (12,15)
        R04.record_scientific_history!(r,p04_snapshot(f;sequence,action=:witness_update))
        R04.flush_scientific_history!(r)
    end
    # Inventory is fixture setup only; the production cache need not retain this prefix.
    old=Set(replace(relpath(joinpath(directory,name),P04_ROOT),'\\'=>'/') for
        (directory,_,names) in walkdir(joinpath(r.directory,"history")) for name in names if endswith(name,".h5"))
    previous=R04._p04_read_observer[];reads=Any[]
    R04._p04_read_observer[]=(kind,path,bytes)->begin
        relative=replace(relpath(path,P04_ROOT),'\\'=>'/')
        @test !(relative in old)
        push!(reads,(kind,relative,bytes))
    end
    checkpoint=nothing
    try
        R04.record_scientific_history!(r,p04_snapshot(f;sequence=18,action=:witness_update))
        R04.flush_scientific_history!(r)
        checkpoint=R04.commit_exact_checkpoint!(r,f.problem,f.state;f.bind...,status=p04_status())
        @test R04.checkpoint_reference(checkpoint)["identity"]==p04_identity()
    finally;R04._p04_read_observer[]=previous;end
    @test !isempty(reads)
    # Reusing a nonadjacent leaf can evade an immediate-previous-page-only test.
    pin=R04._p04_parse(checkpoint.declaration_json)["history"]
    head=R04._p04_parse(read(joinpath(P04_ROOT,pin["head"]["path"]),String));oldest=deepcopy(head)
    while oldest["previous"]!==nothing
        oldest=R04._p04_parse(read(joinpath(P04_ROOT,oldest["previous"]["head"]["path"]),String))
    end
    head["artifacts"][end]=deepcopy(oldest["artifacts"][end])
    length(head["artifacts"])==2 && push!(head["artifacts"][end]["dependencies"],head["artifacts"][1]["path"])
    directory=joinpath(P04_ROOT,"duplicate-catalog");mkdir(directory);path=joinpath(directory,"page.json")
    open(io->R04._p04_json(io,head),path,"w")
    pin["head"]=R04._p04_ref(P04_ROOT,path,"qcl-negf.scientific-catalog.v1")
    duplicate=p04_forge(checkpoint,"duplicate-catalog-state";declaration_mutator=d->(d["history"]=pin),manifest_mutator=m->(m["history"]=pin))
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,duplicate;maximum_metadata_bytes=4*1024^2)
end

@testset "Crash barriers preserve complete pointers and leave invisible orphans" begin
    f=p04_exact_fixture()
    for stage in (:payload_closed,:leaves_published,:catalog_published,:checkpoint_published,
            :manifest_published,:recovery_pointer_published,:current_pointer_published)
        r=p04_recorder("fault-"*string(stage))
        R04.record_scientific_history!(r,p04_snapshot(f))
        baseline=R04.commit_exact_checkpoint!(r,f.problem,f.state;f.bind...,status=p04_status())
        R04.record_scientific_history!(r,p04_snapshot(f;sequence=10,action=:witness_update))
        @test_throws ErrorException R04.commit_exact_checkpoint!(r,f.problem,f.state;f.bind...,status=p04_status(),
            publication_hook=at->at==stage && error("manufactured fault at "*string(stage)))
        for name in ("current.json","recovery/current.json")
            pointer=R04._p04_parse(read(joinpath(r.directory,name),String))
            manifest=R04._p04_parse(read(joinpath(P04_ROOT,pointer["manifest"]["path"]),String))
            reference=Dict("identity"=>manifest["identity"],"state_id"=>manifest["state_id"],
                "state_sequence"=>manifest["state_sequence"],"manifest"=>pointer["manifest"])
            handle=R04.open_exact_checkpoint(P04_ROOT,reference;maximum_metadata_bytes=4*1024^2)
            @test R04.load_exact_solver_state(handle).integrity==f.state.integrity
            @test manifest["history"]["records"] in ("1","2")
        end
        @test R04.load_exact_solver_state(baseline).integrity==f.state.integrity
        if stage in (:recovery_pointer_published,:current_pointer_published)
            @test R04.flush_scientific_history!(r)["records"]=="2"
        else
            @test_throws ArgumentError R04.flush_scientific_history!(r)
        end
    end
end

@testset "Public Core exact state, frozen cutoff and immediate-parent ancestry" begin
    f=p04_exact_fixture()
    @test C04.validate_exact_state(f.problem,f.state;f.bind...)===nothing
    r=p04_recorder("exact")
    @test R04.record_scientific_history!(r,p04_snapshot(f))===nothing
    checkpoint=R04.commit_exact_checkpoint!(r,f.problem,f.state;f.bind...,status=p04_status())
    reference=R04.checkpoint_reference(checkpoint)
    original=deepcopy(reference)
    opened=R04.open_exact_checkpoint(P04_ROOT,reference;maximum_metadata_bytes=4*1024^2)
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,reference;maximum_metadata_bytes=1)
    for unsafe in ("../manifest.json","/absolute.json","windows\\manifest.json")
        locator=deepcopy(reference);locator["manifest"]["path"]=unsafe
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,locator;maximum_metadata_bytes=4*1024^2)
    end
    loaded=R04.load_exact_solver_state(opened)
    @test loaded.integrity==f.state.integrity
    @test C04.validate_exact_state(f.problem,loaded;f.bind...)===nothing
    @test C04.restore_exact_state(f.problem,loaded;f.bind...) isa C04.RestoredSolverState
    @test all(isequal(getfield(loaded.scba.history[1],name),getfield(f.state.scba.history[1],name)) for name in fieldnames(SCBAIteration))
    # Later committed raw history remains independently visible, outside the exact pin.
    R04.record_scientific_history!(r,p04_row(2;sequence=12,outer=f.state.progress.current_outer))
    tail=R04.flush_scientific_history!(r)
    @test tail["records"]=="2"
    @test R04.checkpoint_reference(checkpoint)==original
    @test R04.load_exact_solver_state(checkpoint).integrity==f.state.integrity
    child=p04_recorder("child";attempt=2,parent=opened)
    R04.record_scientific_history!(child,p04_snapshot(f;sequence=9,action=:witness_update))
    childcp=R04.commit_exact_checkpoint!(child,f.problem,f.state;f.bind...,status=p04_status())
    reopened=R04.open_exact_checkpoint(P04_ROOT,R04.checkpoint_reference(childcp);maximum_metadata_bytes=4*1024^2)
    @test R04.load_exact_solver_state(reopened).integrity==f.state.integrity
    bridge=p04_recorder("empty-parent";attempt=2,parent=opened)
    bridgecp=R04.commit_exact_checkpoint!(bridge,f.problem,f.state;f.bind...,status=p04_status())
    bridgeopen=R04.open_exact_checkpoint(P04_ROOT,R04.checkpoint_reference(bridgecp);maximum_metadata_bytes=4*1024^2)
    @test R04._p04_parse(bridgeopen.declaration_json)["history"]["last_record"]=="0"
    grandchild=p04_recorder("grandchild";attempt=3,parent=bridgeopen)
    @test R04.record_scientific_history!(grandchild,p04_snapshot(f;sequence=21,action=:witness_update))===nothing
    grandcp=R04.commit_exact_checkpoint!(grandchild,f.problem,f.state;f.bind...,status=p04_status())
    @test R04.load_exact_solver_state(R04.open_exact_checkpoint(P04_ROOT,R04.checkpoint_reference(grandcp);
        maximum_metadata_bytes=4*1024^2)).integrity==f.state.integrity
    wrong=deepcopy(reference);wrong["identity"]["model_sha256"]=repeat("c",64)
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,wrong;maximum_metadata_bytes=4*1024^2)
    unknown=p04_forge(checkpoint,"unknown-state-field";declaration_mutator=d->(d["state"]["fields"]["unknown"]=nothing))
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,unknown;maximum_metadata_bytes=4*1024^2)
    unsupported=p04_forge(checkpoint,"unknown-layout";declaration_mutator=d->(d["core_layout_sha256"]=repeat("0",64)))
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,unsupported;maximum_metadata_bytes=4*1024^2)
    zero=p04_forge(checkpoint,"zero-state-sequence";declaration_mutator=d->(d["state_sequence"]="0"),manifest_mutator=m->(m["state_sequence"]="0"))
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,zero;maximum_metadata_bytes=4*1024^2)
    duplicate_inventory=p04_forge(checkpoint,"duplicate-inventory";manifest_mutator=m->push!(m["artifacts"],deepcopy(m["artifacts"][1])))
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,duplicate_inventory;maximum_metadata_bytes=4*1024^2)
    for (name,key,value) in (("wrong-parent-model","model_sha256",repeat("c",64)),("wrong-parent-branch","branch_id","other"))
        forged=p04_forge(childcp,name;declaration_mutator=d->(d["lineage"]["parent_state"]["identity"][key]=value),
            manifest_mutator=m->(m["lineage"]["parent_state"]["identity"][key]=value))
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,forged;maximum_metadata_bytes=4*1024^2)
    end
    wrong_anchor=p04_forge(childcp,"wrong-anchor-epoch";declaration_mutator=d->(d["witness_targets"][1]["locator"]["source_epoch"]="other"))
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,wrong_anchor;maximum_metadata_bytes=4*1024^2)
    future=p04_forge(checkpoint,"future-anchor";declaration_mutator=d->(d["witness_targets"][1]["locator"]["append_ordinal"]="2"))
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,future;maximum_metadata_bytes=4*1024^2)
    tampered=p04_forge(checkpoint,"same-size-native-tamper";payload_mutator=path->nothing)
    tampered_manifest=R04._p04_parse(read(joinpath(P04_ROOT,tampered["manifest"]["path"]),String))
    tampered_decl=R04._p04_parse(read(joinpath(P04_ROOT,tampered_manifest["checkpoint"]["path"]),String))
    path=joinpath(P04_ROOT,tampered_decl["payloads"][1]["path"]);bytes=filesize(path)
    open(path,"r+") do io
        seek(io,bytes-1);byte=read(io,UInt8);seek(io,bytes-1);write(io,byte⊻UInt8(1))
    end
    @test filesize(path)==bytes
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,tampered;maximum_metadata_bytes=4*1024^2)
    # Correct hashes and dependency strings cannot authorize a first-entry record leaf.
    pin=deepcopy(R04._p04_parse(checkpoint.declaration_json)["history"])
    page=R04._p04_parse(read(joinpath(P04_ROOT,pin["head"]["path"]),String))
    reverse!(page["artifacts"]);page["artifacts"][end]["dependencies"]=[page["artifacts"][1]["path"]]
    path=joinpath(P04_ROOT,"swapped-page.json");open(io->R04._p04_json(io,page),path,"w")
    pin["head"]=R04._p04_ref(P04_ROOT,path,"qcl-negf.scientific-catalog.v1")
    swapped=p04_forge(checkpoint,"swapped-page-state";declaration_mutator=d->(d["history"]=pin),manifest_mutator=m->(m["history"]=pin))
    @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,swapped;maximum_metadata_bytes=4*1024^2)
    for variant in (:wrong_dtype,:wrong_shape,:external_raw,:external_link,:soft_link,:wrong_native_version,:wrong_owner,:wrong_representation)
        forged=p04_forge(checkpoint,"native-"*string(variant);payload_mutator=path->R04.HDF5.h5open(path,"r+") do file
            if variant in (:wrong_dtype,:wrong_shape)
                R04.HDF5.delete_object(file,"arrays/a00000001")
                file["arrays/a00000001"]=variant===:wrong_dtype ? zeros(Int64,25) : zeros(Float64,24)
            elseif variant===:external_raw
                dataset=R04.HDF5.create_external_dataset(file,"unowned",joinpath(dirname(path),"outside.raw"),Float64,(2,));close(dataset)
            elseif variant===:external_link
                R04.HDF5.create_external(file,"unowned",joinpath(P04_ROOT,"absent.h5"),"values")
            elseif variant===:soft_link
                R04.HDF5.API.h5l_create_soft("/metadata",file.id,"unowned",R04.HDF5.API.H5P_DEFAULT,R04.HDF5.API.H5P_DEFAULT)
            elseif variant===:wrong_native_version
                meta=file["metadata"];R04.HDF5.delete_attribute(meta,"schema_version")
                R04.attributes(meta)["schema_version"]="4.0";close(meta)
            elseif variant===:wrong_owner
                R04.HDF5.delete_object(file,"metadata/identity_json")
                file["metadata/identity_json"]=R04._p04_json(p04_identity(99))
            else
                meta=file["metadata"];R04.HDF5.delete_attribute(meta,"representation")
                R04.attributes(meta)["representation"]="record_leaf";close(meta)
            end
        end)
        @test_throws ArgumentError R04.open_exact_checkpoint(P04_ROOT,forged;maximum_metadata_bytes=4*1024^2)
    end
    target=deepcopy(R04._p04_parse(checkpoint.declaration_json)["witness_targets"][1])
    path=joinpath(P04_ROOT,"truncated-record-offsets.h5")
    cp(joinpath(P04_ROOT,target["locator"]["leaf"]["path"]),path;force=false)
    R04.HDF5.h5open(path,"r+") do file
        R04.HDF5.delete_object(file,"records/offsets");file["records/offsets"]=UInt64[0]
    end
    target["locator"]["leaf"]=R04._p04_ref(P04_ROOT,path,"qcl-negf-scientific-history-v5";media="application/x-hdf5")
    @test_throws ArgumentError R04._p04_original_record(P04_ROOT,target["locator"],target["row_key"],Dict{String,Any}(),Ref(4*1024^2))
    # Correct native shapes/dtypes cannot mask a changed Core integrity payload.
    changed=p04_forge(checkpoint,"changed-state-values";payload_mutator=path->R04.HDF5.h5open(path,"r+") do file
        dataset=file["arrays/a00000001"];dataset[1]=0.25;close(dataset)
    end)
    changed_handle=R04.open_exact_checkpoint(P04_ROOT,changed;maximum_metadata_bytes=4*1024^2)
    @test_throws ArgumentError R04.load_exact_solver_state(changed_handle)
    # Rebinding an already verified path invalidates the handle even with identical bytes.
    rlink=p04_recorder("path-rebind")
    R04.record_scientific_history!(rlink,p04_snapshot(f))
    linked=R04.commit_exact_checkpoint!(rlink,f.problem,f.state;f.bind...,status=p04_status())
    payload=R04._p04_parse(linked.declaration_json)["payloads"][1]
    path=joinpath(P04_ROOT,payload["path"]);mv(path,path*".original";force=false);symlink(path*".original",path)
    @test_throws ArgumentError R04.load_exact_solver_state(linked)
end
end # module
