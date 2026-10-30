using Test, QCLNEGF, QCLNEGFRunner, LinearAlgebra
const R=QCLNEGFRunner
@testset "exact execution requires real loaded runtime facts" begin
    sources=R._capture_solver_sources()
    @test !isempty(sources["solver_source_files"])
    @test length(sources["core_source_sha256"])==64
    @test_throws ArgumentError R._capture_exact_execution(ProductionOptions(worker_count=0),sources)
    @test_throws ArgumentError R._capture_exact_execution(ProductionOptions(worker_count=1),Dict{String,Any}())
    forged=deepcopy(sources); forged["core_source_sha256"]=repeat("0",64)
    @test_throws ArgumentError R._capture_exact_execution(ProductionOptions(worker_count=1),forged)
    @test_throws ArgumentError R._capture_exact_execution(ProductionOptions(worker_count=Threads.nthreads(:default)+1),sources)
    @test_throws ArgumentError R._p05_fact("unknown","fixture")
    @test_throws ArgumentError R._p05_library_file("/path/definitely/missing/library")
    options=ProductionOptions(worker_count=1)
    captured=R._capture_exact_execution(options,sources)
    @test captured.execution.worker_count==1
    @test captured.execution.blas_threads==BLAS.get_num_threads()
    @test captured.execution.julia==string(VERSION)
    @test captured.execution.core_code==sources["core_source_sha256"]
    @test length(captured.execution.blas)==64 && length(captured.execution.fftw)==64
    @test !isempty(captured.provenance["blas"]["libraries"])
    @test startswith(captured.provenance["fftw"]["double"]["fresh_version_string"],"fftw-")
end
@testset "source identities follow content and not root path" begin
    mktempdir() do dir
        function root(name, code)
            path=joinpath(dir,name); mkpath(joinpath(path,"src"))
            write(joinpath(path,"Project.toml"),"name = \"fixture\"\n")
            write(joinpath(path,"src","file.jl"),code)
            path
        end
        core1=root("core1","one"); core2=root("core2","one"); runner=root("runner","two")
        a=R._capture_solver_sources_at(core1,runner)
        b=R._capture_solver_sources_at(core2,runner)
        @test a==b
        write(joinpath(core2,"src","file.jl"),"changed")
        c=R._capture_solver_sources_at(core2,runner)
        @test c["core_source_sha256"]!=a["core_source_sha256"]
        @test c["solver_source_files"]!=a["solver_source_files"]
    end
end
