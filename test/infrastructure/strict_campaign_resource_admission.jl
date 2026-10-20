module StrictCampaignResourceAdmissionTests
include("../support/common.jl")
include("../support/resource_probe.jl")
const R = QCLNEGFRunner
const M = typemax(Int)

# Every callback and probe receives BOTH explicit fake roots. This fixture's
# three ancestors are leaf -> slice -> root; no defaults may observe the host.
function fixture(f; bound = 100, current = 90)
    mktempdir() do root
        proc = joinpath(root, "proc")
        cgroup = joinpath(root, "cgroup")
        slice = joinpath(cgroup, "fixture.slice")
        leaf = joinpath(slice, "solver.scope")
        groups = [leaf, slice, cgroup]
        _write_resource_fixture(joinpath(proc, "self", "cgroup"), "0::/fixture.slice/solver.scope\n")
        _write_resource_fixture(joinpath(proc, "self", "status"), "Cpus_allowed_list:\t0\n")
        for group in groups
            _write_resource_fixture(joinpath(group, "memory.max"), group == slice ? string(bound) : "max")
            _write_resource_fixture(joinpath(group, "memory.high"), "max")
            _write_resource_fixture(joinpath(group, "memory.current"), string(current))
            _write_resource_fixture(joinpath(group, "cpu.max"), group == slice ? "100000 100000" : "max 100000")
            _write_resource_fixture(joinpath(group, "cpuset.cpus.effective"), "0")
        end
        directory = mkpath(joinpath(root, "telemetry"))
        f((; root, proc, cgroup, groups, directory))
    end
end
phase(x; directory = x.directory) = R._native_phase_request(directory;
    proc_root = x.proc, cgroup_root = x.cgroup, resource_policy = :campaign_strict)
request(; task_width = 1, memory_burst_bytes = 10) =
    (; task_width, memory_burst_bytes, elastic = true, name = :fixture, iteration = 0)
function probe(x; overrides...)
    arguments = merge((;
        proc_root = x.proc, cgroup_root = x.cgroup,
        physical_memory_override = 200, available_memory_override = 110,
        host_logical_cpus = 1, julia_threads = 1, blas_vendor_override = "fixture",
        resource_policy = :campaign_strict), (; overrides...))
    return R.probe_hardware(; arguments...)
end
function after_phase!(completed, callback, req)
    width = callback(req)
    completed[] += 1
    return width
end

@testset "S1 strict exact fit and fixed pool" begin
    fixture() do x
        completed = Ref(0)
        @test after_phase!(completed, phase(x), request(task_width = Threads.nthreads(:default) + 1)) == Threads.nthreads(:default)
        @test completed[] == 1
    end
end
@testset "S2 strict memory one byte short" begin
    fixture(; bound = 99) do x
        completed = Ref(0)
        @test_throws R._NativePhasePressure after_phase!(completed, phase(x), request())
        @test completed[] == 0
    end
end
@testset "S3 each ancestor malformed or missing bound" begin
    for index in 1:3, bad in ("", "broken", "-1", string(big(M) + 1), nothing)
        fixture() do x
            path = joinpath(x.groups[index], "memory.max")
            bad === nothing ? rm(path) : write(path, bad)
            @test_throws ArgumentError phase(x)(request())
        end
    end
end
@testset "S4 no finite bound or valid membership" begin
    fixture() do x
        for group in x.groups
            write(joinpath(group, "memory.max"), "max")
        end
        @test_throws ArgumentError phase(x)(request())
        @test_throws ArgumentError R._native_phase_memory_permit!(x.directory, String[], request(); resource_policy = :campaign_strict)
    end
    for membership in (nothing, "1:name=systemd:/legacy", "0::/../escape", "0::relative", "0::/absent.scope")
        fixture() do x
            path = joinpath(x.proc, "self", "cgroup")
            membership === nothing ? rm(path) : write(path, membership)
            @test_throws ArgumentError phase(x)(request())
        end
    end
end
@testset "S5 each ancestor current unknown is not zero" begin
    for index in 1:3, bad in ("", "max", "broken", "-1", string(big(M) + 1), nothing)
        fixture() do x
            # Make each ancestor an applicable finite bound in turn.
            write(joinpath(x.groups[index], "memory.max"), "100")
            path = joinpath(x.groups[index], "memory.current")
            bad === nothing ? rm(path) : write(path, bad)
            @test_throws ArgumentError phase(x)(request())
        end
    end
end
@testset "S6 unknown burst or directory refuses" begin
    fixture() do x
        @test_throws ArgumentError phase(x)((task_width = 1, elastic = true))
        for bad in (nothing, true, -1, 1.0, big(M) + 1)
            @test_throws ArgumentError phase(x)(request(memory_burst_bytes = bad))
        end
        @test_throws ArgumentError phase(x; directory = nothing)(request())
    end
end
@testset "S7 zero burst still requires measurement" begin
    fixture() do x
        @test phase(x)(request(memory_burst_bytes = 0)) == 1
        write(joinpath(x.groups[2], "memory.current"), "broken")
        @test_throws ArgumentError phase(x)(request(memory_burst_bytes = 0))
    end
