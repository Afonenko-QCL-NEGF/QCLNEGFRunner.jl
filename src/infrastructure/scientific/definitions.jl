struct FilesystemScientificDefinitions <: AbstractScientificDefinitionRepository end

_mapping_input(value, label) =
    value isa AbstractDict ? Dict{String,Any}(String(k)=>v for (k, v) in value) :
    throw(ArgumentError("$label must be a mapping"))
_vector_input(value, label) =
    value isa AbstractVector ? value : throw(ArgumentError("$label must be a list"))
_string_input(value, label) =
    value isa AbstractString && !isempty(value) ? String(value) :
    throw(ArgumentError("$label must be a nonempty string"))
function _keys_input(value, allowed, label)
    unknown=setdiff(Set(String.(keys(value))), Set(allowed))
    isempty(unknown) || throw(
        ArgumentError("$label has unknown fields: "*join(sort!(collect(unknown)), ", ")),
    )
    return value
end
function _identifier_input(value, label)
    id=_string_input(value, label)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$", id) ||
        throw(ArgumentError("$label must be a portable identifier"))
    return id
end
function _boolean_input(value, label)
    value isa Bool || throw(ArgumentError("$label must be boolean"))
    return value
end
function _positive_integer(value, label)
    value isa Integer && !(value isa Bool) && value>0 ||
        throw(ArgumentError("$label must be a positive integer"))
    return Int(value)
end
function _axis_values(value, kind)
    data=_keys_input(
        _mapping_input(value, "$kind axis"),
        ("values", "start", "stop", "step", "unit", "question"),
        "$kind axis",
    )
    unit=_string_input(get(data, "unit", nothing), "$kind.unit")
    factor=kind===:temperature ?
           (unit=="K" ? 1.0 : throw(ArgumentError("temperature unit must be K"))) :
           (
        unit=="V" ? 1.0 :
        unit=="mV" ? 0.001 : throw(ArgumentError("voltage unit must be V or mV"))
    )
    values=if haskey(data, "values")
        any(haskey(data, k) for k in ("start", "stop", "step")) &&
            throw(ArgumentError("axis values and range are exclusive"))
        _vector_input(data["values"], "axis.values")
    else
        a, b, step=(get(data, k, nothing) for k in ("start", "stop", "step"))
        all(x->x isa Real && !(x isa Bool) && isfinite(x), (a, b, step)) ||
            throw(ArgumentError("range needs finite start, stop and step"))
        step!=0 && (b-a)*step>=0 ||
            throw(ArgumentError("axis range step has wrong direction"))
        abs((b-a)/step)<=100000 || throw(ArgumentError("axis range exceeds 100001 points"))
        collect(Float64(a):Float64(step):Float64(b))
    end
    !isempty(values) && all(x->x isa Real && !(x isa Bool) && isfinite(x), values) ||
        throw(ArgumentError("axis values must be nonempty finite numbers"))
    result=Float64.(values) .* factor
    all(x->kind===:temperature ? x>0 : x>=0, result) ||
        throw(ArgumentError("axis values outside physical range"))
    return result
end
function _parse_scientific_policies(raw)
    data=_keys_input(
        _mapping_input(raw, "policies"),
        ("scba_to_poisson", "voltage", "on_child_failure"),
        "policies",
    )
    voltage=_keys_input(
        _mapping_input(get(data, "voltage", Dict()), "policies.voltage"),
        ("mode", "invalid_predecessor"),
        "policies.voltage",
    )
    return ScientificPolicies(
        Symbol(get(data, "scba_to_poisson", "research_continue")),
        VoltageContinuation(
            Symbol(get(voltage, "mode", "independent")),
            Symbol(get(voltage, "invalid_predecessor", "stop_branch")),
        ),
        Symbol(get(data, "on_child_failure", "continue")),
    )
