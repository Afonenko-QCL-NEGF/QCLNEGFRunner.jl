_policies_dict(p::ScientificPolicies) = Dict(
    "scba_to_poisson"=>String(p.scba_to_poisson),
    "voltage"=>Dict(
        "mode"=>String(p.voltage.mode),
        "invalid_predecessor"=>String(p.voltage.invalid_predecessor),
    ),
    "on_child_failure"=>String(p.on_child_failure),
)
_outputs_dict(o::ScientificOutputs) = Dict(
    "archive"=>Dict("full_final"=>true,"optical"=>o.optical,"projections"=>o.projections,
        "intermediate_history"=>o.intermediate_history),
    "recovery"=>Dict("enabled"=>o.recovery.enabled,"interval_seconds"=>o.recovery.interval_seconds,
        "retain_generations"=>o.recovery.retain_generations,"byte_budget"=>o.recovery.byte_budget,
        "reserve_bytes"=>o.recovery.reserve_bytes),
    "telemetry"=>Dict("enabled"=>o.telemetry.enabled,"buffer_events"=>o.telemetry.buffer_events),
)
_point_dict(p::ScientificPoint) = Dict(
    "id"=>p.id,
    "execution_id"=>p.execution_id,
    "temperature_K"=>p.temperature_K,
    "voltage_per_period_V"=>p.voltage_per_period_V,
    "branch"=>p.branch,
    "order"=>p.order,
    "predecessor_id"=>p.predecessor_id,
    "initialization"=>String(p.initialization),
)
_inclusion_dict(i::ScientificInclusion) = Dict(
    "id"=>i.id,
    "definition_id"=>i.definition_id,
    "parent_id"=>i.parent_id,
    "path"=>i.path,
    "execution_ids"=>i.execution_ids,
    "label"=>i.label,
)

function _node_dict(n::ScientificExecutionNode)
    return Dict{String,Any}(
        String(k)=>(getfield(n, k) isa Symbol ? String(getfield(n, k)) : getfield(n, k)) for
        k in fieldnames(ScientificExecutionNode)
    )
end
function _effective_scientific_inputs(configuration)
    seed=effective_seed_parameters(configuration.numerical, configuration.scales)
    return Dict{String,Any}(
        "seed"=>Dict(String(k)=>(v isa Symbol ? String(v) : v) for (k, v) in pairs(seed)),
        "energy_shift"=>String(configuration.algorithms.energy_shift),
        "energy_nodes"=>configuration.numerical.N_E,
        "energy_min_eV"=>Float64(ustrip(u"eV", configuration.numerical.E_min)),
        "energy_max_eV"=>Float64(ustrip(u"eV", configuration.numerical.E_max)),
    )
end

"""Resolve physical axes into a point passport; execution templates may span a branch."""
function _point_resolved_raw(configuration, point::ScientificPoint)
    raw=deepcopy(configuration.raw)
    physical=get!(raw, "physical", Dict{String,Any}())
    physical["voltage_per_period"]="$(point.voltage_per_period_V) V"
    physical["lattice_temperature"]="$(point.temperature_K) K"
    physical["lo_temperature"]="$(point.temperature_K) K"
    study=get!(raw, "study", Dict{String,Any}())
    study["voltages_per_period"]=["$(point.voltage_per_period_V) V"]
    study["temperatures"]=["$(point.temperature_K) K"]
    return raw
end
function _point_passport(configuration, point::ScientificPoint)
    return Dict{String,Any}(
        "temperature_K"=>point.temperature_K,
        "voltage_per_period_V"=>point.voltage_per_period_V,
        "configuration_hash"=>bytes2hex(
            sha256(canonical_bytes(_point_resolved_raw(configuration, point))),
        ),
        "hash_encoding"=>"qcl-negf-canonical-bytes-v1",
        "axes_applied"=>true,
    )
end

