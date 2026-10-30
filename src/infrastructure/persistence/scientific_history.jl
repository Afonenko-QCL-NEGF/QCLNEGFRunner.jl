"""Legacy native4 implementation, retained only until P05 removes its old callsites."""
mutable struct _LegacyScientificHistoryRecorder
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

"""One native5 invocation. Scientific ordinals are independent of Core delivery sequence."""
mutable struct ScientificHistoryRecorder
    directory::String
    root::String
    identity::Dict{String,Any}
    invocation::Dict{String,Any}
    lineage::Dict{String,Any}
    provenance::Dict{String,Any}
    status::Dict{String,Any}
    parent::Union{Nothing,VerifiedExactCheckpoint}
    buffer::Vector{QCLNEGF.ScientificHistorySnapshot}
    buffer_bytes::Int
    maximum_buffer_bytes::Int
    maximum_buffer_records::Int
    maximum_scba_rows::Int
    last_sequence::Int
    ordinal::UInt64
    publication::UInt64
    pin::Dict{String,Any}
    page::Union{Nothing,Dict{String,Any}}
    active::Dict{String,Dict{String,Any}}
    stage::Union{Nothing,Tuple{Int,String,String,Int}}
    last_inner::Int
    outer_done::Bool
    flush_interval_ns::UInt64
    last_flush_ns::UInt64
    clock_ns::Function
    failed::Bool
    closed::Bool
    pending::Any
    verified::Dict{String,Any}
end
_p04_empty_pin()=Dict{String,Any}("head"=>nothing,(k=>"0" for k in ("entries","records","scba_rows","outer_rows","witness_updates","last_record"))...)
const _P04_ROW_KEY_FIELDS=(:domain_revision,:discretization_id,:basis_id,:stage,:outer_iteration,:inner_iteration)
function _p04_row_key(s)
    integer(n)=Dict{String,Any}("kind"=>"integer","type"=>"Int64","decimal"=>string(n))
    projection=(integer(s.domain_revision),s.discretization_id,s.basis_id,
        Dict{String,Any}("kind"=>"symbol","value"=>string(s.stage)),integer(s.outer_iteration),
        s.inner_iteration===nothing ? nothing : integer(s.inner_iteration))
    Dict{String,Any}(string(name)=>value for (name,value) in zip(_P04_ROW_KEY_FIELDS,projection))
end
function _p04_admit_row_key(value)
    _p04_keys(value,string.(_P04_ROW_KEY_FIELDS))
    for name in _P04_ROW_KEY_FIELDS
        _p04_decode(value[string(name)],fieldtype(QCLNEGF.ScientificHistorySnapshot,name),(;validate_only=true))
    end
    value
end
function _p04_admit_row_key(value,core)
    _p04_admit_row_key(value)
    _p04_keys(core,("type","fields"))
    _p04_require(core["type"]==_p04_typeid(QCLNEGF.ScientificHistorySnapshot),"original Core snapshot type differs")
    _p04_keys(core["fields"],string.(fieldnames(QCLNEGF.ScientificHistorySnapshot)))
    _p04_require(all(value[string(name)]==core["fields"][string(name)] for name in _P04_ROW_KEY_FIELDS),
        "original Core row projection differs")
    value
end
function _p04_proofs(verified,references,status)
    proofs=Dict{String,Any}()
    evidence=(status[name]["evidence"] for name in ("convergence","physics","discretization","experimental"))
    for reference in Iterators.flatten((references,evidence))
        reference===nothing && continue
        known=get(verified,reference["path"],nothing)
        _p04_require(known!==nothing && known.reference==reference,"retained immutable proof missing")
        proofs[reference["path"]]=known
    end
    proofs
end
function _p04_trim_verified!(r)
    r.verified=_p04_proofs(r.verified,(locator["leaf"] for locator in values(r.active)),r.status)
    nothing
end
function _p04_unchanged(r,reference)
    path=_p04_path(r.root,reference["path"]);known=get(r.verified,reference["path"],nothing)
    _p04_require(known!==nothing && known.reference==reference && isfile(path) &&
        known.signature==_p04_stat(stat(path)),"original append source changed; reopen verified source before a new attempt")
    nothing
