using QCLNEGFRunner

length(ARGS) == 1 || error(
    "usage: julia --threads=auto --project=. examples/06_reference2019_production.jl CONFIG_DIRECTORY",
)

configuration_directory = abspath(only(ARGS))
result = run_from_configuration(configuration_directory)

println("Configured reference design production run completed")
println("  output:    ", result.output_directory)
println("  summary:   ", result.sweep.summary_path)
isempty(result.progress_csv) || println("  progress:  ", result.progress_csv)
isempty(result.live_dashboard) || println("  dashboard: ", result.live_dashboard)
