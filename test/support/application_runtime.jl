using Test
import QCLNEGFRunner
using QCLNEGFRunner.QCLApplicationRuntime

function application_fixture()
    operating = SweepLevel(
        "operating",
        [
            SweepAxis("temperature_K", [250.0, 300.0]),
            SweepAxis("voltage_V", [0.040, 0.060]),
        ],
        SweepLeaf("poisson_scba"),
    )
    root = SweepLevel("method", [SweepAxis("profile", ["exact", "low_rank"])], operating)
    plan = NestedSweepPlan("reference2019_validation", root)
    definition = RunDefinition(
        plan;
        scientific_identity = Dict(
            "structure" => "QCL-2019",
            "physics" => Dict("scattering" => ["LO", "IR", "impurity"]),
            "algorithms" => Dict("hilbert" => "direct"),
        ),
        software_identity = Dict(
            "package" => "QCLNEGFRunner",
            "version" => "0.8.1-dev",
            "source_sha256" => repeat("a", 64),
        ),
        labels = Dict("title" => "Human label excluded from identity"),
    )
    return plan, definition
end
