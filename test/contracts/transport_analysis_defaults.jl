module TransportAnalysisDefaults
using Test
using SHA
const source_root=normpath(joinpath(@__DIR__, "..", "..", "src"))
const source_path=joinpath(source_root, "infrastructure", "scientific", "postprocessing.jl")

# Include actual definitions. Only the expert numerical recomputation body needs
# Unitful macros; its missing-photon entry check is still exercised below.
let parsed=Meta.parseall(read(source_path, String)), omitted=0
    for expression in parsed.args
        if expression isa Expr && expression.head===:function &&
           expression.args[1] isa Expr && expression.args[1].head===:call &&
           first(expression.args[1].args)===:_recompute_optics
            omitted+=1
            continue
        end
        Core.eval(@__MODULE__, expression)
    end
    omitted==1 || error("fixture must omit only the complete _recompute_optics definition")
end
include(joinpath(source_root, "cli.jl"))
println("postprocessing source SHA256: ", bytes2hex(sha256(read(source_path))))
println("CLI source SHA256: ", bytes2hex(sha256(read(joinpath(source_root,"cli.jl")))))

# Independent saved-data I/O boundaries. These bytes are not a native HDF5 archive.
const saved_series=Ref{Dict{String,Any}}()
const written=Dict{String,Any}()
const dataset_queries=String[]
const datasets=Set{String}()
struct FakeAnalysisFile end
function Base.haskey(::FakeAnalysisFile, dataset)
    push!(dataset_queries, dataset)
    return dataset in datasets
end
_read_series(directory)=(deepcopy(saved_series[]), abspath(directory))
_result_path(root, relative)=joinpath(root, relative)
verify_point_artifacts(path)=Dict("artifacts"=>[Dict("role"=>"physics.analysis", "path"=>"analysis.bin")])
h5open(body::Function, path, mode)=body(FakeAnalysisFile())
canonical_bytes(value)=collect(codeunits(repr(value)))
function _scientific_json(path, value)
    written[path]=deepcopy(value)
    open(path,"w") do io
        print(io,repr(value))
    end
end
_observability_atomic_text(body::Function, path)=open(body, path, "w")

@testset "Default API and CLI request saved transport without optics" begin
    mktempdir() do root
        write(joinpath(root,"analysis.bin"),"synthetic committed transport bytes")
        point=Dict{String,Any}(
            "id"=>"point-1", "execution_id"=>"execution-1", "status"=>"completed",
            "quality"=>"unconverged", "converged"=>false,
            "coordinates"=>Dict("branch"=>"T1/main", "order"=>1,
                "temperature_K"=>70.0, "voltage_per_period_V"=>0.0),
            "observables"=>Dict{String,Any}("current_density_A_per_m2"=>12.0),
            "data"=>Dict{String,Any}("result_commit"=>"commit.json", "optical"=>nothing),
        )
        saved_series[]=Dict{String,Any}(
            "plan_fingerprint"=>"saved-plan-identity", "name"=>"Saved transport candidate",
            "points"=>[point],
        )
        original=deepcopy(saved_series[])
        union!(datasets, ["axes/z_nm", "axes/energy_eV", "observables/spatial_energy_density",
            "basis/sheet_density_matrix_per_m2", "observables/density_per_m3",
            "observables/potential_structure_eV", "observables/potential_external_eV",
            "observables/potential_hartree_eV", "observables/potential_total_eV"])
        expected=["density_map", "energy_density_map", "iv", "populations", "potential_map"]
        derived=postprocess_series(root)
        @test sort!(collect(keys(derived["operations"])))==expected
        @test all(item["status"]=="completed" for item in values(derived["operations"]))
        @test !any(startswith(query,"optical") for query in dataset_queries)
        @test derived["source_plan_fingerprint"]=="saved-plan-identity"
        @test derived["operations"]["iv"]["data"][1]["current_density_A_per_m2"]==12.0
        @test derived["operations"]["iv"]["data"][1]["quality"]=="unconverged"
        @test derived["operations"]["iv"]["data"][1]["converged"]===false
        @test only(only(derived["figures"])["series"])["accepted"]==[false]
        @test saved_series[]==original

        empty!(dataset_queries)
        cli_output=joinpath(root,"cli-analysis")
        @test main(["analyze", root, cli_output])==0
        cli_derived=written[joinpath(cli_output,"derived_result.json")]
        @test sort!(collect(keys(cli_derived["operations"])))==expected
        @test all(item["status"]=="completed" for item in values(cli_derived["operations"]))
        @test !any(startswith(query,"optical") for query in dataset_queries)
        @test isfile(joinpath(cli_output,"report.md"))
        @test main(["analyze",root])==0
        @test sort!(collect(keys(written[joinpath(root,"analysis","derived_result.json")]["operations"])))==expected

        # Explicit expert operations retain their old missing-data diagnostics.
        expert=postprocess_series(root; operations=["gain_voltage","optical_map","optical_recompute"],
            output_directory=joinpath(root,"expert-missing"))
        @test sort!(collect(keys(expert["operations"])))==["gain_voltage","optical_map","optical_recompute"]
        @test all(item["status"]=="insufficient_data" for item in values(expert["operations"]))
        @test occursin("gain_peak_per_cm",expert["operations"]["gain_voltage"]["message"])
        @test occursin("saved annotated optical spectrum",expert["operations"]["optical_map"]["message"])
        @test occursin("explicit Unitful photon_energies vector",expert["operations"]["optical_recompute"]["message"])

        # A stale optical pointer must never be read by a daily default call.
        point["data"]["optical"]="missing-optical.h5"
        empty!(dataset_queries)
        daily=postprocess_series(root;output_directory=joinpath(root,"daily-stale-optics"))
        @test sort!(collect(keys(daily["operations"])))==expected
        @test all(item["status"]=="completed" for item in values(daily["operations"]))
        @test !any(startswith(query,"optical") for query in dataset_queries)
        empty!(dataset_queries)
        missing=postprocess_series(root;operations=["optical_map"],output_directory=joinpath(root,"missing-optics"))
        @test missing["operations"]["optical_map"]["status"]=="insufficient_data"
        @test occursin("saved native optical response is absent",missing["operations"]["optical_map"]["message"])
        @test "optical" in dataset_queries

        # Explicit optical metadata projections remain available; no response recomputed.
        point["observables"]["gain_peak_per_cm"]=1.25
        push!(datasets,"optical")
        ready=postprocess_series(root;operations=["gain_voltage","optical_map"],output_directory=joinpath(root,"expert-ready"))
        @test ready["operations"]["gain_voltage"]["status"]=="completed"
        @test ready["operations"]["gain_voltage"]["data"][1]["gain_peak_per_cm"]==1.25
        @test ready["operations"]["optical_map"]["status"]=="completed"
        @test ready["operations"]["optical_map"]["data"][1]["quality"]=="unconverged"
        @test point["converged"]===false
    end
end
end