end
function ScientificHistoryRecorder(directory::AbstractString;artifact_root::AbstractString,
    identity::AbstractDict,source_epoch::AbstractString,provenance::AbstractDict,status::AbstractDict,
    maximum_scba_rows::Integer,parent_checkpoint::Union{Nothing,VerifiedExactCheckpoint}=nothing,
    maximum_buffer_records::Integer=1000,maximum_buffer_bytes::Integer=1048576,
    flush_interval_seconds::Real=30,clock_ns::Function=time_ns,
    resource_policy::Symbol=:standalone,storage_context=nothing)
    _resource_policy(resource_policy; storage_context)
    _p04_identity(identity);_p04_validate_status(status);_p04_validate_provenance(provenance)
    _p04_require(isdir(artifact_root) && !islink(artifact_root),"artifact root must exist and be owned")
    root=realpath(artifact_root);directory=abspath(directory)
    _p04_path(root,_p04_relative(root,directory));mkpath(directory)
    _p04_require(!ispath(joinpath(directory,"current.json")) && !ispath(joinpath(directory,"history")),"invocation namespace already used")
    _p04_id(String(source_epoch))
    _p04_require(maximum_scba_rows>0 && maximum_buffer_records>0 && maximum_buffer_bytes>0 &&
        isfinite(flush_interval_seconds) && flush_interval_seconds>0,"invalid recorder limits")
    lineage=Dict{String,Any}("parent_state"=>nothing);active=Dict{String,Dict{String,Any}}()
    if parent_checkpoint!==nothing
        _p04_require(parent_checkpoint.root==root,"parent artifact root differs")
        parent=checkpoint_reference(parent_checkpoint);_p04_lineage(identity,parent)
        lineage["parent_state"]=parent
        for entry in _p04_parse(parent_checkpoint.declaration_json)["witness_targets"]
            active[_p04_json(entry["row_key"])]=deepcopy(entry["locator"])
        end
        _p04_require(length(active)<=2,"parent has too many update anchors")
    end
    recorder=ScientificHistoryRecorder(directory,root,deepcopy(identity),Dict("source_epoch"=>String(source_epoch)),
        lineage,deepcopy(provenance),deepcopy(status),parent_checkpoint,QCLNEGF.ScientificHistorySnapshot[],0,
        Int(maximum_buffer_bytes),Int(maximum_buffer_records),Int(maximum_scba_rows),0,0,0,_p04_empty_pin(),nothing,
        active,nothing,0,false,round(UInt64,flush_interval_seconds*1e9),UInt64(clock_ns()),clock_ns,false,false,nothing,
        parent_checkpoint===nothing ? Dict{String,Any}() : copy(parent_checkpoint.verified))
    _p04_verify_status(root,recorder.status,recorder.verified)
    if !isempty(active)
        rowkeys=[_p04_parse(key) for key in Base.keys(active)]
        stageof(key)=(parse(Int,key["domain_revision"]["decimal"]),key["discretization_id"],key["basis_id"],parse(Int,key["outer_iteration"]["decimal"]))
        recorder.stage=stageof(first(rowkeys))
        _p04_require(all(stageof(key)==recorder.stage for key in rowkeys),"parent anchors disagree on current public domain/stage")
        recorder.last_inner=parse(Int,_p04_parse(parent_checkpoint.declaration_json)["state"]["fields"]["progress"]["fields"]["accepted_scba"]["decimal"])
        _p04_require(recorder.last_inner<=maximum_scba_rows,"parent progress exceeds declared SCBA bound")
    end
    _p04_trim_verified!(recorder)
    recorder
end
function record_scientific_history!(r::ScientificHistoryRecorder,s::QCLNEGF.ScientificHistorySnapshot)::Nothing
    _p04_require(!r.failed && !r.closed,"recorder closed or needs reconciliation")
    _p04_require(s.sequence>r.last_sequence && s.action in (:append,:witness_update) &&
        ((s.stage===:scba && s.row isa QCLNEGF.SCBAIteration && s.inner_iteration==s.row.ν) ||
         (s.stage===:outer && s.row isa QCLNEGF.OuterIteration && s.inner_iteration===nothing && s.outer_iteration==s.row.μ)) &&
        s.domain_revision>=0 && !isempty(s.discretization_id) && !isempty(s.basis_id) && s.outer_iteration>0,"invalid scientific snapshot sequence/type/domain")
    stage=(s.domain_revision,s.discretization_id,s.basis_id,s.outer_iteration)
    if r.stage!==nothing && stage!=r.stage
        _p04_require(s.domain_revision>r.stage[1] ||
            (stage[1:3]==r.stage[1:3] && s.outer_iteration>r.stage[4]),"scientific stage regressed or representation rebound")
        flush_scientific_history!(r);empty!(r.active);_p04_trim_verified!(r);r.last_inner=0;r.outer_done=false
    end
    r.stage=stage;key=_p04_json(_p04_row_key(s))
    if s.action===:append
        _p04_require(!haskey(r.active,key) && !r.outer_done,"duplicate append or completed stage reused")
        if s.stage===:scba
            _p04_require(s.inner_iteration>r.last_inner && s.inner_iteration<=r.maximum_scba_rows,"SCBA counter outside declared stage")
        end
    else
        _p04_require(s.stage===:scba && haskey(r.active,key),"witness update lacks original append")
    end
    bytes=Base.summarysize(s)
    !isempty(r.buffer) && r.buffer_bytes+bytes>r.maximum_buffer_bytes && flush_scientific_history!(r)
    next=Base.checked_add(r.ordinal,UInt64(1));offset=length(r.buffer)
    if s.action===:append && s.stage===:scba
        r.active[key]=Dict("source_identity"=>deepcopy(r.identity),"source_epoch"=>r.invocation["source_epoch"],
            "append_ordinal"=>string(next),"leaf"=>nothing,"row_offset"=>string(offset))
        r.last_inner=s.inner_iteration
    elseif s.stage===:outer;r.outer_done=true;end
    r.ordinal=next;r.last_sequence=s.sequence
    # Oversized rows are borrowed only during this synchronous direct seal.
    push!(r.buffer,bytes>r.maximum_buffer_bytes ? s : deepcopy(s));r.buffer_bytes+=bytes
    if bytes>r.maximum_buffer_bytes || length(r.buffer)>=r.maximum_buffer_records ||
            UInt64(r.clock_ns())-r.last_flush_ns>=r.flush_interval_ns
        flush_scientific_history!(r)
    end
    nothing
