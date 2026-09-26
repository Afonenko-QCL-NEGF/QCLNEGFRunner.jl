# Purpose: analyze saved point results without an engine or solver invocation.
# Inputs: a native series_result.json directory; missing data are reported per operation.
# Outputs: analysis/derived_result.json and analysis/report.md.
# Prerequisites: execute a scientific plan first; HDF5 is supplied by Runner; plotting is optional.
using QCLNEGFRunner
length(ARGS)==1 ||
    error("usage: julia --project examples/12_saved_series_analysis.jl RESULT_DIRECTORY")
result=postprocess_series(only(ARGS))
for (operation, outcome) in sort!(collect(result["operations"]); by = first)
    println(operation, ": ", outcome["status"])
end
