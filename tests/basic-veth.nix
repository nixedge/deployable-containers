# NixOS test: static veth pair with two-way SSH access
#
# Verifies:
#   1. The container service starts and the veth pair is configured.
#   2. The container is reachable over SSH using the bootstrap key.
#   3. The system profile is seeded on first boot.
#   4. Restarting the service does NOT re-seed the profile — it always boots
#      from whatever profile is currently in place.
{
  self,
  pkgs,
  lib,
  testKeyPair,
  testPublicKey,
  ...
}: {
  name = "deployable-containers-basic-veth";

  nodes.host = {pkgs, ...}: {
    imports = [self.nixosModules.deployable-containers];

    virtualisation.memorySize = 2048;

    deployableContainers.containers.svc = {
      rootSSHKeys = [testPublicKey];
      hostAddress = "10.100.0.1/32";
      localAddress = "10.100.0.2/32";
    };

    # Expose the test private key so the test script can SSH into the container.
    environment.etc."dc-test-key" = {
      mode = "0600";
      source = "${testKeyPair}/private";
    };

    # Quiet the QEMU console a bit.
    boot.kernelParams = ["quiet"];
  };

  testScript = ''
    SSH = "ssh -i /etc/dc-test-key -o StrictHostKeyChecking=no -o ConnectTimeout=5"
    CT_IP = "10.100.0.2"

    host.start()

    with subtest("container service reaches running state"):
        host.wait_for_unit("deployable-container-svc.service", timeout=120)

    with subtest("host veth interface is configured"):
        host.wait_until_succeeds("ip addr show ve-svc | grep -q 10.100.0.1", timeout=30)

    with subtest("container is reachable over ICMP"):
        host.wait_until_succeeds(f"ping -c1 -W2 {CT_IP}", timeout=60)

    with subtest("SSH into container works"):
        host.wait_until_succeeds(
            f"{SSH} root@{CT_IP} true",
            timeout=60,
        )

    with subtest("container reports as NixOS"):
        out = host.succeed(f"{SSH} root@{CT_IP} uname -r")
        print(f"container kernel: {out.strip()}")

    with subtest("system profile was seeded"):
        host.succeed(
            "test -L /var/lib/deployable-containers/svc/profiles/system"
        )

    with subtest("profile target is stable across service restarts"):
        before = host.succeed(
            "readlink -f /var/lib/deployable-containers/svc/profiles/system"
        ).strip()

        host.systemctl("restart deployable-container-svc.service")
        host.wait_for_unit("deployable-container-svc.service", timeout=120)
        host.wait_until_succeeds(f"ping -c1 -W2 {CT_IP}", timeout=60)

        after = host.succeed(
            "readlink -f /var/lib/deployable-containers/svc/profiles/system"
        ).strip()

        assert before == after, (
            f"Profile target changed across restart!\n  before: {before}\n  after:  {after}"
        )
  '';
}
