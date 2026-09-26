# [Resource limits](@id resource-planning)

Run one Julia process per Slurm task and set `JULIA_NUM_THREADS` to allocated CPUs
per task before process launch. Julia's task pool is fixed at startup. Scheduled
scientific execution uses one BLAS thread to avoid nested oversubscription.

Runner reads process affinity and cgroup v2 bounds, including finite ancestor
memory limits. Estimated peak numerical storage is checked before allocation.
The estimate is not an RSS guarantee: the runtime, native libraries and allocator
can retain additional memory. Phase admission checks observed memory pressure;
shared cache is not credited as memory available exclusively to this process.

A stopped execution may return a paused status and checkpoint provenance. Resume
is possible only when a compatible verified checkpoint was actually written.
AiiDA decides whether and where to schedule subsequent work. Neither Slurm priority
nor walltime changes the physical acceptance criteria.

Direct core-library callers supply their own algorithm and thread options. OS
resource discovery belongs to Runner; the numerical library does not probe its
hosting machine or choose a scheduler policy.
