{
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    treefmt = {
      projectRootFile = "flake.nix";
      programs.alejandra.enable = true;
      settings.global.excludes = [
        "*.lock"
        ".gitignore"
        "LICENSE"
      ];
    };

    formatter = config.treefmt.build.wrapper;
  };
}
