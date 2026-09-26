module Suite_T098
include("../support/common.jl")
using HDF5
include("../support/resource_probe.jl")

@testset "Linux process resource probe" begin
    gib = 1024^3
    mktempdir() do directory
        proc_root = joinpath(directory, "proc")
        cgroup_root = joinpath(directory, "cgroup")
        service = joinpath(cgroup_root, "reference2019.slice", "solver.service")
        slice = dirname(service)
        _write_resource_fixture(
            joinpath(proc_root, "self", "cgroup"),
            "0::/reference2019.slice/solver.service\n",
        )
        _write_resource_fixture(
            joinpath(proc_root, "self", "status"),
            "Name:\tjulia\nCpus_allowed_list:\t2-5,8-9\n",
        )
        _write_resource_fixture(
            joinpath(proc_root, "meminfo"),
            "MemTotal:       16777216 kB\n" * "MemAvailable:    8388608 kB\n",
        )

        _write_resource_fixture(joinpath(cgroup_root, "memory.max"), "max\n")
        _write_resource_fixture(joinpath(cgroup_root, "memory.high"), "max\n")
        _write_resource_fixture(joinpath(cgroup_root, "memory.current"), string(4gib))
        _write_resource_fixture(joinpath(cgroup_root, "cpu.max"), "max 100000\n")
        _write_resource_fixture(joinpath(slice, "memory.max"), string(12gib))
        _write_resource_fixture(joinpath(slice, "memory.high"), string(10gib))
        _write_resource_fixture(joinpath(slice, "memory.current"), string(3gib))
        _write_resource_fixture(joinpath(slice, "cpu.max"), "250000 100000\n")
        _write_resource_fixture(joinpath(service, "memory.max"), "max\n")
        _write_resource_fixture(joinpath(service, "memory.high"), string(9gib))
        _write_resource_fixture(joinpath(service, "memory.current"), string(2gib))
        _write_resource_fixture(joinpath(service, "cpu.max"), "max 100000\n")
        _write_resource_fixture(joinpath(service, "cpuset.cpus.effective"), "2-5,8-9\n")

        hardware = probe_hardware(;
            proc_root,
            cgroup_root,
            physical_memory_override = 16gib,
            host_logical_cpus = 16,
            julia_threads = 12,
            blas_vendor_override = "fixture-blas",
        )
        @test hardware.julia_threads == 12
        @test hardware.logical_cpus == 2
        @test hardware.cpu_affinity_count == 6
        @test hardware.cpu_quota_cores == 2.5
        @test hardware.total_memory_bytes == 9gib
        @test hardware.available_memory_bytes == 7gib
        @test hardware.physical_memory_bytes == 16gib
        @test hardware.cgroup_memory_max_bytes == 12gib
        @test hardware.cgroup_memory_high_bytes == 9gib
        @test hardware.cgroup_memory_current_bytes == 2gib
        @test hardware.cgroup_path == joinpath("reference2019.slice", "solver.service")
        @test occursin("cpu.max", hardware.cpu_source)
        @test occursin("memory.high", hardware.memory_source)

        dictionary = hardware_profile_dict(hardware)
        @test dictionary["effective_logical_cpus"] == 2
        @test dictionary["available_memory_bytes"] == 7gib
    end

    mktempdir() do directory
        proc_root = joinpath(directory, "proc")
        cgroup_root = joinpath(directory, "cgroup")
        _write_resource_fixture(
            joinpath(proc_root, "self", "cgroup"),
            "1:name=systemd:/legacy\n",
        )
        _write_resource_fixture(
            joinpath(proc_root, "self", "status"),
            "Cpus_allowed_list:\t0-7\n",
        )
        _write_resource_fixture(
            joinpath(proc_root, "meminfo"),
            "MemAvailable:    6291456 kB\n",
        )
        _write_resource_fixture(joinpath(cgroup_root, "memory.max"), "max\n")
        _write_resource_fixture(joinpath(cgroup_root, "memory.high"), "max\n")
        _write_resource_fixture(joinpath(cgroup_root, "memory.current"), "0\n")
        _write_resource_fixture(joinpath(cgroup_root, "cpu.max"), "max 100000\n")
        _write_resource_fixture(joinpath(cgroup_root, "cpuset.cpus.effective"), "0-7\n")
        hardware = probe_hardware(;
            proc_root,
            cgroup_root,
            physical_memory_override = 8gib,
            host_logical_cpus = 8,
            julia_threads = 8,
            blas_vendor_override = "fixture-blas",
        )
        @test hardware.logical_cpus == 8
        @test hardware.total_memory_bytes == 8gib
        @test hardware.available_memory_bytes == 6gib
        @test hardware.cgroup_memory_max_bytes == typemax(Int)
        @test hardware.cgroup_path == "."
    end

    @test QCLNEGFRunner._cpuset_count("0-3,8,10-11") == 7
    @test QCLNEGFRunner._cpuset_count("0-3,2-5") == 6
    @test QCLNEGFRunner._cpuset_count("broken") == typemax(Int)
end

end # independent suite
