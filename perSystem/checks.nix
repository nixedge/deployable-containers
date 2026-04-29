# NixOS tests for deployable-containers.
#
# `perSystem/checks.nix` is auto-imported by `recursiveImports` so every test
# defined here appears under `checks.<system>.*` in the flake outputs.
#
# The `self` argument comes from the flake-parts module system and gives us
# access to the nixosModules defined in this flake.
{self, ...}: {
  perSystem = {
    pkgs,
    lib,
    ...
  }: let
    # Generate a fresh ED25519 key pair at build time.  The public key is
    # embedded in container bootstrap images; the private key is placed on the
    # test host VM so the test script can SSH in.
    #
    # This is IFD (import-from-derivation), which is acceptable in tests.
    testKeyPair = pkgs.runCommand "dc-test-key-pair" {} ''
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f "$TMPDIR/key"
      mkdir -p "$out"
      cp "$TMPDIR/key"     "$out/private"
      cp "$TMPDIR/key.pub" "$out/public"
    '';

    testPublicKey = lib.removeSuffix "\n" (builtins.readFile "${testKeyPair}/public");

    # Shared args forwarded to every test file.
    testArgs = {inherit self pkgs lib testKeyPair testPublicKey;};
  in {
    checks = {
      # Integration test: static-IP veth container, SSH, profile persistence.
      basic-veth = pkgs.testers.nixosTest (import ../tests/basic-veth.nix testArgs);

      # Evaluation-only test: guest module sets the expected config values.
      guest-module = import ../tests/guest-module.nix testArgs;
    };
  };
}
