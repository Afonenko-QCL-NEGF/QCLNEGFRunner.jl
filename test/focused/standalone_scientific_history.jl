# Real native-HDF5 regression for first standalone history publication/return.
# Run only in the Root-admitted candidate project with existing Julia/depot.
using QCLNEGFRunner, Test, SHA
const R = QCLNEGFRunner
const H5 = R.HDF5
include(joinpath(@__DIR__, "..", "support", "native_physics_fixture.jl"))

# Existing tiny typed fixture: problem/seed construction only; no SCBA/Poisson.
const history_fixture = native_physics_fixture(; energy_nodes = 33)
history_row(i) = SCBAIteration(
    i, 1e-3, 1e-4, 1e-5, 1e-4, 1e-4, 1.0, 0.0, 0.0, 0.0,
    NaN, NaN, 3.0, 1.0, 1.0, 1.0, NaN, nothing, nothing,
)

# Root supplies an existing empty owned absolute root. Preserve every artifact
# on success and failure; the standalone fallback is persistent as well.
function history_case(f::Function, name::AbstractString)
    base = get(ENV, "QCL_HISTORY_TEST_ROOT", "")
    if isempty(base)
        root = mktempdir(; prefix = "qcl-history-" * name * "-", cleanup = false)
    else
        @assert isabspath(base) && isdir(base)
        root = joinpath(base, name)
        mkdir(root)
    end
    return f(root)
end

@testset "standalone first seal returns published path and consolidates scalar rows" begin
    history_case("explicit-seal") do root
        point = joinpath(root, "point")
        attempt = joinpath(point, "attempt-1")
        identity = Dict{String,Any}("point_id" => "p", "execution_id" => "e", "attempt" => 1)
        tick = Ref(UInt64(0))
        scba_count, outer_count = Ref(0), Ref(0)
        recorder = R.ScientificHistoryRecorder(attempt, identity, scba_count, outer_count;
            clock_ns = () -> tick[], resource_policy = :standalone)
        pointer = joinpath(attempt, "history", "index.json")
        first_path = joinpath(attempt, "history", "segment-000001.h5")
        second_path = joinpath(attempt, "history", "segment-000002.h5")
        @test R.record_scientific_history!(recorder, :scba, 1, history_row(1), history_fixture.problem) === nothing
        @test scba_count[] == 1
        @test !isfile(pointer)
        # Files already exist when the historical return-scope defect throws.
        @test R.flush_scientific_history!(recorder) == first_path
        first_bytes = read(first_path)
        index = R.YAML.load_file(pointer)
        @test index["schema"] == "qcl-negf-scientific-history-index-v2"
        @test index["identity"] == identity
        @test index["generation"] == 1
        @test (index["scba_rows"], index["outer_rows"]) == (1, 0)
        segment = only(index["segments"])
        @test segment["path"] == "segment-000001.h5"
        @test segment["sha256"] == bytes2hex(sha256(first_bytes))
        @test segment["bytes"] == length(first_bytes)
        H5.h5open(first_path, "r") do file
            @test H5.read_attribute(file["metadata"], "schema") == "qcl-negf-scientific-history-v4"
            @test H5.read_attribute(file["metadata"], "scba_rows") == 1
            @test H5.read_attribute(file["metadata"], "outer_rows") == 0
            @test read(file["scba/sequence"]) == [1]
            @test read(file["scba/outer_iteration"]) == [1]
            @test read(file["scba/iteration"]) == [1]
            @test read(file["scba/J"]) == [3.0]
            @test read(file["scba/r_D"]) == [1e-3]
            @test isnan(only(read(file["scba/r_Jchange"])))
        end
        @test isempty(recorder.scba) && isempty(recorder.outer)
        @test (recorder.published_scba, recorder.published_outer) == (1, 0)
        before_empty = readdir(recorder.directory)
        index_bytes = read(pointer)
        @test R.flush_scientific_history!(recorder) === nothing
        @test readdir(recorder.directory) == before_empty
        @test read(pointer) == index_bytes
        @test R.record_scientific_history!(recorder, :scba, 1, history_row(2), history_fixture.problem) === nothing
        @test R.flush_scientific_history_finalizer!(recorder) == second_path
        @test read(first_path) == first_bytes
        @test R.scientific_history_counts(point) == (2, 0)
        @test (scba_count[], outer_count[]) == (2, 0)
        index2 = R.YAML.load_file(pointer)
        @test index2["generation"] == 2
        @test (index2["scba_rows"], index2["outer_rows"]) == (2, 0)
        @test [s["path"] for s in index2["segments"]] == ["segment-000001.h5", "segment-000002.h5"]
        for (path, entry) in zip([first_path, second_path], index2["segments"])
            @test entry["sha256"] == bytes2hex(sha256(read(path)))
            @test entry["bytes"] == filesize(path)
        end
        sources = R.scientific_history_sources(point)
        @test sources == [first_path, second_path]
        destination = joinpath(point, "export.h5")
        @test R.consolidate_scientific_history(destination, sources) == destination
        H5.h5open(destination, "r") do file
            @test read(file["scba/sequence"]) == [1, 2]
            @test read(file["scba/iteration"]) == [1, 2]
            @test read(file["scba/outer_iteration"]) == [1, 1]
            @test read(file["scba/J"]) == [3.0, 3.0]
            @test read(file["scba/r_D"]) == [1e-3, 1e-3]
            @test all(isnan, read(file["scba/r_Jchange"]))
            @test H5.read_attribute(file["metadata"], "scba_rows") == 2
            @test H5.read_attribute(file["metadata"], "outer_rows") == 0
            provenance = R.YAML.load(String(read(file["metadata/source_segments_json"])))
            @test length(provenance) == 2
            @test all(p -> p["identity"] == identity, provenance)
            @test [p["sha256"] for p in provenance] == [s["sha256"] for s in index2["segments"]]
        end
    end
