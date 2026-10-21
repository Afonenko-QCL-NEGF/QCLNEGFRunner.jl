# Finite real-Pkg regression packet; run only inside an externally bounded,
# network-isolated allocation. This is not the outer Deno empty-depot oracle.
# A production change restoring automatic Pkg.build must fail GREEN via marker.
# Future top-level harness argv must also include --startup-file=no
# --history-file=no --threads=1 --compiled-modules=existing --pkgimages=existing
# before this script and its options; its direct `$julia` commands need explicit flags.
using SHA
using TOML
using Tar

const BASELINE = "4f60f1680c6903f79f6d07bf4d14ced74d8c4f3f"
const PACKAGE = "QCLDepotPoison"
const PACKAGE_UUID = "562a00b8-cb28-4fab-8556-8e030046f526"
const PAYLOAD = "frozen lazy artifact bytes\n"
# Vetted gzip transport of the fixed 1024-byte USTAR fixture; raw helper below
# independently checks the generated payload tree/mode. Native Pkg must unpack.
const LAZY_GZIP = hex2bytes("1f8b08000000000002ff2b48acccc94f4c61a0253030303033315100d140804e0381b1b18201022818181a981a9b32281830d0019416972416019d42054fa2786e8880b4a2fcaad43c859cc4aa4a85c4a292ccb4c4e41285a4ca92d4622e865130fc010049ea527800040000")

check(ok, message) = ok || error(message)
const IO_CONTRACT = "qcl-selected-io-v2"
const READ_CAP = 32 * 1024^2
const WRITE_CAP = 96 * 1024^2
mutable struct SelectedLedger
    reads::Int
    writes::Int
    failed::Bool
    failure::String
    attempted::Int
    completed::Int
end
const LEDGER = SelectedLedger(0, 1024^2, false, "", 0, 0)
# The initial 1MiB is irrevocable terminal/error evidence allowance. Only the
# single fixed receipt (64KiB), error prefix (64KiB) and packet marker (128B)
# tokens below may consume it; it is never a general reserve bypass.
const TERMINAL_USED = Set{Symbol}()
function io_failure(kind, path, requested, message)
    LEDGER.failed = true
    isempty(LEDGER.failure) && (LEDGER.failure = "$kind|$path|$requested|$message")
    error(message)
end
function reserve_io(n; write=false, path="", kind="content")
    LEDGER.failed && error("Sticky selected-I/O failure")
    used, cap = write ? (LEDGER.writes, WRITE_CAP) : (LEDGER.reads, READ_CAP)
    0 <= n <= cap - used || io_failure(kind, path, n, "Selected-I/O allowance exhausted")
    write ? (LEDGER.writes += n) : (LEDGER.reads += n)
end
function selected_read(path, cap=65536; reader=(io,n)->read(io,n))
    try
        islink(path) && error("Selected symlink rejected")
        before = lstat(path)
        isfile(before) && before.size <= cap || error("Not a bounded regular selected file")
        # Open for read performs metadata only; content reservation precedes reader.
        return open(path, "r") do io
            actual = stat(io)
            !islink(path) && actual.device == before.device && actual.inode == before.inode &&
                actual.size == before.size && isfile(actual) || error("Selected file replaced")
            reserve_io(actual.size + 1; path=path, kind="read")
            bytes = reader(io, actual.size + 1)
            length(bytes) == actual.size || error("Selected file grew/shrank")
            bytes
        end
    catch err
        io_failure("read", path, cap, sprint(showerror, err))
    end
end
function write_bytes(path, bytes; writer=(io,b)->write(io,b), opener=open)
    opener(path, "w") do io
        offset = 1
        while offset <= length(bytes)
            n = writer(io, @view bytes[offset:end])
            0 < n <= length(bytes)-offset+1 || error("Selected write made invalid progress")
            offset += n
        end
    end
end
function selected_write(path, content; cap=65536, writer=(io,b)->write(io,b), opener=open)
    bytes = content isa AbstractString ? collect(codeunits(content)) : copy(content)
    try
        length(bytes) <= cap || error("Selected per-file write cap")
        reserve_io(length(bytes); write=true, path=path, kind="write")
        write_bytes(path, bytes; writer=writer, opener=opener)
    catch err
        io_failure("write", path, length(bytes), sprint(showerror, err))
    end
