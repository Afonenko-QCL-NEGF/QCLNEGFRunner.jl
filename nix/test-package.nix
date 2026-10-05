# Pure evaluation of the actual derivation; dummy store, no realization.
{ nixpkgs }:
let
  pkgs = import (builtins.toPath nixpkgs) { system = "x86_64-linux"; };
  bundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  inputs = {
    inherit pkgs;
    julia = import ./julia.nix { inherit pkgs; };
    preparedDepot = pkgs.emptyDirectory;
    # No sources are read or built. These fixtures let package evaluation stay
    # independent of an external scientific workspace and prepared depot.
    coreSrc = ../.;
    runnerSrc = ../.;
    environmentSrc = ../.;
  };
  package = import ./package.nix inputs;
  production = import ./package.nix (inputs // { testProfile = "production-build"; });
  localDebug = import ./package.nix (inputs // { testProfile = "local-debug"; });
  # Regex matching cannot accept store context. Check the actual environment's
  # context separately below before discarding it for textual wrapper checks.
  contains = text: pkgs.lib.hasInfix
    (builtins.unsafeDiscardStringContext text)
    (builtins.unsafeDiscardStringContext package.installPhase);
in
assert (package.JULIA_SSL_CA_ROOTS_PATH or "") == bundle;
assert builtins.getContext package.JULIA_SSL_CA_ROOTS_PATH == builtins.getContext bundle;
assert builtins.getContext bundle != {};
assert contains "--set JULIA_SSL_CA_ROOTS_PATH \"${bundle}\"";
assert contains "export JULIA_PKG_OFFLINE=true";
assert contains "--set JULIA_PKG_OFFLINE true";
assert package.doInstallCheck;
assert package.installPhase == production.installPhase;
assert contains "export JULIA_NUM_PRECOMPILE_TASKS=\"$NIX_BUILD_CORES\"";
assert !(contains "export JULIA_NUM_PRECOMPILE_TASKS=2");
assert pkgs.lib.hasInfix "export JULIA_NUM_PRECOMPILE_TASKS=2" localDebug.installPhase;
assert localDebug.JULIA_SSL_CA_ROOTS_PATH == bundle && localDebug.doInstallCheck;
assert !(package ? JULIA_CPU_THREADS) && !(localDebug ? JULIA_CPU_THREADS);
assert !(builtins.tryEval (import ./package.nix (inputs // { testProfile = "unknown"; }))).success;
{
  buildCaBundle = package.JULIA_SSL_CA_ROOTS_PATH;
  runtimeCaBundlePinned = true;
  storeContextRetained = true;
  offlineRetained = true;
  installCheckRetained = true;
  pureEvaluationOnly = true;
  defaultProfile = "production-build";
  productionPrecompileTasks = "NIX_BUILD_CORES";
  localDebugPrecompileTasks = 2;
  # Expose generated phases for bounded environment-only checks, without
  # executing Pkg, package imports, source copying or derivation builds.
  profileInstallPhases = {
    production-build = package.installPhase;
    local-debug = localDebug.installPhase;
  };
}
