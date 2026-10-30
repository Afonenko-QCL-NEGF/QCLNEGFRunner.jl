using Test, QCLNEGFRunner, Unitful
const R = QCLNEGFRunner
@testset "configuration unit boundary is independent of Core private helpers" begin
    src=read(joinpath(dirname(dirname(pathof(R))),"src/infrastructure/config/configuration.jl"),String)
    @test isempty(collect(eachmatch(r"\b_(?:energy|length|temperature|field|wavenumber|sheetdensity|massdensity|speed|volume|mass)\b",src)))
    @test R._energy_configuration("1 meV", "energy") == 0.001u"eV"
    @test R._length_configuration("2 nm", "length") == 2e-9u"m"
    @test R._temperature_configuration("70 K", "temperature") == 70.0u"K"
    @test R._field_configuration("2 V/m", "field") == 2.0u"V/m"
    @test R._wavenumber_configuration("2 m^-1", "wave") == 2.0u"m^-1"
    @test R._sheetdensity_configuration("2 m^-2", "sheet") == 2.0u"m^-2"
    @test R._massdensity_configuration("2 kg/m^3", "density") == 2.0u"kg/m^3"
    @test R._speed_configuration("2 m/s", "speed") == 2.0u"m/s"
    @test R._volume_configuration("2 m^3", "volume") == 2.0u"m^3"
    @test R._mass_configuration("2 kg", "mass") == 2.0u"kg"
    @test_throws R.ConfigurationError R._energy_configuration("1 m", "energy")
end