end
function terminal_write(token, path, content)
    cap = token == :receipt ? 65536 : token == :error ? 65536 : token == :packet ? 128 : 0
    expected = token == :packet ? joinpath(abspath(options(ARGS)["--tmp-root"]), "packet-passed") :
        token == :error ? ENV["QCL_ORACLE_IO_RECEIPT"] * ".error" : ENV["QCL_ORACLE_IO_RECEIPT"]
    check(cap > 0 && path == expected && !(token in TERMINAL_USED), "Invalid terminal token")
    bytes = collect(codeunits(content))
    check(length(bytes) <= cap, "Terminal slot overflow")
    push!(TERMINAL_USED, token)
    write_bytes(path, bytes)
end
digest(path, cap=65536) = bytes2hex(sha256(selected_read(path, cap)))
function save_toml(path, data)
    io = IOBuffer()
    TOML.print(io, data; sorted=true)
    selected_write(path, take!(io))
end
function snapshot(directory)
    result = Dict{String,String}()
    entries = 0
    for (root, dirs, files) in walkdir(directory; follow_symlinks=false)
        filter!(!=(".git"), dirs)
        entries += length(dirs) + length(files)
        check(entries <= 128 && length(splitpath(relpath(root, directory))) <= 16,
            "Snapshot traversal bound")
        check(all(!islink(joinpath(root, d)) for d in dirs), "Snapshot symlink directory")
        for file in files
            path = joinpath(root, file)
            check(length(result) < 16 && ncodeunits(relpath(path, directory)) <= 256,
                "Snapshot file/name bound")
            result[relpath(path, directory)] = digest(path)
        end
    end
    return result
end
function selected_command_stdout(command, cap)
    reserve_io(cap+1; path=string(command), kind="command-stdout")
    process = open(ignorestatus(command), "r")
    bytes = UInt8[]
    try
        bytes = read(process, cap+1)
        if length(bytes) > cap
            # Preserve the original boundary failure even if prefix publication
            # itself fails. This records cause, not success or a reserve bypass.
            LEDGER.failure = "command-stdout|$(string(command))|$(cap+1)|Command stdout overflow"
            selected_write(ENV["QCL_ORACLE_IO_RECEIPT"] * ".command-prefix", bytes; cap=cap+1)
            io_failure("command-stdout", string(command), cap+1, "Command stdout overflow")
        end
        # read(io,n) returns fewer than n bytes only at EOF; no extra pipe read.
        wait(process)
        success(process) || error("Command failed")
        return bytes
    catch err
        # Exact owned command only; enclosing allocation supplies finite deadline.
        process_exited(process) || kill(process)
        wait(process)
        io_failure("command-stdout", string(command), cap+1, sprint(showerror, err))
    finally
        close(process)
    end
end
function selected_payload_tar(directory, output)
    function inventory()
        check(readdir(directory) == ["payload"], "Artifact inventory is not exactly payload")
        path = joinpath(directory, "payload")
        info = lstat(path)
        check(!islink(path) && isfile(info) && info.size <= 65536, "Invalid artifact payload")
        (info.device, info.inode, info.mode, info.size)
    end
    before = inventory()
    reserve_io(1024^2+1; path=directory, kind="Tar.create input")
    io = IOBuffer(; maxsize=65536)
    try
        Tar.create(directory, io)
        check(inventory() == before, "Artifact changed during Tar.create")
        selected_write(output, take!(io))
        bytes = selected_read(output)
        return Tar.tree_hash(IOBuffer(bytes)), bytes2hex(sha256(bytes))
    catch err
        io_failure("Tar.create", directory, 1024^2+1, sprint(showerror, err))
    end
end
function git(repo, args...)
    command = `git -c core.hooksPath=/dev/null -c commit.gpgsign=false -C $repo $args`
    return strip(String(selected_command_stdout(addenv(command, "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0"), 4096)))
end
function options(args)
    check(length(args) == 8, "Expected --baseline-ref, --candidate-script, --tmp-root, --julia")
    opts = Dict(args[i] => args[i + 1] for i in 1:2:length(args))
    check(Set(keys(opts)) == Set(["--baseline-ref", "--candidate-script", "--tmp-root", "--julia"]),
        "Unknown or duplicate option")
    check(opts["--baseline-ref"] == BASELINE, "Unexpected baseline identity")
    return opts
end

