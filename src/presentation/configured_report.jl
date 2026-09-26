"""Markdown adapter for the configured-report application port."""
struct MarkdownConfiguredReportRenderer <: AbstractConfiguredReportRenderer end

const _CONFIGURED_REPORT_SECTION_METADATA = Dict{Symbol,NamedTuple}(
    :configuration => (
        title = "Configuration",
        description = "Resolved, validated inputs used by the calculation.",
    ),
    :provenance => (
        title = "Provenance",
        description = "Algorithm, software, and execution evidence.",
    ),
    :convergence => (
        title = "Convergence",
        description = "Stored convergence status and residual evidence.",
    ),
    :current_density => (
        title = "Current density",
        description = "Electron-flow current density; stored scientific data " *
                      "use explicit units.",
    ),
    :hartree_potential => (
        title = "Hartree potential",
        description = "Links to retained state data containing the Hartree potential.",
    ),
    :wavefunctions => (
        title = "Wavefunctions and localized states",
        description = "Links to retained state data; arrays are not copied into Markdown.",
    ),
    :performance => (
        title = "Performance",
        description = "Machine-readable events, timings, and resource evidence.",
    ),
    :method_classification => (
        title = "Method classification",
        description = "Declared E0/E1/E2/E3 method metadata and the effective " *
                      "algorithm catalog.",
    ),
    :physical_equivalence => (
        title = "Physical equivalence",
        description = "Pointwise comparison evidence; convergence remains a " *
                      "prerequisite for acceptance.",
    ),
    :discretization_convergence => (
        title = "Discretization convergence",
        description = "Independent refinement results and their full-precision tables.",
    ),
    :current_and_gain => (
        title = "Current and gain",
        description = "Stored operating-point observables and optical-response results.",
    ),
    :matrix_diagnostics => (
        title = "Matrix diagnostics",
        description = "Hamiltonian, Green-function, self-energy, and basis data " *
                      "are projected to bounded JSON/CSV/SVG for ordinary viewing; optional HDF5 is a separate debug output.",
    ),
    :incomplete_points => (
        title = "Incomplete points",
        description = "Non-converged or incomplete points must remain visible " *
                      "and excluded from physical claims.",
    ),
)

function _configured_report_artifact(
    label::AbstractString,
    path::AbstractString,
    media_type::AbstractString,
)
    isempty(path) && return nothing
    absolute = abspath(path)
    isfile(absolute) || return nothing
    return ConfiguredReportArtifact(String(label), absolute, String(media_type))
end

function _configured_report_artifacts(candidates)
    artifacts = ConfiguredReportArtifact[]
    for (label, path, media_type) in candidates
        artifact = _configured_report_artifact(label, path, media_type)
        artifact === nothing || push!(artifacts, artifact)
    end
    return artifacts
end

_configured_report_first(artifacts) =
    isempty(artifacts) ? ConfiguredReportArtifact[] : artifacts[1:1]

_configured_report_prefix(artifacts, count::Integer) =
    isempty(artifacts) ? ConfiguredReportArtifact[] :
    artifacts[1:min(Int(count), length(artifacts))]

_configured_report_section(notes, artifacts = ConfiguredReportArtifact[]) =
    ConfiguredReportSection(String[String(note) for note in notes], artifacts)

function _configured_run_status(result::ConfiguredRunResult)
    records = result.sweep.records
    isempty(records) && return "incomplete"
    all(record -> record.converged, records) && return "completed"
    return all(record -> record.converged || record.status === :approximate, records) ?
           "completed_with_warnings" : "incomplete"
end

function _configured_run_provenance_artifacts(output::AbstractString)
    return _configured_report_artifacts([
        (
            "Resolved configuration",
            joinpath(output, "resolved_configuration.yaml"),
            "application/yaml",
        ),
        (
            "Algorithm manifest",
            joinpath(output, "algorithm_manifest.yaml"),
            "application/yaml",
        ),
        (
            "Optimization catalog",
            joinpath(output, "optimization_catalog.yaml"),
            "application/yaml",
        ),
        (
            "Configuration provenance",
            joinpath(output, "configuration_provenance.yaml"),
            "application/yaml",
        ),
        ("Execution plan", joinpath(output, "execution_plan.yaml"), "application/yaml"),
        ("Output policy", joinpath(output, "output_policy.yaml"), "application/yaml"),
    ])
