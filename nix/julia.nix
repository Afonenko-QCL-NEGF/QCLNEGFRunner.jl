{ pkgs }:
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
pkgs.julia-bin.overrideAttrs (_old: {
  version = "1.13.0";
  src = pkgs.fetchurl {
    url = "https://julialang-s3.julialang.org/bin/linux/x64/1.13/julia-1.13.0-linux-x86_64.tar.gz";
    sha256 = "8975da61c128a5e5ded3e719e868da8c8781deb7ad7913d37fb99be02a81904b";
  };
})
