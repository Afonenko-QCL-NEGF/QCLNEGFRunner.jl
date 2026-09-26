module PhysicalMarkersAndPackedHistory
include("../support/common.jl")
using HDF5
include("../support/native_physics_fixture.jl")
const BN=QCLNEGFRunner

marker(i) = BN.SCBAPhysicalMarkers(
    i,
    2.0,
    3.0,
    1.0,
    0.01,
    0.02,
    0.03,
    true,
    :available,
    -0.02,
    0.1,
    0.09,
    0.0,
    0.00015625,
    0.1,
    1.0,
    10.0,
    0.25,
    16,
    :available,
    :spectral_weight_quantiles,
    10,
    512,
    1e-10,
    :available,
    939.52,
    1228.8,
    0.001,
    0.002,
    0.003,
    0.004,
    -0.03,
    1.0,
    0.2,
    0.19,
    [BN.SCBAChannelMarker(:LO, :lesser, 0.1, 2.0, 0.05)],
    [BN.SCBACollisionMarker(:LO, :fresh, 0.01, 2.0, 0.0, 0.02, 3.0, 0.0)],
)
function row(i; measured = true)
    plain=SCBAIteration(
        i,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        NaN,
        NaN,
        NaN,
        NaN,
        nothing,
        nothing,
    )
    return SCBAIteration(
        (getfield(plain, name) for name in fieldnames(SCBAIteration)[1:18])...,
        measured ? marker(i) : nothing,
    )
end