end
function _parse_scientific_outputs(raw)
    data=_mapping_input(raw, "output")
    legacy=any(haskey(data,key) for key in ("full_state","optical","projections","intermediate_history"))
    if legacy
        _keys_input(data,("full_state","optical","projections","intermediate_history"),"legacy outputs")
        @warn "legacy outputs migrated to output.archive; full_final is always true"
        haskey(data,"full_state") && _boolean_input(data["full_state"],"outputs.full_state")
        data=Dict{String,Any}("archive"=>Dict(key=>value for (key,value) in data if key!="full_state"))
    end
    _keys_input(data,("archive","recovery","telemetry"),"output")
    archive=_keys_input(_mapping_input(get(data,"archive",Dict()),"output.archive"),
        ("full_final","optical","projections","intermediate_history"),"output.archive")
    _boolean_input(get(archive,"full_final",true),"output.archive.full_final") ||
        throw(ArgumentError("output.archive.full_final must be true; every returned state is archived"))
    recovery=_keys_input(_mapping_input(get(data,"recovery",Dict()),"output.recovery"),
        ("enabled","interval_seconds","retain_generations","byte_budget","reserve_bytes"),"output.recovery")
    interval=get(recovery,"interval_seconds",1800.0)
    interval isa Real && !(interval isa Bool) && isfinite(interval) && interval>0 ||
        throw(ArgumentError("output.recovery.interval_seconds must be positive and finite"))
    reserve=get(recovery,"reserve_bytes",64*1024^2)
    reserve isa Integer && !(reserve isa Bool) && reserve>=0 ||
        throw(ArgumentError("output.recovery.reserve_bytes must be a nonnegative integer"))
    telemetry=_keys_input(_mapping_input(get(data,"telemetry",Dict()),"output.telemetry"),
        ("enabled","buffer_events"),"output.telemetry")
    return ScientificOutputs(true,
        _boolean_input(get(archive,"optical",false),"output.archive.optical"),
        _boolean_input(get(archive,"projections",true),"output.archive.projections"),
        _positive_integer(get(archive,"intermediate_history",16),"output.archive.intermediate_history");
        recovery=RecoveryOutputPolicy(
            _boolean_input(get(recovery,"enabled",true),"output.recovery.enabled"),Float64(interval),
            _positive_integer(get(recovery,"retain_generations",2),"output.recovery.retain_generations"),
            _positive_integer(get(recovery,"byte_budget",8*1024^3),"output.recovery.byte_budget"),Int(reserve)),
        telemetry=TelemetryOutputPolicy(
            _boolean_input(get(telemetry,"enabled",true),"output.telemetry.enabled"),
            _positive_integer(get(telemetry,"buffer_events",256),"output.telemetry.buffer_events")))
end
function _scientific_output_input(data)
    haskey(data,"output") && haskey(data,"outputs") &&
        throw(ArgumentError("output and legacy outputs are conflicting policy sources"))
    return get(data,"output",get(data,"outputs",Dict()))
end

function _scientific_children(source, data)
    children=ScientificChild[]
    for item in _vector_input(get(data, "includes", Any[]), "includes")
        child=item isa AbstractString ? Dict{String,Any}("source"=>item) :
              _mapping_input(item, "include")
        _keys_input(child, ("source", "overrides"), "include")
        path=abspath(
            joinpath(
                dirname(source),
                _string_input(get(child, "source", nothing), "include.source"),
            ),
        )
        isfile(path) || throw(ArgumentError("missing inclusion: $source -> $path"))
        push!(
            children,
            ScientificChild(
                path,
                _mapping_input(get(child, "overrides", Dict()), "include.overrides"),
            ),
        )
    end
    selector=get(data, "select", nothing)
    if selector!==nothing
        selection=_keys_input(
            _mapping_input(selector, "select"),
            ("directory", "recursive", "include_tags", "exclude_tags", "exclude_ids"),
            "select",
        )
        directory=abspath(
            joinpath(
                dirname(source),
                _string_input(get(selection, "directory", nothing), "select.directory"),
            ),
        )
        isdir(directory) ||
            throw(ArgumentError("selection directory does not exist: $directory"))
        include_tags=Set(
            String.(_vector_input(get(selection, "include_tags", Any[]), "include_tags")),
        )
        exclude_tags=Set(
            String.(_vector_input(get(selection, "exclude_tags", Any[]), "exclude_tags")),
        )
        exclude_ids=Set(
            String.(_vector_input(get(selection, "exclude_ids", Any[]), "exclude_ids")),
        )
        recursive=_boolean_input(get(selection, "recursive", true), "recursive")
        paths=String[]
        for (root, dirs, files) in walkdir(directory)
            recursive || empty!(dirs)
            for file in files
                endswith(file, ".yaml") || endswith(file, ".yml") || continue
                path=joinpath(root, file)
                realpath(path)==realpath(source) && continue
                document=YAML.load_file(path; dicttype = Dict{String,Any})
                document isa AbstractDict &&
                get(document, "schema", nothing)=="qcl-negf-study-v2" || continue
                get(document, "kind", nothing) in ("study", "meta") || continue
                tags=Set(String.(get(document, "tags", Any[])))
                isempty(include_tags) || !isempty(intersect(tags, include_tags)) || continue
                isempty(intersect(tags, exclude_tags)) || continue
                get(document, "id", nothing) in exclude_ids && continue
                push!(paths, path)
            end
        end
        append!(children, [ScientificChild(p, Dict{String,Any}()) for p in sort!(paths)])
    end
    isempty(children) &&
        throw(ArgumentError("meta definition $source has no executable children"))
    return children
