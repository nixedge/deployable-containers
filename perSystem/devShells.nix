{inputs, ...}: {
  perSystem = {
    config,
    inputs',
    pkgs,
    ...
  }: let
    toolchain = with inputs'.fenix.packages;
      combine [
        minimal.rustc
        minimal.cargo
        stable.rust-analyzer
        stable.rustfmt
        stable.clippy
      ];
  in {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        # Rust toolchain
        toolchain

        # Deployment
        colmena

        # Nix tooling
        nix
        nix-tree # inspect container closure sizes

        # Network diagnostics
        iproute2
        openssh

        # Code formatting (wraps alejandra for .nix files)
        config.treefmt.build.wrapper
      ];

      shellHook = ''
        echo "deployable-containers dev shell"
        echo "  cargo    $(cargo --version)"
        echo "  colmena  $(colmena --version)"
        echo "  nix      $(nix --version)"
      '';
    };
  };
}
