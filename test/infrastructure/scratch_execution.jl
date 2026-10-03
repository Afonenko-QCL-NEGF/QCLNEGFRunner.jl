module ScratchExecutionTests
include("../support/common.jl")
@testset "Verified scratch delivery" begin
    mktempdir() do root
        source = joinpath(root, "source")
        mkpath(joinpath(source, "nested"))
        write(joinpath(source, "nested", "data.bin"), UInt8[0,1,2,255])
        destination = joinpath(root, "shared", "result")
        @test stage_result_tree(source, destination) == destination
        @test read(joinpath(destination, "nested", "data.bin")) == UInt8[0,1,2,255]
        @test_throws ArgumentError stage_result_tree(source, destination)
        @test_throws ArgumentError stage_result_tree(source, joinpath(source, "nested", "result"))
        symlink(joinpath(source, "nested", "data.bin"), joinpath(source, "linked"))
        @test_throws ArgumentError stage_result_tree(source, joinpath(root, "linked-result"))
        @test !ispath(joinpath(root, "linked-result"))
    end
end

@testset "Staging rejects special files and admits bytes before hashing" begin
    mktempdir() do root
        source=joinpath(root,"source")
        mkpath(source)
        path=joinpath(source,"data.bin")
        write(path,UInt8[1,2,3,4])
        chmod(path,0o000)
        try
            failure=try
                stage_result_tree(source,joinpath(root,"result");byte_budget=1,reserve_bytes=0)
                nothing
            catch error
                error
            end
            @test failure isa ArgumentError
            @test failure isa ArgumentError && occursin("budget",sprint(showerror,failure))
            @test !ispath(joinpath(root,"result"))
        finally
            chmod(path,0o600)
        end
        rm(path)
        fifo=joinpath(source,"named-pipe")
        run(`mkfifo $fifo`)
        @test_throws ArgumentError stage_result_tree(source,joinpath(root,"fifo-result");byte_budget=1024,reserve_bytes=0)
        @test !ispath(joinpath(root,"fifo-result"))
    end
end

@testset "Staging budget includes the source and simultaneous pending copy" begin
    mktempdir() do root
        source = joinpath(root, "source")
        mkpath(joinpath(source, "nested"))
        write(joinpath(source, "first.bin"), UInt8[1,2,3,4,5,6,7,8])
        write(joinpath(source, "nested", "second.bin"), UInt8[9,10,11,12])
        destination = joinpath(root, "shared", "result")
        # Twelve source bytes need another twelve bytes during publication.
        failure = try
            stage_result_tree(source, destination; byte_budget=23, reserve_bytes=0)
            nothing
        catch error
            error
        end
        @test failure isa ArgumentError
        @test failure isa ArgumentError && occursin("budget", sprint(showerror, failure))
        @test !ispath(destination)
        @test !ispath(dirname(destination))
        @test read(joinpath(source, "first.bin")) == UInt8[1,2,3,4,5,6,7,8]
        @test stage_result_tree(source, destination; byte_budget=24, reserve_bytes=0) == destination
        @test read(joinpath(destination, "nested", "second.bin")) == UInt8[9,10,11,12]
    end
end

@testset "Staging reserve refusal preserves an existing destination" begin
    mktempdir() do root
        source, destination = joinpath(root, "source"), joinpath(root, "destination")
        mkpath(source)
        write(joinpath(source, "data.bin"), UInt8[1,2,3,4])
        refused = joinpath(root, "new-parent", "result")
        @test_throws ArgumentError stage_result_tree(source, refused; byte_budget=10, reserve_bytes=3)
        @test !ispath(dirname(refused))
        mkpath(destination)
        write(joinpath(destination, "owned-by-someone-else"), "keep")
        @test_throws ArgumentError stage_result_tree(source, destination; byte_budget=1, reserve_bytes=0)
        @test read(joinpath(destination, "owned-by-someone-else"), String) == "keep"
        for options in ((byte_budget=0, reserve_bytes=0), (byte_budget=8, reserve_bytes=-1),
                        (byte_budget=8, reserve_bytes=8))
            @test_throws ArgumentError stage_result_tree(source, refused; options...)
            @test !ispath(dirname(refused))
        end
    end
end
end
