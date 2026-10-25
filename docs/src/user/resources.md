# [Resource limits](@id resource-planning)

Optional ordinary [live/performance capture](capture.md) reserves its finite
storage forecast inside the existing operational credit; it grants no new CPU,
RAM or scientific storage capacity.

Run one Julia process per Slurm task and set `JULIA_NUM_THREADS` to allocated CPUs
per task before process launch. Julia's task pool is fixed at startup. Scheduled
scientific execution uses one BLAS thread to avoid nested oversubscription.

Runner reads process affinity and cgroup v2 bounds, including finite ancestor
memory limits. Estimated peak numerical storage is checked before allocation.
The estimate is not an RSS guarantee: the runtime, native libraries and allocator
can retain additional memory. Ordinary `:standalone` phases retain estimates and
telemetry under external Slurm/systemd/cgroup controls, without predicting fit
from current memory plus a phase estimate. The telemetry mode
`external_controls_not_predicted_fit` describes this policy; it does not verify
actual external limits. The legacy `:campaign_strict` phase guard still checks
observed memory pressure without crediting shared cache; its scientific entry
point remains closed pending its required bindings.

A stopped execution may return a paused status and checkpoint provenance. Resume
is possible only when a compatible verified checkpoint was actually written.
An external memory limit can terminate the process before the next checkpoint;
completion of a pending generation is not guaranteed.
AiiDA decides whether and where to schedule subsequent work. Neither Slurm priority
nor walltime changes the physical acceptance criteria.

Direct core-library callers supply their own algorithm and thread options. OS
resource discovery belongs to Runner; the numerical library does not probe its
hosting machine or choose a scheduler policy.