end

function configured_report_context(result::ConfiguredRunResult)
    output = abspath(result.output_directory)
    summary = result.sweep.summary_path
    state_artifacts = _configured_report_artifacts([(
        "Derived snapshots",
        joinpath(output, "derived", "manifest.yaml"),
        "application/yaml",
    ),])
    manifest_path=joinpath(output, "derived", "manifest.yaml")
    if isfile(manifest_path)
        manifest=YAML.load_file(manifest_path; dicttype = Dict{String,Any})
        for snapshot in get(manifest, "snapshots", []),
            artifact in get(snapshot, "artifacts", [])

            get(artifact, "media_type", "")=="image/svg+xml" || continue
            path=normpath(joinpath(output, artifact["path"]))
            any(==(".."), splitpath(relpath(path, output))) && continue
            candidate=_configured_report_artifact(
                string(snapshot["id"], " ", artifact["kind"]),
                path,
                "image/svg+xml",
            )
            candidate===nothing || push!(state_artifacts, candidate)
        end
    end
    provenance = _configured_run_provenance_artifacts(output)
    summary_artifact =
        _configured_report_artifacts([("Operating-point summary", summary, "text/csv")])
    performance = _configured_report_artifacts([
        (
            endswith(result.progress_csv, ".jsonl") ? "Lifecycle events" :
            "User progress export",
            result.progress_csv,
            endswith(result.progress_csv, ".jsonl") ? "application/x-ndjson" : "text/csv",
        ),
        (
            "Timing samples",
            joinpath(dirname(result.progress_csv), "timings.csv"),
            "text/csv",
        ),
        (
            "Timing quantiles",
            joinpath(dirname(result.progress_csv), "timing_summary.yaml"),
            "application/yaml",
        ),
        ("Execution plan", joinpath(output, "execution_plan.yaml"), "application/yaml"),
    ])
    sections = Dict{Symbol,ConfiguredReportSection}(
        :configuration =>
            _configured_report_section(String[], _configured_report_first(provenance)),
        :provenance => _configured_report_section(String[], provenance),
        :convergence => _configured_report_section(String[], summary_artifact),
        :current_density => _configured_report_section(String[], summary_artifact),
        :hartree_potential => _configured_report_section(
            [
                "The derived manifest indexes bounded outer-iteration snapshots in JSON/CSV/SVG; HDF5 is optional.",
            ],
            state_artifacts,
        ),
        :wavefunctions => _configured_report_section(
            [
                "Effective k=0 wavefunctions and the fixed localized basis are retained separately with explicit units.",
            ],
            state_artifacts,
        ),
        :performance => _configured_report_section(String[], performance),
    )
    facts = Pair{String,String}[
        "Run"=>result.configured_problem.configuration.name,
        "Operating points"=>string(length(result.sweep.records)),
        "Strict points"=>string(count(record->record.converged, result.sweep.records)),
        "Approximate points"=>string(
            count(record->record.status===:approximate, result.sweep.records),
        ),
        "Invalid points"=>string(
            count(record->record.scba_quality===:invalid, result.sweep.records),
        ),
        "Unconverged points"=>string(
            count(
                record->!record.converged&&record.status!==:approximate&&record.scba_quality!==:invalid,
                result.sweep.records,
            ),
        ),
        "Quality warnings"=>string(
            sum(length(record.warnings) for record in result.sweep.records),
        ),
    ]
    return ConfiguredReportContext(
        result.configured_problem.configuration.name,
        :configured_run,
        _configured_run_status(result),
        output,
        facts,
        sections,
    )
end

