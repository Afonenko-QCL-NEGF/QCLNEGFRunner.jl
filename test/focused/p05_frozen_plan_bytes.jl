using Test, QCLNEGFRunner, SHA
const W=QCLNEGFRunner.QCLScientificWorkflow
@testset "frozen plan uses captured bytes, not semantic fingerprint" begin
    plan=resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    raw=Vector{UInt8}(codeunits(sprint(write_scientific_plan,plan)))
    changed=vcat(raw,UInt8[0x20])
    mktempdir() do root
        bound=W._freeze_scientific_plan(plan,root;frozen_plan_bytes=raw)
        @test bound.plan_sha256 == bytes2hex(sha256(raw))
        @test read(joinpath(root,"scientific_plan.json")) == raw
        @test W._freeze_scientific_plan(plan,root;frozen_plan_bytes=raw).plan_sha256 == bound.plan_sha256
        @test_throws ArgumentError W._freeze_scientific_plan(plan,root;frozen_plan_bytes=changed)
        @test read(joinpath(root,"scientific_plan.json")) == raw
    end
    mktempdir() do root
        bound=W._freeze_scientific_plan(plan,root;frozen_plan_bytes=changed)
        @test bound.plan_sha256==bytes2hex(sha256(changed))
        @test bound.plan_sha256!=bytes2hex(sha256(raw))
    end
    mktempdir() do root
        bound=W._freeze_scientific_plan(plan,root)
        @test bound.plan_sha256==bytes2hex(sha256(read(joinpath(root,"scientific_plan.json"))))
    end
end
@testset "plan loader returns the exact bounded bytes" begin
    plan=resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    raw=Vector{UInt8}(codeunits(sprint(write_scientific_plan,plan)))
    mktempdir() do dir
        path=joinpath(dir,"plan.json"); write(path,raw)
        loaded=W._load_scientific_plan_bytes(path)
        @test loaded.bytes==raw
        @test hasproperty(loaded,:capture)
        if hasproperty(loaded,:capture)
            @test loaded.bytes === loaded.capture.bytes
            @test loaded.capture.kind === :scientific_plan_v2
            write(path, "replaced after capture")
            @test loaded.capture.bytes == raw
            mktempdir() do output
                frozen=W._freeze_scientific_plan(plan,output;frozen_plan_capture=loaded.capture)
                @test frozen.bytes === loaded.capture.bytes
                @test read(joinpath(output,"scientific_plan.json")) == raw
                @test_throws ArgumentError W._freeze_scientific_plan(plan,output;frozen_plan_bytes=raw,frozen_plan_capture=loaded.capture)
                graph=Dict{String,Any}("format"=>"qcl-negf.git-graph.v1","revision"=>repeat("a",40),"components"=>[])
                for call in (W.execute_scientific_plan, QCLNEGFRunner.execute_scientific_plan_staged)
                    err=try
                        call(plan,joinpath(output,"not-created");source_graph=graph,frozen_plan_bytes=raw,frozen_plan_capture=loaded.capture)
                        nothing
                    catch ex
                        ex
                    end
                    @test err isa ArgumentError
                    @test occursin("choose one frozen plan source",sprint(showerror,err))
                    @test !ispath(joinpath(output,"not-created"))
                end
            end
        end
        @test loaded.plan.fingerprint==plan.fingerprint
        write(path,fill(UInt8(' '),W.CONFIGURATOR_PLAN_BYTES+1))
        @test_throws ArgumentError W._load_scientific_plan_bytes(path)
    end
end
@testset "frozen plan rejects symlink selection" begin
    plan=resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    raw=Vector{UInt8}(codeunits(sprint(write_scientific_plan,plan)))
    mktempdir() do root
        target=joinpath(root,"target"); write(target,raw)
        symlink(target,joinpath(root,"scientific_plan.json"))
        @test_throws ArgumentError W._freeze_scientific_plan(plan,root;frozen_plan_bytes=raw)
        @test read(target)==raw
    end
end
@testset "untrusted plan input is detached and strictly parsed" begin
    plan=resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    raw=Vector{UInt8}(codeunits(sprint(write_scientific_plan,plan)))
    original=copy(raw)
    @test isdefined(QCLNEGFRunner,:_p05_capture_plan)
    if isdefined(QCLNEGFRunner,:_p05_capture_plan)
        capture=QCLNEGFRunner._p05_capture_plan(raw,:scientific_plan_v2;maximum_metadata_bytes=128*1024*1024)
        raw[1]=UInt8('x')
        @test capture.bytes==original
        @test capture.bytes !== raw
        @test_throws ArgumentError QCLNEGFRunner._p05_capture_plan(Vector{UInt8}(codeunits("{\"x\":1,\"x\":2}")),:scientific_plan_v2;maximum_metadata_bytes=64*1024*1024)
        @test_throws ArgumentError QCLNEGFRunner._p05_capture_plan(original,:unknown;maximum_metadata_bytes=128*1024*1024)
    end
