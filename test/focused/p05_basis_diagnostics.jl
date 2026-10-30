using Test, QCLNEGFRunner
const R=QCLNEGFRunner; const W=R.QCLScientificWorkflow
@testset "basis checks use public Core diagnostics" begin
    src=read(joinpath(dirname(dirname(pathof(R))),"src/composition/operator_physical_anchors.jl"),String)
    @test !occursin("._STRUCTURAL_VALIDATION_LIMITS",src)
    @test !occursin("._PZP_TRANSLATION_LIMIT",src)
    @test !occursin("._PZP_TWO_PAIR_LIMIT",src)
    @test !occursin("._relative_norm",src)
    base=R.load_run_configuration(joinpath(dirname(@__DIR__),"fixtures/configurations/studies-smoke.yaml"))
    raw=deepcopy(base.raw)
    raw["physical"]["layers"]=[Dict("thickness"=>"12 nm","material"=>"GaAs", "aluminium_fraction"=>0., "conduction_band_edge"=>"0.2 eV", "longitudinal_relative_mass"=>0.067, "transverse_relative_mass"=>0.067, "relative_permittivity"=>12.9, "doped"=>true)]
    raw["physical"]["interfaces"]=["0 nm"]
    merge!(raw["numerical"],Dict("spatial_nodes"=>12,"basis_states"=>12,"basis_periods"=>1,"energy_nodes"=>201,"momentum_nodes"=>3,"longitudinal_momentum_nodes"=>5,"angular_nodes"=>4))
    raw["algorithms"]["localization"]="real_space"
    config=R._resolve_configuration(raw,base.provenance)
    rows=W._structure_spectrum_checks(config,nothing)
    @test getindex.(rows,"name") == ["structure_basis_orthonormal","structure_basis_eigen","structure_Hermitian_H0","structure_coupling_adjoint"]
    @test all(row->isfinite(row["value"]) && row["passed"],rows)
    raw["numerical"]["basis_states"]=3
    raw["numerical"]["basis_periods"]=3
    raw["algorithms"]["localization"]="pzp"
    pzp=R._resolve_configuration(raw,base.provenance)
    prows=W._structure_spectrum_checks(pzp,nothing)
    @test getindex.(prows[end-2:end],"name") == ["structure_translation","structure_translation_nearest","structure_translation_two_pairs"]
    @test getindex.(prows[end-2:end],"threshold") == [0.1,0.1,0.005]
    @test all(row->isfinite(row["value"]),prows)
end
