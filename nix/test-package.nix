# Pure evaluation of the actual derivation; dummy store, no realization.
{ nixpkgs }:
let
  pkgs = import (builtins.toPath nixpkgs) { system = "x86_64-linux"; };
  bundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  package = import ./package.nix {
    inherit pkgs;
    julia = import ./julia.nix { inherit pkgs; };
    preparedDepot = pkgs.emptyDirectory;
    # No sources are read or built. These fixtures let package evaluation stay
    # independent of an external scientific workspace and prepared depot.
    coreSrc = ../.;
    runnerSrc = ../.;
    environmentSrc = ../.;
  };
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
{
  buildCaBundle = package.JULIA_SSL_CA_ROOTS_PATH;
  runtimeCaBundlePinned = true;
  storeContextRetained = true;
  offlineRetained = true;
  installCheckRetained = true;
  pureEvaluationOnly = true;
}
