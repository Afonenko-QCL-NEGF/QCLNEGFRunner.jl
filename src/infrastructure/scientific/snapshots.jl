"""Read a frozen plan without accessing its original definition files."""
function load_scientific_plan(path::AbstractString)
    data=_mapping_input(YAML.load_file(path; dicttype = Dict{String,Any}), "plan")
    return load_scientific_plan(data)
end
function load_scientific_plan(data::AbstractDict)
    get(data, "schema", nothing)=="qcl-negf-scientific-plan-v2" ||
        throw(ArgumentError("unsupported scientific plan schema"))
    get(data,"resolved_snapshot_schema",nothing)==_RESOLVED_SNAPSHOT_SCHEMA ||
        throw(ArgumentError("unsupported resolved snapshot schema"))
    all(e->e isa AbstractDict && haskey(e,"resolved_snapshot"),get(data,"executions",Any[])) ||
        throw(ArgumentError("missing resolved snapshot"))
    get(data, "fingerprint", nothing)==_plan_fingerprint(data) ||
        throw(ArgumentError("frozen scientific plan fingerprint mismatch"))
    get(data, "scientific_fingerprint", nothing)==_scientific_fingerprint(data) ||
        throw(ArgumentError("scientific identity mismatch"))
    executions=ScientificExecution{ResolvedRunConfiguration}[]
    for raw in _vector_input(data["executions"], "executions")
        item=_mapping_input(raw, "execution")
        _scientific_identity(String(item["id"]), "execution id")
        Int(item["estimated_peak_bytes"])>=0 ||
            throw(ArgumentError("negative scientific memory estimate"))
        configuration=_mapping_input(
            item["resolved_configuration"],
            "resolved_configuration",
        )
        sources=Dict{String,Vector{String}}(
            String(k)=>String.(v) for
            (k, v) in get(get(item, "provenance", Dict()), "sources", Dict())
        )
        policy=_parse_scientific_outputs(_scientific_output_input(item))
        get(get(configuration,"output",Dict()),"save_full_state",nothing)==true ||
            throw(ArgumentError("resolved scientific configuration conflicts with mandatory full_final archive"))
        config=_resolve_configuration(
            configuration,
            ConfigurationProvenance(String[], String[], sources),
        )
        isequal(get(item,"resolved_snapshot",nothing),
            resolved_snapshot_dict(resolved_configuration_snapshot(config))) ||
            throw(ArgumentError("resolved snapshot differs from actual inputs/rules"))
        get(item, "effective_inputs", nothing)==_effective_scientific_inputs(config) ||
            throw(
                ArgumentError(
                    "effective scientific inputs differ from resolved configuration",
                ),
            )
        operation=Symbol(item["operation"])
        receipt=get(item,"resource_estimate",nothing)
        receipt isa AbstractDict || throw(ArgumentError("missing scientific resource estimate"))
        capacity=get(receipt,"worker_capacity",1)
        capacity isa Integer && !(capacity isa Bool) && capacity>=1 ||
            throw(ArgumentError("invalid estimate planning worker capacity"))
        expected=_scientific_estimate_receipt(config,operation;worker_capacity=capacity)
        isequal(receipt,expected) || throw(ArgumentError("scientific resource estimate differs from inputs/basis"))
        if operation===:stationary
            item["estimated_peak_bytes"]==receipt["estimated_numerical_peak_bytes"] ||
                throw(ArgumentError("scientific numerical estimate differs"))
        end
        push!(
            executions,
            ScientificExecution(
                String(item["id"]),
                String(item["definition_id"]),
                String(item["variant_id"]),
                String(item["method_id"]),
                String.(item["point_ids"]),
                config,
                _parse_scientific_policies(item["policies"]),
                policy,
                Int(item["estimated_peak_bytes"]),
                Symbol(item["purpose"]),
                Int(item["repetition"]),
                operation,
                String(item["label"]),
                deepcopy(receipt),
            ),
        )
    end
    points=ScientificPoint[
        ScientificPoint(
            String(p["id"]),
            String(p["execution_id"]),
            p["temperature_K"],
            p["voltage_per_period_V"],
            String(p["branch"]),
            Int(p["order"]),
            p["predecessor_id"]===nothing ? nothing : String(p["predecessor_id"]),
            Symbol(p["initialization"]),
        ) for p in data["points"]
    ]
    for (point, raw) in zip(points, data["points"])
        config=only(e.configuration for e in executions if e.id==point.execution_id)
        get(raw, "effective_inputs", nothing)==_point_passport(config, point) || throw(
            ArgumentError("effective point passport differs from actual scientific axes"),
        )
    end
    inclusions=ScientificInclusion[
        ScientificInclusion(
            String(i["id"]),
            String(i["definition_id"]),
            i["parent_id"]===nothing ? nothing : String(i["parent_id"]),
            String.(i["path"]),
            String.(i["execution_ids"]),
            String(i["label"]),
        ) for i in data["inclusions"]
    ]
    point_ids=Set(p.id for p in points)
    execution_ids=Set(e.id for e in executions)
    inclusion_ids=Set(i.id for i in inclusions)
    length(point_ids)==length(points) &&
    length(execution_ids)==length(executions) &&
    length(inclusion_ids)==length(inclusions) ||
        throw(ArgumentError("duplicate frozen plan identity"))
    previous=Set{String}()
    for p in points
        p.execution_id in execution_ids ||
            throw(ArgumentError("point references unknown execution"))
        p.predecessor_id===nothing ||
            p.predecessor_id in previous ||
            throw(ArgumentError("point continuation is missing or out of order"))
        if p.predecessor_id!==nothing
            predecessor=only(q for q in points if q.id==p.predecessor_id)
            predecessor.execution_id==p.execution_id &&
            predecessor.branch==p.branch &&
            predecessor.temperature_K==p.temperature_K || throw(
                ArgumentError("continuation crosses execution, branch or temperature"),
            )
        end
        push!(previous, p.id)
    end
    for e in executions
        Set(e.point_ids)==Set(p.id for p in points if p.execution_id==e.id) ||
            throw(ArgumentError("execution point membership mismatch"))
    end
    for i in inclusions
        all(id->id in execution_ids, i.execution_ids) ||
            throw(ArgumentError("inclusion references unknown execution"))
        i.parent_id===nothing ||
            i.parent_id in inclusion_ids ||
            throw(ArgumentError("inclusion parent missing"))
    end
    length(points)==Int(data["computation_count"]) &&
    length(points)<=Int(data["maximum_solver_runs"]) ||
        throw(ArgumentError("plan computation count/limit mismatch"))
    get(data, "campaign", nothing) === nothing ||
        throw(ArgumentError("plan campaign policy belongs to AiiDA"))
    nodes=ScientificExecutionNode[]
    for n in _vector_input(data["nodes"], "nodes")
        push!(
            nodes,
            ScientificExecutionNode(
                String(n["execution_id"]),
                String(n["stage_id"]),
                String.(n["depends_on"]),
                String.(n["required_evidence"]),
                String.(n["forbidden_evidence"]),
                Int(n["priority"]),
                _boolean_input(n["reserve"], "reserve"),
                Int(n["estimated_memory_bytes"]),
                n["comparison_reference"]===nothing ? nothing :
                String(n["comparison_reference"]),
                Symbol(n["comparison_kind"]),
                String.(n["controlled_paths"]),
                String(n["comparable_fingerprint"]),
            ),
        )
    end
    _validate_execution_nodes(nodes, executions)
    for n in nodes
        execution=only(e for e in executions if e.id==n.execution_id)
        _comparable_fingerprint(execution.configuration, n.controlled_paths)==n.comparable_fingerprint ||
            throw(ArgumentError("comparison fingerprint mismatch"))
        n.estimated_memory_bytes==execution.estimated_peak_bytes ||
            throw(ArgumentError("execution memory estimate mismatch"))
    end
    return ScientificPlan(
        String(data["root_definition_id"]),
        Symbol(data["root_kind"]),
        String(data["name"]),
        String(data["fingerprint"]),
        Int(data["maximum_solver_runs"]),
        inclusions,
        executions,
        points,
        nodes,
    )
