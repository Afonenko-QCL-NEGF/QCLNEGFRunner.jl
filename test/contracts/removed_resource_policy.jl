module RemovedResourcePolicyTests
using QCLNEGFRunner, QCLNEGF, Test, SHA, Unitful, LinearAlgebra
const R = QCLNEGFRunner
const R04 = R
const C04 = QCLNEGF
const P04_ROOT = mktempdir(; prefix="removed-policy-")
include("../support/exact_persistence_fixture.jl")

failure(f) = try f(); nothing catch error; error end
function refused(f, marker)
    error = failure(f)
    @test error isa ArgumentError
    @test error isa ArgumentError && occursin(marker, sprint(showerror, error))
end
function snapshot(root)
    Dict(relpath(joinpath(dir,name),root) =>
        (bytes2hex(sha256(read(joinpath(dir,name)))), stat(joinpath(dir,name)).mode)
        for (dir,_,files) in walkdir(root) for name in files)
end
function fake_resources(f)
    mktempdir() do root
        proc = joinpath(root,"proc")
        group = joinpath(root,"cgroup")
        mkpath(joinpath(proc,"self")); mkpath(group)
        write(joinpath(proc,"self","cgroup"),"0::/\n")
        write(joinpath(proc,"self","status"),"Cpus_allowed_list:\t0\n")
        for (name,value) in (("memory.max","1000"),("memory.high","max"),
                ("memory.current","10"),("cpu.max","100000 100000"),
                ("cpuset.cpus.effective","0"))
            write(joinpath(group,name),value)
        end
        f(root,proc,group)
    end
end

@testset "Removed resource policy contract" begin
# Break caught: dispatching a removed policy into healthy strict admission,
# rather than rejecting the argument at the actual entry boundary.
@testset "Removed policy cannot probe or create a phase callback" begin
    fake_resources() do root,proc,cgroup
        before = snapshot(root)
        refused("unsupported_resource_policy") do
            probe_hardware(;proc_root=proc,cgroup_root=cgroup,physical_memory_override=2000,
                available_memory_override=1000,host_logical_cpus=1,julia_threads=1,
                blas_vendor_override="fixture",resource_policy=:campaign_strict)
        end
        refused("unsupported_resource_policy") do
            R._native_phase_request(joinpath(root,"new-telemetry");proc_root=proc,
                cgroup_root=cgroup,resource_policy=:campaign_strict)
        end
        @test snapshot(root)==before
        @test !ispath(joinpath(root,"new-telemetry"))
    end
end

# Break caught: accepting an obsolete context while taking the default branch
# would silently rename and chmod the caller's files.
@testset "Obsolete atomic context cannot fall back to ordinary publication" begin
    mktempdir() do root
        source,target=joinpath(root,"pending"),joinpath(root,"current")
        write(source,"literal new bytes");write(target,"literal old bytes")
        before=snapshot(root)
        refused("unsupported_storage_context") do
            R._atomic_replace_file(source,target;storage_context=:obsolete)
        end
        @test snapshot(root)==before
    end
end