end
@testset "plan metadata admission counts nodes before parsing" begin
    plan=resolve_scientific_plan(joinpath(dirname(@__DIR__),"fixtures/configurations/resource-proposal-study.yaml"))
    text=strip(sprint(write_scientific_plan,plan))
    padded=text[1:end-1]*",\"extra\":["*join(fill("0",2000),",")*"]}"
    err=try
        QCLNEGFRunner._p05_capture_plan(Vector{UInt8}(codeunits(padded)),:scientific_plan_v2;maximum_metadata_bytes=1024*1024)
        nothing
    catch ex
        ex
    end
    @test err isa ArgumentError
    @test occursin("metadata allowance",sprint(showerror,err))
end

@testset "native invocation validates the same original and actual point before allocation" begin
    R=QCLNEGFRunner
    c=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    runner=R.QCLProductionPointRunner(c)
    capture=runner.plan_capture
    graph=Dict("format"=>"qcl-negf.git-graph.v1","revision"=>"a"^40,"components"=>Any[])
    identity=Dict{String,Any}("run_id"=>"run","execution_id"=>"execution","point_id"=>"point","attempt"=>"1","branch_id"=>"branch",
        "model_sha256"=>bytes2hex(sha256(R.canonical_bytes(W._snapshot_model(c)))),"plan_sha256"=>capture.plan_sha256)
    mktempdir() do root
        context=(;artifact_root=root,identity,plan_capture=capture,parent_checkpoint=nothing)
        output=joinpath(root,"not-created")
        call(;native_context=context,frozen_plan_bytes=capture.bytes,run_id="run",voltages=c.study.voltages_per_period)=
            R._p05_sweep_inputs(c,voltages,c.study.temperatures,output,frozen_plan_bytes,graph,nothing,run_id,native_context,64*1024^2)
        inputs=call()
        @test inputs.capture===capture && inputs.root==root
        @test capture.bytes==runner.plan_capture.bytes
        @test !ispath(output)
        reordered=(;identity,artifact_root=root,parent_checkpoint=nothing,plan_capture=capture)
        @test call(native_context=reordered).capture===capture
        @test_throws ArgumentError call(native_context=merge(context,(;extra=true)))
        @test_throws ArgumentError call(run_id="other")
        @test_throws ArgumentError call(frozen_plan_bytes=vcat(capture.bytes,UInt8[0x20]))
        @test_throws ArgumentError call(voltages=vcat(c.study.voltages_per_period,c.study.voltages_per_period))
        bad=deepcopy(identity);bad["model_sha256"]="0"^64
        @test_throws ArgumentError call(native_context=merge(context,(;identity=bad)))
        @test !ispath(output)
    end
end

@testset "cold direct uses canonical public point identities across original reorder" begin
    R=QCLNEGFRunner
    base=load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/exact_cpu.yaml"))
    raw=deepcopy(base.raw);raw["study"]["mode"]="sweep"
    raw["study"]["temperatures"]=["70 K","80 K"];raw["study"]["voltages_per_period"]=["0 V","0.01 V"]
    c=W._resolve_configuration(raw,base.provenance)
    definition=R.configured_nested_run_definition(c)
    capture=R.QCLProductionPointRunner(c).plan_capture
    original=deepcopy(capture.document);reverse!(original["root"]["axes"][1]["values"])
    reverse!(original["root"]["child"]["axes"][1]["values"])
    reordered=R._p05_capture_plan(Vector{UInt8}(codeunits(R.YAML.write(original))),:nested_sweep;maximum_metadata_bytes=64*1024^2)
    graph=Dict("format"=>"qcl-negf.git-graph.v1","revision"=>"a"^40,"components"=>Any[])
    mktempdir() do root
        output=joinpath(root,"not-created")
        call(bytes=capture.bytes;voltages=c.study.voltages_per_period,run_id=nothing)=
            R._p05_sweep_inputs(c,voltages,c.study.temperatures,output,bytes,graph,nothing,run_id,nothing,64*1024^2)
        first=call();second=call(reordered.bytes)
        @test first.identifier==second.identifier==definition.identity.run_id
        @test Set(p.point_id for p in values(first.selected_points))==Set(p.point_id for p in planned_points(definition.plan,definition.identity.run_id))
        @test Dict(k=>p.point_id for (k,p) in first.selected_points)==Dict(k=>p.point_id for (k,p) in second.selected_points)
        @test first.capture.bytes==capture.bytes && second.capture.bytes==reordered.bytes && capture.plan_sha256!=reordered.plan_sha256
        @test call(run_id="explicit-opaque-run").identifier=="explicit-opaque-run"
        @test_throws ArgumentError call(voltages=vcat(c.study.voltages_per_period,c.study.voltages_per_period))
        bad=deepcopy(capture.document);push!(bad["root"]["axes"][1]["values"],90.0)
        @test_throws ArgumentError call(Vector{UInt8}(codeunits(R.YAML.write(bad))))
        @test !ispath(output)
    end
end
