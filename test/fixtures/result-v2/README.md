# Manufactured result-v2 / native5 fixtures

The fixture packet contains public-constructor state and persistence operations only. It never runs
transport, SCBA/Poisson, a completed map, package installation or precompilation. Generated arrays
and raw logs belong in a fresh caller-owned directory outside versioned fixture sources. Keep failed
attempts under their original unique identities.

From the Runner checkout, using the explicitly prepared Julia project/depot and Python environment:

```sh
QCL_P04_TEST_ROOT=/absolute/fresh/owned/directory julia --project=/prepared/project --startup-file=no --compiled-modules=existing -O0 --check-bounds=yes test/focused/scientific_persistence_v2.jl
python test/contracts/check_scientific_persistence_v2.py /absolute/fresh/owned/directory
```

Create the supplied root before running. Python requires the published `qcl_negf_contracts`, h5py
and NumPy already present; this packet does not bootstrap them. The independent checker uses
canonical validators, HDF5 and literal values rather than Runner encoder/decoder code.

The packet records typed SCBA append/update and complete outer vectors, public exact-state
validation/materialization/restore, actual native rank1/2/4 and empty/non-square arrays, IEEE bits,
complex compound/Bool enum, chunk bounds, bounded locator metadata, no old-prefix payload reads,
frozen live/exact cutoffs, immediate-parent/multihop anchors, all seven publication barriers and
hash/path/native-layout negative cases. A final frozen source receipt must accompany its logs.

Core restore is an owning semantic validator. Same-Core roundtrip plus literal Python decoding is
not an independent physics oracle, continuous-versus-resumed solve, production performance
measurement, cross-NFS durability test or installed-service readiness result.
