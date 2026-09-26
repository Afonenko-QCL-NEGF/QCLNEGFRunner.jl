# [Architecture](@id developer-architecture)

QCLNEGFRunner depends on QCLNEGF. The core supplies dimensional types, reference
and optimized operators, SCBA/Poisson iteration and observables. Runner supplies
configuration, scientific plans, filesystem persistence, checkpoints and presentation.

## [Source ownership](@id developer-source-map)

| Layer | Responsibility |
|---|---|
| Application | Point-local execution, continuation and scientific plan handling |
| Composition | Connect numerical callbacks to selected adapters |
| Infrastructure | Validate YAML, inspect OS resource bounds and commit artifacts |
| Presentation | Progress views, reports and optional CairoMakie plots |

## [Configuration contract](@id configuration-contract)

Every study declares `configuration.sources` and operating-point axes. YAML is
checked against `schema/run.schema.json`; vendored schema provenance is recorded
in `schema/PROVENANCE.json`. A frozen plan preserves the effective inputs and
fingerprints. Unknown keys, invalid dimensions and inconsistent input fail before
solving. Resource admission never reduces a grid or relaxes an acceptance threshold.

## External services

AiiDA owns durable distributed process state and provenance. Slurm owns allocation
and queue policy. Runner performs one declared execution inside that allocation,
checks process affinity and cgroup bounds, and writes results. NixOS deployment,
service identity and CI installation are owned by qcl-negf-platform.

The storage contract is [documented separately](@ref native-result-formats).
Python readers live in qcl-negf-results. No deployment controller or distributed
queue service is embedded in this package.
