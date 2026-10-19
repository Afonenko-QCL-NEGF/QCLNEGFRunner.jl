module Suite_RuntimeCheckpointDurability
using Test, SHA, YAML
# Real source-selected module: no common.jl, Core, HDF5 or substitute packages.
const SOURCE = realpath(joinpath(@__DIR__, "../../src/composition/application_runtime.jl"))
include(SOURCE)
using .QCLApplicationRuntime
const RT = QCLApplicationRuntime
const RUN, POINT = "run-" * repeat("a", 64), "point-" * repeat("b", 64)
const OLD, NEW = "state: old\n", "state: new\n"
const STAGES = (:payload_closed, :payload_hashed, :payload_synced, :payload_published,
    :payload_ancestry_synced, :metadata_closed, :metadata_synced, :metadata_published,
    :metadata_directory_synced, :publication_verified)
const CONTEXT_KEYS = (:run_id, :point_id, :attempt, :generation, :directory,
    :payload_temporary, :payload_path, :metadata_temporary, :metadata_path)
const SEAMS = (:_RuntimeCheckpointIO, :_save_runtime_checkpoint!, :_runtime_checkpoint_io,
    :_sync_runtime_checkpoint_file, :_sync_runtime_checkpoint_directory,
    :_write_runtime_checkpoint_metadata, :_publish_runtime_checkpoint_file)
const HAVE_SEAM = all(name -> isdefined(RT, name), SEAMS)
const TREES, CELLS = String[], String[]
capture(f) = try
    (value = f(), error = nothing)
catch error
    (value = nothing, error = error)
end
dir(r) = joinpath(r.root, RUN, "points", POINT, "checkpoints")
stem(g) = lpad(string(g), 12, '0')
mp(r, g) = joinpath(dir(r), stem(g) * ".metadata.yaml")
pp(r, g) = joinpath(dir(r), stem(g) * ".payload.yaml")

# Literal old v1 tree: never calls production writer/reference/hash helpers.
function literal!(r; generation = 1, attempt = 1, bytes = OLD)
    mkpath(dir(r)); write(pp(r, generation), bytes)
    e = Dict{String,Any}("schema" => "reference2019-runtime-checkpoint-v1",
        "run_id" => RUN, "point_id" => POINT, "generation" => generation,
        "attempt" => attempt, "kind" => "iteration", "iteration" => 1,
        "payload_file" => basename(pp(r, generation)), "payload_extension" => "yaml",
        "payload_bytes" => sizeof(bytes), "sha256" => bytes2hex(SHA.sha256(codeunits(bytes))),
        "metadata" => Dict{String,Any}())
    YAML.write_file(mp(r, generation), e)
    e
end

# Independent selection/identity/length/hash oracle; only SHA/YAML libraries shared.
# Unavailable always has reason+locator; never repairs or falls back.
function independent(r; expected_attempt = nothing)
    isdir(dir(r)) || return (status = :absent, path = dir(r), reason = "directory")
    names = sort(filter(n -> endswith(n, ".metadata.yaml"), readdir(dir(r))))
    isempty(names) && return (status = :absent, path = dir(r), reason = "no envelope")
    selected = joinpath(dir(r), last(names))
    unavailable(reason) = (status = :unavailable, path = selected, reason = reason)
    try
        isfile(selected) && !islink(selected) || return unavailable("metadata regular")
        m = match(r"^([0-9]{12})\.metadata\.yaml$", basename(selected))
        m === nothing && return unavailable("metadata basename")
        e = YAML.load_file(selected)
        e isa AbstractDict || return unavailable("mapping")
        fields = ("schema", "run_id", "point_id", "generation", "attempt", "kind",
            "iteration", "payload_file", "payload_extension", "payload_bytes", "sha256", "metadata")
        all(k -> haskey(e, k), fields) || return unavailable("missing field")
        e["schema"] == "reference2019-runtime-checkpoint-v1" || return unavailable("schema")
        e["run_id"] == RUN || return unavailable("run")
        e["point_id"] == POINT || return unavailable("point")
        g, a = e["generation"], e["attempt"]
        g isa Integer && !(g isa Bool) && g > 0 || return unavailable("generation")
        g == parse(Int, only(m.captures)) || return unavailable("filename generation")
        a isa Integer && !(a isa Bool) && a > 0 || return unavailable("attempt")
        expected_attempt === nothing || a == expected_attempt || return unavailable("attempt mismatch")
        e["payload_extension"] == "yaml" || return unavailable("extension")
        n = e["payload_file"]
        n isa AbstractString && basename(n) == n || return unavailable("payload basename")
        n == stem(g) * ".payload.yaml" || return unavailable("payload generation")
        payload = joinpath(dir(r), n)
        isfile(payload) && !islink(payload) || return unavailable("payload regular")
        count = e["payload_bytes"]
        count isa Integer && !(count isa Bool) && count >= 0 || return unavailable("count")
        bytes = read(payload)
        length(bytes) == count || return unavailable("length")
        sha = e["sha256"]
        sha isa AbstractString && occursin(r"^[0-9a-f]{64}$", sha) || return unavailable("digest shape")
        bytes2hex(SHA.sha256(bytes)) == sha || return unavailable("digest")
        (status = :complete, path = selected, generation = Int(g), attempt = Int(a), bytes = bytes, sha256 = String(sha))
    catch error
        error isa InterruptException && rethrow()
        unavailable(sprint(showerror, error))
    end