function main(args)
    VERSION == v"1.13.0" || error("Oracle requires pinned Julia 1.13.0")
    opts = options(args)
    runner = dirname(@__DIR__)
    candidate = abspath(opts["--candidate-script"])
    julia = abspath(opts["--julia"])
    root = abspath(opts["--tmp-root"])
    check(isfile(candidate) && isfile(julia), "Missing candidate or Julia executable")
    check(!ispath(root), "Attempt root must be fresh; no retries in place")
    check(git(runner, "rev-parse", "HEAD") == BASELINE, "Runner HEAD identity changed")
    mkpath(root)
    baseline = joinpath(root, "baseline-prepare_depot.jl")
    selected_write(baseline, selected_command_stdout(`git -C $runner show $BASELINE:tools/prepare_depot.jl`, 65536))
    # Freeze exact candidate bytes used for every child, retaining the original path.
    frozen_candidate = joinpath(root, "candidate-prepare_depot.jl")
    selected_write(frozen_candidate, selected_read(candidate))

    artifact_source = mkpath(joinpath(root, "artifact-source"))
    selected_write(joinpath(artifact_source, "payload"), PAYLOAD)
    raw_archive = joinpath(root, "artifact-control.tar")
    artifact_tree, raw_archive_sha = selected_payload_tar(artifact_source, raw_archive)
    archive = joinpath(root, "lazy.tar.gz")
    selected_write(archive, LAZY_GZIP)
    archive_sha = digest(archive)
    check(archive_sha == "7c832d43b28e80fa3f3053ac5b15391e57e7fb99fde510d934258a20d9dae465", "Gzip fixture identity changed")
    # ASCII-only URI avoids ambiguity in file:// paths supplied to Downloads.
    encoded_parts = [replace(part, r"[^A-Za-z0-9_.~-]" =>
        s -> join("%" * uppercase(string(b; base=16, pad=2)) for b in codeunits(s)))
        for part in split(archive, '/')]
    archive_url = "file://" * join(encoded_parts, '/')
    artifact = Dict("lazy_fixture" => Dict("git-tree-sha1" => artifact_tree,
        "lazy" => true, "download" => [Dict("url" => archive_url, "sha256" => archive_sha)]))

    repo = mkpath(joinpath(root, "package-repo"))
    mkpath(joinpath(repo, "src"))
    mkpath(joinpath(repo, "deps"))
    save_toml(joinpath(repo, "Project.toml"), Dict("name" => PACKAGE,
        "uuid" => PACKAGE_UUID, "version" => "0.1.0"))
    selected_write(joinpath(repo, "src", "$PACKAGE.jl"), "module $PACKAGE\nend\n")
    selected_write(joinpath(repo, "deps", "build.jl"), """
    write(ENV["QCL_DEPOT_BUILD_MARKER"], "QCL_DEPOT_POISON_BUILD_EXECUTED\\n")
    error("QCL_DEPOT_POISON_BUILD_EXECUTED")
    """)
    save_toml(joinpath(repo, "Artifacts.toml"), artifact)
    git(repo, "init", "--quiet")
    git(repo, "add", "Project.toml", "Artifacts.toml", "src", "deps")
    git(repo, "-c", "user.name=QCL fixture", "-c", "user.email=fixture@invalid",
        "commit", "--quiet", "-m", "Frozen poison build and lazy artifact fixture")
    commit = git(repo, "rev-parse", "HEAD")
    tree = git(repo, "rev-parse", "HEAD^{tree}")
    package_bytes = snapshot(repo)

    registry = mkpath(joinpath(root, "frozen-registry"))
    registry_package = mkpath(joinpath(registry, "Q", PACKAGE))
    save_toml(joinpath(registry, "Registry.toml"), Dict("name" => "QCLFixture",
        "uuid" => "4a118f8e-d43e-4499-90eb-451cc50a966f", "repo" => repo,
        "description" => "Offline no-build regression fixture",
        "packages" => Dict(PACKAGE_UUID => Dict("name" => PACKAGE, "path" => "Q/$PACKAGE"))))
    save_toml(joinpath(registry_package, "Package.toml"),
        Dict("name" => PACKAGE, "uuid" => PACKAGE_UUID, "repo" => repo))
    save_toml(joinpath(registry_package, "Versions.toml"),
        Dict("0.1.0" => Dict("git-tree-sha1" => tree)))
    registry_bytes = snapshot(registry)
    project = Dict("deps" => Dict(PACKAGE => PACKAGE_UUID))
    manifest = Dict("julia_version" => "1.13.0", "manifest_format" => "2.0",
        "deps" => Dict(PACKAGE => [Dict("uuid" => PACKAGE_UUID, "version" => "0.1.0",
            "repo-url" => repo, "repo-rev" => commit, "git-tree-sha1" => tree)]))
    save_toml(joinpath(root, "frozen-Project.toml"), project)
    save_toml(joinpath(root, "frozen-Manifest.toml"), manifest)
    project_bytes = selected_read(joinpath(root, "frozen-Project.toml"))
    manifest_bytes = selected_read(joinpath(root, "frozen-Manifest.toml"))
    save_toml(joinpath(root, "identity.toml"), Dict("baseline_ref" => BASELINE,
        "baseline_sha256" => digest(baseline), "candidate_source" => candidate,
        "candidate_sha256" => digest(frozen_candidate), "julia" => julia,
        "julia_sha256" => digest(julia, 1024^2), "package_repo" => repo, "package_commit" => commit,
        "package_tree" => tree, "package_files" => package_bytes,
        "registry_files" => registry_bytes, "artifact_url" => archive_url,
        "artifact_tree" => artifact_tree, "artifact_archive_sha256" => archive_sha,
        "artifact_raw_archive_sha256" => raw_archive_sha,
        "project_sha256" => digest(joinpath(root, "frozen-Project.toml")),
        "manifest_sha256" => digest(joinpath(root, "frozen-Manifest.toml")),
        "network_isolation" => "external prerequisite; environment is not proof"))

    # Exactly five sequential child invocations; external supervisor owns total
    # wall/RSS/output/process-tree limits. Every raw log and sandbox is retained.
    for name in ("red", "green", "missing-project", "missing-manifest", "bad-artifact")
        LEDGER.attempted += 1
        directory = mkpath(joinpath(root, name))
        environment = mkpath(joinpath(directory, "project"))
        depot = mkpath(joinpath(directory, "depot"))
        registry_target = joinpath(depot, "registries", "QCLFixture")
        mkpath(dirname(registry_target))
        check(snapshot(registry) == registry_bytes, "Registry changed before copy")
        for relative in ("Registry.toml", "Q/$PACKAGE/Package.toml", "Q/$PACKAGE/Versions.toml")
            target = joinpath(registry_target, relative)
            mkpath(dirname(target))
            selected_write(target, selected_read(joinpath(registry, relative)))
        end
        check(snapshot(registry_target) == registry_bytes, "Registry copy mismatch")
        name == "missing-project" || selected_write(joinpath(environment, "Project.toml"), project_bytes)
        name == "missing-manifest" || selected_write(joinpath(environment, "Manifest.toml"), manifest_bytes)
        if name == "bad-artifact"
            # A distinct expected tree cannot be satisfied by the good lazy fixture.
            bad = Dict("broken_fixture" => Dict("git-tree-sha1" => repeat("0", 40),
                "lazy" => true, "download" => [Dict("url" => archive_url, "sha256" => repeat("0", 64))]))
            save_toml(joinpath(environment, "Artifacts.toml"), bad)
        end
        marker = joinpath(directory, "build-marker") # outside depot, survives cleanup
        check(readdir(depot) == ["registries"], "Depot fixture is not fresh")
        script = name == "red" ? baseline : frozen_candidate
        command = `$julia --startup-file=no --history-file=no --threads=1 --compiled-modules=existing --pkgimages=existing --project=$environment $script`
        command = addenv(command, "JULIA_DEPOT_PATH" => depot, "JULIA_LOAD_PATH" => "@stdlib",
            "JULIA_PKG_SERVER" => "", "JULIA_PKG_OFFLINE" => "true",
            "JULIA_PKG_PRECOMPILE_AUTO" => "0", "JULIA_NUM_THREADS" => "1",
            "OPENBLAS_NUM_THREADS" => "1", "QCL_DEPOT_BUILD_MARKER" => marker,
            "JULIA_PKG_IGNORE_HASHES" => "false", "JULIA_PKG_USE_CLI_GIT" => "false")
        stdout_path = joinpath(directory, "stdout.log")
        stderr_path = joinpath(directory, "stderr.log")
        reserve_io(0; write=true, path=stdout_path, kind="child raw open")
        reserve_io(0; write=true, path=stderr_path, kind="child raw open")
        # Single pinned baseline build hook writes this exact literal once.
        name == "red" && reserve_io(ncodeunits("QCL_DEPOT_POISON_BUILD_EXECUTED\n");
            write=true, path=marker, kind="poison hook")
        process = open(stdout_path, "w") do out
            open(stderr_path, "w") do err
                run(pipeline(ignorestatus(command); stdout=out, stderr=err))
            end
        end
        stdout_bytes = selected_read(stdout_path, 1024^2)
        stderr_bytes = selected_read(stderr_path, 1024^2)
        diagnostic = String(copy(stdout_bytes)) * String(copy(stderr_bytes))
        observations = Dict{String,Any}("exitcode" => process.exitcode,
            "build_marker" => isfile(marker), "script_sha256" => digest(script),
            "stdout_sha256" => bytes2hex(sha256(stdout_bytes)), "stderr_sha256" => bytes2hex(sha256(stderr_bytes)),
            "registry_unchanged" => snapshot(registry_target) == registry_bytes,
            "project_unchanged" => name == "missing-project" ? !ispath(joinpath(environment, "Project.toml")) :
                isfile(joinpath(environment, "Project.toml")) && selected_read(joinpath(environment, "Project.toml")) == project_bytes,
            "manifest_unchanged" => name == "missing-manifest" ? !ispath(joinpath(environment, "Manifest.toml")) :
                isfile(joinpath(environment, "Manifest.toml")) && selected_read(joinpath(environment, "Manifest.toml")) == manifest_bytes)
        if name == "green"
            installed_root = joinpath(depot, "packages", PACKAGE)
            installed = isdir(installed_root) ? readdir(installed_root; join=true) : String[]
            observations["package_bytes_match"] = length(installed) == 1 && snapshot(only(installed)) == package_bytes
            artifact_path = joinpath(depot, "artifacts", artifact_tree)
            payload_path = joinpath(artifact_path, "payload")
            observations["artifact_bytes_match"] = isfile(payload_path) && String(selected_read(payload_path)) == PAYLOAD
            if isdir(artifact_path)
                captured_tar = joinpath(directory, "captured-artifact.tar")
                captured_tree, _ = selected_payload_tar(artifact_path, captured_tar)
                observations["artifact_tree_match"] = captured_tree == artifact_tree
            else
                observations["artifact_tree_match"] = false
            end
        end
        # Preserve observations even when an assertion fails; no automatic retries.
        save_toml(joinpath(directory, "receipt.toml"), observations)
        check(observations["registry_unchanged"], "$name changed frozen registry")
        check(observations["project_unchanged"], "$name changed/created Project")
        check(observations["manifest_unchanged"], "$name changed/created Manifest")
        if name == "red"
            check(process.exitcode != 0 && isfile(marker) &&
                occursin("QCL_DEPOT_POISON_BUILD_EXECUTED", diagnostic), "RED did not reach poison build")
            check(String(selected_read(marker, 64)) == "QCL_DEPOT_POISON_BUILD_EXECUTED\n", "Wrong RED marker")
        elseif name == "green"
            check(process.exitcode == 0 && !isfile(marker), "GREEN failed or executed build")
            check(all(observations[key] for key in ("package_bytes_match", "artifact_bytes_match", "artifact_tree_match")),
                "GREEN did not capture exact package/lazy artifact")
        elseif name == "bad-artifact"
            check(process.exitcode != 0 && !isfile(marker) && occursin("broken_fixture", diagnostic) &&
                occursin("Unable to automatically download/install artifact", diagnostic) &&
                occursin("Expected sha256", diagnostic), "Bad artifact failed at wrong boundary")
        else
            expected = name == "missing-project" ? "existing Project file" : "existing Manifest file"
            check(process.exitcode != 0 && !isfile(marker) && occursin(expected, diagnostic),
                "$name failed at wrong boundary")
            check(!ispath(joinpath(depot, "packages")) && !ispath(joinpath(depot, "clones")) &&
                !ispath(joinpath(depot, "artifacts")), "$name entered instantiate")
        end
        selected_write(joinpath(directory, "assertions-passed"), "targeted oracle assertions passed\n")
        summary = "$name: targeted oracle assertions passed; raw logs retained\n"
        reserve_io(ncodeunits(summary); write=true, path="stdout", kind="summary")
        write(stdout, summary)
        LEDGER.completed += 1
    end
    check(digest(candidate) == digest(frozen_candidate), "Candidate changed during packet")