end
@testset "S8 width validation and required byte overflow" begin
    fixture() do x
        completed = Ref(0)
        for bad in (true, 0, -1, 1.0, big(M) + 1)
            @test_throws ArgumentError after_phase!(completed, phase(x), request(task_width = bad))
        end
        @test completed[] == 0
        write(joinpath(x.groups[2], "memory.max"), string(M))
        write(joinpath(x.groups[2], "memory.current"), string(M))
        @test_throws OverflowError after_phase!(completed, phase(x), request(memory_burst_bytes = 1))
        @test completed[] == 0
    end
end
@testset "S9 strict CPU input and raw status distinctions" begin
    fixture() do x
        @test probe(x).logical_cpus == 1
        @test R._strict_resource_integer("max").status === :unlimited
        @test R._strict_resource_integer("0").status === :finite
        @test R._strict_resource_integer("0").value == 0
        @test R._strict_resource_integer("").status === :unknown
        @test R._strict_resource_integer("broken").status === :malformed
        @test R._strict_resource_integer(string(big(M) + 1)).status === :out_of_range
    end
    for bad in (nothing, "", "Cpus_allowed_list:\tbroken", "Cpus_allowed_list:\t0-999999999999999999999999")
        fixture() do x
            path = joinpath(x.proc, "self", "status")
            bad === nothing ? rm(path) : write(path, bad)
            @test_throws ArgumentError probe(x)
        end
    end
    for index in 1:3, bad in (nothing, "", "broken", "max 0", "-1 100000", "1 0", "NaN 100000")
        fixture() do x
            path = joinpath(x.groups[index], "cpu.max")
            bad === nothing ? rm(path) : write(path, bad)
            @test_throws ArgumentError probe(x)
        end
    end
    for bad in (nothing, "", "broken", "-1")
        fixture() do x
            path = joinpath(x.groups[1], "cpuset.cpus.effective")
            bad === nothing ? rm(path) : write(path, bad)
            @test_throws ArgumentError probe(x)
        end
    end
    for key in (:physical_memory_override, :available_memory_override, :host_logical_cpus, :julia_threads), bad in (true, -1, 1.0, big(M) + 1)
        fixture() do x
            @test_throws ArgumentError probe(x; (key => bad,)...)
        end
    end
    for key in (:host_logical_cpus, :julia_threads)
        fixture() do x
            @test_throws ArgumentError probe(x; (key => 0,)...)
        end
    end
    fixture() do x
        write(joinpath(x.proc, "self", "cgroup"), "1:name=systemd:/legacy")
        @test_throws ArgumentError probe(x)
    end
end

@testset "O1 actual entry preflight seam remains closed" begin
    completed = Ref(0)
    envelope = R.ExecutionEnvelope("fixture", 8, 1, 1, 10, 1, [0])
    for (policy, grant) in ((:campaign_strict, nothing), (:wrong_policy, envelope), (:campaign_strict, envelope))
        @test_throws ArgumentError begin
            R._scientific_resource_preflight(policy, grant)
            completed[] += 1
        end
    end
    @test completed[] == 0
    # Actual execute_scientific_plan must call this seam before mkpath, plan
    # writing and problem construction. Independent source trace is mandatory.
end
function tiny_solution(ne)
    return (problem = (numerical = (N_E = ne, N_k = 1, N_b = 1),
        kernels = (K = Dict{Symbol,Vector{UInt8}}(), Fᴸᴼ = UInt8[])),)
end
@testset "O2 actual checkpoint preflight seam before writer" begin
    completed = Ref(0)
    @test_throws ArgumentError begin
        R._checkpoint_storage_preflight(tiny_solution(true), 0)
        completed[] += 1
    end
    @test_throws OverflowError begin
        R._checkpoint_storage_preflight(tiny_solution(1), M)
        completed[] += 1
    end
    @test completed[] == 0
    # Actual commit_point_artifacts must use this same checked forecast/reserve
    # seam before generation creation/HDF5. Root mkdir is a separate effect.
end
@testset "O3 actual phase callback before continuation" begin
    fixture() do x
        completed = Ref(0)
        callback = phase(x)
        @test_throws ArgumentError after_phase!(completed, callback, (task_width = 1, elastic = true))
        @test completed[] == 0
        @test !haskey(R._NATIVE_PHASE_ADMISSIONS, x.directory) ||
            get(R._NATIVE_PHASE_ADMISSIONS[x.directory], "memory_admission_mode", "") != "cgroup_v2"
        @test !isfile(joinpath(x.directory, "phases.jsonl"))
    end
end
@testset "O4 healthy finite gate fires real continuation" begin
    fixture() do x
        completed = Ref(0)
        @test after_phase!(completed, phase(x), request()) == 1
        @test completed[] == 1
        @test R._checkpoint_storage_preflight(tiny_solution(1), 0) ==
            (forecast_bytes = 16777728, required_bytes = 16777728)
        @test R._scientific_resource_preflight(:standalone, nothing) === nothing
    end
end
end