end

function cell(f, name; old = false, nested = false)
    push!(CELLS, name)
    tree = mktempdir(; prefix = "qcl-dev18-", cleanup = false); push!(TREES, tree)
    r = FilesystemRunRepository(nested ? joinpath(tree, "missing", "root") : joinpath(tree, "root"))
    old && literal!(r)
    snapshot = old ? Dict(p => read(p) for p in (pp(r, 1), mp(r, 1))) : Dict{String,Vector{UInt8}}()
    @testset "$name" begin
        try
            f(r, tree)
        finally
            for (p, bytes) in snapshot
                @test isfile(p)
                isfile(p) && @test read(p) == bytes
            end
            write(joinpath(tree, "cell.txt"), name * "\n")
        end
    end
end
function seam_cell(f, name; kwargs...)
    cell(name; kwargs...) do r, tree
        # Missing interface is a RED assertion, not an exception aborting R/H04 cells.
        @test HAVE_SEAM
        HAVE_SEAM && f(r, tree)
    end
end
function codec(counter = Ref(0); writer = (p, state) -> write(p, state))
    CallbackCheckpointCodec("yaml", writer, p -> begin
        counter[] += 1
        YAML.load_file(p)
    end)
end
function complete(r, g, a, bytes; guarded = false)
    observed = independent(r; expected_attempt = guarded ? a : nothing)
    @test observed.status == :complete
    if observed.status == :complete
        @test observed.generation == g
        @test observed.attempt == a
        @test observed.bytes == collect(codeunits(bytes))
        @test observed.sha256 == bytes2hex(SHA.sha256(codeunits(bytes)))
    end
end
function ancestry(r, anchor)
    result = String[]; current = dir(r)
    while true
        push!(result, current)
        current == anchor && return result
        parent = dirname(current); parent == current && error("invalid anchor")
        current = parent
    end
end
function fault_io(r, trace; cut = (s, c) -> nothing, fault = nothing, original = ErrorException("injected"))
    default = RT._runtime_checkpoint_io()
    counts = Dict(:file => 0, :directory => 0, :publish => 0, :metadata => 0)
    function operation(which, args...)
        counts[which] += 1; push!(trace, (which, args...))
        if fault == (which, counts[which])
            if which == :metadata
                open(first(args), "w") do stream
                    write(stream, "schema: [partial")
                end
            end
            throw(original)
        end
        if which == :file
            @test isfile(first(args)) && !islink(first(args))
            @test stat(first(args)).mode & 0o777 == 0o640
            return default.sync_file(args...)
        end
        which == :directory && return default.sync_directory(args...)
        which == :publish && return default.publish_file(args...)
        default.write_metadata(args...)
    end
    RT._RuntimeCheckpointIO(p -> operation(:file, p), p -> operation(:directory, p),
        (s, d) -> operation(:publish, s, d), (p, e) -> operation(:metadata, p, e),
        (s, c) -> begin
            @test keys(c) == CONTEXT_KEYS
            @test c.run_id == RUN && c.run_id isa String
            @test c.point_id == POINT && c.point_id isa String
            @test c.attempt isa Int && c.generation isa Int
            @test c.directory == dir(r)
            @test c.payload_temporary isa String
            @test c.payload_path == pp(r, c.generation)
            @test c.metadata_path == mp(r, c.generation)
            if s in STAGES[1:5]
                @test c.metadata_temporary === nothing
            else
                @test c.metadata_temporary isa String
            end
            @test islocked(r.lock)
            push!(trace, (:cut, s, c)); cut(s, c); nothing
        end)
end
save_with(r, io; attempt = 2, state = NEW, selected_codec = codec()) =
    RT._save_runtime_checkpoint!(r, selected_codec, RUN, POINT, attempt, state, io; iteration = 1)

