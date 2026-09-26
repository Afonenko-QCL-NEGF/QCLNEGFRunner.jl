using QCLNEGFRunner

length(ARGS) == 1 || error("usage: validate_configuration.jl CONFIG_DIRECTORY")
configuration_directory = only(ARGS)
configuration = load_run_configuration(configuration_directory)
threads = configure_execution!(configuration)
output_directory = configuration_output_directory(configuration)

println("configuration=", configuration.name)
println("classification=", configuration.classification)
println("output_directory=", output_directory)
println("julia_threads=", threads.julia_threads)
println("blas_threads=", threads.blas_threads)
