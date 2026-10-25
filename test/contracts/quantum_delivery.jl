module QuantumDeliveryContract
using Test, SHA, QCLNEGFRunner
const W=QCLNEGFRunner.QCLScientificWorkflow
json(x)=sprint(io->QCLNEGFRunner._light_json(io,x))
@testset "default trusted delivery getter uses anchored record, not environment echo" begin
    graph=Dict("format"=>"qcl-negf.git-graph.v1","revision"=>"a"^40,"components"=>[
        Dict("path"=>"components/QCLNEGF.jl","revision"=>"b"^40,"url"=>"https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl"),
        Dict("path"=>"components/QCLNEGFRunner.jl","revision"=>"c"^40,"url"=>"https://github.com/Afonenko-QCL-NEGF/QCLNEGFRunner.jl")])
    output="/nix/store/"*"d"^32*"-solver"
    context=Dict("release_id"=>"e"^64,"solver_executable"=>output*"/bin/qcl-negf",
        "solver_output"=>output,"nar_hash"=>"sha256-"*"A"^43*"=","drv_path"=>output*".drv",
        "source_graph_sha256"=>bytes2hex(sha256(W._quantum_sorted_ascii_json(graph))),
        "julia_manifest_sha256"=>"f"^64,"runner_source_id"=>"c"^40,"core_source_id"=>"b"^40)
    context["context_sha256"]=bytes2hex(sha256(W._quantum_sorted_ascii_json(context)))
    record=Dict("ready"=>true,"release_id"=>context["release_id"],"solver_executable"=>context["solver_executable"],
        "quantum_runtime_context"=>context,"sources"=>graph,"closures"=>[Dict("path"=>output,"narHash"=>context["nar_hash"])],
        "solver_build"=>Dict("source_graph_sha256"=>context["source_graph_sha256"],"julia_manifest_sha256"=>context["julia_manifest_sha256"],"drv_path"=>context["drv_path"],"output_path"=>output))
    environment=Dict("QCL_NEGF_QUANTUM_RUNTIME_CONTEXT"=>json(context),
        "QCL_NEGF_QUANTUM_RUNTIME_CONTEXT_SHA256"=>context["context_sha256"],
        "QCL_NEGF_QUANTUM_RUNTIME_RELEASE_FILE"=>W.QUANTUM_RELEASE_FILE,
        "QCL_NEGF_RELEASE_ID"=>context["release_id"],"QCL_NEGF_SOLVER_EXECUTABLE"=>context["solver_executable"])
    expected=(runner_source_id="c"^40,core_source_id="b"^40)
    trusted=()->deepcopy(record) # Explicit trusted record boundary double, not root ownership proof.
    got=W._quantum_delivery_context(expected,nothing;environment,read_record=trusted)
    @test got.runner_source_id=="c"^40 && got.context_sha256==context["context_sha256"]
    literal="{\"a\":[\"z\",\"a\"],\"b\":\"x\"}"
    @test W._quantum_sorted_ascii_json(Dict("b"=>"x","a"=>["z","a"]))==literal
    for change in (Dict("QCL_NEGF_QUANTUM_RUNTIME_CONTEXT_SHA256"=>"0"^64),Dict("QCL_NEGF_QUANTUM_RUNTIME_RELEASE_FILE"=>"/tmp/forged.json"),Dict("QCL_NEGF_RELEASE_ID"=>"foreign"),Dict("QCL_NEGF_QUANTUM_RUNTIME_CONTEXT"=>"{}"))
        @test_throws W.QuantumPreviewRefusal W._quantum_delivery_context(expected,nothing;environment=merge(environment,change),read_record=trusted)
    end
    for key in ("ready","sources","solver_build","closures","quantum_runtime_context")
        bad=deepcopy(record);bad[key]=nothing
        @test_throws W.QuantumPreviewRefusal W._quantum_delivery_context(expected,nothing;environment,read_record=()->bad)
    end
    bad=deepcopy(record);bad["closures"][1]["narHash"]="sha256-foreign"
    @test_throws W.QuantumPreviewRefusal W._quantum_delivery_context(expected,nothing;environment,read_record=()->bad)
    @test_throws W.QuantumPreviewRefusal W._quantum_delivery_context(expected,nothing;environment=Dict(),read_record=trusted)
    @test_throws W.QuantumPreviewRefusal W._quantum_sorted_ascii_json(Dict("a"=>"кириллица"))
end
end