@testset "Direct writer rejection dominates IO and callbacks, including empty history" begin
    fixture=p04_exact_fixture()
    solution=NEGFSolution(fixture.problem,fixture.bind.options,fixture.state.published_U,
        fixture.state.published_n,fixture.state.scba,fixture.state.outer_history,
        Dict{Symbol,Any}(),ConvergenceReport(false,Dict{Symbol,Float64}(),String[]),false,:running_scba)
    for (policy,context) in ((:campaign_strict,nothing),(:campaign_strict,:obsolete),
            (:unknown,nothing),(:standalone,:obsolete))
        mktempdir() do root
            target=joinpath(root,"new-parent","output")
            source=mkpath(joinpath(root,"source"));write(joinpath(source,"bytes"),"source")
            write(joinpath(root,"current"),"verified current")
            recorder=R._LegacyScientificHistoryRecorder(root,Dict{String,Any}(),Ref(0),Ref(0))
            before=snapshot(root);calls=Ref(0)
            marker=policy===:standalone ? "unsupported_storage_context" : "unsupported_resource_policy"
            entries=(
                ()->R._observability_atomic_text(target,io->(calls[]+=1);resource_policy=policy,storage_context=context),
                ()->R.commit_point_artifacts(target,solution;resource_policy=policy,storage_context=context),
                ()->R.commit_operator_artifacts(target,Dict();identity=Dict(),operation="test",accepted=false,
                    resource_policy=policy,storage_context=context),
                ()->stage_result_tree(source,target;resource_policy=policy,storage_context=context),
                ()->R._LegacyScientificHistoryRecorder(target,Dict{String,Any}(),Ref(0),Ref(0);
                    resource_policy=policy,storage_context=context),
                ()->R.ScientificHistoryRecorder(target;artifact_root=root,identity=p04_identity(),
                    source_epoch="epoch",provenance=p04_provenance(),status=p04_status(),maximum_scba_rows=3,
                    resource_policy=policy,storage_context=context),
                ()->R.flush_scientific_history!(recorder;resource_policy=policy,storage_context=context),
            )
            if policy!==:standalone
                entries=(entries...,
                    ()->R.flush_scientific_history_finalizer!(recorder;resource_policy=policy),
                    ()->save_checkpoint(target,solution;resource_policy=policy),
                    ()->R._atomic_checkpoint(target,solution;resource_policy=policy))
            end
            for entry in entries
                refused(entry,marker)
                @test snapshot(root)==before
                @test !ispath(dirname(target))
            end
            @test calls[]==0
        end
    end
end

# Retained ordinary O4 preflight is independent of the storage forecast.
@test R._scientific_resource_preflight(:standalone, nothing) === nothing

# Ordinary storage bounds from O2/O4 of the retired strict tests. These are
# checked forecasts, not permits, and must fail before reaching a writer.
@testset "Ordinary checkpoint forecast rejects malformed size and checked overflow" begin
    tiny(ne)=(problem=(numerical=(N_E=ne,N_k=1,N_b=1),
        kernels=(K=Dict{Symbol,Vector{UInt8}}(),Fᴸᴼ=UInt8[])),)
    reached=Ref(false)
    @test_throws ArgumentError begin
        R._checkpoint_storage_preflight(tiny(true),0);reached[]=true
    end
    @test_throws OverflowError begin
        R._checkpoint_storage_preflight(tiny(1),typemax(Int));reached[]=true
    end
    @test !reached[]
    @test R._checkpoint_storage_preflight(tiny(1),0)==
        (forecast_bytes=16777728,required_bytes=16777728)
end

@testset "Removed CLI option fails before plan reads and preserves its reason" begin
    mktempdir() do root
        output=joinpath(root,"output")
        status,reason=mktemp() do path,io
            status=redirect_stderr(io) do
                R.main(["run-plan",joinpath(root,"missing-plan.json"),output,
                    "--resource-policy","campaign_strict"])
            end
            flush(io)
            status,read(path,String)
        end
        @test status==2
        @test occursin("unknown run-plan option --resource-policy",reason)
        @test isempty(readdir(root))
    end
end

# The graph and parent paths are deliberately unusable. Removed arguments must
# win before source identity reads, output creation or numerical construction.
@testset "Actual scientific entries reject removed policy before source handling" begin
    S=R.QCLScientificWorkflow
    plan=ScientificPlan{Nothing}("fixture",:run,"fixture",repeat("a",64),1,
        ScientificInclusion[],S.ScientificExecution{Nothing}[],ScientificPoint[],S.ScientificExecutionNode[])
    mktempdir() do root
        output=joinpath(root,"new-parent","output")
        scratch=joinpath(root,"new-scratch")
        for entry in (
            ()->execute_scientific_plan(plan,output;resource_policy=:campaign_strict),
            ()->execute_scientific_plan_staged(plan,output;scratch_root=scratch,resource_policy=:campaign_strict),
        )
            refused(entry,"unsupported_resource_policy")
            @test isempty(readdir(root))
        end
    end
end
end
include("../focused/standalone_writer_failures.jl")
end