end

function read_scientific_definition(::FilesystemScientificDefinitions, requested::String)
    isfile(requested) || throw(ArgumentError("scientific definition not found: $requested"))
    source=realpath(requested)
    data=_keys_input(
        _mapping_input(YAML.load_file(source; dicttype = Dict{String,Any}), source),
        (
            "schema",
            "kind",
            "id",
            "name",
            "description",
            "tags",
            "configuration",
            "variants",
            "axes",
            "policies",
            "output",
            "outputs",
            "includes",
            "select",
            "purpose",
            "repetitions",
            "operation",
        ),
        source,
    )
    get(data, "schema", nothing)=="qcl-negf-study-v2" ||
        throw(ArgumentError("unsupported scientific definition schema at $source"))
    kind=Symbol(get(data, "kind", "study"))
    kind in (:study, :meta) || throw(ArgumentError("kind must be study or meta"))
    id=_identifier_input(get(data, "id", nothing), "id")
    name=_string_input(get(data, "name", id), "name")
    tags=String.(_vector_input(get(data, "tags", Any[]), "tags"))
    policies=_parse_scientific_policies(get(data, "policies", Dict()))
    outputs=_parse_scientific_outputs(_scientific_output_input(data))
    if kind===:meta
        any(
            haskey(data, key) for
            key in ("configuration", "variants", "axes", "repetitions")
        ) && throw(ArgumentError("meta cannot define solver axes or variants"))
        return ScientificDefinition(
            source,
            id,
            name,
            kind,
            tags,
            _scientific_children(source, data),
            String[],
            Dict(),
            ScientificVariant[],
            Float64[],
            ScientificBranch[],
            policies,
            outputs,
            :research,
            1,
            :stationary,
        )
    end
    any(haskey(data, key) for key in ("includes", "select")) &&
        throw(ArgumentError("study cannot include studies; use kind: meta"))
    configuration=_keys_input(
        _mapping_input(get(data, "configuration", Dict()), "configuration"),
        ("sources", "overrides"),
        "configuration",
    )
    sources=[
        abspath(joinpath(dirname(source), _string_input(item, "source"))) for
        item in _vector_input(get(configuration, "sources", Any[]), "sources")
    ]
    isempty(sources) && throw(ArgumentError("study requires explicit configuration.sources"))
    overrides=_mapping_input(
        get(configuration, "overrides", Dict()),
        "configuration.overrides",
    )
    variants=ScientificVariant[]
    for item in _vector_input(
        get(data, "variants", [Dict("id"=>"baseline", "method_id"=>"configured")]),
        "variants",
    )
        variant=_keys_input(
            _mapping_input(item, "variant"),
            ("id", "method_id", "overrides", "controlled_paths", "comparison_kind"),
            "variant",
        )
        push!(
            variants,
            ScientificVariant(
                _identifier_input(get(variant, "id", nothing), "variant.id"),
                _identifier_input(
                    get(variant, "method_id", "configured"),
                    "variant.method_id",
                ),
                _mapping_input(get(variant, "overrides", Dict()), "variant.overrides"),
                String.(
                    _vector_input(
                        get(variant, "controlled_paths", Any[]),
                        "controlled_paths",
                    ),
                ),
                Symbol(get(variant, "comparison_kind", "controlled_axis")),
            ),
        )
    end
    isempty(variants) && throw(ArgumentError("study variants must not be empty"))
    length(unique(v.id for v in variants))==length(variants) ||
        throw(ArgumentError("duplicate variant id"))
    axes=_keys_input(
        _mapping_input(get(data, "axes", Dict()), "axes"),
        ("temperatures", "voltages", "branches"),
        "axes",
    )
    temperatures=_axis_values(
        get(axes, "temperatures", nothing),
        :temperature,
    )
    branches=ScientificBranch[]
    if haskey(axes, "branches")
        haskey(axes, "voltages") &&
            throw(ArgumentError("axes branches and voltages are exclusive"))
        for item in _vector_input(axes["branches"], "branches")
            branch=_keys_input(_mapping_input(item, "branch"), ("id", "voltages"), "branch")
            push!(
                branches,
                ScientificBranch(
                    _identifier_input(get(branch, "id", nothing), "branch.id"),
                    _axis_values(get(branch, "voltages", nothing), :voltage),
                ),
            )
        end
    else
        push!(
            branches,
            ScientificBranch(
                "forward",
                _axis_values(
                    get(axes, "voltages", nothing),
                    :voltage,
                ),
            ),
        )
    end
    isempty(branches) && throw(ArgumentError("branches must not be empty"))
    length(unique(b.id for b in branches))==length(branches) ||
        throw(ArgumentError("duplicate branch id"))
    purpose=Symbol(get(data, "purpose", "research"))
    purpose in (:research, :diagnostic, :reproducibility, :benchmark) ||
        throw(ArgumentError("unknown study purpose"))
    repetitions=_positive_integer(get(data, "repetitions", 1), "repetitions")
    repetitions>1 &&
        !(purpose in (:reproducibility, :benchmark)) &&
        throw(
            ArgumentError(
                "explicit repetitions require reproducibility or benchmark purpose",
            ),
        )
    operation=Symbol(get(data, "operation", "stationary"))
    operation in (
        :stationary,
        :operator_algebra,
        :operator_metrics,
        :operator_representation,
        :operator_continuum,
        :operator_cavity,
        :operator_lo_equilibrium,
        :operator_spectral_resolution,
        :structure_spectrum,
    ) || throw(ArgumentError("unsupported scientific operation"))
    return ScientificDefinition(
        source,
        id,
        name,
        kind,
        tags,
        ScientificChild[],
        sources,
        overrides,
        variants,
        temperatures,
        branches,
        policies,
        outputs,
        purpose,
        repetitions,
        operation,
    )
