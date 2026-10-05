{ pkgs }:
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
# Instantiate the pinned nixpkgs factory with this version. overrideAttrs on an
# already-created julia-bin leaves version-dependent phases closed over the old
# version, including the NetworkOptions stdlib patch path.
(pkgs.callPackage (import (pkgs.path + "/pkgs/development/compilers/julia/generic-bin.nix") {
  version = "1.13.0";
  sha256.x86_64-linux = "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b";
}) { }).overrideAttrs (old: {
  # Bound test worker processes, not Julia's native CPU/affinity detection.
  # JULIA_CPU_THREADS also changes BLAS defaults in child affinity tests.
  # This local launcher patch targets the pinned 1.13.0 source and must fail
  # if its upstream worker-selection expression changes. Test selection and
  # the factory's original install-check command remain unchanged.
  postPatch = (old.postPatch or "") + ''
    substituteInPlace share/julia/test/runtests.jl \
      --replace-fail \
        'n = min(Sys.EFFECTIVE_CPU_THREADS, length(tests))' \
        'n = min(2, Sys.EFFECTIVE_CPU_THREADS, length(tests))'
  '';
  preInstallCheck = (old.preInstallCheck or "") + ''
    "$out/bin/julia" --startup-file=no --threads=1 ${./tests/julia_cpu_budget.jl}
  '';
})
