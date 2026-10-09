function _scientific_identity(value::String, label::String)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", value) ||
        throw(ArgumentError("$label is not a portable scientific identity"))
    return value
end

"""Named voltage continuation, separate from inner SCBA→Poisson permission.

New executable plans support `:independent` (default) or `:strict` predecessors.
Legacy finite `:research` predecessors are retired, including typed frozen-plan
load and resume. Create a new explicitly selected plan; do not migrate its identity.
"""
struct VoltageContinuation
    mode::Symbol
    invalid_predecessor::Symbol
    function VoltageContinuation(
        mode::Symbol = :independent,
        invalid_predecessor::Symbol = :stop_branch,
    )
        mode===:research && throw(ArgumentError(
            "voltage continuation :research retired: legacy finite predecessor policy; create a new explicit :independent or :strict plan",
        ))
        mode in (:independent, :strict) ||
            throw(ArgumentError("unknown voltage continuation: $mode"))
        invalid_predecessor in (:stop_branch, :skip, :cold_start) ||
            throw(ArgumentError("invalid predecessor policy: $invalid_predecessor"))
        new(mode, invalid_predecessor)
    end
end

struct ScientificPolicies
    scba_to_poisson::Symbol
    voltage::VoltageContinuation
    on_child_failure::Symbol
    function ScientificPolicies(
        scba::Symbol = :research_continue,
        voltage::VoltageContinuation = VoltageContinuation(),
        failure::Symbol = :continue,
    )
        scba in (:research_continue, :strict_fail_fast, :adaptive_working) ||
            throw(ArgumentError("unknown SCBA continuation policy"))
        failure in (:continue, :stop) ||
            throw(ArgumentError("on_child_failure must be continue or stop"))
        new(scba, voltage, failure)
    end
end

struct RecoveryOutputPolicy
    enabled::Bool
    interval_seconds::Float64
    retain_generations::Int
    byte_budget::Int
    reserve_bytes::Int
end
struct TelemetryOutputPolicy
    enabled::Bool
    buffer_events::Int
end

"""One scientific archive policy with independent operational recovery and telemetry."""
struct ScientificOutputs
    full_state::Bool
    optical::Bool
    projections::Bool
    intermediate_history::Int
    recovery::RecoveryOutputPolicy
    telemetry::TelemetryOutputPolicy
    function ScientificOutputs(
        full_state::Bool = true,
        optical::Bool = false,
        projections::Bool = true,
        history::Int = 16;
        recovery = RecoveryOutputPolicy(true, 1800.0, 2, 8*1024^3, 64*1024^2),
        telemetry = TelemetryOutputPolicy(true, 256),
    )
        history>=1 || throw(ArgumentError("intermediate_history must be positive"))
        isfinite(recovery.interval_seconds) && recovery.interval_seconds>0 ||
            throw(ArgumentError("recovery interval must be finite and positive"))
        recovery.retain_generations>=2 || throw(ArgumentError("recovery needs latest and previous generations"))
        recovery.byte_budget>0 && 0<=recovery.reserve_bytes<recovery.byte_budget ||
            throw(ArgumentError("recovery byte budget must exceed its nonnegative reserve"))
        telemetry.buffer_events>0 || throw(ArgumentError("telemetry buffer_events must be positive"))
        new(true, optical, projections, history, recovery, telemetry)
    end
end

"""A typed operating point; branch/order distinguish repeated visits to the same bias."""
struct ScientificPoint
    id::String
    execution_id::String
    temperature_K::Float64
    voltage_per_period_V::Float64
    branch::String
    order::Int
    predecessor_id::Union{Nothing,String}
    initialization::Symbol
    function ScientificPoint(
        id::String,
        execution::String,
        T::Real,
        V::Real,
        branch::String,
        order::Int,
        predecessor::Union{Nothing,String},
        initialization::Symbol,
    )
        _scientific_identity(id, "point id")
        _scientific_identity(execution, "execution id")
        predecessor===nothing || _scientific_identity(predecessor, "predecessor id")
        isempty(branch) && throw(ArgumentError("branch must not be empty"))
        all(isfinite, (T, V)) && T>0 && V>=0 ||
            throw(ArgumentError("operating coordinates must be finite, T>0 and V>=0"))
        order>0 || throw(ArgumentError("point order must be positive"))
        initialization in (:cold, :predecessor) ||
            throw(ArgumentError("invalid point initialization"))
        (initialization===:predecessor)==(predecessor!==nothing) ||
            throw(ArgumentError("initialization/predecessor mismatch"))
        new(
            id,
            execution,
            Float64(T),
            Float64(V),
            branch,
            order,
            predecessor,
            initialization,
        )
    end