function configured_report_context(result::ProductionStudyResult)
    output = abspath(result.output_directory)
    method_points_available =
        !isempty(result.method_report.points_csv) &&
        isfile(abspath(result.method_report.points_csv))
    convergence_table_available =
        !isempty(result.convergence_csv) && isfile(abspath(result.convergence_csv))
    report_directory =
        isempty(result.method_report.markdown) ?
        joinpath(output, result.configuration.output.report_directory) :
        dirname(abspath(result.method_report.markdown))
    method_report = _configured_report_artifacts([
        ("Expert method report", result.method_report.markdown, "text/markdown"),
        ("Pointwise method comparison", result.method_report.comparison_csv, "text/csv"),
        ("Method operating points", result.method_report.points_csv, "text/csv"),
    ])
    convergence = _configured_report_artifacts([
        ("Convergence report", result.convergence_markdown, "text/markdown"),
        ("Convergence table", result.convergence_csv, "text/csv"),
    ])
    catalog = _configured_report_artifacts([(
        "Method catalog",
        result.method_catalog,
        "text/csv",
    )])
    plot_candidates = _configured_report_artifacts([
        (
            "Method comparison (PNG)",
            joinpath(report_directory, "method_comparison.png"),
            "image/png",
        ),
        (
            "Method comparison (PDF)",
            joinpath(report_directory, "method_comparison.pdf"),
            "application/pdf",
        ),
    ])
    point_header, point_rows =
        method_points_available ? _read_report_csv(result.method_report.points_csv) :
        (String[], Dict{String,String}[])
    method_points_available &&
        !("converged" in point_header) &&
        throw(ArgumentError("method-points table lacks the required converged column"))
    point_converged = [
        _parse_report_bool(
            _required_report_field(row, "converged", result.method_report.points_csv),
            "converged",
        ) for row in point_rows
    ]
    converged_points = count(identity, point_converged)
    approximate_points = count(row -> get(row, "status", "")=="approximate", point_rows)
    invalid_points = count(row -> get(row, "scba_quality", "")=="invalid", point_rows)
    incomplete_points = length(point_converged) - converged_points - approximate_points
    convergence_header, convergence_rows =
        convergence_table_available ? _read_report_csv(result.convergence_csv) :
        (String[], Dict{String,String}[])
    convergence_pairs = length(convergence_rows)
    incomplete_pairs = if convergence_pairs == 0
        0
    else
        "pair_converged" in convergence_header || throw(
            ArgumentError("convergence table lacks the required pair_converged column"),
        )
        count(
            row ->
                !_parse_report_bool(
                    _required_report_field(row, "pair_converged", result.convergence_csv),
                    "pair_converged",
                ),
            convergence_rows,
        )
    end
    failed_phases = String[]
    method_points_available || push!(failed_phases, "method comparison")
    convergence_table_available || push!(failed_phases, "grid convergence")
    workflow_status = if !isempty(failed_phases)
        "workflow_incomplete_failed_phases"
    elseif isempty(point_converged)
        "workflow_completed_without_method_points"
    elseif incomplete_points == 0 && incomplete_pairs == 0 && approximate_points == 0
        "workflow_completed_all_points_converged"
    elseif incomplete_points == 0
        "workflow_completed_with_warnings"
    else
        "workflow_completed_with_incomplete_points"
    end
    sections = Dict{Symbol,ConfiguredReportSection}(
        :configuration => _configured_report_section(
            ["Every compared method inherits one physical structure and resource budget."],
            catalog,
        ),
        :provenance => _configured_report_section(String[], catalog),
        :method_classification => _configured_report_section(
            String[],
            vcat(catalog, _configured_report_first(method_report)),
        ),
        :physical_equivalence => _configured_report_section(
            ["The linked expert report applies convergence and physics-signature gates."],
            _configured_report_prefix(method_report, 2),
        ),
        :discretization_convergence =>
            _configured_report_section(String[], convergence),
        :current_and_gain =>
            _configured_report_section(String[], vcat(method_report, plot_candidates)),
        :matrix_diagnostics => _configured_report_section(
            [
                "Matrix-valued state is intentionally not duplicated in Markdown; " *
                "inspect each point derived manifest and its bounded spectral/population projections. Full HDF5 is optional.",
            ],
            _configured_report_first(method_report),
        ),
        :performance => _configured_report_section(
            [
                "Full-precision wall-time and memory columns are retained in " *
                "the comparison table.",
            ],
            method_report,
        ),
        :incomplete_points => _configured_report_section(
            [
                "Unavailable diagnostic phases: " *
                (isempty(failed_phases) ? "none" : join(failed_phases, ", ")) *
                ". Incomplete method points: $incomplete_points of " *
                "$(length(point_converged)); incomplete convergence pairs: " *
                "$incomplete_pairs of $convergence_pairs. The expert report " *
                "preserves their status and never treats them as evidence.",
            ],
            _configured_report_first(method_report),
        ),
    )
    facts = Pair{String,String}[
        "Study"=>result.configuration.name,
        "Reference profile"=>something(
            result.configuration.study.reference_profile,
            "not selected",
        ),
        "Method count"=>string(length(result.configuration.study.methods)),
        "Method points"=>string(length(point_converged)),
        "Strict method points"=>string(converged_points),
        "Approximate method points"=>string(approximate_points),
        "Invalid method points"=>string(invalid_points),
        "Unconverged method points"=>string(incomplete_points-invalid_points),
        "Convergence pairs"=>string(convergence_pairs),
        "Converged convergence pairs"=>string(convergence_pairs-incomplete_pairs),
        "Unavailable diagnostic phases"=>(isempty(failed_phases) ? "none" :
                                          join(failed_phases, ", ")),
    ]
    return ConfiguredReportContext(
        result.configuration.name,
        :production_study,
        workflow_status,
        report_directory,
        facts,
        sections,
    )
