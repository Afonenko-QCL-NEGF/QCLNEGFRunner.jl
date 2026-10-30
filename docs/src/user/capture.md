# Optional live/performance capture

The packaged public `qcl-negf` keeps its InstalledCode/release identity. With an
immutable `captureExecutable` and trusted `QCL_NEGF_CAPTURE_SPEC`, only `run-plan`
execs Results capture-run; one internal `.qcl-negf-julia` wrapper then execs Julia.
Other commands, B0 and missing pre-spawn capability use the ordinary launcher.
No solver fallback/retry is allowed after an uncertain or proven spawn.

The ordinary CLI validates bounded spec/plan bytes against its selected fullFP,
execution/input attempt/token. It admits a fixed104MiB operational reserve using
the existing used/budget/protected-reserve/free-space forecasts:32performance,
64scalar,8auxiliary metadata/temporaries. If it cannot fit, no locator is published
and the original scientific guards remain. It never edits the frozen plan,
configuration, numerical grid, criteria, fingerprint or kernel ABI.

After admission the same reserve remains charged throughout startup/import,
all recovery publication tails and archive free preflight, even after observer
failure or a retained partial copy. Staging counts source+staged result trees;
the observer directories live beside result, so its guards add one reserve,
without a second observer directory scan. This is a software forecast, not a
global allocator, atomic disk quota or extra scientific storage capacity.

The existing token/fullFP locator identifies actual direct output first.
Recovery-enabled execution keeps its direct route. Actual scratch execution
publishes scratch/result, then verified staged destination before cleanup, with
an advancing epoch. Each control publication is best effort, with no observer
acknowledgement or retry. Filesystem latency for this existing Runner control
write is not bounded. Failure changes neither scientific status nor source raw.

The disposable Results observer must see a valid locator before its first
Writer/output write. Only it polls/copies/flushes NFS telemetry; the sole solver
supervisor retains signal/reap/exit ownership and bounded terminal drain. Missing
samples/sidecar are unavailable, not measured zero or scientific acceptance.
Source fixtures prepare tiny launcher/storage/locator controls without solving.
Root/Platform capture-runtime injection and native qualification are separate.

Native ingress is enabled only by the explicit pair
`QCL_NEGF_CAPTURE_SPEC=capture-spec.json` and
`QCL_NEGF_NATIVE_CAPTURE_INPUT=native-execution.json`. The public launcher adds
`--native-execution` to Results `capture-run` and passes the original scientific
argv unchanged. Its fixed native protocol is `run-plan plan.json ORIGINAL_OUTPUT
--execution-id E --source-graph source-graph.json`; it adds no solver `--attempt`.
The spec's integer transport attempt identifies the CalcJob capture allocation;
the solver retains its default/native continuation counter. Unsupported options
or native scratch refuse capture admission without changing scientific execution.
Launcher fallback clears both capture environment markers.

The native admission checks bounded original plan/source-graph bytes and their
whole native INPUT claims, the execution ID and exact absolute CLI output. The
output must end in the declared relative execution root. That suffix is an
assertion: controller/Platform policy must establish the absolute jobs-root
mapping, InstalledCode/release identity and writer lifetime. It grants no storage
authority by itself. The existing 104 MiB reserve and all forecast/free/protected
reserve checks apply unchanged; invalid optional metadata grants no capture credit.

This ingress does not prove the original creator/transport of any selected
StateRef, or retention and access lifetime of its technical workdir. Until the
owning AiiDA/Platform ports provide those original operands, the native selected
performance association remains unavailable (`source_binding_missing`). No
source transport is inferred from a native counter, source epoch, retained-source
relation or current graph. Engineering fixture success does not qualify native
installation, observation cost, retention or scientific acceptance.