end

# JSON is serialized locally: no additional package/import or hidden file I/O.
json_string(s) = "\"" * replace(s, "\\"=>"\\\\", "\""=>"\\\"", "\n"=>"\\n", "\r"=>"\\r", "\t"=>"\\t") * "\""
function run_packet()
    outcome = "failed"
    receipt = get(ENV, "QCL_ORACLE_IO_RECEIPT", "")
    opts = options(ARGS)
    root = abspath(opts["--tmp-root"])
    check(receipt == joinpath(dirname(root), "control", "oracle-io.json"), "Unbound accounting path")
    # Source identity is captured before sticky failure; receipt never performs
    # an unreserved failure-path source read.
    source_sha = ""
    try
        source_sha = digest(@__FILE__)
        main(ARGS)
        check(!LEDGER.failed && LEDGER.completed == 5, "Incomplete accounting")
        outcome = "passed"
    catch err
        terminal_write(:error, receipt * ".error", first(sprint(showerror, err), 60000))
        rethrow()
    finally
        # Source SHA uses the already captured immutable identity on failure.
        payload = accounting_payload(source_sha, outcome)
        terminal_write(:receipt, receipt, payload)
    end
    terminal_write(:packet, joinpath(root, "packet-passed"), "five targeted cases passed; no full CI or science claim\n")