end

function resolve_scientific_configuration(
    ::FilesystemScientificDefinitions,
    definition,
    variant,
    inherited_overrides,
)
    base=load_run_configuration(definition.configuration_sources)
    raw=deepcopy(base.raw)
    provenance=deepcopy(base.provenance.sources)
    for (override, origin) in (
        (definition.overrides, definition.source),
        (variant.overrides, definition.source*"#"*variant.id),
        (inherited_overrides, definition.source*"#inclusion"),
    )
        if haskey(override,"output")
            aliases=_mapping_input(override["output"],"$origin.output")
            haskey(aliases,"save_full_state") && aliases["save_full_state"]!=true &&
                throw(ArgumentError("scientific archive full_final conflicts with output.save_full_state override at $origin"))
            any(haskey(aliases,key) for key in ("archive","recovery","telemetry")) &&
                throw(ArgumentError("scientific output policy belongs to the definition output, not configuration overrides"))
        end
        _deep_merge!(raw, override, provenance, origin)
    end
    # Generated labels identify the assigning policy, not physical data sources.
    _deep_merge!(raw, Dict{String,Any}(
        "run"=>Dict{String,Any}("name"=>definition.id*"-"*variant.id),
    ), provenance, definition.source*"#generated:run-identity")
    raw["study"]=_scientific_single_study(raw["study"], definition, provenance)
    _deep_merge!(raw, Dict{String,Any}(
        "solver"=>Dict{String,Any}("convergence"=>Dict{String,Any}(
            "mode"=>String(definition.policies.scba_to_poisson),
        )),
    ), provenance, definition.source*"#generated:convergence-policy")
    _deep_merge!(raw, Dict{String,Any}(
        "physical"=>Dict{String,Any}(
            "lattice_temperature"=>"$(first(definition.temperatures)) K",
            "lo_temperature"=>"$(first(definition.temperatures)) K",
        ),
    ), provenance, definition.source*"#generated:temperature-axis")
    _deep_merge!(raw, Dict{String,Any}(
        "output"=>Dict{String,Any}(
            "resume"=>false,
            "save_full_state"=>definition.outputs.full_state,
            "save_csv"=>true,
            "save_plots"=>false,
            "live_visualization"=>false,
            "progress"=>Dict{String,Any}("terminal"=>false),
            "light_max_snapshots"=>definition.outputs.intermediate_history,
        ),
    ), provenance, definition.source*"#generated:output-policy")
    return _resolve_configuration(
        raw,
        ConfigurationProvenance(
            copy(base.provenance.manifests),
            copy(base.provenance.files),
            provenance,
        ),
    )
