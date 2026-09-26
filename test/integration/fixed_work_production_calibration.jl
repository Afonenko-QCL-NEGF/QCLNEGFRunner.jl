module FixedWorkProductionCalibrationTests
using Test
using QCLNEGFRunner
using YAML
using SHA
include("../../scripts/calibrate_production_kernels.jl")
const Calibration=QCLFixedWorkCalibration

function calibration_plan(directory, family)
    source=normpath(joinpath(@__DIR__, "..", "fixtures", "research-inputs", "model", "reference-2019-70k.yaml"))
    overrides=Dict{String,Any}(
        "numerical"=>Dict(
            "spatial_nodes"=>48,
            "basis_states"=>3,
            "basis_periods"=>1,
            "energy_min"=>"-0.10 eV",
            "energy_max"=>"0.28 eV",
            "energy_nodes"=>49,
            "energy_trust_margin"=>"56 meV",
            "momentum_max"=>"0.45 nm^-1",
            "momentum_nodes"=>5,
            "angular_nodes"=>8,
            "longitudinal_momentum_max"=>"6 nm^-1",
            "longitudinal_momentum_nodes"=>25,
            "seed_broadening"=>"2 meV",
        ),
        "scattering"=>Dict(
            "lo_phonon"=>true,
            "acoustic_phonon"=>family=="lo-elastic",
            "ionized_impurity"=>family=="lo-elastic",
            "interface_roughness"=>family=="lo-elastic",
            "alloy_disorder"=>false,
        ),
    )
    study=Dict(
        "schema"=>"qcl-negf-study-v2",
        "kind"=>"study",
        "id"=>"calibration-"*family,
        "purpose"=>"reproducibility",
        "operation"=>"stationary",
        "configuration"=>Dict("sources"=>[source], "overrides"=>overrides),
        "axes"=>Dict(
            "temperatures"=>Dict("values"=>[70], "unit"=>"K"),
            "voltages"=>Dict("values"=>[48], "unit"=>"mV"),
        ),
    )
    study_path=joinpath(directory, family*".yaml")
    YAML.write_file(study_path, study)
    plan=resolve_scientific_plan(study_path)
    plan_path=joinpath(directory, family*"-plan.json")
    open(io->write_scientific_plan(io, plan), plan_path, "w")
    return plan_path, only(plan.executions).id
end

@testset "Fixed production work preserves finite full states without acceptance" begin
    options=Calibration.fixed_work_options(SolverOptions(), 2)
    @test options.max_scba==2
    @test options.convergence.required_consecutive_scba_passes==3
    @test options.tolerances==SolverOptions().tolerances
    @test !options.convergence.diagnostic_quality.enabled
    @test_throws ArgumentError Calibration.fixed_work_options(options, 1)
    @test_throws ArgumentError Calibration.fixed_work_options(options, 10_001)
    bytes=UInt8[0x61, 0x62]
    @test Calibration.workload_fingerprint(bytes, "run", 2) ==
          bytes2hex(sha256(UInt8[0x61, 0x62, 0, 0x72, 0x75, 0x6e, 0, 0x32]))
    mktempdir() do directory
        for family in ("lo", "lo-elastic")
            plan_path, id=calibration_plan(directory, family)
            output=joinpath(directory, family*"-result")
            result=Calibration.calibrate(plan_path, output, id, 2)
            @test result["status"]=="completed"
            @test !result["physical_accepted"] && !result["scientific_accepted"]
            @test result["kernel_calls"]==2
            @test result["total_candidate_calls"]==3
            @test result["initialization_candidate_calls"]==1
            @test result["toolchain"]["manifest_sha256"]==bytes2hex(
                open(sha256, joinpath(dirname(Base.active_project()), "Manifest.toml")),
            )
            @test result["effective_input_fingerprint"]==Calibration.workload_fingerprint(
                read(plan_path),
                id,
                2,
            )
            @test all(isfinite, values(result["scientific_observables"]))
            @test_throws ArgumentError Calibration.calibrate(plan_path, output, id, 2)
            QCLNEGFRunner.h5open(joinpath(output, result["arrays_file"]), "r") do file
                @test read(QCLNEGFRunner.attributes(file)["toolchain_json"])==sprint(
                    QCLNEGFRunner._light_json,
                    result["toolchain"],
                )
                @test sort!(collect(keys(file)))==result["state_datasets"]
                metadata=QCLNEGFRunner.attributes(file)
                @test Tuple(
                    read(metadata[name]) for
                    name in ("energy_unit", "momentum_unit", "hartree_unit", "density_unit")
                )==("scaled (E-E_ref)/E0", "scaled k*L0", "scaled U/E0", "scaled n*L0^3")
                @test (
                    read(metadata["energy_scale_eV"]),
                    read(metadata["reference_energy_eV"]),
                )==(0.1, 0.0)
                @test read(metadata["length_scale_m"])≈1e-8
                @test size(read(file["GR_real"]))==(49, 5, 3, 3)
                @test size(read(file["history_raw"]))==(2, 8)
                @test all(name->all(isfinite, read(file[name])), result["state_datasets"])
                @test all(iszero, read(file["U"]))
                @test haskey(file, "scattering_LO_SR_real")
                @test haskey(file, "scattering_acoustic_SR_real") == (family=="lo-elastic")
                @test sum(abs2, read(file["SL_imag"]))>0
            end
            @test isfile(joinpath(output, "calibration-result.json"))
        end
    end
end
end
