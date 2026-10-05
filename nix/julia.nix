{ pkgs, testProfile ? "production-build", testWorkerLimit ? null }:
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
assert builtins.elem testProfile [ "production-build" "local-debug" ];
assert testWorkerLimit == null || (builtins.isInt testWorkerLimit && testWorkerLimit > 0);
assert testProfile != "local-debug" || testWorkerLimit == null || testWorkerLimit == 2;
let workerLimit = if testProfile == "local-debug" then 2 else testWorkerLimit;
in
# Instantiate the pinned nixpkgs factory with this version. overrideAttrs on an
# already-created julia-bin leaves version-dependent phases closed over the old
# version, including the NetworkOptions stdlib patch path.
(pkgs.callPackage (import (pkgs.path + "/pkgs/development/compilers/julia/generic-bin.nix") {
  version = "1.13.0";
  sha256.x86_64-linux = "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b";
}) { }).overrideAttrs (old: {
  # A caller can admit an explicit production worker budget from available RAM.
  # With no budget production keeps the upstream count; local-debug always uses
  # two workers. These limits preserve native CPU/affinity and BLAS detection.
  # Any version-bound patch fails if upstream worker selection changes.
  postPatch = (old.postPatch or "") + pkgs.lib.optionalString (workerLimit != null) ''
    substituteInPlace share/julia/test/runtests.jl \
      --replace-fail \
        'n = min(Sys.EFFECTIVE_CPU_THREADS, length(tests))' \
        'n = min(${toString workerLimit}, Sys.EFFECTIVE_CPU_THREADS, length(tests))'
  '';
  preInstallCheck = (old.preInstallCheck or "") + ''
    "$out/bin/julia" --startup-file=no --threads=1 ${./tests/julia_cpu_budget.jl} ${testProfile} ${if workerLimit == null then "native" else toString workerLimit}
  '';
})
