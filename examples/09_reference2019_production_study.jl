using QCLNEGFRunner

isempty(ARGS) && error(
    "usage: julia --threads=auto --project=. " *
    "examples/09_reference_production_study.jl CONFIG_DIRECTORY " *
    "[--report-template REPORT.yaml]",
)

arguments = configured_report_arguments(ARGS)
length(arguments.configuration_sources) == 1 ||
    error("production study accepts exactly one profile root or resolved snapshot")
configuration_directory = only(arguments.configuration_sources)
configuration = load_run_configuration(configuration_directory)
plots_available = Base.find_package("CairoMakie") !== nothing
if configuration.output.save_comparison_plots && plots_available
    @eval using CairoMakie
elseif configuration.output.save_comparison_plots
    @warn "CairoMakie is not installed; data and Markdown/CSV reports remain complete, plots are skipped"
end

result = run_production_study(configuration_directory)
println("Method report: ", result.method_report.markdown)
println("Method comparison CSV: ", result.method_report.comparison_csv)
println("Convergence report: ", result.convergence_markdown)
println("Convergence CSV: ", result.convergence_csv)
if configuration.output.save_comparison_plots && plots_available
    paths = save_production_study_plots(result)
    println("Method comparison plots: ", paths)
end
if arguments.report_template !== nothing
    report = render_configured_report(arguments.report_template, result)
    println("Templated Markdown report: $report")
end