end

struct ScientificExecution{C}
    id::String
    definition_id::String
    variant_id::String
    method_id::String
    point_ids::Vector{String}
    configuration::C
    policies::ScientificPolicies
    outputs::ScientificOutputs
    estimated_peak_bytes::Int
    purpose::Symbol
    repetition::Int
    operation::Symbol
    label::String
end

struct ScientificInclusion
    id::String
    definition_id::String
    parent_id::Union{Nothing,String}
    path::Vector{String}
    execution_ids::Vector{String}
    label::String
end

struct ScientificExecutionNode
    execution_id::String
    stage_id::String
    depends_on::Vector{String}
    required_evidence::Vector{String}
    forbidden_evidence::Vector{String}
    priority::Int
    reserve::Bool
    estimated_memory_bytes::Int
    comparison_reference::Union{Nothing,String}
    comparison_kind::Symbol
    controlled_paths::Vector{String}
    comparable_fingerprint::String
end

struct ScientificPlan{C}
    root_definition_id::String
    root_kind::Symbol
    name::String
    fingerprint::String
    maximum_solver_runs::Int
    inclusions::Vector{ScientificInclusion}
    executions::Vector{ScientificExecution{C}}
    points::Vector{ScientificPoint}
    nodes::Vector{ScientificExecutionNode}
end

abstract type AbstractScientificDefinitionRepository end
function read_scientific_definition end
function resolve_scientific_configuration end
function scientific_memory_estimate end

"""Structured result preserves technical status separately from the scientific verdict."""
struct ScientificPointResult
    id::String
    execution_id::String
    attempt::Int
    coordinates::NamedTuple{
        (:temperature_K, :voltage_per_period_V, :branch, :order),
        Tuple{Float64,Float64,String,Int},
    }
    initialization::NamedTuple{
        (:kind, :source_point_id, :checkpoint, :fallback_reason),
        Tuple{String,Union{Nothing,String},Union{Nothing,String},Union{Nothing,String}},
    }
    status::Symbol
    quality::Symbol
    converged::Bool
    warnings::Vector{Dict{String,Any}}
    observables::Dict{String,Any}
    data::Dict{String,Any}
    postprocessing::Dict{String,Any}
end

struct ScientificVariant
    id::String
    method_id::String
    overrides::Dict{String,Any}
    controlled_paths::Vector{String}
    comparison_kind::Symbol
end
struct ScientificBranch
    id::String
    voltages::Vector{Float64}
end
struct ScientificChild
    source::String
    overrides::Dict{String,Any}
end
struct ScientificDefinition
    source::String
    id::String
    name::String
    kind::Symbol
    tags::Vector{String}
    children::Vector{ScientificChild}
    configuration_sources::Vector{String}
    overrides::Dict{String,Any}
    variants::Vector{ScientificVariant}
    temperatures::Vector{Float64}
    branches::Vector{ScientificBranch}
    policies::ScientificPolicies
    outputs::ScientificOutputs
    purpose::Symbol
    repetitions::Int
    operation::Symbol
end

function _merge_scientific!(destination::Dict{String,Any}, incoming::AbstractDict)
    for (key, value) in incoming
        name=String(key)
        if value isa AbstractDict && get(destination, name, nothing) isa AbstractDict
            _merge_scientific!(destination[name], value)
        else
            destination[name]=deepcopy(value)
        end
    end
    return destination
end
