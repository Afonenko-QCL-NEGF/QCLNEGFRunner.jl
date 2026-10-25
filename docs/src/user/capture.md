# Optional ordinary live/performance capture

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
