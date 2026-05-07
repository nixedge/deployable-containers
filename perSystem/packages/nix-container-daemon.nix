{inputs, ...}: {
  perSystem = {
    inputs',
    lib,
    pkgs,
    ...
  }: let
    toolchain = inputs'.fenix.packages.minimal.toolchain;
    craneLib = (inputs.crane.mkLib pkgs).overrideToolchain toolchain;

    src = lib.fileset.toSource {
      root = ../../nix-container-daemon;
      fileset = lib.fileset.unions [
        ../../nix-container-daemon/Cargo.lock
        ../../nix-container-daemon/Cargo.toml
        ../../nix-container-daemon/src
      ];
    };
  in {
    packages.nix-container-daemon = craneLib.buildPackage {
      inherit src;
      pname = "nix-container-daemon";
      version = "0.1.0";
      strictDeps = true;
    };
  };
}
