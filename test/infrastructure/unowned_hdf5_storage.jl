module UnownedHDF5Storage
include("../support/common.jl")
using HDF5, SHA, YAML
include("../support/native_physics_fixture.jl")
const R=QCLNEGFRunner
function refresh_hashes(commit_path)
    manifest=YAML.load_file(commit_path;dicttype=Dict{String,Any})
    physical=joinpath(dirname(commit_path),"physics.h5")
    reference_path=joinpath(dirname(commit_path),"recovery.json")
    reference=YAML.load_file(reference_path;dicttype=Dict{String,Any})
    reference["payload"]["bytes"]=filesize(physical)
    reference["payload"]["sha256"]=bytes2hex(open(sha256,physical))
    open(io->R._light_json(io,reference),reference_path,"w")
    for artifact in manifest["artifacts"]
        path=joinpath(dirname(commit_path),artifact["path"])
        artifact["bytes"]=filesize(path)
        artifact["sha256"]=bytes2hex(open(sha256,path))
    end
    open(io->R._light_json(io,manifest),commit_path,"w")
    receipt_path=joinpath(dirname(commit_path),"receipt.json")
    receipt=YAML.load_file(receipt_path;dicttype=Dict{String,Any})
    receipt["commit_sha256"]=bytes2hex(open(sha256,commit_path))
    open(io->R._light_json(io,receipt),receipt_path,"w")
end
@testset "Hash-valid native bundles reject unowned HDF5 storage" begin
    solution=native_physics_fixture(;energy_nodes=17)
    mktempdir() do root
        original=R.commit_point_artifacts(root,solution;algorithms=AlgorithmOptions(),analysis=false,reserve_bytes=0)
        @test R.verify_recovery_receipt(original)["status"]=="verified"
        external=joinpath(root,"outside.h5")
        h5open(external,"w") do file
            file["values"]=[1.0,2.0]
        end
        for variant in (:external_raw,:virtual,:external_link,:soft_link)
            target=joinpath(root,String(variant))
            cp(dirname(original),target)
            physical=joinpath(target,"physics.h5")
            h5open(physical,"r+") do file
                if variant===:external_raw
                    dataset=HDF5.create_external_dataset(file,"unowned",joinpath(root,"outside.raw"),Float64,(2,))
                    close(dataset)
                elseif variant===:virtual
                    source_space=HDF5.dataspace((2,))
                    virtual_space=HDF5.dataspace((2,))
                    try
                        dataset=HDF5.create_dataset(file,"unowned",HDF5.datatype(Float64),virtual_space;
                            virtual=[HDF5.VirtualMapping(virtual_space,external,"values",source_space)])
                        close(dataset)
                    finally
                        close(source_space);close(virtual_space)
                    end
                elseif variant===:external_link
                    HDF5.create_external(file,"unowned",external,"values")
                else
                    HDF5.API.h5l_create_soft("/metadata",file.id,"unowned",HDF5.API.H5P_DEFAULT,HDF5.API.H5P_DEFAULT)
                end
            end
            commit_path=joinpath(target,"commit.json")
            refresh_hashes(commit_path)
            @test_throws ArgumentError R.verify_point_artifacts(commit_path)
        end
    end
end
end
