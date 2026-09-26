using QCLNEGFRunner

# This is an algorithmic smoke calculation only.  Restore baseline_numerics()
# and all mechanisms, then perform every convergence sequence before drawing
# physical conclusions.
problem = build_problem(
    numerical = tutorial_numerics(),
    scattering = ScatteringOptions(
        LO = false,
        acoustic = true,
        impurity = false,
        IFR = false,
        alloy = false,
    ),
)
solution = solve(problem; options = tutorial_options())
println(solution)
println(solution.report.metrics)
save_light_solution("results/reference2019_tutorial", solution)
# Optional exact restart data (requires HDF5 installed during preparation):
# save_checkpoint("results/reference2019_tutorial/checkpoint.h5", solution)
