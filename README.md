# QCLNEGFRunner.jl

Julia **1.13.0** execution and storage adapters for
[QCLNEGF.jl](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl), version **0.2.0**.
The runner validates YAML input, freezes scientific plans, executes calculations,
checks process resource limits, writes verified results and HDF5 checkpoints,
and analyzes saved data. CairoMakie plotting is an optional extension.

## Run

Prepare the package environment from a published checkout:

```console
julia --project=. -e 'using Pkg; Pkg.instantiate()'
bin/qcl-negf plan examples/config/operator-algebra.yaml > plan.json
bin/qcl-negf run-plan plan.json result
bin/qcl-negf analyze result analysis
```

A study must declare configuration sources, temperature and voltage axes.
`run-plan PLAN OUTPUT --execution-id ID` selects an ID in `plan.executions`.
AiiDA can schedule independent executions while continuation points inside an
execution remain sequential. One Slurm task hosts one Julia process; set
`JULIA_NUM_THREADS` to the allocated CPUs per task.

Exit code zero means that the process completed. Inspect result and point statuses,
quality and physical gates before using a result as scientific evidence. HDF5 is a required Runner dependency. Plotting additionally requires CairoMakie in
the active Julia environment.

For direct Julia use, import `QCLNEGF` for scientific types and numerical functions,
and `QCLNEGFRunner` for adapters. Core depends only on its numerical dependencies;
Runner depends on core.

## Development and installation

```console
deno task check
deno task test:depot
deno task test
deno task docs
```

Release environments lock Julia dependencies in a Pkg-generated manifest. Tests exercise configuration errors,
persistence, exact restart, adapter boundaries and public command-line behavior.
The [platform repository](https://github.com/Afonenko-QCL-NEGF/qcl-negf-platform) owns
NixOS installation and trusted local GitHub Actions runners. Source repositories
remain on GitHub.

The root workspace's `solver:depot` command prepares an empty dependency depot
with exactly Julia 1.13.0 and its committed Julia manifest. Preparation captures
all artifacts selected for the host, including lazy artifacts, and verifies their
tree hashes before retaining the depot. It also retains the captured registry:
Julia Pkg checks for a registry before checking whether packages are already
installed. Registry, package and artifact bytes all enter the root command's
SHA-256 archive; temporary compilation, logs and scratch caches are removed.
The Nix package uses this complete input with registry updates disabled.

Generate a fresh depot after committing the runner change and its root gitlink.
The root command binds the depot to that source revision and Julia manifest hash;
an older archive without its registry cannot supply this build. Preparation needs
network access and temporary disk space for all selected artifacts and the archive.
`test:depot` checks capture/pruning with a fake Julia process; it runs no Julia,
scientific calculation, dependency download or Nix build. A real sandbox build is
still required to establish the complete runtime behavior.

The Nix Julia package constructs the binary derivation with the release's pinned
nixpkgs `pkgs/development/compilers/julia/generic-bin.nix` factory and the immutable
Julia 1.13.0 archive hash. Passing the version to that factory regenerates its
version-dependent stdlib patch paths and test selection. Changing only `version`
and `src` with `overrideAttrs` on an existing `julia-bin` retains the original
version in those phases. The upstream patching, installation and install checks
remain enabled.

A focused evaluation contract uses the selected nixpkgs source and mocks only
the build/fetch dependencies:

```console
nix-instantiate --store dummy:// --eval --strict --json nix/test-julia.nix \
  --argstr nixpkgs /absolute/path/to/pinned/nixpkgs
```

This check compares the generated source, patching and install-check phases with
the pinned upstream factory. It does not create derivations, fetch the archive,
run Julia or establish that the Julia binary installs successfully.

For coordinated development from adjacent checkouts, create a separate integration
environment without rewriting either package project:

```console
julia tools/prepare_workspace.jl ../QCLNEGF.jl . ../qcl-negf-env
QCL_NEGF_PROJECT=/absolute/path/to/qcl-negf-env deno task test
QCL_NEGF_PROJECT=/absolute/path/to/qcl-negf-env deno task docs
```

Use the same `QCL_NEGF_PROJECT` value when invoking `bin/qcl-negf` from that workspace.
The generated manifest belongs to the integration/release environment. The published
Runner project resolves core from its `v0.2.0` source tag.

The [configuration guide](docs/src/user/configuration.md),
[results and restart](docs/src/user/results.md),
[resource boundary](docs/src/user/resources.md), and
[architecture](docs/src/developer/architecture.md) describe runtime behavior.
The physical equations and independent numerical operators are documented in
[QCLNEGF.jl](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/tree/main/docs/src).

The [contracts repository](https://github.com/Afonenko-QCL-NEGF/qcl-negf-contracts) owns
schemas; [qcl-negf-results](https://github.com/Afonenko-QCL-NEGF/qcl-negf-results) reads
published data in Python. [qcl-negf-aiida](https://github.com/Afonenko-QCL-NEGF/qcl-negf-aiida)
owns distributed workflows; [qcl-negf-research](https://github.com/Afonenko-QCL-NEGF/qcl-negf-research)
owns scientific studies.

License: MIT.
