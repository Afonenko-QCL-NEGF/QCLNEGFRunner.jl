module Suite_T113
include("../support/common.jl")

@testset "Every scattering channel is isolated and configured" begin
    root = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))
    study = load_run_configuration(joinpath(root, "studies-research-scattering.yaml"))
    names = (
        "lo_phonon",
        "acoustic_phonon",
        "ionized_impurity",
        "interface_roughness",
        "alloy_disorder",
    )
    fields = (:LO, :acoustic, :impurity, :IFR, :alloy)
    for (name, field) in zip(names, fields)
        index = findfirst(
            m -> endswith(m.profile, "only_" * name * ".yaml"),
            study.study.methods,
        )
        @test index !== nothing
        metadata = study.study.methods[index]
        profile = load_run_configuration(joinpath(root, metadata.profile))
        configured = QCLNEGFRunner._method_configuration(
            study,
            profile,
            "unused";
            overrides = study.raw["study"]["methods"][index]["overrides"],
        )
        @test all(getfield(configured.scattering, f) == (f == field) for f in fields)
        @test configured.classification === :physics_changing
    end
    @test study.physical.ΔV_alloy !== nothing
    @test study.physical.Ω₀ !== nothing
end

end # independent suite
