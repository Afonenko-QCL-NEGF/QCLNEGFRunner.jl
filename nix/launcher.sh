#!@bash@
# Public immutable InstalledCode path stays stable. Exactly one solver spawn.
set -eu
solver='@solver@'
capture='@capture@'
if [ "${1-}" = run-plan ] && [ -n "${QCL_NEGF_CAPTURE_SPEC-}" ] && [ -n "$capture" ] && [ -x "$capture" ]; then
    # No spec/NFS read here: capture supervisor spawns Julia before its observer.
    if [ -n "${QCL_NEGF_NATIVE_CAPTURE_INPUT-}" ]; then
        exec "$capture" capture-run --spec "$QCL_NEGF_CAPTURE_SPEC" --solver "$solver" --native-execution "$QCL_NEGF_NATIVE_CAPTURE_INPUT" -- "$@"
    fi
    exec "$capture" capture-run --spec "$QCL_NEGF_CAPTURE_SPEC" --solver "$solver" -- "$@"
fi
unset QCL_NEGF_CAPTURE_SPEC QCL_NEGF_NATIVE_CAPTURE_INPUT
exec "$solver" "$@"
