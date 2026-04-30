# Guest-side NixOS module.
#
# Import this module in the NixOS configuration you deploy to a deployable
# container (e.g. in your Colmena hive).  It configures the system to run
# correctly inside a systemd-nspawn container that shares the host's Nix store
# and nix-daemon socket.
#
# Example Colmena usage:
#
#   {
#     "my-container" = { deployable-containers, ... }: {
#       deployment.targetHost = "10.100.0.2";
#       imports = [ deployable-containers.nixosModules.deployable-container-guest ];
#       # … your service config …
#     };
#   }
{
  flake.nixosModules.deployable-container-guest = {
    lib,
    pkgs,
    ...
  }: {
    # Required: tells NixOS it is running in a container.
    boot.isContainer = true;

    # Things that do not exist or make no sense inside nspawn.
    boot.kernel.enable = lib.mkDefault false;
    boot.modprobeConfig.enable = lib.mkDefault false;
    security.audit.enable = lib.mkDefault false;
    services.udev.enable = lib.mkDefault false;
    services.lvm.enable = lib.mkDefault false;
    powerManagement.enable = lib.mkDefault false;
    documentation.nixos.enable = lib.mkDefault false;

    # Store is read-only, shared with the host — no point optimising it here.
    nix.optimise.automatic = lib.mkDefault false;

    # All nix operations go through the host's daemon, so GC runs on the host
    # store with host privileges.  Containers must never trigger GC themselves.
    nix.gc.automatic = lib.mkForce false;

    # Route all nix operations through the host's daemon (socket is bind-mounted
    # at the standard path by the deployable-containers host module).
    environment.variables.NIX_REMOTE = lib.mkDefault "daemon";
    nix.settings.trusted-users = lib.mkDefault ["root" "@wheel"];
    nix.settings.experimental-features = lib.mkDefault ["nix-command" "flakes"];

    # Use the host's resolver rather than managing our own.
    networking.useHostResolvConf = lib.mkDefault true;

    # Start SSH on demand so it does not consume resources when idle.
    services.openssh.startWhenNeeded = lib.mkDefault true;

    # There is no boot loader in a container; make the activation script a no-op
    # for that phase.
    system.build.installBootLoader = lib.mkDefault "${pkgs.coreutils}/bin/true";
  };
}