end

function _load_scientific_plan_bytes(path::AbstractString)
    isfile(path) && !islink(path) || throw(ArgumentError("scientific plan must be a regular non-symlink file"))
    bytes=open(path,"r") do io
        before=stat(io)
        same(st)=(st.device,st.inode,st.size,st.mtime,st.ctime)
        same(before)==same(stat(path)) || throw(ArgumentError("scientific plan path rebound"))
        data=read(io,CONFIGURATOR_PLAN_BYTES+1)
        !islink(path) && same(before)==same(stat(io))==same(stat(path)) ||
            throw(ArgumentError("scientific plan changed during capture"))
        data
    end
    length(bytes)<=CONFIGURATOR_PLAN_BYTES || throw(ArgumentError("scientific plan exceeds byte limit"))
    text=String(copy(bytes))
    isvalid(text) || throw(ArgumentError("scientific plan is not valid UTF-8"))
    document=_mapping_input(_configurator_json(text;maximum=CONFIGURATOR_PLAN_BYTES),"plan")
    plan=load_scientific_plan(document)
    capture=_P05PlanCapture((:scientific_plan_v2,bytes,document,bytes2hex(sha256(bytes))))
    return (plan=plan,bytes=bytes,capture=capture)
end

# Freeze the selected plan bytes once; semantic equality cannot replace byte identity.
function _freeze_scientific_plan(plan::ScientificPlan, root::AbstractString;
    frozen_plan_bytes::Union{Nothing,Vector{UInt8}}=nothing,
    frozen_plan_capture::Union{Nothing,_P05PlanCapture}=nothing)
    frozen_plan_bytes===nothing || frozen_plan_capture===nothing || throw(ArgumentError("choose one frozen plan source"))
    path=joinpath(root,"scientific_plan.json")
    islink(path) && throw(ArgumentError("scientific plan path cannot be a symlink"))
    function bounded_bytes(path)
        isfile(path) && !islink(path) || throw(ArgumentError("scientific plan must be a regular non-symlink file"))
        data=open(path,"r") do io
            stamp(s)=(s.device,s.inode,s.size,s.mtime,s.ctime)
            before=stamp(stat(io))
            before==stamp(stat(path)) || throw(ArgumentError("scientific plan path rebound"))
            bytes=read(io,CONFIGURATOR_PLAN_BYTES+1)
            !islink(path) && before==stamp(stat(io))==stamp(stat(path)) ||
                throw(ArgumentError("scientific plan changed during capture"))
            bytes
        end
        length(data)<=CONFIGURATOR_PLAN_BYTES || throw(ArgumentError("scientific plan exceeds byte limit"))
        return data
    end
    selected = if frozen_plan_capture !== nothing
        frozen_plan_capture.kind===:scientific_plan_v2 || throw(ArgumentError("wrong frozen plan kind"))
        frozen_plan_capture.bytes
    elseif frozen_plan_bytes !== nothing
        length(frozen_plan_bytes)<=CONFIGURATOR_PLAN_BYTES || throw(ArgumentError("scientific plan exceeds byte limit"))
        copy(frozen_plan_bytes)
    elseif isfile(path)
        bounded_bytes(path)
    else
        Vector{UInt8}(codeunits(sprint(write_scientific_plan,plan)))
    end
    length(selected)<=CONFIGURATOR_PLAN_BYTES || throw(ArgumentError("scientific plan exceeds byte limit"))
    text=String(copy(selected))
    isvalid(text) || throw(ArgumentError("scientific plan is not valid UTF-8"))
    document=_mapping_input(_configurator_json(text;maximum=CONFIGURATOR_PLAN_BYTES),"plan")
    if frozen_plan_capture !== nothing
        bytes2hex(sha256(selected))==frozen_plan_capture.plan_sha256 || throw(ArgumentError("frozen plan bytes changed"))
        canonical_bytes(document)==canonical_bytes(frozen_plan_capture.document) || throw(ArgumentError("frozen plan document changed"))
    end
    bound=load_scientific_plan(document)
    expected=load_scientific_plan(scientific_plan_dict(plan))
    canonical_bytes(scientific_plan_dict(bound))==canonical_bytes(scientific_plan_dict(expected)) ||
        throw(ArgumentError("frozen plan differs from selected plan"))
    if isfile(path)
        existing=bounded_bytes(path)
        bytes2hex(sha256(existing))==bytes2hex(sha256(selected)) ||
            throw(ArgumentError("output directory has different frozen plan bytes"))
    else
        _observability_atomic_text(path) do io
            write(io,selected)
        end
    end
    return _P05PlanCapture((:scientific_plan_v2,selected,document,bytes2hex(sha256(selected))))
