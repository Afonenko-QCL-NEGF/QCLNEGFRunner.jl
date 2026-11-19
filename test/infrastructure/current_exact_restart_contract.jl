module CurrentExactRestartContract
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

@testset "Exact restart requires the complete current numerical contract" begin
    # State-storage fixture, no SCBA/Poisson solve or convergence claim.
    solution = native_physics_fixture(energy_nodes=65)
    problem = solution.problem
    hilbert = AlgorithmOptions()
    direct = AlgorithmOptions(elastic_retarded=:direct_green)
    mktempdir() do directory
        modern = joinpath(directory,"explicit_hilbert.h5")
        save_checkpoint(modern,solution;include_kernels=false,algorithms=hilbert)
        restored = load_production_restart(modern,problem;
            algorithms=hilbert,solver_options=solution.options)
        @test restored !== nothing
        @test restored.Uᴴ == solution.Uᴴ
        @test restored.scba.green.Gᴿ == solution.scba.green.Gᴿ
        @test restored.scba.green.Gˡ == solution.scba.green.Gˡ
        @test restored.scba.embedding_plus.Σᴿ == solution.scba.embedding_plus.Σᴿ
        @test restored.scba.restart_contract["algorithms"]["elastic_retarded"] == "hilbert"
        @test_throws ArgumentError load_production_restart(modern,problem;algorithms=direct)

        for (label,change) in (
            ("unknown", contract->(contract["algorithms"]["future_switch"]="unqualified")),
            ("missing_required", contract->delete!(contract["algorithms"],"hilbert")),
            ("missing_elastic_retarded", contract->delete!(contract["algorithms"],"elastic_retarded")),
            ("missing_solver_option", contract->delete!(contract["solver"],"convergence")),
            ("missing_nested_option", contract->delete!(
                contract["solver"]["convergence"]["diagnostic_quality"], "enabled",
            )),
            ("wrong_algorithm_type", contract->(contract["algorithms"]["hilbert"]=42)),
            ("wrong_tolerance_type", contract->(contract["solver"]["tolerances"]["r_K"]="loose")),
            ("unknown_envelope_field", contract->(contract["future_field"]=true)),
        )
            rejected = joinpath(directory,label*".h5")
            cp(modern,rejected)
            edit_contract!(rejected,change)
            bytes = read(rejected)
            @test_throws ArgumentError load_production_restart(rejected,problem)
            @test_throws ArgumentError load_production_restart(rejected,problem;algorithms=hilbert)
            @test load_production_restart(rejected,problem;
                incompatible=:ignore) === nothing
            @test read(rejected) == bytes
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
        @test load_production_restart(modern_direct,problem).scba.green.Gᴿ == solution.scba.green.Gᴿ
        @test selected.scba.restart_contract["algorithms"]["elastic_retarded"] == "direct_green"
        @test_throws ArgumentError load_production_restart(modern_direct,problem;algorithms=hilbert)
    end
end
end
