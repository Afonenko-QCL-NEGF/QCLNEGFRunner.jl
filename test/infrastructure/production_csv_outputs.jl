module Suite_T094
include("../support/common.jl")
using HDF5

@testset "Production CSV outputs" begin
    response = OpticalResponse(
        [0.010u"eV", 0.012u"eV"],
        [2.0e12u"Hz", 2.5e12u"Hz"],
        [1.2e13u"s^-1", 1.5e13u"s^-1"],
        ComplexF64[1.0+0.2im, 0.8-0.1im],
        ComplexF64[3.6+0.01im, 3.5-0.02im],
        [100.0u"m^-1", -50.0u"m^-1"],
        BitVector([true, false]),
        [0.0, 0.25],
        12.9,
        :bare_bubble,
        :length,
        false,
    )
    mktempdir() do directory
        optical_path = joinpath(directory, "nested", "optical.csv")
        @test save_optical_response(optical_path, response) == optical_path
        optical_lines = readlines(optical_path)
        @test length(optical_lines) == 3
        @test startswith(optical_lines[1], "photon_energy_eV,frequency_Hz")
        @test occursin(",true,0.0", optical_lines[2])
        @test occursin(",false,0.25", optical_lines[3])

        interpolation = KernelInterpolationDiagnostic(
            :LO,
            :piecewise_linear_q_lookup,
            65,
            211,
            1.0e-4,
            1.5e-4,
            1.2e-4,
            [33, 65],
            [4.0e-4, 1.5e-4],
            true,
        )
        diagnostics = ProductionKernelDiagnostics(Dict(:LO => interpolation), 1.5e-4, true)
        diagnostic_path = joinpath(directory, "kernels.csv")
        @test save_kernel_diagnostics(diagnostic_path, diagnostics) == diagnostic_path
        diagnostic_lines = readlines(diagnostic_path)
        @test length(diagnostic_lines) == 2
        @test startswith(diagnostic_lines[1], "mechanism,construction,lookup_nodes")
        @test occursin("LO,piecewise_linear_q_lookup,65,211", diagnostic_lines[2])
        @test occursin("33;65", diagnostic_lines[2])
    end
end

end # independent suite