end
function accounting_payload(source_sha, outcome)
    # Use no source reads after failure.
    "{" * join(["\"contract\":" * json_string(IO_CONTRACT),
        "\"oracle_sha256\":" * json_string(source_sha),
        "\"read_cap\":$READ_CAP", "\"write_cap\":$WRITE_CAP",
        "\"read_reserved\":$(LEDGER.reads)", "\"write_reserved\":$(LEDGER.writes)",
        "\"io_failed\":$(LEDGER.failed)", "\"failure\":" * json_string(LEDGER.failure),
        "\"attempted_cases\":$(LEDGER.attempted)", "\"completed_cases\":$(LEDGER.completed)",
        "\"terminal_prepaid\":1048576", "\"terminal_state\":\"consumed\"",
        "\"outcome\":" * json_string(outcome)], ",") * "}"
end
# Source-only controls for a separately admitted finite check allocation. They
# are never entered by the five-case packet, and do not claim Pkg PASS. Caller
# supplies an owned fresh directory and a tiny exact local overflow command.
function selected_io_controls(directory, overflow_command, baseline_overflow_command)
    reserve_io(4*1024^2; kind="prepaid control read window")
    reserve_io(1024^2; write=true, kind="prepaid control write window")
    saved = (LEDGER.reads, LEDGER.writes, LEDGER.failed, LEDGER.failure,
        LEDGER.attempted, LEDGER.completed)
    function reset_control(r=0, w=0)
        LEDGER.reads = r; LEDGER.writes = w
        LEDGER.failed = false; LEDGER.failure = ""
    end
    function rejects(f)
        rejected = false
        try f() catch; rejected = true end
        check(rejected, "Negative accounting control unexpectedly succeeded")
    end
    results = Dict{String,Bool}()
    try
        check(!ispath(directory), "Controls require fresh owned directory")
        mkpath(directory)
        fixture = joinpath(directory, "fixture")
        reset_control()
        selected_write(fixture, "abc")
        calls = Ref(0)
        spy = (io,n)->(calls[] += 1; read(io,n))
        reset_control(READ_CAP-4)
        check(selected_read(fixture; reader=spy) == UInt8[0x61,0x62,0x63] && calls[] == 1,
            "Exact positive read control")
        reset_control(READ_CAP-3)
        rejects(()->selected_read(fixture; reader=spy))
        check(calls[] == 1 && LEDGER.failed && LEDGER.reads == READ_CAP-3, "Read reject primitive called")
        results["read_boundary"] = true
        newpath = joinpath(directory, "must-not-exist")
        opens = Ref(0)
        opener = (f,path,mode)->(opens[] += 1; open(f,path,mode))
        reset_control(0, WRITE_CAP-2)
        rejects(()->selected_write(newpath, "abc"; opener=opener))
        check(!ispath(newpath) && opens[] == 0, "Write reject opened new target")
        reset_control(0, WRITE_CAP-2)
        rejects(()->selected_write(fixture, "abc"; opener=opener))
        reset_control()
        check(selected_read(fixture) == UInt8[0x61,0x62,0x63], "Rejected write changed sentinel")
        reset_control(0, WRITE_CAP-3)
        selected_write(newpath, "abc"; opener=opener)
        check(opens[] == 1, "Exact write did not open")
        results["write_before_open"] = true
        reset_control()
        partial = joinpath(directory, "partial")
        broken = (io,b)->(write(io, @view b[1:1]); error("control partial write"))
        rejects(()->selected_write(partial, "abc"; writer=broken))
        check(LEDGER.failed && LEDGER.writes == 3 && stat(partial).size == 1,
            "Partial failure refunded reservation")
        # Exercise the same prepaid terminal primitive despite sticky failure;
        # the production path/token remains fixed, never caller-selected.
        error_path = ENV["QCL_ORACLE_IO_RECEIPT"] * ".error"
        terminal_write(:error, error_path, "control partial write retained")
        results["partial_failure_terminal"] = isfile(error_path)
        reset_control()
        small = mkpath(joinpath(directory, "snapshot"))
        selected_write(joinpath(small, "a"), "a")
        selected_write(joinpath(small, "b"), "b")
        reset_control(READ_CAP-2)
        rejects(()->snapshot(small))
        check(LEDGER.failed && LEDGER.reads == READ_CAP, "Snapshot aggregate exhaustion")
        reset_control()
        symlink(joinpath(small, "a"), joinpath(small, "link"))
        rejects(()->snapshot(small))
        results["snapshot_aggregate_and_symlink"] = true
        reset_control()
        rejects(()->selected_command_stdout(overflow_command, 2))
        check(LEDGER.failed && occursin("Command stdout overflow", LEDGER.failure),
            "Command overflow did not retain original cause")
        reset_control()
        # Caller binds this tiny local producer to exactly 65537 bytes of 0x78.
        # Exercise the actual baseline cap and actual helper, not cap arithmetic.
        rejects(()->selected_command_stdout(baseline_overflow_command, 65536))
        check(LEDGER.failed && occursin("Command stdout overflow", LEDGER.failure) &&
            !occursin("Selected per-file write cap", LEDGER.failure),
            "Baseline stdout overflow lost original cause")
        # Keep the failed state as evidence; a new control read is prepaid from
        # the fixed control window and uses the same real selected_read wrapper.
        failure = LEDGER.failure
        reset_control()
        prefix = selected_read(ENV["QCL_ORACLE_IO_RECEIPT"] * ".command-prefix", 65537)
        check(prefix == fill(UInt8(0x78), 65537), "Baseline overflow prefix not byte-equal")
        check(occursin("Command stdout overflow", failure), "Missing saved overflow cause")
        results["command_overflow_reaped"] = true
        reset_control()
        calls[] = 0
        bytes = selected_read(fixture; reader=spy)
        diagnostic, hash = String(copy(bytes)), bytes2hex(sha256(bytes))
        check(calls[] == 1 && diagnostic == "abc" && hash == bytes2hex(sha256(UInt8[0x61,0x62,0x63])),
            "Raw diagnostic/hash did not share bounded read")
        results["raw_read_reuse"] = true
        reset_control()
        tarroot = mkpath(joinpath(directory, "tar"))
        selected_write(joinpath(tarroot, "payload"), "abc")
        chmod(joinpath(tarroot, "payload"), 0o644)
        tree1, _ = selected_payload_tar(tarroot, joinpath(directory, "one.tar"))
        chmod(joinpath(tarroot, "payload"), 0o755)
        tree2, _ = selected_payload_tar(tarroot, joinpath(directory, "two.tar"))
        check(tree1 != tree2, "Tar erased executable mode")
        selected_write(joinpath(tarroot, "extra"), "x")
        rejects(()->selected_payload_tar(tarroot, joinpath(directory, "extra.tar")))
        check(!ispath(joinpath(directory, "extra.tar")), "Tar extra-file control created archive")
        rm(joinpath(tarroot, "extra"))
        rm(joinpath(tarroot, "payload"))
        symlink(fixture, joinpath(tarroot, "payload"))
        rejects(()->selected_payload_tar(tarroot, joinpath(directory, "symlink.tar")))
        check(!ispath(joinpath(directory, "symlink.tar")), "Tar symlink control created archive")
        results["tar_inventory_and_mode"] = true
    finally
        # Control subledgers never refund the fixed, externally admitted window.
        LEDGER.reads, LEDGER.writes, LEDGER.failed, LEDGER.failure,
            LEDGER.attempted, LEDGER.completed = saved
    end
    results
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_packet()
end
