using Test, QCLNEGF, QCLNEGFRunner
const R = QCLNEGFRunner
@testset "runner metadata names the runner package version" begin
    metadata=R._runtime_software_identity()
    @test metadata["package"] == "QCLNEGFRunner"
    @test metadata["package_version"] == string(Base.pkgversion(QCLNEGFRunner))
    @test R._core_package_version() == string(Base.pkgversion(QCLNEGF))
end
