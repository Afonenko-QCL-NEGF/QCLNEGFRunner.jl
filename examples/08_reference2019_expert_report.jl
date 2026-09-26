using QCLNEGFRunner

length(ARGS) == 1 ||
    error("usage: julia --project=. examples/08_reference2019_expert_report.jl CONFIG_DIRECTORY")

configuration = load_run_configuration(only(ARGS))
configuration.study.mode === :comparison ||
    error("the supplied configuration must declare study.mode: comparison")
reference = configuration.study.reference_profile
reference === nothing && error("the comparison requires reference_profile")
output = configuration_output_directory(configuration)
catalog = joinpath(output, "method_catalog.csv")
isfile(catalog) ||
    error("missing $catalog; run examples/09_reference_production_study.jl first")
report_directory = joinpath(output, configuration.output.report_directory)
generated = generate_expert_report(
    catalog,
    report_directory;
    reference_id = Symbol(reference),
    title = "reference design NEGF production method comparison",
)

println("Expert report: ", generated.paths.markdown)
println("Comparison CSV: ", generated.paths.comparison_csv)

if configuration.output.save_comparison_plots
    Base.find_package("CairoMakie") === nothing &&
        error("save_comparison_plots=true, but CairoMakie is not installed")
    @eval using CairoMakie
    comparison_figure = plot_method_comparison(generated.comparison)
    png = joinpath(report_directory, "method_comparison.png")
    pdf = joinpath(report_directory, "method_comparison.pdf")
    CairoMakie.save(png, comparison_figure; px_per_unit = 2)
    CairoMakie.save(pdf, comparison_figure)
    println("Plots: ", png, " and ", pdf)
end