end

@testset "first append crossing cadence completes after real HDF5 publication" begin
    history_case("first-cadence-append") do root
        tick = Ref(UInt64(0))
        recorder = R.ScientificHistoryRecorder(root, Dict{String,Any}("attempt" => 1), Ref(0), Ref(0);
            clock_ns = () -> tick[], resource_policy = :standalone)
        tick[] = UInt64(31_000_000_000)
        @test R.record_scientific_history!(recorder, :scba, 1, history_row(1), history_fixture.problem) === nothing
        @test recorder.scba_count[] == 1
        @test recorder.published_scba == 1
        @test isempty(recorder.scba) && isempty(recorder.outer)
        index = R.YAML.load_file(joinpath(recorder.directory, "index.json"))
        @test index["generation"] == 1
        @test index["scba_rows"] == 1
        H5.h5open(joinpath(recorder.directory, only(index["segments"])["path"]), "r") do file
            @test read(file["scba/sequence"]) == [1]
            @test read(file["scba/iteration"]) == [1]
        end
    end
end

@testset "collision preserves destination and index and removes standalone temporary" begin
    history_case("collision") do root
        recorder = R.ScientificHistoryRecorder(root, Dict{String,Any}("attempt" => 1), Ref(0), Ref(0);
            clock_ns = () -> UInt64(0), resource_policy = :standalone)
        target = joinpath(recorder.directory, "segment-000001.h5")
        pointer = joinpath(recorder.directory, "index.json")
        write(target, "original segment sentinel\n")
        write(pointer, "original index sentinel\n")
        names_before = readdir(recorder.directory)
        @test R.record_scientific_history!(recorder, :scba, 1, history_row(1), history_fixture.problem) === nothing
        caught = try
            R.flush_scientific_history!(recorder)
            nothing
        catch failure
            failure
        end
        @test caught isa ArgumentError
        @test read(target, String) == "original segment sentinel\n"
        @test read(pointer, String) == "original index sentinel\n"
        @test readdir(recorder.directory) == names_before
        @test recorder.segment == 1
        @test recorder.published_scba == 0
        @test length(recorder.scba) == 1
    end
end