function assert_trace(r, trace, anchor; through = nothing, prefix = false)
    contexts = [e[3] for e in trace if e[1] == :cut]
    isempty(contexts) && return @test false
    c = last(contexts)
    writes = [e for e in trace if e[1] == :metadata]
    mt = isempty(writes) ? c.metadata_temporary : first(writes)[2]
    expected = Any[(:cut, :payload_closed), (:cut, :payload_hashed), (:file, c.payload_temporary),
        (:cut, :payload_synced), (:publish, c.payload_temporary, c.payload_path), (:cut, :payload_published)]
    append!(expected, [(:directory, p) for p in ancestry(r, anchor)])
    append!(expected, Any[(:cut, :payload_ancestry_synced), (:metadata, mt),
        (:cut, :metadata_closed), (:file, mt), (:cut, :metadata_synced),
        (:publish, mt, c.metadata_path), (:cut, :metadata_published),
        (:directory, dir(r)), (:cut, :metadata_directory_synced), (:cut, :publication_verified)])
    if through !== nothing
        boundary = findfirst(e -> e == (:cut, through), expected)
        expected = expected[1:boundary]
    end
    normal(e) = e[1] in (:cut, :metadata) ? e[1:2] : e
    prefix && (expected = expected[1:length(trace)])
    @test normal.(trace) == expected
end

