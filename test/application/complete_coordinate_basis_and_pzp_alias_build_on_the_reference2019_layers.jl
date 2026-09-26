module Suite_T114
include("../support/common.jl")

@testset "Complete coordinate basis and PzP representation build on the QCL layers" begin
    root = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))
    reference =
        load_run_configuration(joinpath(root, "research-cases-full_space_legacy.yaml"))
    bases = Dict{Symbol,Any}()
    for mode in (:pzp, :none, :real_space)
        # Preserve the actual material layers, coordinate grid and full basis.
        # No kernels/SCBA are needed to test the basis construction contract.
        grids = build_grids(reference.physical, reference.numerical, reference.scales)
        profiles =
            build_profiles(reference.physical, reference.numerical, reference.scales, grids)
        basis = build_localized_basis(
            reference.physical,
            reference.numerical,
            reference.scales,
            grids,
            profiles;
            localization = mode,
        )
        bases[mode] = basis
        @test size(basis.Φ) == (12, 12)
        @test norm(basis.Φ' * basis.Φ - I) < 1e-10
        @test norm(basis.T₋ - basis.T₊') < 1e-10
    end
    @test bases[:real_space].Φ ≈ Matrix{ComplexF64}(I, 12, 12)
end

end # independent suite
