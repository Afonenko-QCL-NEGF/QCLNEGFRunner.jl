# Evaluation only: use the release's pinned nixpkgs source, without constructing
# real derivations, fetching Julia, or executing its install checks.
{ nixpkgs }:
let
  source = builtins.toPath nixpkgs;
  lib = import (source + "/lib");
  factory = import (source + "/pkgs/development/compilers/julia/generic-bin.nix");
  mkDerivation = attrs: attrs // {
    overrideAttrs = update: mkDerivation (attrs // (update attrs));
  };
  stdenv = {
    hostPlatform = {
      system = "x86_64-linux";
      isLinux = true;
      isDarwin = false;
      isx86_64 = true;
    };
    cc.cc = "mock-compiler-runtime";
    inherit mkDerivation;
  };
  dependencies = {
    inherit lib stdenv;
    autoPatchelfHook = "mock-auto-patchelf-hook";
    fetchurl = attrs: attrs;
  };
  callPackage = function: overrides: function (dependencies // overrides);
  pkgs = dependencies // {
    inherit callPackage;
    path = source;
    # Reproduce the real upstream version closure for the previous overrideAttrs
    # implementation. The test evaluates the upstream factory, not copied phases.
    julia-bin = callPackage (factory {
      version = "1.12.6";
      sha256.x86_64-linux = "upstream-version-fixture";
    }) { };
  };
  default = import ./julia.nix { inherit pkgs; };
  production = import ./julia.nix { inherit pkgs; testProfile = "production-build"; };
  localDebug = import ./julia.nix { inherit pkgs; testProfile = "local-debug"; };
  productionBound = import ./julia.nix {
    inherit pkgs;
    testProfile = "production-build";
    testWorkerLimit = 16;
  };
  expected = callPackage (factory {
    version = "1.13.0";
    sha256.x86_64-linux = "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b";
  }) { };
  same = julia: field: julia.${field} == expected.${field};
  contract = julia:
    assert lib.assertMsg (julia.version == expected.version && julia.src == expected.src)
      "Julia source must use the immutable 1.13.0 URL and SHA-256";
    assert lib.assertMsg (lib.hasPrefix expected.postPatch julia.postPatch)
      "Julia 1.13.0 must retain the upstream stdlib patch";
    assert lib.assertMsg (same julia "patches" && same julia "nativeBuildInputs"
      && same julia "installPhase" && same julia "dontStrip" && same julia "dontAutoPatchelf")
      "Julia must retain the pinned upstream binary patching and installation contract";
    assert lib.assertMsg (julia.doInstallCheck
      && lib.hasPrefix expected.preInstallCheck julia.preInstallCheck
      && same julia "installCheckPhase")
      "Julia must retain the pinned upstream install checks and version-dependent skip list";
    assert lib.assertMsg (!(julia ? JULIA_CPU_THREADS))
      "Test profiles must not override native Julia CPU detection";
    true;
in
assert lib.assertMsg (default.postPatch == expected.postPatch)
  "The default production profile must retain the upstream native worker count";
assert lib.all contract [ default production localDebug productionBound ];
assert lib.assertMsg (production.postPatch == expected.postPatch
  && default.preInstallCheck == production.preInstallCheck)
  "Explicit production and default must leave the upstream launcher unchanged";
assert lib.assertMsg (lib.hasInfix "--replace-fail" localDebug.postPatch
  && lib.hasInfix "n = min(2, Sys.EFFECTIVE_CPU_THREADS, length(tests))" localDebug.postPatch)
  "Only local-debug must apply the version-pinned fail-on-mismatch worker limit";
assert lib.assertMsg (lib.hasInfix "julia_cpu_budget.jl production-build" production.preInstallCheck
  && lib.hasInfix "julia_cpu_budget.jl local-debug" localDebug.preInstallCheck)
  "Each install-check guard must receive its selected test profile";
assert lib.assertMsg (lib.hasInfix "--replace-fail" productionBound.postPatch
  && lib.hasInfix "n = min(16, Sys.EFFECTIVE_CPU_THREADS, length(tests))" productionBound.postPatch
  && lib.hasInfix "julia_cpu_budget.jl production-build 16" productionBound.preInstallCheck)
  "An explicit production worker budget must cap only workers and reach the guard";
assert lib.assertMsg (!(builtins.tryEval (import ./julia.nix { inherit pkgs; testProfile = "unknown"; })).success)
  "Unknown Julia test profiles must be rejected";
assert lib.all (limit: !(builtins.tryEval (import ./julia.nix {
  inherit pkgs; testWorkerLimit = limit;
})).success) [ 0 (-1) "16" ];
assert !(builtins.tryEval (import ./julia.nix {
  inherit pkgs; testProfile = "local-debug"; testWorkerLimit = 16;
})).success;
assert (import ./julia.nix {
  inherit pkgs; testProfile = "local-debug"; testWorkerLimit = 2;
}).postPatch == localDebug.postPatch;
{
  version = default.version;
  source = default.src;
  patchStdlib = "v1.13";
  upstreamPatchingRetained = true;
  upstreamInstallChecksRetained = default.doInstallCheck;
  upstreamPreInstallHookRetained = true;
  defaultProfile = "production-build";
  nativeCpuDetectionRetained = true;
  profiles = {
    production-build = {
      testWorkerLimit = "Sys.EFFECTIVE_CPU_THREADS";
      postPatch = production.postPatch;
    };
    local-debug = {
      testWorkerLimit = 2;
      postPatch = localDebug.postPatch;
    };
    production-bounded = {
      testWorkerLimit = 16;
      postPatch = productionBound.postPatch;
    };
  };
}
