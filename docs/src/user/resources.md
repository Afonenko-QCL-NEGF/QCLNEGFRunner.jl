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

Optional phase and scalar telemetry use one fixed background slot each. Closing a
producer requests shutdown without waiting for its writer or collector. Runner
retains its complete bounded Julia payload reservation until the actual task has
finished, every already admitted producer copy/admission lane has quiesced, and
the owning caller has released its last use. Close seals producer admission
atomically; a producer that previously read an open flag cannot begin payload
work after close/reap. A known previous writer
may therefore be draining while the next point runs with telemetry unavailable or
disabled; its original reservation still counts against the next point's grant.
A smaller current buffer policy cannot erase that reservation. A missing lifetime
record or an unknown custom callback/transport prevents admission of that caller.

The input/final publication ledger counts stable shared roots once, with one joint
graph, and separately debits the reserved queue, batch, stack, scalar-copy and JSON
work. It does not traverse a queue concurrently to estimate its size. Production
options passed to Core remain unchanged; the actual grant and these owned payloads
determine the remaining publication allowance. Disk reserve bytes are separate.
Only the owning default phase hook and the prepared HTTP transport have this
source-bound payload profile. Custom sinks or callbacks require their own concrete
bounded ownership proof. Direct Julia senders also retain their slot after close
until their task finishes; close and release caller aliases before constructing a
replacement. Retaining an old closed sender in a custom callback does not make it
part of a newer reservation. Owning public records are admitted by an explicit
source-bound catalogue and inspection of their actual callback/container fields;
their module name alone grants no exemption.

Scientific configured construction also debits old observer residency and the
closed caller captures before grid, basis, kernel or cache allocation, using the
already selected execution plan and unchanged production options. This source
gate does not open the stationary native consumer gate.

This accounting bounds the supported owned Julia payload. It does not measure RSS,
prove memory returned to the OS, or add a second host reserve. Task stacks, JIT,
Downloads/native-library work and allocator retention remain in their existing
runtime partitions. Telemetry losses and transport/status failures remain separate
from convergence, physical validation and discretization evidence.
