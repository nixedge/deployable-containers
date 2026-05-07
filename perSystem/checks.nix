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
    # Hard-coded ED25519 test key pair.  Using a static key avoids IFD and
    # ensures the public key baked into container bootstrap images always
    # matches the private key placed on the test host VM.
    #
    # These keys are only ever used inside ephemeral NixOS test VMs.
    testPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKpEzamReEZXDjHbgHiStFOvTC9NbDbfj9wVyejO5e0 deployable-containers-test";

    testKeyPair = pkgs.runCommand "dc-test-key-pair" {} ''
      mkdir -p "$out"
      cat > "$out/private" <<'EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACByqRM2pkXhGVw4x24B4krRTr0wvTWw234/cFcnozuXtAAAAKDif3Gu4n9x
rgAAAAtzc2gtZWQyNTUxOQAAACByqRM2pkXhGVw4x24B4krRTr0wvTWw234/cFcnozuXtA
AAAECJZDOIRi/hpDhoMUjL6ecSH2FWhtEIAjBsRXrkm4mTDXKpEzamReEZXDjHbgHiStFO
vTC9NbDbfj9wVyejO5e0AAAAGmRlcGxveWFibGUtY29udGFpbmVycy10ZXN0AQID
-----END OPENSSH PRIVATE KEY-----
EOF
    '';

    # Second-generation container system used in the GC-protection deploy
    # simulation.  Mirrors the bootstrap system config but adds hello to
    # systemPackages, giving us a concrete store path to track through GC.
    deployedContainerSystem = (pkgs.nixos ({lib, pkgs, ...}: {
      boot.isContainer = true;
      users.users.root.openssh.authorizedKeys.keys = [testPublicKey];
      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = lib.mkDefault "prohibit-password";
          PasswordAuthentication = lib.mkDefault false;
          UseDns = false;
        };
      };
      environment.systemPackages = [pkgs.hello];
      environment.variables.NIX_REMOTE = lib.mkDefault "daemon";
      nix.settings.trusted-users = ["root" "@wheel"];
      nix.settings.experimental-features = ["nix-command" "flakes"];
      system.stateVersion = lib.trivial.release;
    })).toplevel;

    # Shared args forwarded to every test file.
    testArgs = {inherit self pkgs lib testKeyPair testPublicKey deployedContainerSystem;};
  in {
    checks = {
      # Integration test: static-IP veth container, SSH, profile persistence.
      basic-veth = pkgs.testers.nixosTest (import ../tests/basic-veth.nix testArgs);

      # Integration test: GC denied inside container; host GC roots are valid.
      gc-protection = pkgs.testers.nixosTest (import ../tests/gc-protection.nix testArgs);

      # Evaluation-only test: guest module sets the expected config values.
      guest-module = import ../tests/guest-module.nix testArgs;
    };
  };
}
