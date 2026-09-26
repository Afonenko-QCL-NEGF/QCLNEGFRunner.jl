module NativeV3SchemaPrecision
include("../support/common.jl")
using HDF5
const BN=QCLNEGFRunner

@testset "Native v3 marker precision is mandatory even when unmeasured" begin
    mktempdir() do directory
        original=joinpath(directory, "typed.h5")
        h5open(original, "w") do file
            BN._write_physical_marker_columns!(
                file,
                BN._physical_marker_columns([nothing], [1]),
            )
        end
        h5open(original, "r") do file
            @test BN._read_physical_markers(file, 1)==[nothing]
        end
        for (name, type) in (
            ("fdt_raw", Float32),
            ("sequence", Int32),
            ("measured_iteration", Int32),
            ("available", Int64),
            ("equilibrium_applicable", Int64),
        )
            broken=joinpath(directory, name*".h5")
            cp(original, broken)
            h5open(broken, "r+") do file
                table=file["physical_markers"]
                values=type.(read(table[name]))
                HDF5.delete_object(table, name)
                table[name]=values
            end
            h5open(broken, "r") do file
                @test_throws ArgumentError BN._read_physical_markers(file, 1)
            end
        end
    end
end

@testset "Native artifact schema fixes media type before dispatch" begin
    mktempdir() do directory
        path=joinpath(directory, "commit.json")
        for (schema, role, media_type) in (
            ("qcl-negf-checkpoint-v4", "recovery", "application/octet-stream"),
            ("qcl-negf-checkpoint-v4", "recovery", "application/json"),
            (
                "qcl-negf-operator-diagnostics-v4",
                "science.comparison",
                "application/x-hdf5",
            ),
            ("qcl-negf-resolved-configuration-v3", "model", "application/x-hdf5"),
        )
            commit=Dict(
                "schema"=>BN.POINT_COMMIT_SCHEMA,
                "contract_set"=>BN._RESULT_CONTRACT_SET,
                "artifacts"=>[
                    Dict("schema"=>schema, "role"=>role, "media_type"=>media_type),
                ],
            )
            open(path, "w") do io
                BN._light_json(io, commit)
            end
            @test_throws r"declared artifact media type" BN.verify_point_artifacts(path)
        end
    end
end

end
