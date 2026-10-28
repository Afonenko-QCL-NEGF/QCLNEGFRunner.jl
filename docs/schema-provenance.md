# Packaged schema provenance

Contracts owns the canonical schema definitions. Runner packages their bytes in `schema/` and
records declared SHA256 digests in `schema/PROVENANCE.json`. Its source URL and version are
descriptive metadata. The selected workspace Git gitlink identifies the Contracts source; this file
is not a second revision lock.

The runtime and CLI enforce the verification contract below. Input configuration resolution
currently verifies both bundled run.schema.json and the complete result contract registry. A
canonical result registry update therefore requires the reviewed Runner mirror/provenance refresh
before input-only resolution can proceed. This is a source composition gate, not a scientific or
native readiness gate.

`tools/verify_schema_provenance.jl` provides one verifier for the CLI and runtime. It parses the
provenance mapping, checks every declared packaged file, and hashes the exact captured bytes.
Workspace mode additionally compares those bytes with the canonical files below the selected root's
`components/qcl-negf-contracts/src/qcl_negf_contracts/schemas/`. Standalone mode checks bundled
declared digests and needs no sibling Contracts checkout.

From a prepared root workspace, run:

    julia --startup-file=no --project=julia --threads=1 components/QCLNEGFRunner.jl/tools/verify_schema_provenance.jl --mode workspace --workspace-root .

From a prepared standalone Runner environment, run:

    julia --startup-file=no --project=. --threads=1 tools/verify_schema_provenance.jl --mode standalone

These commands need the selected Julia runtime and its existing YAML dependency. They do not install
packages or fetch a remote latest schema. A mismatch, missing file, invalid provenance mapping, or
unsupported mode fails with process status 2. A successful check exits 0 and identifies the mode and
checked-file count.

Runtime verification runs before a configuration schema is used and before `_resolve_configuration`
converts a declarative or frozen-plan mapping to typed values. The package resolves resources from
its loaded installation location. It detects a source workspace from its component placement and
root `.gitmodules` marker; within a detected workspace, a missing Contracts copy is an error. An
installed standalone runtime uses its bundled files. It does not infer workspace selection from the
caller's current directory. Verification has no success cache.

Configuration APIs report verification failure as `ConfigurationError`; the existing `qcl-negf`
command maps that exception to status 2. The verifier does not run at package import and does not
add a new scientific acceptance condition. A caller-supplied `schema_path` still undergoes the
existing schema validation; it does not bypass packaged verification or become a canonical packaged
schema.

To update a packaged schema, first publish and review the canonical Contracts change. Select that
source through the workspace workflow, copy its schema bytes without independent edits, and update
the existing declared digest from those bytes. Review the copy, provenance, and negative controls
together in Runner. The root integration owner subsequently publishes the owning gitlink selection.

Byte agreement establishes the checked schema copies' integrity. It does not establish model
adequacy, convergence, discretization sufficiency, experimental validation, or the complete origin
of an effective configuration value.