function scientific_plan_dict(plan::ScientificPlan)
    executions=[
        Dict(
            "id"=>e.id,
            "definition_id"=>e.definition_id,
            "variant_id"=>e.variant_id,
            "method_id"=>e.method_id,
            "point_ids"=>e.point_ids,
            "resolved_configuration"=>deepcopy(e.configuration.raw),
            "effective_inputs"=>_effective_scientific_inputs(e.configuration),
            "provenance"=>Dict("sources"=>e.configuration.provenance.sources),
            "policies"=>_policies_dict(e.policies),
            "output"=>_outputs_dict(e.outputs),
            "estimated_peak_bytes"=>e.estimated_peak_bytes,
            "purpose"=>String(e.purpose),
            "repetition"=>e.repetition,
            "operation"=>String(e.operation),
            "label"=>e.label,
        ) for e in plan.executions
    ]
    resources=Dict(
        "scheduling"=>"scheduler_execution_dag",
        "maximum_active_executions"=>length(plan.executions),
        "estimated_peak_bytes"=>maximum(
            (e.estimated_peak_bytes for e in plan.executions);
            init = 0,
        ),
        "minimum_output_bytes"=>_minimum_scientific_output_bytes(plan),
        "output_estimate_basis"=>"uncompressed native physical arrays; local full state is independent of the analytical archive budget",
    )
    data=Dict{String,Any}(
        "schema"=>"qcl-negf-scientific-plan-v2",
        "model_revision"=>"transport-contract-v2",
        "root_definition_id"=>plan.root_definition_id,
        "root_kind"=>String(plan.root_kind),
        "name"=>plan.name,
        "fingerprint"=>plan.fingerprint,
        "maximum_solver_runs"=>plan.maximum_solver_runs,
        "computation_count"=>length(plan.points),
        "inclusions"=>_inclusion_dict.(plan.inclusions),
        "executions"=>executions,
        "points"=>[
            merge(
                _point_dict(p),
                Dict(
                    "effective_inputs"=>_point_passport(
                        only(
                            e.configuration for e in plan.executions if e.id==p.execution_id
                        ),
                        p,
                    ),
                ),
            ) for p in plan.points
        ],
        "science_archive_preflight"=>nothing,
        "resources"=>resources,
        "campaign"=>nothing,
        "nodes"=>_node_dict.(plan.nodes),
    )
    data["scientific_fingerprint"]=_scientific_fingerprint(data)
    return data
end

function _plan_fingerprint(data::AbstractDict)
    canonical=deepcopy(data)
    pop!(canonical, "fingerprint", nothing)
    return bytes2hex(sha256(canonical_bytes(canonical)))
end

