using Test

# A test-directory argument allows the same guard to check the patched launcher
# against the existing raw runtime without building another Julia package.
test_directory = isempty(ARGS) ? normpath(Sys.BINDIR, "..", "share", "julia", "test") : abspath(only(ARGS))

@testset "Julia install-check worker budget preserves native CPU behavior" begin
    @test VERSION == v"1.13.0"
    cpu_override_present = haskey(ENV, "JULIA_CPU_THREADS")
    @test !cpu_override_present
    native_cpus = Int(ccall(:jl_cpu_threads, Int32, ()))
    native_effective = min(native_cpus, Int(ccall(:jl_effective_threads, Int32, ())))
    @test Sys.CPU_THREADS == native_cpus
    @test Sys.EFFECTIVE_CPU_THREADS == native_effective

    # Exercise the actual installed launcher's worker-selection expression with
    # boundary inputs in a separate module; native Sys globals remain untouched.
    source = readlines(joinpath(test_directory, "runtests.jl"))
    selection = Meta.parse(only(filter(line -> startswith(strip(line), "n = min("), source)))
    scope = Module(gensym(:WorkerSelection), false, false)
    Core.eval(scope, :(const min = $min))
    Core.eval(scope, :(const length = $length))
    for (effective, count, expected) in ((1, 3, 1), (2, 3, 2), (8, 3, 2), (8, 1, 1), (8, 8, 2))
        Core.eval(scope, :(Sys = (EFFECTIVE_CPU_THREADS = $effective,)))
        Core.eval(scope, :(tests = $(fill("fixture", count))))
        @test Core.eval(scope, selection) == expected
    end

    # Use Julia's own affinity helper and independently specified expectations.
    # A global CPU override broke these cases after over an hour of full tests.
    include(joinpath(test_directory, "print_process_affinity.jl"))
    allowed_cpus = findall(uv_thread_getaffinity())
    expected_blas_threads = (1, 1, 1, 2, 2, 3, 3, 4)
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no -E 'using LinearAlgebra; BLAS.get_num_threads()'`,
                 "OPENBLAS_NUM_THREADS" => nothing,
                 "GOTO_NUM_THREADS" => nothing,
                 "OMP_NUM_THREADS" => nothing)
    for n in 1:min(length(allowed_cpus), length(expected_blas_threads))
        observed = try
            readchomp(setcpuaffinity(cmd, allowed_cpus[1:n]))
        catch
            nothing
        end
        # ProcessFailedException renders Cmd.env. Throw outside the catch so
        # failed probes stop the guard without printing an inherited environment.
        observed === nothing && error("BLAS affinity probe failed for CPU count $n")
        println("BLAS affinity CPUs=", n, ": observed=", observed, " expected=", expected_blas_threads[n])
        @test observed == string(expected_blas_threads[n])
    end
end

println("Julia test-worker budget: 2; native CPUs=", Sys.CPU_THREADS,
        "; effective CPUs=", Sys.EFFECTIVE_CPU_THREADS)
