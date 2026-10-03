{ pkgs }:
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
# Instantiate the pinned nixpkgs factory with this version. overrideAttrs on an
# already-created julia-bin leaves version-dependent phases closed over the old
# version, including the NetworkOptions stdlib patch path.
(pkgs.callPackage (import (pkgs.path + "/pkgs/development/compilers/julia/generic-bin.nix") {
  version = "1.13.0";
  sha256.x86_64-linux = "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b";
}) { }).overrideAttrs (old: {
  # Julia's upstream test launcher uses Sys.EFFECTIVE_CPU_THREADS rather than
  # NIX_BUILD_CORES. The supported override bounds workers without skipping tests.
  JULIA_CPU_THREADS = "2";
  preInstallCheck = (old.preInstallCheck or "") + ''
    "$out/bin/julia" --startup-file=no --threads=1 ${./tests/julia_cpu_budget.jl}
  '';
})