end

function configured_report_context(result::SweepRunSummary)
    output = dirname(abspath(result.result_path))
    result_artifact = _configured_report_artifacts([(
        "Hierarchical run result",
        result.result_path,
        "application/yaml",
    )])
    provenance = _configured_report_artifacts([
        ("Run definition", joinpath(output, "run.yaml"), "application/yaml"),
        ("Execution plan", joinpath(output, "execution_plan.yaml"), "application/yaml"),
        ("Provenance", joinpath(output, "provenance.yaml"), "application/yaml"),
    ])
    performance = _configured_report_artifacts([
        ("Core timing", joinpath(output, "core_timing.yaml"), "application/yaml"),
        ("Disk estimate", joinpath(output, "disk_estimate.yaml"), "application/yaml"),
    ])
    sections = Dict{Symbol,ConfiguredReportSection}(
        :configuration =>
            _configured_report_section(String[], _configured_report_first(provenance)),
        :provenance => _configured_report_section(String[], provenance),
        :convergence => _configured_report_section(String[], result_artifact),
        :current_density => _configured_report_section(String[], result_artifact),
        :hartree_potential => _configured_report_section(
            [
                "Open the point derived manifest: outer snapshots contain Hartree potentials in JSON/CSV/SVG without HDF5.",
            ],
            result_artifact,
        ),
        :wavefunctions => _configured_report_section(
            [
                "Open the point derived wavefunctions and localized basis; optional HDF5 is not required.",
            ],
            result_artifact,
        ),
        :performance => _configured_report_section(String[], performance),
    )
    facts = Pair{String,String}[
        "Run ID"=>result.run_id,
        "Points"=>string(result.point_count),
        "Completed"=>string(result.completed),
        "Incomplete"=>string(result.incomplete),
        "Failed"=>string(result.failed),
        "Interrupted"=>string(result.interrupted),
    ]
    return ConfiguredReportContext(
        result.run_id,
        :nested_sweep,
        String(result.status),
        output,
        facts,
        sections,
    )
end

function _configured_report_markdown_escape(value::AbstractString)
    return replace(
        String(value),
        '\\' => "\\\\",
        '`' => "\\`",
        '*' => "\\*",
        '_' => "\\_",
        '[' => "\\[",
        ']' => "\\]",
    )
end

