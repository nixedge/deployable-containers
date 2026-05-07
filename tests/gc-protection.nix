# NixOS test: GC protection via the nix-container-daemon proxy
#
# Verifies two properties:
#
#   1. A container cannot trigger GC on the host.
#      The proxy (nix-container-daemon) runs as an unprivileged user.  The
#      nix-daemon rejects wopCollectGarbage for untrusted callers with:
#        "error: you are not privileged to collect garbage"
#      Normal read/build operations must continue to work.
#
#   2. The host holds a GC root that covers the container's profiles directory,
#      so a host-side GC cannot delete any deployed generation — including one
#      that was deployed via a switch (no service restart).
{
  self,
  pkgs,
  lib,
  testKeyPair,
  testPublicKey,
  deployedContainerSystem,
  ...
}: {
  name = "deployable-containers-gc-protection";

  nodes.host = {pkgs, ...}: {
    imports = [self.nixosModules.deployable-containers];

    virtualisation.memorySize = 2048;
    virtualisation.additionalPaths = [deployedContainerSystem];

    deployableContainers.containers.svc = {
      rootSSHKeys = [testPublicKey];
      hostAddress = "10.100.0.1/32";
      localAddress = "10.100.0.2/32";
    };

    environment.etc."dc-test-key" = {
      mode = "0600";
      source = "${testKeyPair}/private";
    };

    boot.kernelParams = ["quiet"];
  };

  testScript = ''
    SSH = "ssh -i /etc/dc-test-key -o StrictHostKeyChecking=no -o ConnectTimeout=5"
    CT_IP = "10.100.0.2"

    host.start()

    # ── Proxy infrastructure ───────────────────────────────────────────────────

    with subtest("nix-container-daemon service is active"):
        host.wait_for_unit("nix-container-daemon.service", timeout=30)

    with subtest("proxy socket file exists"):
        host.succeed("test -S /run/nix-container-daemon/socket")

    # ── Container reachability ─────────────────────────────────────────────────

    with subtest("container service reaches running state"):
        host.wait_for_unit("deployable-container-svc.service", timeout=30)

    with subtest("container is reachable over SSH"):
        host.wait_until_succeeds(
            f"{SSH} root@{CT_IP} true",
            timeout=30,
        )

    # ── GC is denied ──────────────────────────────────────────────────────────
    #
    # The container connects to the proxy socket, which forwards the connection
    # to the host nix-daemon as the unprivileged nix-container-daemon user.
    # The daemon's wopCollectGarbage handler checks SO_PEERCRED and rejects the
    # request with "not privileged to collect garbage".

    with subtest("container cannot trigger GC on host"):
        rc, out = host.execute(
            f"{SSH} root@{CT_IP}"
            " '/run/current-system/sw/bin/nix-collect-garbage 2>&1'",
            timeout=5,
        )
        assert rc != 0, (
            f"nix-collect-garbage should have been denied but exited {rc}.\n"
            f"Output: {out}"
        )
        assert "not privileged" in out, (
            f"Expected a privilege-denial error from nix-daemon, got:\n{out}"
        )

    # ── Normal nix operations still work ──────────────────────────────────────
    #
    # Read-only queries and path-info must succeed; blocking GC must not
    # break the container's ability to use nix for deployments.

    with subtest("container can query store paths via the proxy"):
        host.succeed(
            f"{SSH} root@{CT_IP}"
            " 'nix-store --check-validity /run/current-system'",
            timeout=5,
        )

    # ── Host GC roots protect the container's generation ──────────────────────

    with subtest("host GC root for container exists"):
        host.succeed(
            "test -L /nix/var/nix/gcroots/deployable-containers/svc",
            timeout=5,
        )

    with subtest("GC root resolves to the container's profiles directory"):
        # The symlink must point at the profiles dir, not dangle.
        profiles = host.succeed(
            "readlink /nix/var/nix/gcroots/deployable-containers/svc",
            timeout=5,
        ).strip()
        host.succeed(f"test -d {profiles}", timeout=5)
        host.succeed(f"test -L {profiles}/system", timeout=5)

    with subtest("container's current system generation is a live store path"):
        system_path = host.succeed(
            "readlink -f /var/lib/deployable-containers/svc/profiles/system",
            timeout=5,
        ).strip()
        # nix-store --check-validity exits 0 iff the path exists in the store.
        host.succeed(
            f"/run/current-system/sw/bin/nix-store --check-validity {system_path}",
            timeout=5,
        )

    # ── Deploy simulation: GC protects a newly-deployed generation ────────────
    #
    # Simulate what Colmena does during a switch-style deploy: update the
    # container's nix-env profile to a new generation (one that adds hello to
    # systemPackages) without restarting the container service.  Then run host
    # GC and verify the new generation was not collected.
    #
    # This exercises the profiles-directory GC root: the root points at the
    # profiles directory, so Nix traverses all generation symlinks within it
    # and protects every generation — including ones deployed after boot.

    DEPLOYED = "${deployedContainerSystem}"

    with subtest("pre-deploy: initial container system has no hello"):
        rc, _ = host.execute(
            f"{SSH} root@{CT_IP} 'test -f /run/current-system/sw/bin/hello'",
            timeout=5,
        )
        assert rc != 0, "hello must not be present before the simulated deploy"

    with subtest("simulate deploy: advance container profile to system with hello"):
        host.succeed(
            "nix-env --option substituters ''' --profile"
            " /var/lib/deployable-containers/svc/profiles/system"
            f" --set {DEPLOYED}",
            timeout=30,
        )

    with subtest("deployed system contains hello"):
        host.succeed(f"test -f {DEPLOYED}/sw/bin/hello", timeout=5)

    with subtest("host GC does not collect the deployed generation"):
        host.succeed("nix-collect-garbage --option substituters '''", timeout=30)
        host.succeed(f"test -f {DEPLOYED}/sw/bin/hello", timeout=5)
        host.succeed(
            f"/run/current-system/sw/bin/nix-store --check-validity {DEPLOYED}",
            timeout=5,
        )
  '';
}