@testset "Runtime checkpoint publication faults" begin
    repository_source = realpath(joinpath(dirname(SOURCE), "../infrastructure/runtime/filesystem_repository.jl"))
    @info "DEV18 source-selected fixture" source = SOURCE sha256 = bytes2hex(SHA.sha256(read(SOURCE))) repository_source = repository_source repository_sha256 = bytes2hex(SHA.sha256(read(repository_source)))
    for old in (false, true), (i, stage) in enumerate(STAGES)
        name = "C" * lpad(string(i + (old ? 10 : 0)), 2, '0')
        seam_cell(name; old = old) do r, tree
            trace = Any[]; original = ErrorException("cut $name")
            io = fault_io(r, trace; cut = (s, c) -> s == stage ? throw(original) : nothing)
            result = capture(() -> save_with(r, io; attempt = old ? 2 : 1))
            @test result.error === original
            @test result.value === nothing
            assert_trace(r, trace, tree; through = stage)
            if i < 8
                old ? complete(r, 1, 1, OLD) : (@test independent(r).status == :absent)
            else
                complete(r, old ? 2 : 1, old ? 2 : 1, NEW)
            end
            c = last(trace)[3]
            i < 4 && @test isfile(c.payload_temporary)
            i >= 4 && @test isfile(c.payload_path)
            i in (6, 7) && @test isfile(c.metadata_temporary)
            write(joinpath(tree, "trace.txt"), repr(trace))
        end
    end
    for i in 1:9
        seam_cell("E" * lpad(string(i), 2, '0'); old = true) do r, tree
            trace = Any[]
            original = SystemError(i in (1, 5) ? "ENOSPC injected" : "EIO injected", Int32(i in (1, 5) ? 28 : 5))
            faults = Dict(2 => (:file, 1), 3 => (:publish, 1), 4 => (:directory, 1),
                5 => (:metadata, 1), 6 => (:file, 2), 7 => (:publish, 2),
                8 => (:directory, length(ancestry(r, tree)) + 1))
            writer = (p, state) -> begin
                if i == 1
                    write(p, "partial"); throw(original)
                end
                write(p, state)
            end
            cut = (s, c) -> begin
                if i == 9 && s == :metadata_directory_synced
                    @test filesize(c.payload_path) == sizeof(NEW)
                    write(c.payload_path, "state: bad\n")
                    @test filesize(c.payload_path) == sizeof(NEW)
                end
                nothing
            end
            io = fault_io(r, trace; fault = get(faults, i, nothing), original = original, cut = cut)
            result = capture(() -> save_with(r, io; selected_codec = codec(; writer = writer)))
            @test result.value === nothing
            if i == 9
                @test result.error isa CheckpointIntegrityError
                @test !any(e -> e[1] == :cut && e[2] == :publication_verified, trace)
                @test independent(r).status == :unavailable
            else
                @test result.error === original
                if i == 8
                    complete(r, 2, 2, NEW)
                else
                    complete(r, 1, 1, OLD)
                    @test !ispath(mp(r, 2))
                end
                if i == 1
                    @test isempty(trace)
                    @test any(p -> isfile(p) && read(p, String) == "partial", readdir(dir(r); join = true))
                else
                    @test last(trace)[1] == faults[i][1]
                    @test count(e -> e[1] == faults[i][1], trace) == faults[i][2]
                end
                if i == 5
                    @test isfile(last(trace)[2])
                    @test read(last(trace)[2], String) == "schema: [partial"
                end
            end
            i > 1 && assert_trace(r, trace, tree; prefix = true)
            write(joinpath(tree, "trace.txt"), repr(trace))
        end
    end
    for i in 1:16
        cell("R" * lpad(string(i), 2, '0'); old = true) do r, tree
            e = literal!(r; generation = 2, attempt = i == 14 ? 2 : 1, bytes = NEW)
            p, payload = mp(r, 2), pp(r, 2)
            if i == 1
                rm(payload)
            elseif i == 2
                write(payload, "state:")
            elseif i == 3
                write(payload, "state: bad\n")
            elseif i == 4
                e["sha256"] = "not-a-digest"
            elseif i == 5
                delete!(e, "metadata")
            elseif i == 6
                write(p, "schema: [unterminated")
            elseif i == 7
                e["run_id"] = "run-" * repeat("c", 64)
            elseif i == 8
                e["point_id"] = "point-" * repeat("c", 64)
            elseif i == 9
                mv(p, mp(r, 3))
            elseif i == 10
                e["payload_file"] = "../" * basename(payload)
            elseif i == 11
                e["payload_extension"] = "h5"
            elseif i == 12
                e["attempt"] = 0
            elseif i == 13
                e["attempt"] = true
            elseif i == 15
                mv(p, joinpath(tree, "foreign.metadata")); symlink(joinpath(tree, "foreign.metadata"), p)
            elseif i == 16
                mv(payload, joinpath(tree, "foreign.payload")); symlink(joinpath(tree, "foreign.payload"), payload)
            end
            i in (4, 5, 7, 8, 10, 11, 12, 13) && YAML.write_file(p, e)
            foreign = Dict(p => read(p) for p in filter(isfile,
                [joinpath(tree, "foreign.metadata"), joinpath(tree, "foreign.payload")]))
            counter = Ref(0)
            result = capture() do
                i == 14 ? load_latest_checkpoint(r, codec(counter), RUN, POINT; expected_attempt = 1) :
                    load_latest_checkpoint(r, codec(counter), RUN, POINT)
            end
            @test result.error isa CheckpointIntegrityError
            @test result.value === nothing
            @test counter[] == 0
            @test independent(r; expected_attempt = i == 14 ? 1 : nothing).status == :unavailable
            for (p, bytes) in foreign
                @test read(p) == bytes
            end
        end
    end
    for (name, invalid) in (("R17", 0), ("R18", true))
        cell(name; old = true) do r, tree
            counter = Ref(0)
            result = capture(() -> load_latest_checkpoint(r, codec(counter), RUN, POINT; expected_attempt = invalid))
            @test result.error isa ArgumentError
            @test result.value === nothing
            @test counter[] == 0
        end
    end
    seam_cell("H01"; nested = true) do r, tree
        trace = Any[]
        ref = save_with(r, fault_io(r, trace); attempt = 1,
            state = Dict("state" => "new"), selected_codec = YamlCheckpointCodec())
        @test ref.generation == 1
        # Built-in YAML codec quotes string values; callback cells write raw NEW bytes.
        # Independent literal: do not derive expected bytes from the production writer.
        assert_trace(r, trace, tree); complete(r, 1, 1, "state: \"new\"\n")
        @test load_latest_checkpoint(r, YamlCheckpointCodec(), RUN, POINT).state == Dict("state" => "new")
    end
    seam_cell("H02") do r, tree
        first_trace = Any[]
        first_ref = save_with(r, fault_io(r, first_trace); attempt = 1, state = OLD)
        @test first_ref.generation == 1
        assert_trace(r, first_trace, tree)
        old_bytes = Dict(p => read(p) for p in (pp(r, 1), mp(r, 1)))
        trace = Any[]; ref = save_with(r, fault_io(r, trace))
        @test ref.generation == 2
        assert_trace(r, trace, tree); complete(r, 2, 2, NEW)
        @test load_latest_checkpoint(r, YamlCheckpointCodec(), RUN, POINT).state["state"] == "new"
        for (p, bytes) in old_bytes
            @test read(p) == bytes
        end
    end
    seam_cell("H03") do r, tree
        trace = Any[]; counter = Ref(0); selected = codec(counter)
        ref = save_with(r, fault_io(r, trace); attempt = 1, selected_codec = selected)
        @test counter[] == 0 # readback must not decode payload again
        @test ref.generation == 1
        assert_trace(r, trace, tree); complete(r, 1, 1, NEW)
        @test load_latest_checkpoint(r, selected, RUN, POINT).state["state"] == "new"
        @test counter[] == 1
    end
    cell("H04"; old = true) do r, tree
        counter = Ref(0); selected = codec(counter)
        historical = load_latest_checkpoint(r, selected, RUN, POINT)
        @test historical.reference.attempt == 1 # resume source for future context attempt2
        @test historical.state["state"] == "old"
        matching = capture(() -> load_latest_checkpoint(r, selected, RUN, POINT; expected_attempt = 1))
        @test matching.error === nothing
        matching.value === nothing || @test matching.value.reference.attempt == 1
        @test counter[] == 2
        complete(r, 1, 1, OLD; guarded = true)
        absent_point = "point-" * repeat("d", 64)
        absent = capture(() -> load_latest_checkpoint(r, selected, RUN, absent_point; expected_attempt = 2))
        @test absent.error === nothing
        @test absent.value === nothing
        @test counter[] == 2
    end
    seam_cell("H05"; old = true) do r, tree
        orphan = pp(r, 2); write(orphan, "orphan\n")
        trace = Any[]; ref = save_with(r, fault_io(r, trace))
        @test ref.generation == 3
        @test read(orphan, String) == "orphan\n"
        assert_trace(r, trace, tree); complete(r, 3, 2, NEW)
        @test load_latest_checkpoint(r, YamlCheckpointCodec(), RUN, POINT).state["state"] == "new"
        @test all(n -> !occursin("current", n) && !occursin("previous", n), readdir(dir(r)))
    end
    seam_cell("L01") do r, tree
        entered, release, second_started = Channel{Nothing}(1), Channel{Nothing}(1), Channel{Nothing}(1)
        t1, t2, second_writes = Any[], Any[], Ref(0)
        io = fault_io(r, t1; cut = (s, c) -> begin
            if s == :payload_closed
                put!(entered, nothing); take!(release)
            end
            nothing
        end)
        first_task = @async capture(() -> save_with(r, io; attempt = 1))
        second_task = nothing
        try
            @test timedwait(() -> isready(entered), 2.0) == :ok
            second_task = @async begin
                put!(second_started, nothing)
                capture(() -> save_with(r, fault_io(r, t2); selected_codec = codec(; writer = (p, state) -> begin
                    second_writes[] += 1; write(p, state)
                end)))
            end
            @test timedwait(() -> isready(second_started), 2.0) == :ok
            yield()
            @test second_writes[] == 0
            @test isempty(t2)
            @test isempty(filter(n -> endswith(n, ".payload.yaml"), readdir(dir(r))))
        finally
            put!(release, nothing)
        end
        @test timedwait(() -> istaskdone(first_task) && istaskdone(second_task), 2.0) == :ok
        if istaskdone(first_task) && istaskdone(second_task)
            a, b = fetch(first_task), fetch(second_task)
            @test a.error === nothing && b.error === nothing
            if a.value !== nothing && b.value !== nothing
                @test a.value.generation == 1 && b.value.generation == 2
            end
            @test second_writes[] == 1
            complete(r, 2, 2, NEW)
        end
    end
    seam_cell("L02"; old = true) do r, tree
        original = ErrorException("lock release"); trace = Any[]
        io = fault_io(r, trace; cut = (s, c) -> s == :payload_published ? throw(original) : nothing)
        @test capture(() -> save_with(r, io)).error === original
        @test isfile(pp(r, 2))
        ref = save_with(r, fault_io(r, Any[]))
        @test ref.generation == 3
        @test read(pp(r, 2), String) == NEW
        @test !islocked(r.lock)
        complete(r, 3, 2, NEW)
    end
    seam_cell("L03"; old = true) do r, tree
        nested = Ref{Any}(nothing)
        selected = codec(; writer = (p, state) -> begin
            before = sort(readdir(dir(r)))
            nested[] = capture(() -> save_runtime_checkpoint!(r, codec(), RUN, POINT, 3, "nested\n"))
            @test nested[].error isa ArgumentError
            @test sort(readdir(dir(r))) == before
            write(p, state)
        end)
        ref = save_with(r, fault_io(r, Any[]); selected_codec = selected)
        @test ref.generation == 2
        @test nested[].value === nothing
        complete(r, 2, 2, NEW)
        @test save_runtime_checkpoint!(r, codec(), RUN, POINT, 3, NEW).generation == 3
        @test !islocked(r.lock)
    end
    @test length(CELLS) == 55
    @test length(unique(CELLS)) == 55
    @info "DEV18 retained raw fixture trees" trees = TREES cells = CELLS
end
end # module