@testset "Strict native v4 markers survive analysis, recovery and complete history" begin
    fixture=native_physics_fixture(; energy_nodes = 33)
    append!(fixture.scba.history, [row(1), row(2; measured = false), row(3)])
    mktempdir() do directory
        checkpoint=joinpath(directory, "recovery.h5")
        save_checkpoint(
            checkpoint,
            fixture;
            include_kernels = false,
            algorithms = AlgorithmOptions(),
        )
        loaded=load_production_restart(checkpoint, fixture.problem)
        @test isequal(first(loaded.scba.history).physical_markers, marker(1))
        @test loaded.scba.history[2].physical_markers===nothing
        @test isequal(last(loaded.scba.history).physical_markers, marker(3))
        analysis=joinpath(directory, "analysis.h5")
        BN.save_analysis_physics(analysis, fixture)
        h5open(analysis, "r") do file
            table=file["diagnostics/physical_markers"]
            thresholds = file["diagnostics/scba_threshold_crossings"]
            @test read_attribute(thresholds, "schema") ==
                  "qcl-negf-scba-threshold-crossings-v1"
            @test length(read(thresholds["threshold"])) == 20
            @test all(read(thresholds["first_iteration"]) .== 1)
            # The tutorial preset requires one pass. Persistence must forward
            # this setting instead of using the summary helper's default three.
            @test all(read(thresholds["required_consecutive"]) .== 1)
            @test all(read(thresholds["sustained_end_iteration"]) .== 1)
            @test occursin("acceptance", read_attribute(thresholds, "acceptance_role"))
            @test read(table["available"])==Int8[1, 0, 1]
            @test read(table["measured_iteration"])==[1, 0, 3]
            @test isnan(read(table["fdt_raw"])[2])
            @test read_attribute(table["delta_energy_eV"], "units")=="eV"
            @test occursin(
                "equilibrium_applicable",
                read_attribute(table["fdt_raw"], "applicability"),
            )
        end
        for corruption in (
            :old_version,
            :old_schema,
            :missing_markers,
            :missing_psd,
            :legacy_selected,
            :old_columns,
            :missing_channels,
            :orphan_collision,
            :old_markers,
            :missing_warnings,
            :missing_adaptation,
        )
            broken=joinpath(directory, string(corruption)*".h5")
            cp(checkpoint, broken)
            h5open(broken, "r+") do file
                if corruption===:old_version
                    HDF5.delete_attribute(file["metadata"], "schema_version")
                    attributes(file["metadata"])["schema_version"]="2.0"
                elseif corruption===:old_schema
                    HDF5.delete_attribute(file["metadata"], "schema")
                    attributes(file["metadata"])["schema"]="qcl-negf-checkpoint-v2"
                elseif corruption===:missing_markers
                    HDF5.delete_object(file["convergence"], "physical_markers")
                elseif corruption===:missing_channels
                    HDF5.delete_object(file["convergence/physical_markers"], "channels")
                elseif corruption===:orphan_collision
                    file["convergence/physical_markers/collisions/sequence"][1] = 2
                elseif corruption===:old_markers
                    HDF5.delete_attribute(file["convergence/physical_markers"], "schema")
                    attributes(
                        file["convergence/physical_markers"],
                    )["schema"] = "qcl-negf-physical-markers-v1"
                elseif corruption===:missing_psd
                    HDF5.delete_object(file["convergence"], "psd_history")
                elseif corruption===:legacy_selected
                    HDF5.delete_attribute(
                        file["convergence/psd_history/selected_blocks"],
                        "schema",
                    )
                elseif corruption in (:missing_warnings, :missing_adaptation)
                    name=corruption===:missing_warnings ? "warnings_json" :
                         "adaptation_checkpoint_json"
                    HDF5.delete_object(file["metadata"], name)
                else
                    HDF5.delete_object(file["convergence"], "scba")
                    BN._write_array(file["convergence"], "scba", zeros(3, 13))
                end
            end
            @test_throws ArgumentError load_production_restart(broken, fixture.problem)
        end
        recorder=BN.ScientificHistoryRecorder(
            directory,
            Dict{String,Any}("point_id"=>"p"),
            Ref(0),
            Ref(0),
        )
        BN.record_scientific_history!(
            recorder,
            :scba,
            1,
            row(1; measured = false),
            fixture.problem,
        )
        old=BN.flush_scientific_history!(recorder)
        BN.record_scientific_history!(recorder, :scba, 1, row(2), fixture.problem)
        new=BN.flush_scientific_history!(recorder)
        joined=BN.consolidate_scientific_history(
            joinpath(directory, "history.h5"),
            [old, new],
        )
        h5open(joined, "r") do file
            @test read(file["physical_markers/available"])==Int8[0, 1]
            @test read(file["physical_markers/sequence"])==[1, 2]
            @test BN._read_physical_markers(file, 2)[1]===nothing
            @test isequal(BN._read_physical_markers(file, 2)[2], marker(2))
        end
        h5open(old, "r+") do file
            HDF5.delete_object(file, "physical_markers")
        end
        @test_throws ArgumentError BN.consolidate_scientific_history(
            joinpath(directory, "rejected.h5"),
            [old, new],
        )
    end
end

