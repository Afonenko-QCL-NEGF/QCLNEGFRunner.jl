"""Read a frozen plan without accessing its original definition files."""
function load_scientific_plan(path::AbstractString)
    data=_mapping_input(YAML.load_file(path; dicttype = Dict{String,Any}), "plan")
    return load_scientific_plan(data)
end
function load_scientific_plan(data::AbstractDict)
    get(data, "schema", nothing)=="qcl-negf-scientific-plan-v2" ||
        throw(ArgumentError("unsupported scientific plan schema"))
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
        config=_resolve_configuration(
            configuration,
            ConfigurationProvenance(String[], String[], sources),
        )
        get(item, "effective_inputs", nothing)==_effective_scientific_inputs(config) ||
            throw(
                ArgumentError(
                    "effective scientific inputs differ from resolved configuration",
                ),
            )
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
                _parse_scientific_outputs(item["outputs"]),
                Int(item["estimated_peak_bytes"]),
                Symbol(item["purpose"]),
                Int(item["repetition"]),
                Symbol(item["operation"]),
                String(item["label"]),
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
        "schema"=>"qcl-negf-series-result-v3",
        "contract_set"=>"qcl-negf.results.v1",
        "plan_fingerprint"=>plan.fingerprint,
        "plan_scientific_fingerprint"=>scientific_plan_dict(plan)["scientific_fingerprint"],
        "root_definition_id"=>plan.root_definition_id,
        "name"=>plan.name,
        "status"=>String(status),
        "model_version"=>_software_version(),
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
function _read_series(directory)
    path=isdir(directory) ? joinpath(directory, "series_result.json") : directory
    isfile(path) || throw(
        ArgumentError(
            "committed scientific series is absent; expected qcl-negf.results.v1",
        ),
    )
    data=_mapping_input(YAML.load_file(path; dicttype = Dict{String,Any}), "series result")
    get(data, "contract_set", nothing)=="qcl-negf.results.v1" &&
    get(data, "schema", nothing)=="qcl-negf-series-result-v3" ||
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
    get(result, "contract_set", nothing)=="qcl-negf.results.v1" &&
    get(result, "schema", nothing)=="qcl-negf-series-result-v3" ||
        throw(ArgumentError("unsupported scientific result schema"))
    _light_json(io, result)
    println(io)
    return nothing
end
