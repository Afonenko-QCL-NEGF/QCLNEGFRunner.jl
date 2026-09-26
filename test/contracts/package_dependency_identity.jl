module PackageDependencyIdentityTests
include("../support/common.jl")
@testset "Both package sources bind runtime identity" begin
    identity = QCLNEGFRunner._runtime_software_identity()
    records = identity["source_files"]
    paths = getindex.(records, "path")
    @test "QCLNEGF/src/numerics/reference/solver.jl" in paths
    @test "QCLNEGFRunner/src/composition/scientific_execution.jl" in paths
    @test allunique(paths)
    @test !any(isabspath, paths)
    @test all(record -> length(record["sha256"]) == 64, records)
    @test identity["toolchain"]["manifest_sha256"] == bytes2hex(QCLNEGFRunner.SHA.sha256(read(joinpath(dirname(Base.active_project()), "Manifest.toml"))))
end
end
