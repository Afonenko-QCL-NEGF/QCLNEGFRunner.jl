# The upstream test launcher selects workers from Sys.EFFECTIVE_CPU_THREADS.
# Check Julia's interpretation of the build limit before its full stdlib suite.
@assert VERSION == v"1.13.0" "The test-worker contract targets the pinned Julia runtime"
@assert Sys.CPU_THREADS == 2 "Julia did not apply the two-CPU build limit"
@assert 1 <= Sys.EFFECTIVE_CPU_THREADS <= 2 "Upstream tests can exceed the worker budget"
println("Julia test-worker budget: ", Sys.EFFECTIVE_CPU_THREADS)