function _comparison_inputs(configuration, controlled_paths::Vector{String})
    data=deepcopy(configuration.raw)
    for key in ("run", "output", "study")
        pop!(data, key, nothing)
    end
    for path in controlled_paths
        occursin(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$", path) ||
            throw(ArgumentError("invalid controlled path: $path"))
        parts=split(path, '.')
        current=data
        first(parts) in ("run", "output", "study") &&
            throw(ArgumentError("presentation is not a scientific controlled axis"))
        for part in parts[1:(end-1)]
            current=get(current, part, nothing)
            current isa AbstractDict || break
        end
        current isa AbstractDict && pop!(current, last(parts), nothing)
    end
    return data
end
function _comparable_fingerprint(configuration, paths)
    return bytes2hex(sha256(canonical_bytes(_comparison_inputs(configuration, paths))))
end
function _validate_controlled_variant(base, config, variant)
    variant.comparison_kind in (
        :controlled_axis,
        :discretization,
        :representation,
        :boundary_model,
        :physical_model,
        :physical_parameter,
        :initialization,
    ) || throw(ArgumentError("unknown variant comparison kind"))
    _comparison_inputs(base, variant.controlled_paths)==_comparison_inputs(
        config,
        variant.controlled_paths,
    ) || throw(
        ArgumentError(
            "variant $(variant.id) changes undeclared physical, numerical or acceptance inputs",
        ),
    )
end
function _validate_execution_nodes(nodes, executions)
    ids=Set(e.id for e in executions)
    Set(n.execution_id for n in nodes)==ids && length(nodes)==length(ids) ||
        throw(ArgumentError("every execution requires exactly one execution record"))
    for n in nodes
        n.stage_id == "standalone" && isempty(n.depends_on) &&
        isempty(n.required_evidence) && isempty(n.forbidden_evidence) &&
        n.priority == 0 && !n.reserve && n.comparison_reference === nothing ||
            throw(ArgumentError("execution scheduling belongs to AiiDA; only independent nodes are accepted"))
    end
    return nothing
end

"""Build immutable independent executions using repository/configuration ports.

Repeated inclusions keep their own identity. Executions are shared only within this
root, and only when complete resolved inputs, policies, outputs, initial state,
point order and continuation dependencies coincide. Explicit repeats never share.
"""
function resolve_scientific_plan(
    repository::AbstractScientificDefinitionRepository,
    source::AbstractString;
    maximum_solver_runs::Int = 10000,
)
    maximum_solver_runs>0 || throw(ArgumentError("maximum_solver_runs must be positive"))
    root=read_scientific_definition(repository, String(source))
    inclusions=ScientificInclusion[]
    executions=ScientificExecution{ResolvedRunConfiguration}[]
    points=ScientificPoint[]
    owners=Dict{String,String}()
    specs=Dict{String,ScientificVariant}()
    function expand(
        definition,
        parent,
        path,
        active,
        inherited_overrides = Dict{String,Any}(),
    )
        key=definition.source
        key in active &&
            throw(ArgumentError("meta inclusion cycle: "*join(vcat(active, key), " -> ")))
        inclusion_id="inclusion-$(length(inclusions)+1)"
        inclusion_path=vcat(path, definition.id)
        inclusion=ScientificInclusion(
            inclusion_id,
            definition.id,
            parent,
            inclusion_path,
            String[],
            definition.name,
        )
        push!(inclusions, inclusion)
        if definition.kind===:meta
            for child in definition.children
                child_definition=read_scientific_definition(repository, child.source)
                overrides=deepcopy(inherited_overrides)
                _merge_scientific!(overrides, child.overrides)
                before=length(inclusions)
                expand(
                    child_definition,
                    inclusion_id,
                    inclusion_path,
                    vcat(active, key),
                    overrides,
                )
                append!(inclusion.execution_ids, inclusions[before+1].execution_ids)
            end
            unique!(inclusion.execution_ids)
            return
        end
        base_variant=ScientificVariant(
            "comparison-baseline",
            "configured",
            Dict{String,Any}(),
            String[],
            :controlled_axis,
        )
        base=resolve_scientific_configuration(
            repository,
            definition,
            base_variant,
            inherited_overrides,
        )
        # A queue unit is one independent point or one complete continuation branch.
        units=definition.policies.voltage.mode===:independent ?
              [
            ScientificBranch(b.id, [voltage]) for b in definition.branches for
            voltage in b.voltages
        ] : definition.branches
        for variant in definition.variants,
            repeat = 1:definition.repetitions,
            (temperature_index, T) in enumerate(definition.temperatures),
            branch in units

            config=resolve_scientific_configuration(
                repository,
                definition,
                variant,
                inherited_overrides,
            )
            _validate_controlled_variant(base, config, variant)
            identity=Dict(
                "configuration"=>deepcopy(config.raw),
                "policies"=>_policies_dict(definition.policies),
                "output"=>_outputs_dict(definition.outputs),
                "branch"=>Dict("id"=>branch.id, "voltages"=>branch.voltages),
                "temperature"=>T,
                "purpose"=>String(definition.purpose),
                "operation"=>String(definition.operation),
            )
            identity["configuration"]["run"]["name"]="scientific-execution"
            identity["configuration"]["run"]["description"]=""
            identity["configuration"]["output"]["directory"]="result"
            definition.repetitions>1 && (identity["explicit_repeat"]=[inclusion_id, repeat])
            # Requested sub-grid seeds can name the same actual numerical state.
            # Keep requested inputs in the frozen execution, but share work only
            # after canonicalizing the effective seed used by the solver.
            effective=effective_seed_parameters(config.numerical, config.scales)
            identity["configuration"]["numerical"]["seed_broadening"]="$(effective.effective_eV) eV"
            fingerprint=bytes2hex(sha256(canonical_bytes(identity)))
            if haskey(owners, fingerprint)
                push!(inclusion.execution_ids, owners[fingerprint])
                continue
            end
            execution_id="execution-$(length(executions)+1)"
            ids=String[]
            previous=nothing
            for (order, V) in enumerate(branch.voltages)
                point_id="point-$(length(points)+1)"
                predecessor=definition.policies.voltage.mode===:independent ? nothing :
                            previous
                push!(
                    points,
                    ScientificPoint(
                        point_id,
                        execution_id,
                        T,
                        V,
                        "T$(temperature_index)/"*branch.id,
                        order,
                        predecessor,
                        predecessor===nothing ? :cold : :predecessor,
                    ),
                )
                push!(ids, point_id)
                previous=point_id
                length(points)<=maximum_solver_runs || throw(
                    ArgumentError(
                        "scientific plan exceeds maximum_solver_runs=$maximum_solver_runs",
                    ),
                )
            end
            push!(
                executions,
                ScientificExecution(
                    execution_id,
                    definition.id,
                    variant.id,
                    variant.method_id,
                    ids,
                    config,
                    definition.policies,
                    definition.outputs,
                    definition.operation===:stationary ?
                    scientific_memory_estimate(repository, config) : 0,
                    definition.purpose,
                    repeat,
                    definition.operation,
                    definition.name*" / "*variant.id,
                ),
            )
            owners[fingerprint]=execution_id
            specs[execution_id]=variant
            push!(inclusion.execution_ids, execution_id)
        end
    end
    expand(root, nothing, String[], String[])
    nodes=ScientificExecutionNode[]
    for e in executions
        variant=specs[e.id]
        push!(
            nodes,
            ScientificExecutionNode(
                e.id,
                "standalone",
                String[],
                String[],
                String[],
                0,
                false,
                e.estimated_peak_bytes,
                nothing,
                variant.comparison_kind,
                variant.controlled_paths,
                _comparable_fingerprint(e.configuration, variant.controlled_paths),
            ),
        )
    end
    _validate_execution_nodes(nodes, executions)
    provisional=ScientificPlan(
        root.id,
        root.kind,
        root.name,
        "",
        maximum_solver_runs,
        inclusions,
        executions,
        points,
        nodes,
    )
    return ScientificPlan(
        root.id,
        root.kind,
        root.name,
        _plan_fingerprint(scientific_plan_dict(provisional)),
        maximum_solver_runs,
        inclusions,
        executions,
        points,
        nodes,
    )
end


function _minimum_scientific_output_bytes(plan::ScientificPlan)
    total=0
    for execution in plan.executions
        execution.operation===:stationary || continue
        n=execution.configuration.numerical
        count=length(execution.point_ids)
        if execution.outputs.full_state
            # Four complex Green arrays, Hartree/density and explicit axes are required.
            total=Base.checked_add(
                total,
                Base.checked_mul(count, 64*n.N_E*n.N_k*n.N_b^2+8*(3n.N_z+n.N_E+n.N_k)),
            )
        end
        if execution.outputs.projections
            # JSON has at least one byte per scalar; this is a lower bound, not a forecast.
            output=execution.configuration.output
            nz=min(n.N_z, output.light_max_space_points)
            ne=min(n.N_E, output.light_max_energy_points)
            nk=min(n.N_k, output.light_max_momentum_points)
            total=Base.checked_add(total, Base.checked_mul(count, 8nz+2ne*nk+4nz*n.N_b))
        end
    end
    return total
end


"""Stationary scientific identity excludes presentation, location and optical grids."""
function _scientific_fingerprint(data::AbstractDict)
    executions=Any[]
    for execution in data["executions"]
        inputs=deepcopy(execution["resolved_configuration"])
        for key in ("run", "output", "study")
            pop!(inputs, key, nothing)
        end
        push!(
            executions,
            Dict(
                "id"=>execution["id"],
                "inputs"=>inputs,
                "effective_inputs"=>execution["effective_inputs"],
                "policies"=>execution["policies"],
                "purpose"=>execution["purpose"],
                "repetition"=>execution["repetition"],
                "operation"=>execution["operation"],
            ),
        )
    end
    identity=Dict(
        "model_revision"=>data["model_revision"],
        "executions"=>executions,
        "points"=>[
            Dict(k=>v for (k, v) in point if k!="effective_inputs") for
            point in data["points"]
        ],
        "nodes"=>data["nodes"],
        "campaign"=>data["campaign"],
    )
    return bytes2hex(sha256(canonical_bytes(identity)))
end