function _configured_report_link_target(path::AbstractString, report_path::AbstractString)
    relative = replace(relpath(abspath(path), dirname(abspath(report_path))), '\\' => '/')
    return replace(
        relative,
        '%' => "%25",
        ' ' => "%20",
        '(' => "%28",
        ')' => "%29",
        '#' => "%23",
        '?' => "%3F",
    )
end

function _write_configured_report(
    io::IO,
    template::ConfiguredReportTemplate,
    context::ConfiguredReportContext,
    output_path::AbstractString,
)
    println(io, "# ", _configured_report_markdown_escape(template.label), "\n")
    println(io, "- Template: `", template.id, "`")
    println(io, "- Template SHA-256: `", template.source_sha256, "`")
    println(io, "- Subject: `", _configured_report_markdown_escape(context.title), "`")
    println(io, "- Result kind: `", context.result_kind, "`")
    println(io, "- Status: `", _configured_report_markdown_escape(context.status), "`")
    for (label, value) in context.facts
        println(
            io,
            "- ",
            _configured_report_markdown_escape(label),
            ": `",
            _configured_report_markdown_escape(value),
            "`",
        )
    end
    println(
        io,
        "\n> Scientific arrays and full-precision tables remain in their " *
        "native artifacts. This Markdown file links to them and does not " *
        "re-implement numerical analysis.\n",
    )
    for section_id in template.sections
        metadata = _CONFIGURED_REPORT_SECTION_METADATA[section_id]
        println(io, "## ", metadata.title, "\n")
        println(io, metadata.description, "\n")
        content = get(
            context.sections,
            section_id,
            _configured_report_section([
                "This result kind produced no artifact for this section.",
            ]),
        )
        for note in content.notes
            println(io, "- ", _configured_report_markdown_escape(note))
        end
        for artifact in content.artifacts
            target = _configured_report_link_target(artifact.path, output_path)
            println(
                io,
                "- [",
                _configured_report_markdown_escape(artifact.label),
                "](",
                target,
                ") — `",
                artifact.media_type,
                "`",
            )
        end
        isempty(content.notes) &&
            isempty(content.artifacts) &&
            println(io, "- No retained artifact is available for this section.")
        println(io)
    end
    return nothing
end

function render_configured_report(
    ::MarkdownConfiguredReportRenderer,
    template::ConfiguredReportTemplate,
    context::ConfiguredReportContext;
    output_directory::AbstractString = context.output_directory,
)
    template.image_policy === :links ||
        throw(ArgumentError("Markdown configured reports support only image_policy=:links"))
    allunique(template.sections) ||
        throw(ArgumentError("configured report sections must be unique"))
    all(
        section -> haskey(_CONFIGURED_REPORT_SECTION_METADATA, section),
        template.sections,
    ) || throw(ArgumentError("configured report contains an unknown section"))
    directory = abspath(output_directory)
    mkpath(directory)
    root = realpath(directory)
    requested = abspath(joinpath(root, template.output))
    lowercase(splitext(requested)[2]) == ".md" ||
        throw(ArgumentError("configured report output must use the .md extension"))
    mkpath(dirname(requested))
    parent = realpath(dirname(requested))
    relative = relpath(parent, root)
    first(splitpath(relative)) == ".." &&
        throw(ArgumentError("configured report output escapes its result directory"))
    path = joinpath(parent, basename(requested))
    islink(path) &&
        throw(ArgumentError("configured report output cannot replace a symbolic link"))
    return _observability_atomic_text(path) do stream
        _write_configured_report(stream, template, context, path)
    end
end

function render_configured_report(
    template::ConfiguredReportTemplate,
    result;
    renderer::AbstractConfiguredReportRenderer = MarkdownConfiguredReportRenderer(),
    output_directory = nothing,
)
    context = configured_report_context(result)
    destination =
        output_directory === nothing ? context.output_directory : String(output_directory)
    return render_configured_report(
        renderer,
        template,
        context;
        output_directory = destination,
    )
end

function render_configured_report(template_path::AbstractString, result; keywords...)
    template = load_configured_report_template(template_path)
    return render_configured_report(template, result; keywords...)
end