@testset "Packed witnesses retain every native bit and reject legacy groups" begin
    mktempdir() do directory
        old=joinpath(directory, "old.h5")
        bits=UInt64[
            0x8000000000000000,
            0x7ff8000000000123,
            0x3ff0000000000000,
            0x4000000000000000,
            0x4008000000000000,
            0x4010000000000000,
        ]
        values=reshape(copy(reinterpret(Float64, bits)), 2, 3)
        h5open(old, "w") do file
            selected=create_group(file, "selected_blocks")
            record=create_group(selected, "sequence-7")
            attributes(record)["sequence"]=7
            attributes(record)["iteration"]=3
            attributes(record)["matrix_kind"]="raw_occupied"
            attributes(record)["E0_eV"]=0.1
            group=create_group(record, "evidence")
            attributes(group)["definition"]="complex component test"
            dataset=BN._write_array(group, "native", values; axis_order = "a,b")
            attributes(dataset)["units"]="1"
        end
        h5open(old, "r") do file
            @test_throws ArgumentError BN._read_packed_witness_records(
                file["selected_blocks"],
            )
        end
        records=[(
            sequence = Int64(7),
            attributes = Dict{String,Any}(
                "sequence"=>7,
                "iteration"=>3,
                "matrix_kind"=>"raw_occupied",
                "E0_eV"=>0.1,
            ),
            groups = Dict{String,Any}(
                "evidence"=>Dict("definition"=>"complex component test"),
            ),
            payloads = [(
                metadata = Dict{String,Any}(
                    "path"=>"evidence/native",
                    "shape"=>[2, 3],
                    "attributes"=>Dict("units"=>"1", "logical_axis_order"=>"a,b"),
                ),
                values = vec(BN._storage_order(values)),
            )],
        )]
        packed=joinpath(directory, "packed.h5")
        h5open(packed, "w") do file
            BN._write_packed_witness_records!(file, records)
        end
        h5open(packed, "r") do file
            restored=only(BN._read_packed_witness_records(file["selected_blocks"]))
            expected=only(records)
            @test restored.attributes==expected.attributes
            @test restored.groups==expected.groups
            @test only(restored.payloads).metadata==only(expected.payloads).metadata
            @test only(restored.payloads).metadata["shape"]==[2, 3]
            @test reinterpret(UInt64, only(restored.payloads).values)==reinterpret(
                UInt64,
                only(expected.payloads).values,
            )
        end
        h5open(packed, "r+") do file
            offsets=read(file["selected_blocks/payload_offsets"])
            offsets[end]+=1
            write(file["selected_blocks/payload_offsets"], offsets)
        end
        h5open(packed, "r") do file
            @test_throws ArgumentError BN._read_packed_witness_records(
                file["selected_blocks"],
            )
        end
    end
end

@testset "Lossless numeric chunks preserve precision and empty-array compatibility" begin
    mktempdir() do directory
        path=joinpath(directory, "arrays.h5")
        raw=repeat(
            UInt64[0x8000000000000000, 0x7ff8000000000123, 0x3ff0000000000000, 0],
            4096,
        )
        values=reshape(copy(reinterpret(Float64, raw)), 128, 128)
        h5open(path, "w") do file
            BN._write_array(file, "values", values)
            BN._write_array(file, "empty", zeros(0, 3))
        end
        @test filesize(path)<sizeof(values)÷2
        h5open(path, "r") do file
            @test reinterpret(UInt64, vec(BN._read_array(file, "values")))==raw
            @test size(BN._read_array(file, "empty"))==(0, 3)
        end
    end
end
@testset "Packed UTF-8 metadata uses lossless filtered fixed-width strings" begin
    mktempdir() do directory
        path=joinpath(directory, "metadata.h5")
        rows=[repeat("модель/Γ/строка-$(i)", 20) for i = 1:100]
        h5open(path, "w") do file
            BN._write_packed_column(file, "metadata_json", rows)
        end
        @test filesize(path)<sum(ncodeunits, rows)÷2
        h5open(path, "r") do file
            @test read(file["metadata_json"])==rows
        end
    end
end

@testset "Commit declarations bind native schemas and artifact roles" begin
    fixture=native_physics_fixture(; energy_nodes = 33)
    identity=Dict{String,Any}(
        "point_id"=>"p",
        "execution_id"=>"e",
        "attempt"=>1,
        "plan_fingerprint"=>"fixture",
    )
    mktempdir() do directory
        checkpoint=BN.commit_point_artifacts(
            joinpath(directory, "physics"),
            fixture;
            identity,
            algorithms = AlgorithmOptions(),
        )
        commit=BN.verify_point_artifacts(checkpoint)
        first(commit["artifacts"])["role"]="science.history"
        open(checkpoint, "w") do io
            BN._light_json(io, commit)
        end
        @test_throws ArgumentError BN.verify_point_artifacts(checkpoint)
        operator=BN.commit_operator_artifacts(
            joinpath(directory, "operator"),
            Dict("passed"=>true);
            identity,
            operation = "fixture",
            accepted = true,
        )
        commit=BN.verify_point_artifacts(operator)
        only(commit["artifacts"])["schema"]="qcl-negf-operator-diagnostics-v2"
        open(operator, "w") do io
            BN._light_json(io, commit)
        end
        @test_throws ArgumentError BN.verify_point_artifacts(operator)
    end
end

end
