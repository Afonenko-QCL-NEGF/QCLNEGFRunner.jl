# Purpose: inspect an immutable study/meta plan without allocating solver arrays.
# Inputs: one study definition (default: examples/config/operator-algebra.yaml).
# Outputs: strict F=0-to-voltage branches, predecessors and actual computation count.
# Prerequisites: instantiate the pinned project. No solver arrays are allocated.
using QCLNEGFRunner
source=isempty(ARGS) ?
       joinpath(@__DIR__, "config", "operator-algebra.yaml") : only(ARGS)
plan=resolve_scientific_plan(source)
println(
    plan.name,
    ": ",
    length(plan.points),
    " actual points; ",
    length(plan.inclusions),
    " inclusions",
)
for point in plan.points
    println(
        point.id,
        "  T=",
        point.temperature_K,
        " K; Vperiod=",
        point.voltage_per_period_V,
        " V; branch=",
        point.branch,
        "; seed=",
        something(point.predecessor_id, "cold"),
    )
end
