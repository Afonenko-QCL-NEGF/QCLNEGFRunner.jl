using Test

# An optional test-directory argument checks the selected launcher's behavior
# against an existing raw runtime without building another Julia package.
length(ARGS) <= 3 || error("Expected test profile, worker limit and optional test directory")
test_profile = isempty(ARGS) ? "production-build" : ARGS[1]
test_profile in ("production-build", "local-debug") || error("Unknown Julia test profile")
limit_argument = length(ARGS) < 2 ? (test_profile == "local-debug" ? "2" : "native") : ARGS[2]
worker_limit = limit_argument == "native" ? nothing : tryparse(Int, limit_argument)
(limit_argument == "native" || (worker_limit !== nothing && worker_limit > 0)) || error("Invalid test worker limit")
(test_profile != "local-debug" || worker_limit === 2) || error("Local-debug requires two test workers")
test_directory = length(ARGS) < 3 ? normpath(Sys.BINDIR, "..", "share", "julia", "test") : abspath(ARGS[3])

@testset "Julia install-check profile preserves native CPU behavior" begin
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
    for (effective, count, production_expected, debug_expected) in
        ((1, 3, 1, 1), (2, 3, 2, 2), (8, 3, 3, 2), (8, 1, 1, 1), (8, 8, 8, 2),
         (8, 0, 0, 0), (32, 40, 32, 2), (64, 70, 64, 2))
        expected = test_profile == "local-debug" ? debug_expected :
            worker_limit === nothing ? production_expected : min(production_expected, worker_limit)
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

println("Julia test profile: ", test_profile, "; worker limit=", limit_argument, "; native CPUs=", Sys.CPU_THREADS,
        "; effective CPUs=", Sys.EFFECTIVE_CPU_THREADS)