end
function _scientific_single_study(study, definition, provenance)
    value=deepcopy(study)
    # Merge only assigned leaves so copied photon-energy controls keep their origins.
    _deep_merge!(value, Dict{String,Any}(
        "mode"=>"single",
        "voltages_per_period"=>["$(first(first(definition.branches).voltages)) V"],
        "temperatures"=>["$(first(definition.temperatures)) K"],
        "methods"=>Any[],
        "reference_profile"=>nothing,
        "comparison_profiles"=>Any[],
        "repetitions"=>1,
        "calculate_optical_response"=>false,
        "convergence"=>Dict{String,Any}(
            key=>Int[] for
            key in ("spatial_nodes", "energy_nodes", "momentum_nodes", "angular_nodes")
        ),
    ), provenance, definition.source*"#generated:single-study", "study")
    return value
end
function scientific_memory_estimate(
    ::FilesystemScientificDefinitions,
    c::ResolvedRunConfiguration,
)
    mechanisms=count(name->getfield(c.scattering, name), fieldnames(typeof(c.scattering)))
    mechanisms+=c.physical_models.electron_electron.mode===:none ? 0 : 1
    estimate(n) = estimate_production_memory(
        n,
        mechanisms;
        dense_mechanism_count = mechanisms,
        lo_kernel = c.scattering.LO ? :dense : :absent,
        options = c.production,
        worker_capacity = Sys.CPU_THREADS,
    )
    initial=estimate(c.numerical)
    policy=c.domain_adaptation
    (policy.mode===:none || policy.maximum_expansions==0) && return initial.peak_bytes
    # Preflight spectral coverage can request the entire declared node cap.
    # Evaluate the estimator there: dense shifts are quadratic and FFT sizes jump.
    n=c.numerical
    nodes=max(n.N_E, policy.maximum_energy_nodes)
    bounded=typeof(n)(;
        (
            name=>(name===:N_E ? nodes : getfield(n, name)) for
            name in fieldnames(typeof(n))
        )...,
    )
    largest=estimate(bounded)
    # Retain initial problem/cache, preceding voltage problem and previous domain
    # while the next domain is built. Counting full residents is conservative.
    return Base.checked_add(
        largest.peak_bytes,
        Base.checked_add(
            Base.checked_mul(2, largest.resident_bytes),
            initial.resident_bytes,
        ),
    )
end
resolve_scientific_plan(source::AbstractString; kwargs...) =
    resolve_scientific_plan(FilesystemScientificDefinitions(), source; kwargs...)

"""Identify an executable scientific definition without treating fragments as jobs."""
function is_scientific_definition(path::AbstractString)
    isfile(path) || return false
    document=YAML.load_file(path; dicttype = Dict{String,Any})
    return document isa AbstractDict &&
           get(document, "schema", nothing)=="qcl-negf-study-v2" &&
           get(document, "kind", nothing) in ("study", "meta")
end

