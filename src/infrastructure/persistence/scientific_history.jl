"""Closed, typed scalar history segments. Each accepted iteration is recorded once."""
mutable struct ScientificHistoryRecorder
    directory::String
    identity::Dict{String,Any}
    scba_count::Base.RefValue{Int}
    outer_count::Base.RefValue{Int}
    scba::Vector{Tuple{Int,Int,SCBAIteration}}
    outer::Vector{Tuple{Int,OuterIteration}}
    segment::Int
    problem_id::String
    segments::Vector{Dict{String,Any}}
    published_scba::Int
    published_outer::Int
    flush_interval_ns::UInt64
    last_flush_ns::UInt64
    clock_ns::Function
    problem::Union{Nothing,NEGFProblem}
end

function scientific_history_counts(execution_directory)
    scba=0
    outer=0
    isdir(execution_directory) || return scba, outer
    for (root, _, files) in walkdir(execution_directory)
        basename(root)=="history" || continue
        occursin(
            string(Base.Filesystem.path_separator)*"artifacts"*string(
                Base.Filesystem.path_separator,
            ),
            root,
        ) && continue
        for name in files
            endswith(name, ".h5") || continue
            h5open(joinpath(root, name), "r") do file
                _require_native_metadata(file, "qcl-negf-scientific-history-v4")
                _require_native_scba_tables(file)
                scba+=Int(read_attribute(file["metadata"], "scba_rows"))
                outer+=Int(read_attribute(file["metadata"], "outer_rows"))
            end
        end
    end
    return scba, outer
end

function ScientificHistoryRecorder(
    directory,
    identity,
    scba_count,
    outer_count;
    flush_interval_seconds::Real = 30,
    clock_ns::Function = time_ns,
)
    isfinite(flush_interval_seconds) && flush_interval_seconds>0 || throw(
        ArgumentError("scientific history flush interval must be finite and positive"),
    )
    root=joinpath(directory, "history")
    mkpath(root)
    return ScientificHistoryRecorder(
        root,
        identity,
        scba_count,
        outer_count,
        Tuple{Int,Int,SCBAIteration}[],
        Tuple{Int,OuterIteration}[],
        0,
        "",
        Dict{String,Any}[],
        0,
        0,
        round(UInt64, flush_interval_seconds*1e9),
        UInt64(clock_ns()),
        clock_ns,
        nothing,
    )
end

function record_scientific_history!(
    recorder::ScientificHistoryRecorder,
    kind,
    outer,
    row,
    problem,
)
    # A domain rebuild starts a new segment; metadata identifies the actual grid.
    problem_id=string(
        problem.numerical.N_E,
        "/",
        problem.numerical.N_k,
        "/",
        problem.numerical.N_z,
        "/",
        problem.numerical.E_min,
        "/",
        problem.numerical.E_max,
    )
    if !isempty(recorder.problem_id) && recorder.problem_id!=problem_id
        flush_scientific_history!(recorder)
    end
    recorder.problem_id=problem_id
    recorder.problem=problem
    if kind===:scba
        recorder.scba_count[]+=1
        push!(recorder.scba, (recorder.scba_count[], outer, row))
    else
        recorder.outer_count[]+=1
        push!(recorder.outer, (recorder.outer_count[], row))
    end
    # Presentation follows durable closed scalar segments. Its cadence does not
    # request expensive matrix checkpoints or alter solver iteration limits.
    if length(recorder.scba)+length(recorder.outer)>=1000 ||
       UInt64(recorder.clock_ns())-recorder.last_flush_ns>=recorder.flush_interval_ns
        flush_scientific_history!(recorder)
    end
    return nothing
end

