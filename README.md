# deployable-containers

NixOS containers designed to be managed by an external deployment tool such as
[Colmena](https://colmena.cli.rs).

## Motivation

The built-in `nixos-containers` module is host-centric: the host's NixOS
configuration is the single source of truth for every container's config, and
`nixos-rebuild switch` on the host rebuilds and redeploys all of them.  That
model works well for simple cases but breaks down when you want independent
release cycles, separate teams, or tooling (Colmena, NixOps, deploy-rs) that
treats each container as a first-class deployment target.

`deployable-containers` turns each container into an independent node:

1. **Bootstrap once.** The host builds a minimal initial image containing only
   what is needed to accept the first deployment: SSH with your authorised
   key(s) and a working network interface.  The image is produced from the
   options you declare on the host, baked into the Nix store, and used exactly
   once — on first boot.

2. **Deploy externally.** After that first boot Colmena (or any tool that can
   SSH in and update `/nix/var/nix/profiles/system`) owns the container
   completely.  The host never touches the container's NixOS configuration
   again.

3. **Survive reboots.** When the container or the host reboots, the container
   boots from whatever system profile was last deployed — not from the
   bootstrap image.

The host's `/nix/store` is mounted read-only inside the container; the host's
nix-daemon socket is shared, so deployed closures are stored in the host's Nix
store and builds inside the container run through the host's daemon.

---

## Flake outputs

| Output | Description |
|---|---|
| `nixosModules.deployable-containers` | Host module — declare and run containers |
| `nixosModules.deployable-container-guest` | Guest module — import in Colmena targets |
| `devShells.<system>.default` | Shell with colmena, nix, iproute2, openssh |
| `checks.<system>.basic-veth` | VM integration test |
| `checks.<system>.guest-module` | Guest module attribute check |

---

## Quick start

### 1. Add the flake input

```nix
# flake.nix
inputs.deployable-containers.url = "github:nixedge/deployable-containers";
```

### 2. Configure the host

```nix
# hosts/my-host/configuration.nix
{ inputs, ... }:
{
  imports = [ inputs.deployable-containers.nixosModules.deployable-containers ];

  deployableContainers.containers.api = {
    # SSH key Colmena will use for deployments
    rootSSHKeys = [ "ssh-ed25519 AAAA..." ];

    # Point-to-point veth pair (static)
    hostAddress  = "10.100.0.1/32";
    localAddress = "10.100.0.2/32";
  };
}
```

After `nixos-rebuild switch` on the host:

- A systemd service `deployable-container-api.service` is created.
- On first start the service seeds
  `/var/lib/deployable-containers/api/profiles/system` with the bootstrap
  image and launches the container.
- The container's `eth0` comes up at `10.100.0.2` and SSH is available.

### 3. Deploy with Colmena

```nix
# hive.nix
{
  meta.nixpkgs = import <nixpkgs> {};

  api = { inputs, ... }: {
    deployment.targetHost = "10.100.0.2";

    imports = [
      inputs.deployable-containers.nixosModules.deployable-container-guest
      ./api-service.nix
    ];
  };
}
```

```
colmena apply --on api
```

Colmena SSHes into the container, pushes the new system closure through the
host's nix-daemon, updates `/nix/var/nix/profiles/system`, and runs
`switch-to-configuration switch`.  Future reboots of the container use that
profile.

---

## Host module options

### `deployableContainers.stateDirectory`

Base directory for container state on the host.  Defaults to
`/var/lib/deployable-containers`.  Each container gets a subdirectory
`<stateDirectory>/<name>/`:

```
<stateDirectory>/<name>/
  root/        container root filesystem (persistent /etc, /var, …)
  profiles/    bind-mounted as /nix/var/nix/profiles inside the container
  gcroots/     bind-mounted as /nix/var/nix/gcroots inside the container
```

### `deployableContainers.containers.<name>`

| Option | Type | Default | Description |
|---|---|---|---|
| `rootSSHKeys` | `[str]` | `[]` | SSH public keys for root in the bootstrap image |
| `privateNetwork` | `bool` | `true` | Create a private veth pair |
| `hostAddress` | `str?` | `null` | CIDR for the host end of the veth pair |
| `localAddress` | `str?` | `null` | CIDR for the container end; `null` → DHCP |
| `hostBridge` | `str?` | `null` | Attach to this bridge instead of a veth pair |
| `autoStart` | `bool` | `true` | Start at boot |
| `timeoutStartSec` | `str` | `"2min"` | Systemd start timeout |
| `extraInitialConfig` | module | `{}` | Extra NixOS config merged into the bootstrap image only |

`privateNetwork` and `hostBridge` are mutually exclusive.

---

## Networking modes

### Static veth pair

The most common mode.  A point-to-point link between the host and the
container.  The host routes packets to the container via the `/32` (or `/128`)
route added automatically.

```nix
deployableContainers.containers.svc = {
  hostAddress  = "10.100.0.1/32";
  localAddress = "10.100.0.2/32";
};
```

### DHCP veth pair

Leave `localAddress` unset.  The container's `eth0` is brought up and a DHCP
client negotiates the address.  The typical pattern is a
[kea](https://www.isc.org/kea/) static host entry on the host so the container
always gets the same address without it being hardcoded in the Nix config.

```nix
deployableContainers.containers.svc = {
  hostAddress = "10.100.0.1/32";   # host veth IP (kea listens here)
  # localAddress omitted → DHCP
};
```

```json
// kea-dhcp4.conf (excerpt)
{
  "reservations": [{
    "hw-address": "...",
    "ip-address": "10.100.0.2"
  }]
}
```

### Bridge attachment

Attach the container to an existing host bridge (e.g. for direct LAN access).
Use `localAddress` for a static IP or omit it for DHCP from whatever server
is on the bridge.

```nix
deployableContainers.containers.svc = {
  privateNetwork = false;   # no veth pair
  hostBridge     = "br0";
  localAddress   = "192.168.1.50/24";   # or omit for DHCP
  extraInitialConfig.networking.defaultGateway = "192.168.1.1";
};
```

### Shared host network

Set `privateNetwork = false` and omit `hostBridge` to share the host's network
namespace.  The container sees the host's interfaces directly.

```nix
deployableContainers.containers.svc = {
  privateNetwork = false;
};
```

---

## Guest module

Import `nixosModules.deployable-container-guest` in every NixOS configuration
you deploy to a container.  It sets sensible defaults for the container
environment:

- `boot.isContainer = true` — skips kernel and udev setup
- `environment.variables.NIX_REMOTE = "daemon"` — routes nix operations
  through the host's daemon socket at `/nix/var/nix/daemon-socket/socket`
- `networking.useHostResolvConf = true` — uses the host's resolver
- `nix.settings.trusted-users = ["root" "@wheel"]` — allows deployments as root
- Disables udev, lvm, power management, audit, and the boot loader activation

---

## How reboots work

The systemd service is configured with:

```
RestartForceExitStatus = 133
SuccessExitStatus      = 133
Restart                = on-failure
```

`systemd-nspawn` exits with code **133** when the container executes a reboot
internally (e.g. `systemctl reboot`).  The host service catches this, restarts,
and boots the container again — from whatever system profile is currently
symlinked at `<stateDirectory>/<name>/profiles/system`.

Because the pre-start script only seeds the profile when it does **not** exist,
a service restart or host reboot never reverts the container to the bootstrap
image.  The profile is only ever changed by the deployment tool.

---

## Nix store and GC

The host's `/nix/store` is mounted **read-only** inside every container.
Closures pushed by Colmena are written to the host's store via the shared
nix-daemon socket and become immediately visible inside the container.

Each container's profile directory is registered as a GC root under
`/nix/var/nix/gcroots/deployable-containers/<name>` so the host's `nix-collect-garbage`
never removes a deployed generation while the profile symlink exists.

---

## Running the tests

```
nix build .#checks.x86_64-linux.basic-veth    # VM integration test (~5 min)
nix build .#checks.x86_64-linux.guest-module  # fast eval check
nix flake check                                # all checks + treefmt
```

The `basic-veth` test:
1. Boots a QEMU VM running the host module with a single container (`svc`).
2. Waits for `deployable-container-svc.service` to reach the running state.
3. Confirms the host veth interface (`ve-svc`) has the expected address.
4. Waits for ICMP and SSH to succeed from the host VM into the container.
5. Verifies the system profile symlink was created.
6. Restarts the service and asserts the profile target is unchanged.

---

## Development shell

```
nix develop
```

Provides: `colmena`, `nix`, `nix-tree`, `iproute2`, `openssh`, `treefmt`
(with alejandra for `.nix` formatting).
