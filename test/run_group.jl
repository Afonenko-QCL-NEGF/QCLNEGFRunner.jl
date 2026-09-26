using Test
Base.JLOptions().check_bounds == 1 ||
    error("Scientific tests require explicit --check-bounds=yes")
const TEST_GROUPS = ("application", "contracts", "infrastructure", "presentation", "integration")
function run_test_group(group::AbstractString)
    group in TEST_GROUPS ||
        throw(ArgumentError("unknown group $group; choose $(join(TEST_GROUPS, ", "))"))
    directory = joinpath(@__DIR__, group)
    files = sort(filter(path -> endswith(path, ".jl"), readdir(directory; join = true)))
    isempty(files) && error("empty test group: $group")
    @testset verbose=true "$group" begin
        for file in files
            println("[suite] ", relpath(file, @__DIR__))
            flush(stdout)
            include(file)
        end
    end
end
if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 1 || error("usage: julia --project=test test/run_group.jl GROUP")
    run_test_group(only(ARGS))
end
