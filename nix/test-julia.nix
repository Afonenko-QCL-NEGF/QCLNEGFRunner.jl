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
  julia = import ./julia.nix { inherit pkgs; };
  expected = callPackage (factory {
    version = "1.13.0";
    sha256.x86_64-linux = "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b";
  }) { };
  same = field: julia.${field} == expected.${field};
in
assert lib.assertMsg (julia.version == expected.version && julia.src == expected.src)
  "Julia source must use the immutable 1.13.0 URL and SHA-256";
assert lib.assertMsg (same "postPatch")
  "Julia 1.13.0 must regenerate the upstream stdlib patch path, not retain v1.12";
assert lib.assertMsg (same "patches" && same "nativeBuildInputs" && same "installPhase"
  && same "dontStrip" && same "dontAutoPatchelf")
  "Julia must retain the pinned upstream binary patching and installation contract";
assert lib.assertMsg (julia.doInstallCheck && same "preInstallCheck" && same "installCheckPhase")
  "Julia must retain the pinned upstream install checks and version-dependent skip list";
{
  version = julia.version;
  source = julia.src;
  patchStdlib = "v1.13";
  upstreamPatchingRetained = true;
  upstreamInstallChecksRetained = julia.doInstallCheck;
}