end

function flush_scientific_history!(r::ScientificHistoryRecorder)::Dict{String,Any}
    _p04_flush_history!(r)
end
function _p04_flush_history!(r;hook=stage->nothing,publish_live=true)
    _p04_require(!r.closed,"recorder is closed")
    if r.failed
        _p04_reconcile!(r) && return deepcopy(r.pin)
        throw(ArgumentError("scientific publication needs reconciliation/new attempt"))
    end
    isempty(r.buffer) && return deepcopy(r.pin)
    r.failed=true
    next=Base.checked_add(r.publication,UInt64(1));prefix=r.invocation["source_epoch"]*"-"*lpad(string(next),9,'0')
    arrays=Any[];records=Any[];dependencies=Dict{String,Any}()
    first=parse(UInt64,r.pin["last_record"])+1
    totals=Dict{String,Any}(k=>r.pin[k] for k in ("records","scba_rows","outer_rows","witness_updates","last_record"))
    for (offset,s) in enumerate(r.buffer)
        ordinal=first+UInt64(offset-1);target=nothing
        if s.action===:witness_update
            original=r.active[_p04_json(_p04_row_key(s))]
            scope=original["source_identity"]==r.identity && original["source_epoch"]==r.invocation["source_epoch"] ?
                original["leaf"]===nothing ? "same_leaf" : "sealed_leaf" : "parent_checkpoint"
            target=merge(deepcopy(original),Dict("scope"=>scope,"anchor_state"=>nothing,"anchor_history"=>nothing))
            if scope=="parent_checkpoint"
                target["anchor_state"]=checkpoint_reference(r.parent)
                target["anchor_history"]=_p04_parse(r.parent.declaration_json)["history"]
            end
            if target["leaf"]!==nothing
                _p04_unchanged(r,target["leaf"]);dependencies[target["leaf"]["path"]]=target["leaf"]
            end
        end
        push!(records,Dict("schema"=>_P04_SCHEMAS["record"],"contract_set"=>_P04_CONTRACT,"identity"=>r.identity,
            "invocation"=>r.invocation,"stream_ordinal"=>string(ordinal),"row_key"=>_p04_row_key(s),"target"=>target,
            "core"=>_p04_encode(s,arrays)))
        channel=s.action===:witness_update ? "witness_updates" : s.stage===:scba ? "scba_rows" : "outer_rows"
        totals[channel]=string(Base.checked_add(parse(UInt64,totals[channel]),UInt64(1)))
    end
    totals["records"]=string(r.ordinal);totals["last_record"]=string(r.ordinal)
    artifacts=Dict{String,Any}[]
    if !isempty(arrays)
        ref=_p04_payload!(r,joinpath("history","arrays-"*prefix*".h5"),arrays,
            "qcl-negf-scientific-history-v5","science.history";hook)
        dependencies[ref["path"]]=ref;push!(artifacts,_p04_artifact(ref,"science.history";dependencies=String[]))
        _p04_remember!(r.verified,r.root,ref)
        for record in records;_p04_bind_arrays!(record["core"],ref);end
    end
    leafpath=_p04_new_hdf!(r,joinpath("history","records-"*prefix*".h5"),"qcl-negf-scientific-history-v5","science.history","record_leaf") do file
        group=create_group(file,"records");bytes=UInt8[];offsets=UInt64[0]
        for record in records;append!(bytes,codeunits(_p04_json(record)));push!(offsets,UInt64(length(bytes)));end
        group["offsets"]=offsets;group["json_utf8"]=bytes
        group["stream_ordinal"]=UInt64[parse(UInt64,x["stream_ordinal"]) for x in records];close(group)
    end
    leaf=_p04_ref(r.root,leafpath,"qcl-negf-scientific-history-v5";media="application/x-hdf5")
    _p04_remember!(r.verified,r.root,leaf)
    hook(:leaves_published)
    push!(artifacts,_p04_artifact(leaf,"science.history";dependencies=sort!(collect(keys(dependencies)))))
    page=Dict{String,Any}("schema"=>_P04_SCHEMAS["catalog"],"contract_set"=>_P04_CONTRACT,"identity"=>r.identity,
        "invocation"=>r.invocation,"generation"=>string(next),"entries"=>string(Base.checked_add(parse(UInt64,r.pin["entries"]),UInt64(length(artifacts)))),
        "previous"=>r.pin["head"]===nothing ? nothing : deepcopy(r.pin),"artifacts"=>artifacts,
        "range"=>Dict("first_record"=>string(first),"last_record"=>string(r.ordinal)),"totals"=>totals)
    pageref=_p04_publish_json!(r,joinpath("history","catalog-"*prefix*".json"),page,_P04_SCHEMAS["catalog"])
    hook(:catalog_published)
    pin=merge(Dict{String,Any}("head"=>pageref,"entries"=>page["entries"]),totals)
    for locator in values(r.active)
        locator["leaf"]===nothing && (locator["leaf"]=deepcopy(leaf))
    end
    r.pending=(;pin,page,publication=next,manifest=nothing,manifest_ref=nothing,checkpoint=nothing)
    if publish_live
        manifest=_p04_manifest(r,next,pin,nothing,Dict{String,Any}[],nothing,r.status,false)
        reference=_p04_publish_json!(r,joinpath("manifests","state-"*prefix*".json"),manifest,_P04_SCHEMAS["manifest"])
        r.pending=merge(r.pending,(;manifest,manifest_ref=reference))
        hook(:manifest_published);_p04_pointer!(r,"current.json",manifest,reference);hook(:current_pointer_published)
    end
    _p04_ack_history!(r,pin,page,next)
    deepcopy(pin)
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