end

function _scientific_json(path, data)
    _observability_atomic_text(path) do io
        _light_json(io, data)
        println(io)
    end
    return abspath(path)
end
function _scientific_result_dict(result::ScientificPointResult)
    return Dict{String,Any}(
        String(key)=>getfield(result, key) for key in fieldnames(ScientificPointResult)
    )
end
function _series_document(plan, results, status)
    return Dict{String,Any}(
        "schema"=>"qcl-negf-series-result-v4",
        "contract_set"=>"qcl-negf.results.v2",
        "plan_fingerprint"=>plan.fingerprint,
        "plan_scientific_fingerprint"=>scientific_plan_dict(plan)["scientific_fingerprint"],
        "root_definition_id"=>plan.root_definition_id,
        "name"=>plan.name,
        "status"=>String(status),
        "model_version"=>_core_package_version(),
        "inclusions"=>_inclusion_dict.(plan.inclusions),
        "executions"=>[
            Dict(
                "id"=>e.id,
                "definition_id"=>e.definition_id,
                "variant_id"=>e.variant_id,
                "method_id"=>e.method_id,
                "point_ids"=>e.point_ids,
                "purpose"=>String(e.purpose),
                "repetition"=>e.repetition,
                "label"=>e.label,
                "operation"=>String(e.operation),
            ) for e in plan.executions
        ],
        "expected_point_count"=>length(plan.points),
        "available_point_count"=>length(results),
        "points"=>_scientific_result_dict.(results),
    )
