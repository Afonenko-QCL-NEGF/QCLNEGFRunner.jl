module BufferedRecoveryCopyTests
using Test, SHA
include(joinpath(@__DIR__, "..", "..", "src", "infrastructure", "persistence", "atomic_files.jl"))

@testset "buffered recovery bytes and refusals" begin
    mktempdir() do root
        source = mkdir(joinpath(root, "source"))
        nested = mkdir(joinpath(source, "nested"))
        empty = mkdir(joinpath(nested, "empty"))
        sizes = (0, 1, 2 * 1024^2 + 17)
        pattern(n) = UInt8[mod(37 * i + 11, 256) for i in 0:(n - 1)]
        for n in sizes
            write(joinpath(nested, "bytes-$n"), pattern(n))
        end
        chmod(joinpath(nested, "bytes-1"), 0o640)
        chmod(empty, 0o750)
        chmod(nested, 0o750)
        chmod(source, 0o750)
        destination = joinpath(root, "copy")
        @test _copy_regular_tree_buffered(source, destination) == abspath(destination)
        @test isdir(joinpath(destination, "nested", "empty"))
        @test isempty(readdir(joinpath(destination, "nested", "empty")))
        for n in sizes
            path = joinpath(destination, "nested", "bytes-$n")
            @test filesize(path) == n
            @test read(path) == pattern(n)
            @test open(sha256, path) == sha256(pattern(n))
            @test stat(path).mode & 0o7777 == stat(joinpath(nested, "bytes-$n")).mode & 0o7777
        end
        for relative in (".", "nested", joinpath("nested", "empty"))
            @test stat(joinpath(destination, relative)).mode & 0o7777 ==
                stat(joinpath(source, relative)).mode & 0o7777
        end
        sentinel = joinpath(destination, "sentinel")
        write(sentinel, "keep")
        @test_throws ArgumentError _copy_regular_tree_buffered(source, destination)
        @test read(sentinel, String) == "keep"
        @test_throws ArgumentError _copy_regular_tree_buffered(source, source)
        inside = joinpath(source, "inside")
        @test_throws ArgumentError _copy_regular_tree_buffered(source, inside)
        @test !ispath(inside)
        alias = joinpath(root, "alias")
        symlink(source, alias)
        @test_throws ArgumentError _copy_regular_tree_buffered(alias, joinpath(root, "alias-copy"))
        @test !ispath(joinpath(root, "alias-copy"))
        @test_throws ArgumentError _copy_regular_tree_buffered(source, joinpath(alias, "inside-alias"))
        @test !ispath(joinpath(source, "inside-alias"))
        symlink(joinpath(nested, "bytes-1"), joinpath(source, "link"))
        @test_throws ArgumentError _copy_regular_tree_buffered(source, joinpath(root, "link-copy"))
        @test !ispath(joinpath(root, "link-copy"))
        rm(joinpath(source, "link"))
        dangling = joinpath(root, "dangling")
        symlink(joinpath(root, "absent"), dangling)
        @test_throws ArgumentError _copy_regular_tree_buffered(source, dangling)
        @test islink(dangling)
        if Sys.islinux()
            fifo = joinpath(source, "fifo")
            run(`mkfifo $fifo`)
            @test_throws ArgumentError _copy_regular_tree_buffered(source, joinpath(root, "fifo-copy"))
            @test !ispath(joinpath(root, "fifo-copy"))
        end
    end
end
end
