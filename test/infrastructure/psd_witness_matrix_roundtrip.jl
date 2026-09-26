module PSDWitnessMatrixRoundtrip
include("../support/common.jl")
using HDF5
include("../support/native_physics_fixture.jl")

function sample_row(index)
    block=ComplexF64[1.0 0.2+0.3im; 0.2-0.3im -0.1index]
    witness=QCLNEGFRunner.SCBAPhysicsWitness(
        :raw_unoccupied,
        2,
        1,
        -0.1index,
        1.0,
        1e-12,
        0.1index,
        0.1index,
        0.1index,
        0.0,
        Dict("Gp_raw_dimensionless"=>block, "A_dimensionless"=>Matrix{ComplexF64}(I, 2, 2)),
        ComplexF64[1/sqrt(2), im/sqrt(2)],
    )
    return SCBAIteration(
        index,
        1e-10,
        1e-10,
        1e-3,
        1e-3,
        1e-4,
        0.9999,
        0.1index,
        0.0,
        0.0,
        NaN,
        NaN,
        1.0,
        0.9999,
        1.0,
        1.0,
        NaN,
        witness,
        nothing,
    )
end

@testset "Every scalar PSD witness and selected complex blocks survive HDF5" begin
    fixture=native_physics_fixture(; energy_nodes = 33)
    rows=[sample_row(i) for i = 1:5]
    mktempdir() do directory
        path=joinpath(directory, "witness.h5")
        HDF5.h5open(path, "w") do file
            QCLNEGFRunner._write_psd_history!(file, rows; problem = fixture.problem)
        end
        HDF5.h5open(path, "r") do file
            restored=QCLNEGFRunner._read_psd_history(file, 5)
            @test read(file["psd_history/matrix_kind"])==fill("raw_unoccupied", 5)
            @test read(file["psd_history/minimum_eigenvalue"])==[-0.1i for i = 1:5]
            @test read(file["psd_history/energy_eV"])[1]≈fixture.problem.grids.ε[2]*fixture.problem.scales.E₀_eV+QCLNEGFRunner._electronvolts(
                fixture.problem.physical.E_ref,
            )
            @test restored[1].matrices==rows[1].witness.matrices
            @test restored[5].matrices==rows[5].witness.matrices
            @test restored[5].eigenvector==rows[5].witness.eigenvector
            @test isempty(restored[3].matrices)
            @test restored[3].minimum_eigenvalue==rows[3].witness.minimum_eigenvalue
            # Reverse-axis HDF5 storage preserves complex asymmetric off-diagonals.
            block=restored[5].matrices["Gp_raw_dimensionless"]
            @test read_attribute(file["psd_history/selected_blocks"], "schema") ==
                  "qcl-negf-psd-selected-packed-v2"
            @test block[1, 2]==0.2+0.3im
            @test block[2, 1]==0.2-0.3im
        end
        legacy=joinpath(directory, "legacy.h5")
        HDF5.h5open(legacy, "w") do file
            file["legacy"]=Int8[1]
        end
        HDF5.h5open(legacy, "r") do file
            @test_throws ArgumentError QCLNEGFRunner._read_psd_history(file, 3)
        end
    end
end

@testset "Closed history segments consolidate measured witnesses and payloads" begin
    fixture=native_physics_fixture(; energy_nodes = 33)
    mktempdir() do directory
        identity=Dict{String,Any}("point_id"=>"p", "execution_id"=>"e", "attempt"=>1)
        recorder=QCLNEGFRunner.ScientificHistoryRecorder(
            directory,
            identity,
            Ref(0),
            Ref(0);
            clock_ns = ()->UInt64(0),
        )
        for i = 1:5
            QCLNEGFRunner.record_scientific_history!(
                recorder,
                :scba,
                1,
                sample_row(i),
                fixture.problem,
            )
            i==3 && QCLNEGFRunner.flush_scientific_history!(recorder)
        end
        QCLNEGFRunner.flush_scientific_history!(recorder)
        paths=sort(
            filter(
                p->endswith(p, ".h5"),
                readdir(joinpath(directory, "history"); join = true),
            ),
        )
        consolidated=QCLNEGFRunner.consolidate_scientific_history(
            joinpath(directory, "joined.h5"),
            paths,
        )
        HDF5.h5open(consolidated, "r") do file
            @test read(file["scba/sequence"])==collect(1:5)
            @test read(file["psd_history/sequence"])==collect(1:5)
            restored=QCLNEGFRunner._read_psd_history(file, 5)
            @test restored[3].matrices==sample_row(3).witness.matrices
            @test restored[5].matrices==sample_row(5).witness.matrices
        end
    end
end

@testset "Final native physics separates local diagnostics from physical certification" begin
    fixture=native_physics_fixture(; energy_nodes = 33)
    mktempdir() do directory
        path=joinpath(directory, "analysis.h5")
        QCLNEGFRunner.save_analysis_physics(path, fixture)
        HDF5.h5open(path, "r") do file
            summary=QCLNEGFRunner.YAML.load(
                String(read(file["metadata/physical_certification_json"])),
            )
            @test summary["algebra"]["status"]=="not_evaluated"
            @test summary["stationary"]["status"]=="not_evaluated"
            @test summary["discretization"]["status"]=="not_certified"
            @test !summary["quantitative_physics_certified"]
            integral=QCLNEGFRunner._read_complex(
                file["diagnostics/matrix_audit"],
                "spectral_integral",
            )
            expected=sum(
                fixture.problem.grids.wᴱ[e] .*
                Matrix(view(fixture.scba.green.A, e, 1, :, :)) for e = 1:33
            )/(2π)
            @test integral[1, :, :]≈expected
            @test QCLNEGFRunner._read_array(
                file["diagnostics/matrix_audit"],
                "spectral_integral_eigenvalues",
            )[
                1,
                :,
            ]≈eigvals(Hermitian(expected))
            @test length(read(file["diagnostics/matrix_audit/negative_block_count"]))==6
            data=QCLNEGFRunner.YAML.load(String(read(file["diagnostics/positivity_json"])))
            @test Set(row["matrix_kind"] for row in data["matrices"])==Set([
                "spectral",
                "occupied",
                "unoccupied",
                "broadening",
                "raw_occupied",
                "raw_unoccupied",
            ])
        end
    end
end
end
