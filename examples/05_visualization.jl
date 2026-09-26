using QCLNEGFRunner

# Purpose: render the exact data saved by 04, without invoking another solver.
# Dependency: examples/04_closed_tutorial.jl; no HDF5 or plotting extension.
snapshot = "results/reference2019_tutorial/derived/snapshots/final/data.json"
isfile(snapshot) || error("run examples/04_closed_tutorial.jl first")
for path in render_saved_snapshot(snapshot, "results/reference2019_tutorial/figures")
    println(path)
end
