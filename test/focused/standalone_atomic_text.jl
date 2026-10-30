# Focused stdlib regression: losing the outer target binding breaks the return
# contract after a successful publication, before scientific work can begin.
using Test
module StandaloneAtomicTextSandbox
using SHA
const SOURCE_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
# Include WHOLE owning files; no extracted function, mock writer, or FS adapter.
include(joinpath(SOURCE_ROOT, "src/infrastructure/persistence/atomic_files.jl"))
include(joinpath(SOURCE_ROOT, "src/infrastructure/telemetry/progress.jl"))
end
const R = StandaloneAtomicTextSandbox

@testset "standalone atomic text path-first publishes and returns absolute path" begin
    mktempdir() do root
        cd(root) do
            mkpath("nested")
            write("nested/plan.json", "old publication\n")
            @test R._observability_atomic_text("nested/plan.json", io ->
                write(io, "{\"schema\":\"fixture-plan\",\"points\":1}\n")) ==
                joinpath(root, "nested", "plan.json")
            @test read("nested/plan.json", String) ==
                "{\"schema\":\"fixture-plan\",\"points\":1}\n"
            @test readdir("nested") == ["plan.json"]
        end
    end
end

@testset "standalone atomic text do-order replaces exact bytes and returns path" begin
    mktempdir() do root
        target = joinpath(root, "progress.csv")
        write(target, "old progress\n")
        returned = R._observability_atomic_text(target) do io
            write(io, "stage,iteration\ninitialization,0\n")
        end
        @test returned == target
        @test read(target, String) == "stage,iteration\ninitialization,0\n"
        @test readdir(root) == ["progress.csv"]
    end
end

@testset "throwing standalone writer retains original and removes temporary" begin
    mktempdir() do root
        target = joinpath(root, "plan.json")
        write(target, "original complete plan\n")
        failure = ErrorException("intentional callback failure")
        stream = Ref{IO}()
        caught = try
            R._observability_atomic_text(target) do io
                stream[] = io
                write(io, "incomplete replacement")
                throw(failure)
            end
            nothing
        catch actual
            actual
        end
        @test caught === failure
        @test !isopen(stream[])
        @test read(target, String) == "original complete plan\n"
        @test readdir(root) == ["plan.json"]
    end
end
