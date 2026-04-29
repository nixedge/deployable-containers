# NixOS test: guest module correctness
#
# Builds a minimal NixOS system with the deployable-container-guest module and
# checks that the expected option values are set.  This runs as a plain
# derivation — no QEMU VM needed.
{
  self,
  pkgs,
  lib,
  ...
}: let
  eval = pkgs.nixos {
    imports = [self.nixosModules.deployable-container-guest];
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
    system.stateVersion = lib.trivial.release;
  };
in
  pkgs.runCommand "dc-guest-module-check" {} ''
    set -euo pipefail

    echo "--- checking deployable-container-guest options ---"

    # boot.isContainer
    ${
      if eval.config.boot.isContainer
      then "echo 'PASS: boot.isContainer = true'"
      else "echo 'FAIL: boot.isContainer should be true'; exit 1"
    }

    # NIX_REMOTE
    ${
      if eval.config.environment.variables.NIX_REMOTE or "" == "daemon"
      then "echo 'PASS: NIX_REMOTE = daemon'"
      else "echo 'FAIL: NIX_REMOTE should be daemon'; exit 1"
    }

    # networking.useHostResolvConf
    ${
      if eval.config.networking.useHostResolvConf
      then "echo 'PASS: networking.useHostResolvConf = true'"
      else "echo 'FAIL: networking.useHostResolvConf should be true'; exit 1"
    }

    # services.udev is disabled
    ${
      if !eval.config.services.udev.enable
      then "echo 'PASS: services.udev.enable = false'"
      else "echo 'FAIL: services.udev.enable should be false'; exit 1"
    }

    touch $out
    echo "--- all checks passed ---"
  ''
