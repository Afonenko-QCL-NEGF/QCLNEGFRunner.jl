using Test, QCLNEGFRunner, Unitful
const R=QCLNEGFRunner
@testset "scalar unit conversion uses Runner Unitful boundary" begin
    coreapi=read(joinpath(dirname(dirname(pathof(R))),"src/core_api.jl"),String)
    @test !occursin(r"(?m)^\s+_(electronvolts|metres|kelvin|inverse_metres|volts_per_metre|per_square_metre),$",coreapi)
    @test R._runner_electronvolts(3u"meV") == 0.003
    @test R._runner_metres(2u"nm") == 2e-9
    @test R._runner_kelvin(70u"K") == 70.
    @test R._runner_inverse_metres(2u"nm^-1") == 2e9
    @test R._runner_volts_per_metre(3u"V/m") == 3.
    @test R._runner_per_square_metre(2u"m^-2") == 2.
    @test isnan(R._runner_electronvolts(NaN*u"eV"))
    @test isinf(R._runner_electronvolts(Inf*u"eV"))
    @test_throws Unitful.DimensionError R._runner_electronvolts(1u"m")
end
