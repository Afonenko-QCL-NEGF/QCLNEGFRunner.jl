module Suite_SchemaCopyProvenance
include("../support/common.jl")
include("../support/configuration.jl")
using SHA

const RUNNER_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

function fixture(parent; workspace=false)
    root = workspace ? joinpath(parent, "components", "QCLNEGFRunner.jl") : joinpath(parent, "runner")
    mkpath(root)
    cp(joinpath(RUNNER_ROOT, "schema"), joinpath(root, "schema"))
    if workspace
        write(joinpath(parent, ".gitmodules"), "# fixture workspace\n")
        canonical = joinpath(parent, "components", "qcl-negf-contracts", "src", "qcl_negf_contracts", "schemas")
        mkpath(canonical)
        for name in ("run.schema.json", "results-contract-set.json")
            cp(joinpath(root, "schema", name), joinpath(canonical, name))
        end
    end
    return root
end

function failure_message(callback)
    try
        callback()
        return "NO ERROR"
    catch error
        @test error isa ConfigurationError
        return sprint(showerror, error)
    end
end

@testset "Packaged schema provenance rejects drift before resolution" begin
    # Removal of the shared verifier must fail this assertion before fixture calls.
    available = isdefined(QCLNEGFRunner, :QCLSchemaProvenance)
    @test available
    if available
        verifier = QCLNEGFRunner.QCLSchemaProvenance
        verify = verifier.verify_schema_provenance
        @testset "standalone snapshots, exact bytes, and no success cache" begin
            mktempdir() do temporary
                root = fixture(temporary)
                snapshot = verify(root; mode=:standalone)
                @test snapshot.mode === :standalone
                @test snapshot.workspace_root === nothing
                @test length(snapshot.files) == 2
                @test snapshot.runner_root == realpath(root)
                @test snapshot.provenance_path == joinpath(realpath(root), "schema", "PROVENANCE.json")
                for (name, bytes) in snapshot.files
                    @test snapshot.hashes[name] == bytes2hex(sha256(read(joinpath(root, "schema", name))))
                    @test bytes == read(joinpath(root, "schema", name))
                end
                schema_path = joinpath(root, "schema", "run.schema.json")
                write(schema_path, "not a schema")
                parsed = verifier._strict_mapping_from_bytes(snapshot.files["run.schema.json"], schema_path)
                @test parsed["\$schema"] == "https://json-schema.org/draft/2020-12/schema"
                @test_throws verifier.SchemaProvenanceError verify(root; mode=:standalone)
            end
            mktempdir() do temporary
                root = fixture(temporary)
                open(joinpath(root, "schema", "run.schema.json"), "a") do io
                    write(io, "\n")
                end
                @test_throws verifier.SchemaProvenanceError verify(root; mode=:standalone)
                message = failure_message(() -> QCLNEGFRunner._load_configuration_schema(
                    joinpath(root, "schema", "run.schema.json"); schema_provenance_root=root))
                @test occursin("schema provenance", message)
                write(joinpath(root, "schema", "run.schema.json"),
                      "{\"\$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"unsupported_keyword\":true}")
                message = failure_message(() -> QCLNEGFRunner._load_configuration_schema(
                    joinpath(root, "schema", "run.schema.json"); schema_provenance_root=root))
                @test occursin("schema provenance", message)
            end
        end
        @testset "workspace selection and canonical drift" begin
            mktempdir() do temporary
                root = fixture(temporary; workspace=true)
                @test verify(root; mode=:workspace, workspace_root=temporary).mode === :workspace
                @test verify(root).mode === :workspace
                @test verify(root).workspace_root == realpath(temporary)
                canonical = joinpath(temporary, "components", "qcl-negf-contracts", "src", "qcl_negf_contracts", "schemas", "run.schema.json")
                open(canonical, "a") do io
                    write(io, "\n")
                end
                @test_throws verifier.SchemaProvenanceError verify(root)
                @test verify(root; mode=:standalone).mode === :standalone
                rm(canonical)
                @test_throws verifier.SchemaProvenanceError verify(root)
                @test_throws verifier.SchemaProvenanceError verify(root; mode=:workspace, workspace_root=temporary)
            end
        end
        @testset "every declared payload and strict metadata" begin
            mktempdir() do temporary
                root = fixture(temporary)
                rm(joinpath(root, "schema", "results-contract-set.json"))
                @test_throws verifier.SchemaProvenanceError verify(root; mode=:standalone)
            end
            # Removing metadata checks must accept at least one of these controls.
            for text in ("null", "[]", "source: x\nversion: y\nsha256: {}\n",
                         "source: x\nsource: y\nversion: y\nsha256: {}\n",
                         "source: x\nversion: y\nsha256: {run.schema.json: 7}\n",
                         "source: x\nversion: y\nsha256: {../escape: \"" * repeat("0", 64) * "\"}\n")
                mktempdir() do temporary
                    root = fixture(temporary)
                    write(joinpath(root, "schema", "PROVENANCE.json"), text)
                    @test_throws verifier.SchemaProvenanceError verify(root; mode=:standalone)
                end
            end
            mktempdir() do temporary
                root = fixture(temporary)
                path = joinpath(root, "schema", "PROVENANCE.json")
                original = read(path, String)
                # Valid hashes but duplicate source after merge: YAML strict_unique_keys alone accepts it.
                hashes = verify(root; mode=:standalone).hashes
                merge_metadata = "source: original\nversion: x\nsha256:\n  run.schema.json: \"$(hashes["run.schema.json"])\"\n  results-contract-set.json: \"$(hashes["results-contract-set.json"])\"\n<<: {source: merged}\nsource: duplicate\n"
                write(path, merge_metadata)
                @test_throws verifier.SchemaProvenanceError verify(root; mode=:standalone)
                write(path, replace(original, hashes["run.schema.json"] => repeat("0", 64)))
                @test_throws verifier.SchemaProvenanceError verify(root; mode=:standalone)
                # Preserve every required field/hash while exercising filename confinement.
                for unsafe in ("../escape", "sub/file", "sub\\file", "C:escape", ".", "..", "")
                    escaped = replace(unsafe, "\\" => "\\\\")
                    text = replace(original, "\"sha256\": {" =>
                        "\"sha256\": {\n    \"$escaped\": \"$(repeat("0", 64))\",")
                    write(path, text)
                    @test_throws verifier.SchemaProvenanceError verify(root; mode=:standalone)
                end
                write(path, original)
                extra = "extra.schema.json"
                write(joinpath(root, "schema", extra), "{}")
                digest = bytes2hex(sha256("{}"))
                text = replace(original, "\"sha256\": {" => "\"sha256\": {\n    \"$extra\": \"$digest\",")
                write(path, text)
                @test length(verify(root; mode=:standalone).files) == 3
                payload = joinpath(root, "schema", extra)
                outside = joinpath(temporary, "outside.schema.json")
                write(outside, "{}")
                rm(payload)
                symlink(outside, payload)
                @test_throws verifier.SchemaProvenanceError verify(root; mode=:standalone)
                rm(payload)
                write(payload, "[]")
                @test_throws verifier.SchemaProvenanceError verify(root; mode=:standalone)
            end
        end
        @testset "CLI streams and mode syntax" begin
            mktempdir() do temporary
                root = fixture(temporary)
                out, err = IOBuffer(), IOBuffer()
                @test verifier.main(["--mode", "standalone", "--runner-root", root]; output=out, errors=err) == 0
                @test String(take!(out)) == "schema provenance verified (mode=standalone, files=2)\n"
                @test isempty(take!(err))
                rm(joinpath(root, "schema", "run.schema.json"))
                @test verifier.main(["--mode", "standalone", "--runner-root", root]; output=out, errors=err) == 2
                @test isempty(take!(out))
                diagnostic = String(take!(err))
                @test startswith(diagnostic, "schema provenance error at ")
                @test count(==('\n'), diagnostic) == 1
                for args in (String[], ["--mode", "auto"], ["--mode"], ["--unknown"], ["x"],
                             ["--mode", "standalone", "--mode", "standalone"],
                             ["--mode", "standalone", "--workspace-root", temporary], ["--mode", "workspace"])
                    @test verifier.main(args; output=out, errors=err) == 2
                    @test isempty(take!(out))
                    @test startswith(String(take!(err)), "schema provenance usage error: ")
                end
            end
        end
        @testset "actual typed resolver precedence and custom schema compatibility" begin
            base = load_run_configuration(joinpath(CONFIGURATION_ROOT, "base.yaml"))
            mapping = QCLNEGFRunner._load_yaml_mapping(joinpath(CONFIGURATION_ROOT, "base.yaml"))
            mapping["physical"]["lattice_temperature"] = "200 eV"
            mktempdir() do temporary
                root = fixture(temporary)
                valid_message = failure_message(() -> QCLNEGFRunner._resolve_configuration(
                    mapping, base.provenance; schema_provenance_root=root))
                @test !occursin("schema provenance", valid_message)
                @test valid_message != "NO ERROR"
                open(joinpath(root, "schema", "run.schema.json"), "a") do io
                    write(io, "\n")
                end
                message = failure_message(() -> QCLNEGFRunner._resolve_configuration(
                    mapping, base.provenance; schema_provenance_root=root))
                @test occursin("schema provenance", message)
            end
            mktempdir() do temporary
                root = fixture(temporary)
                custom = joinpath(temporary, "custom.yaml")
                write(custom, "\"\$schema\": https://json-schema.org/draft/2020-12/schema\n<<: {type: object}\n")
                @test QCLNEGFRunner._load_configuration_schema(custom; schema_provenance_root=root)["type"] == "object"
            end
        end
    end
end
end
