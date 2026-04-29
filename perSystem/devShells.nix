{
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
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
        echo "  colmena  $(colmena --version)"
        echo "  nix      $(nix --version)"
      '';
    };
  };
}
