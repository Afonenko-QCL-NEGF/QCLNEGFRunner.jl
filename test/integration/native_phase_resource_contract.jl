module NativePhaseResourceContractTests
using Test
using QCLNEGFRunner
using YAML
const N=QCLNEGFRunner.QCLNumerics

@testset "Producer clocks and ordinary phases under external memory controls" begin
    mktempdir() do root
        group=joinpath(root, "group")
        mkpath(group)
        write(joinpath(group, "memory.max"), "1000000")
        write(joinpath(group, "memory.current"), "100")
        width=Threads.nthreads(:default)
        proc = mkpath(joinpath(root, "proc", "self"))
        write(joinpath(proc, "cgroup"), "0::/group")
        fake_proc = dirname(proc)
        boot_A = "00000000-0000-4000-8000-000000000001"
        boot_B = "00000000-0000-4000-8000-000000000002"
        boot_file = joinpath(fake_proc, "sys", "kernel", "random", "boot_id")
        mkpath(dirname(boot_file))
        write(boot_file, boot_A * "\n")
        strict_directory = joinpath(root, "strict")
        try
            # A previous admission must not leak a measured grant into ordinary spans.
            QCLNEGFRunner._NATIVE_PHASE_ADMISSIONS[root] = Dict{String,Any}(
                "memory_admission_mode" => "cgroup_v2",
                "memory_granted_additional_bytes" => 123,
            )
            callback=QCLNEGFRunner._native_phase_request(root; proc_root = fake_proc, cgroup_root = root)
            @test callback((task_width = 1, elastic = true))==1
            @test !haskey(QCLNEGFRunner._NATIVE_PHASE_ADMISSIONS[root], "memory_granted_additional_bytes")
            @test callback((task_width = width + 1,)) == width
            for bad in (true, 0, -1, 1.0, big(typemax(Int)) + 1)
                @test_throws ArgumentError callback((task_width = bad,))
            end
            for bad in (true, -1, 1.0, big(typemax(Int)) + 1)
                @test_throws ArgumentError callback((task_width = 1, memory_burst_bytes = bad))
            end
            @test callback((task_width = 1, memory_burst_bytes = 0)) == 1
            no_journal = QCLNEGFRunner._native_phase_request(nothing;
                proc_root = fake_proc, cgroup_root = root)
            @test no_journal((task_width = width + 1,)) == width
            options=ProductionOptions(
                worker_count = width,
                phase_timing = true,
                event_sink = event->QCLNEGFRunner._record_native_phase!(root, event; proc_root = fake_proc),
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
            @test all(row["memory_admission_mode"] == "external_controls_not_predicted_fit" for row in rows)
            for field in (
                "memory_current_before_bytes", "memory_limit_bytes",
                "memory_granted_additional_bytes", "memory_current_after_gc_bytes",
                "memory_effective_current_bytes", "memory_clean_cache_credit_bytes",
                "memory_full_gc_seconds", "memory_stat_before", "memory_stat_after_gc",
            )
                @test all(row[field] === nothing for row in rows)
            end
            @test rows[4]["memory_burst_bytes"] == 1024
            @test rows[4]["workspace_bytes"] == 256
            @test rows[3]["memory_burst_bytes"] === nothing
            @test occursin("not_measured", rows[3]["capability_reasons"])
            @test rows[1]["clock_domain_id"]==rows[4]["clock_domain_id"]
            # D3: real lazy initialization reads literal fake boot A; a cache
            # hit after replacing A with B preserves directory-owned identity.
            @test startswith(rows[1]["clock_domain_id"], boot_A * ":julia:")
            @test haskey(QCLNEGFRunner._NATIVE_PHASE_JOURNALS, root)
            journal = QCLNEGFRunner._NATIVE_PHASE_JOURNALS[root]
            write(boot_file, boot_B * "\n")
            @test QCLNEGFRunner._native_phase_journal(root; proc_root = fake_proc) === journal
            @test journal.clock_domain == rows[1]["clock_domain_id"]
            write(joinpath(group, "memory.current"), "999999")
            request=(
                name = :mixing,
                iteration = 4,
                task_width = width,
                memory_burst_bytes = 2,
                elastic = true,
            )
            # 999999 + 2 > 1000000: ordinary continuation is independent of fit.
            continued = Ref(false)
            @test begin
                granted_width = callback(request)
                continued[] = true
                granted_width
            end == width
            @test continued[]
            near_limit = N._production_phase_begin(options, :mixing, 4;
                task_width = width, memory_burst_bytes = 2)
            N._production_phase_end(options, near_limit)
            rows = YAML.load.(readlines(joinpath(root, "phases.jsonl")))
            @test length(rows) == 6
            @test rows[5]["span_id"] == rows[6]["span_id"]
            @test all(row["memory_burst_bytes"] == 2 for row in rows[5:6])
            @test all(row["memory_admission_mode"] == "external_controls_not_predicted_fit" for row in rows[5:6])
            @test all(row["memory_granted_additional_bytes"] === nothing for row in rows[5:6])
            @test !isfile(joinpath(root, "resource-pressure.json"))
            @test isempty(journal.stack)
            @test isempty(journal.admissions)
            # The legacy strict permit still refuses the identical byte arithmetic.
            mkpath(strict_directory)
            continued[] = false
            @test_throws QCLNEGFRunner._NativePhasePressure begin
                QCLNEGFRunner._native_phase_memory_permit!(
                    strict_directory, [group], request; resource_policy = :campaign_strict)
                continued[] = true
            end
            @test !continued[]
            pressure=YAML.load_file(joinpath(strict_directory, "resource-pressure.json"))
            @test pressure["reason"]=="phase_memory_bound"
            @test pressure["incremental_estimate_bytes"]==2
            @test length(readlines(joinpath(root, "phases.jsonl")))==6
        finally
            pop!(QCLNEGFRunner._NATIVE_PHASE_JOURNALS, root, nothing)
            pop!(QCLNEGFRunner._NATIVE_PHASE_ADMISSIONS, root, nothing)
            pop!(QCLNEGFRunner._NATIVE_PHASE_ADMISSIONS, strict_directory, nothing)
        end
    end
end
end