end
# Version pairs are independent formats; never relabel an existing payload.
function _scientific_result_pair_supported(result)
    (get(result,"schema",nothing),get(result,"contract_set",nothing)) in (
        ("qcl-negf-series-result-v3","qcl-negf.results.v1"),
        ("qcl-negf-series-result-v4","qcl-negf.results.v2"))
end
function _read_series(directory)
    path=isdir(directory) ? joinpath(directory, "series_result.json") : directory
    isfile(path) || throw(
        ArgumentError(
            "committed scientific series is absent; expected legacy v3/v1 or native v4/v2",
        ),
    )
    data=_mapping_input(YAML.load_file(path; dicttype = Dict{String,Any}), "series result")
    _scientific_result_pair_supported(data) ||
        throw(ArgumentError("unsupported series result schema"))
    return data, dirname(abspath(path))
end
function _result_path(root, path)
    path isa AbstractString || throw(ArgumentError("result artifact path must be a string"))
    candidate=abspath(joinpath(root, path))
    relative=relpath(candidate, abspath(root))
    (relative==".." || startswith(relative, ".."*string(Base.Filesystem.path_separator))) &&
        throw(ArgumentError("result artifact escapes its root"))
    isfile(candidate) || throw(ArgumentError("required saved data is missing: $path"))
    return candidate
end

"""Write the public serialized plan contract to an IO stream."""
function write_scientific_plan(io::IO, plan::ScientificPlan)
    _light_json(io, scientific_plan_dict(plan))
    println(io)
    return nothing
end
"""Write a checked public result envelope; scientific status remains in its payload."""
function write_scientific_result(io::IO, result::AbstractDict)
    _scientific_result_pair_supported(result) ||
        throw(ArgumentError("unsupported scientific result schema"))
    _light_json(io, result)
    println(io)
    return nothing
end
