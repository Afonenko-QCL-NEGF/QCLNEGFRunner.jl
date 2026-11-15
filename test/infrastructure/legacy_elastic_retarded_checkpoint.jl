module LegacyElasticRetardedCheckpoint
include("../support/common.jl")
using HDF5
include("../support/native_physics_fixture.jl")

function edit_contract!(path, change)
    h5open(path,"r+") do file
        group = file["metadata"]
        contract = QCLNEGFRunner.YAML.load(String(read(group["restart_contract_yaml"]));
            dicttype=Dict{String,Any})
        change(contract)
        HDF5.delete_object(group,"restart_contract_yaml")
        group["restart_contract_yaml"] = QCLNEGFRunner.YAML.write(contract)
    end
end

@testset "Legacy Hilbert checkpoint restores through the actual loader" begin
    # State-storage fixture, no SCBA/Poisson solve or convergence claim.
    solution = native_physics_fixture(energy_nodes=65)
    problem = solution.problem
    hilbert = AlgorithmOptions()
    direct = AlgorithmOptions(elastic_retarded=:direct_green)
    mktempdir() do directory
        modern = joinpath(directory,"explicit_hilbert.h5")
        save_checkpoint(modern,solution;include_kernels=false,algorithms=hilbert)
        legacy = joinpath(directory,"legacy_v1.h5")
        cp(modern,legacy)
        edit_contract!(legacy, contract->delete!(contract["algorithms"],"elastic_retarded"))
        original_bytes = read(legacy)

        # The HDF reader must reach and restore actual state arrays; testing only
        # Core's dictionary helper would miss the former early-equality gate.
        restored = load_production_restart(legacy,problem;
            algorithms=hilbert,solver_options=solution.options)
        @test restored !== nothing
        @test restored.Uᴴ == solution.Uᴴ
        @test restored.scba.green.Gᴿ == solution.scba.green.Gᴿ
        @test restored.scba.green.Gˡ == solution.scba.green.Gˡ
        @test restored.scba.embedding_plus.Σᴿ == solution.scba.embedding_plus.Σᴿ
        @test !haskey(restored.scba.restart_contract["algorithms"],"elastic_retarded")
        @test read(legacy) == original_bytes
        @test QCLNEGFRunner._check_exact_restart_contract(
            restored.scba.restart_contract,solution.options,hilbert) === nothing

        @test_throws ArgumentError load_production_restart(legacy,problem;algorithms=direct)
        @test load_production_restart(legacy,problem;algorithms=direct,incompatible=:ignore) === nothing
        @test read(legacy) == original_bytes

        for (label,change) in (
            ("unknown", contract->(contract["algorithms"]["future_switch"]="unqualified")),
            ("missing_required", contract->delete!(contract["algorithms"],"hilbert")),
            ("known_mismatch", contract->(contract["algorithms"]["embedding_periods"]=9)),
        )
            rejected = joinpath(directory,label*".h5")
            cp(legacy,rejected)
            edit_contract!(rejected,change)
            @test_throws ArgumentError load_production_restart(rejected,problem;algorithms=hilbert)
            @test load_production_restart(rejected,problem;
                algorithms=hilbert,incompatible=:ignore) === nothing
        end

        modern_direct = joinpath(directory,"explicit_direct_green.h5")
        save_checkpoint(modern_direct,solution;include_kernels=false,algorithms=direct)
        h5open(modern_direct,"r") do file
            contract = QCLNEGFRunner.YAML.load(String(read(file["metadata/restart_contract_yaml"])))
            @test contract["algorithms"]["elastic_retarded"] == "direct_green"
        end
        selected = load_production_restart(modern_direct,problem;
            algorithms=direct,solver_options=solution.options)
        @test selected.scba.green.Gᴿ == solution.scba.green.Gᴿ
        @test selected.scba.restart_contract["algorithms"]["elastic_retarded"] == "direct_green"
        @test_throws ArgumentError load_production_restart(modern_direct,problem;algorithms=hilbert)
    end
end
end
