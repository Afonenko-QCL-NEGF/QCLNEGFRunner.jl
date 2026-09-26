using QCLNEGFRunner

isempty(ARGS) && error(
    "usage: julia --threads=auto --project=. examples/07_run_from_yaml.jl " *
    "CONFIG_DIRECTORY [OVERRIDE.yaml ...] " *
    "[--report-template REPORT.yaml]",
)

arguments = configured_report_arguments(ARGS)
configuration = load_run_configuration(arguments.configuration_sources)
result = run_from_configuration(configuration)
println("Completed $(result.configured_problem.configuration.name)")
println("Summary: $(result.sweep.summary_path)")
println("Progress CSV: $(result.progress_csv)")
isempty(result.live_dashboard) || println("Live/final dashboard: $(result.live_dashboard)")
if arguments.report_template !== nothing
    report = render_configured_report(arguments.report_template, result)
    println("Markdown report: $report")
end
