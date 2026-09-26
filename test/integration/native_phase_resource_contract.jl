module NativePhaseResourceContractTests
using Test
using QCLNEGFRunner
using YAML
const N=QCLNEGFRunner.QCLNumerics

@testset "Producer clocks and immutable worker phase budget" begin
    mktempdir() do root
        group=joinpath(root, "group")
        mkpath(group)
        write(joinpath(group, "memory.max"), "1000000")
        write(joinpath(group, "memory.current"), "100")
        width=Threads.nthreads(:default)
        proc = mkpath(joinpath(root, "proc", "self"))
        write(joinpath(proc, "cgroup"), "0::/group")
        let
            callback=QCLNEGFRunner._native_phase_request(root; proc_root = dirname(proc), cgroup_root = root)
            @test callback((task_width = 1, elastic = true))==1
            options=ProductionOptions(
                worker_count = width,
                phase_timing = true,
                event_sink = event->QCLNEGFRunner._record_native_phase!(root, event),
                phase_request = callback,
            )
            outer=N._production_phase_begin(
                options,
                :mixing,
                3;
                task_width = width,
                work_units = 512,
                memory_burst_bytes = 1024,
                workspace_bytes = 256,
            )
            inner=N._production_phase_begin(
                options,
                :mixing_gram,
                3;
                task_width = 1,
                work_units = 16,
            )
            N._production_phase_end(options, inner)
            N._production_phase_end(options, outer)
            rows=YAML.load.(readlines(joinpath(root, "phases.jsonl")))
            @test length(rows)==4
            @test rows[1]["span_id"]==rows[4]["span_id"]
            @test rows[2]["parent_span_id"]==rows[1]["span_id"]
            @test rows[4]["duration_seconds"]≈(
                rows[4]["end_monotonic_ns"]-rows[4]["begin_monotonic_ns"]
            )/1e9
            @test rows[4]["allocated_bytes"]>=0
            @test rows[4]["gc_count"]>=0
            @test rows[4]["memory_admission_mode"]=="cgroup_v2"
            @test rows[4]["memory_granted_additional_bytes"]==1024
            @test rows[3]["memory_admission_mode"]=="unavailable"
            @test rows[1]["clock_domain_id"]==rows[4]["clock_domain_id"]
            write(joinpath(group, "memory.current"), "999999")
            request=(
                name = :mixing,
                iteration = 4,
                task_width = width,
                memory_burst_bytes = 2,
                elastic = true,
            )
            @test_throws QCLNEGFRunner._NativePhasePressure callback(request)
            pressure=YAML.load_file(joinpath(root, "resource-pressure.json"))
            @test pressure["reason"]=="phase_memory_bound"
            @test pressure["incremental_estimate_bytes"]==2
            @test length(readlines(joinpath(root, "phases.jsonl")))==4
        end
    end
end
end
