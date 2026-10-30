# Removed resident storage policy

The unfinished `:campaign_strict` resource mode and its resident authority,
lease, ledger and writer-context infrastructure have been removed. They are not
available through a replacement policy or a renamed storage manager.

Existing Julia entry points keep `resource_policy=:standalone` and, where already
present, `storage_context=nothing`. An explicit removed or unknown policy raises
`ArgumentError` before IO or callbacks. Any non-`nothing` obsolete context also raises
`ArgumentError`; it never silently selects ordinary publication. Callers must
remove the unsupported request and use normal resource planning explicitly.

Ordinary `ExecutionEnvelope` planning, Linux affinity/cgroup probes and native
Slurm/systemd/host limits remain in place. The ordinary phase callback reports
`external_controls_not_predicted_fit`; it does not promise fit prediction from
current memory plus a phase estimate or recovery from an external OOM kill.

Atomic file replacement, bounded copy and serialization buffers, output/free-space
reserves, closed history segments, verified checkpoint dependencies and provenance
retain their owning contracts. Failed scientific scratch execution or delivery
retains its workspace and reports the path with the original failure. Owned
ordinary temporary files follow their existing cleanup policy; the deleted
resident ledger no longer tracks partials or supplies deletion credits.

Process completion, solver convergence, physical checks, discretization adequacy
and experimental validation remain separate. This removal changes no equations,
scattering, grids, basis, tolerances or reference acceptance criteria.