function _LegacyScientificHistoryRecorder(
    directory,
    identity,
    scba_count,
    outer_count;
    flush_interval_seconds::Real = 30,
    clock_ns::Function = time_ns,
    resource_policy::Symbol = :standalone,
    storage_context=nothing,
)
    _resource_policy(resource_policy; storage_context)
    isfinite(flush_interval_seconds) && flush_interval_seconds>0 || throw(
        ArgumentError("scientific history flush interval must be finite and positive"),
    )
    root=joinpath(directory, "history")
    mkpath(root)
    recorder = _LegacyScientificHistoryRecorder(
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
    return recorder
end

function record_scientific_history!(
    recorder::_LegacyScientificHistoryRecorder,
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

function flush_scientific_history!(recorder::_LegacyScientificHistoryRecorder;
    resource_policy::Symbol = :standalone, storage_context=nothing)
    _resource_policy(resource_policy; storage_context)
    isempty(recorder.scba) && isempty(recorder.outer) && return nothing
    temporary = io = nothing
    local destination
    try
        recorder.segment+=1
        destination=joinpath(
            recorder.directory,
            "segment-"*lpad(string(recorder.segment), 6, '0')*".h5",
        )
        temporary, io=mktemp(recorder.directory; cleanup=true)
        close(io)
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
        temporary !== nothing && isfile(temporary) && rm(temporary; force = true)
    end
    return destination
end

function flush_scientific_history_finalizer!(recorder::_LegacyScientificHistoryRecorder;
    resource_policy::Symbol=:standalone, primary=nothing)
    _resource_policy(resource_policy)
    return flush_scientific_history!(recorder)
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
            if haskey(metadata,"source_segments_json")
                append!(sources,YAML.load(String(read(metadata["source_segments_json"]));dicttype=Dict{String,Any}))
            else
                push!(sources,Dict(
                    "sha256"=>bytes2hex(open(sha256,path)),
                    "identity"=>YAML.load(String(read(metadata["identity_json"]));dicttype=Dict{String,Any}),
                    "domain_identity"=>String(read_attribute(metadata,"domain_identity")),
                    "scba_rows"=>Int(read_attribute(metadata,"scba_rows")),
                    "scba_sequence_first"=>length(file["scba/sequence"])==0 ? nothing : Int(file["scba/sequence"][1]),
                    "scba_sequence_last"=>length(file["scba/sequence"])==0 ? nothing : Int(file["scba/sequence"][length(file["scba/sequence"])]),
                    "outer_rows"=>Int(read_attribute(metadata,"outer_rows")),
                ))
            end
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