function flush_scientific_history!(recorder::ScientificHistoryRecorder)
    isempty(recorder.scba) && isempty(recorder.outer) && return nothing
    recorder.segment+=1
    destination=joinpath(
        recorder.directory,
        "segment-"*lpad(string(recorder.segment), 6, '0')*".h5",
    )
    temporary, io=mktemp(recorder.directory)
    close(io)
    try
        h5open(temporary, "w") do file
            metadata=create_group(file, "metadata")
            metadata["toolchain_json"] =
                sprint(_light_json, _runtime_toolchain_provenance())
            attributes(metadata)["schema"]="qcl-negf-scientific-history-v4"
            attributes(metadata)["schema_version"]=_CHECKPOINT_SCHEMA_VERSION
            attributes(metadata)["contract_set"]=_RESULT_CONTRACT_SET
            attributes(metadata)["artifact_role"]="science.history"
            attributes(metadata)["scba_rows"]=length(recorder.scba)
            attributes(metadata)["outer_rows"]=length(recorder.outer)
            attributes(metadata)["domain_identity"]=recorder.problem_id
            metadata["identity_json"]=sprint(_light_json, recorder.identity)
            for kind in (:scba, :outer)
                group=create_group(file, String(kind))
                rows=kind===:scba ? recorder.scba : recorder.outer
                group["sequence"]=Int64[first(item) for item in rows]
                if kind===:scba
                    group["outer_iteration"]=Int64[item[2] for item in rows]
                    group["iteration"]=Int64[last(item).ν for item in rows]
                    for field in fieldnames(SCBAIteration)[2:end]
                        fieldtype(SCBAIteration, field)<:Real || continue
                        _physical_dataset(
                            group,
                            String(field),
                            Float64[getfield(last(item), field) for item in rows];
                            units = field===:J ? "A/m^2" : "dimensionless",
                            axes = "iteration",
                            description = "Complete accepted SCBA $(field)",
                        )
                    end
                else
                    group["iteration"]=Int64[last(item).μ for item in rows]
                    for field in fieldnames(OuterIteration)[2:10]
                        _physical_dataset(
                            group,
                            String(field),
                            Float64[getfield(last(item), field) for item in rows];
                            units = field===:J ? "A/m^2" : "dimensionless",
                            axes = "iteration",
                            description = "Complete outer diagnostic $(field)",
                        )
                    end
                end
            end
            _write_psd_history!(
                file,
                SCBAIteration[last(item) for item in recorder.scba];
                problem = recorder.problem,
                sequences = Int64[first(item) for item in recorder.scba],
            )
            _write_physical_markers!(
                file,
                SCBAIteration[last(item) for item in recorder.scba];
                sequences = Int64[first(item) for item in recorder.scba],
            )
            _annotate_physics_tree!(file)
        end
        chmod(temporary, 0o640)
        _sync_artifact_file(temporary)
        mv(temporary, destination; force = false)
        _sync_artifact_directory(recorder.directory)
        scba_rows=length(recorder.scba)
        outer_rows=length(recorder.outer)
        push!(
            recorder.segments,
            Dict{String,Any}(
                "path"=>basename(destination),
                "sha256"=>bytes2hex(open(sha256, destination)),
                "bytes"=>filesize(destination),
                "scba_rows"=>scba_rows,
                "outer_rows"=>outer_rows,
            ),
        )
        recorder.published_scba+=scba_rows
        recorder.published_outer+=outer_rows
        pointer=joinpath(recorder.directory, "index.json")
        index=Dict(
            "schema"=>"qcl-negf-scientific-history-index-v2",
            "contract_set"=>_RESULT_CONTRACT_SET,
            "identity"=>recorder.identity,
            "generation"=>recorder.segment,
            "updated_unix"=>time(),
            "scba_rows"=>recorder.published_scba,
            "outer_rows"=>recorder.published_outer,
            "segments"=>recorder.segments,
        )
        _observability_atomic_text(pointer) do io
            _light_json(io, index)
            println(io)
        end
        _sync_artifact_file(pointer)
        _sync_artifact_directory(recorder.directory)
        recorder.last_flush_ns=UInt64(recorder.clock_ns())
        empty!(recorder.scba)
        empty!(recorder.outer)
    finally
        isfile(temporary) && rm(temporary; force = true)
    end
    return destination
end

function scientific_history_sources(point_directory)
    paths=String[]
    isdir(point_directory) || return paths
    for attempt in sort(readdir(point_directory; join = true))
        history=joinpath(attempt, "history")
        isdir(history) || continue
        append!(
            paths,
            filter(path->endswith(path, ".h5"), sort(readdir(history; join = true))),
        )
    end
    return paths
end

"""Materialize one lossless history table for export; local segments remain recovery inputs."""
function consolidate_scientific_history(destination, paths)
    isempty(paths) && throw(
        ArgumentError(
            "native v4 consolidation requires at least one closed history segment",
        ),
    )
    tables=Dict("scba"=>Dict{String,Any}(), "outer"=>Dict{String,Any}())
    sources=Any[]
    for path in paths
        h5open(path, "r") do file
            _require_native_metadata(file, "qcl-negf-scientific-history-v4")
            _require_native_scba_tables(file)
            metadata=file["metadata"]
            push!(
                sources,
                Dict(
                    "sha256"=>bytes2hex(open(sha256, path)),
                    "identity"=>YAML.load(
                        String(read(metadata["identity_json"]));
                        dicttype = Dict{String,Any},
                    ),
                    "domain_identity"=>String(read_attribute(metadata, "domain_identity")),
                    "scba_rows"=>Int(read_attribute(metadata, "scba_rows")),
                    "scba_sequence_first"=>(
                        length(file["scba/sequence"])==0 ? nothing :
                        Int(file["scba/sequence"][1])
                    ),
                    "scba_sequence_last"=>(
                        length(file["scba/sequence"])==0 ? nothing :
                        Int(file["scba/sequence"][length(file["scba/sequence"])])
                    ),
                    "outer_rows"=>Int(read_attribute(metadata, "outer_rows")),
                ),
            )
            for kind in ("scba", "outer"), name in keys(file[kind])
                values=read(file[kind][name])
                append!(get!(tables[kind], name, eltype(values)[]), values)
            end
        end
    end
    h5open(destination, "w") do file
        metadata=create_group(file, "metadata")
        metadata["toolchain_json"] = sprint(_light_json, _runtime_toolchain_provenance())
        attributes(metadata)["schema"]="qcl-negf-scientific-history-v4"
        attributes(metadata)["schema_version"]=_CHECKPOINT_SCHEMA_VERSION
        attributes(metadata)["contract_set"]=_RESULT_CONTRACT_SET
        attributes(metadata)["artifact_role"]="science.history"
        attributes(metadata)["representation"]="lossless consolidation of every local closed history segment"
        metadata["source_segments_json"]=sprint(_light_json, sources)
        for kind in ("scba", "outer")
            table=tables[kind]
            group=create_group(file, kind)
            sequence=get(table, "sequence", Int64[])
            order=sortperm(sequence)
            length(unique(sequence))==length(sequence) ||
                throw(ArgumentError("duplicate scientific history sequence"))
            attributes(metadata)[kind*"_rows"]=length(sequence)
            for (name, values) in table
                _physical_dataset(
                    group,
                    name,
                    values[order];
                    units = name=="J" ? "A/m^2" : "dimensionless",
                    axes = "iteration",
                    description = "Complete $(kind) $(name), ordered by immutable execution sequence",
                )
            end
        end
        _consolidate_psd_history!(file, paths)
        _consolidate_physical_markers!(file, paths)
        _annotate_physics_tree!(file)
    end
    return destination
end
