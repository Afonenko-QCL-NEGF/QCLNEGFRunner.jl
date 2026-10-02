{ pkgs }:
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
# Instantiate the pinned nixpkgs factory with this version. overrideAttrs on an
# already-created julia-bin leaves version-dependent phases closed over the old
# version, including the NetworkOptions stdlib patch path.
pkgs.callPackage (import (pkgs.path + "/pkgs/development/compilers/julia/generic-bin.nix") {
  version = "1.13.0";
  sha256.x86_64-linux = "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b";
}) { }
