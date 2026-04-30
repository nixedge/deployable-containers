# Host-side NixOS module.
#
# Manages deployable containers on a NixOS host.  Each container is:
#
#   1. Bootstrapped on first start with a minimal NixOS image (SSH + network)
#      built from the options declared here.
#   2. Subsequently fully managed by an external deployment tool such as
#      Colmena — the host never touches the container config again.
#   3. Persistent across reboots: the host always boots the container from
#      its *current* system profile (set by the last deployment), never from
#      the bootstrap image.
#
# Containers use the host's read-only /nix/store and nix-daemon socket so
# that deployments can push closures without a separate nix instance inside
# the container.
{
  flake.nixosModules.deployable-containers = {
    config,
    pkgs,
    lib,
    ...
  }: let
    inherit (lib)
      concatStringsSep
      hasInfix
      head
      last
      literalExpression
      mapAttrs'
      mkDefault
      mkIf
      mkOption
      nameValuePair
      optional
      optionalString
      splitString
      toInt
      types
      ;

    cfg = config.deployableContainers;

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------

    # "10.0.0.1/32" → "10.0.0.1"
    bareIP = cidr: head (splitString "/" cidr);

    # "10.0.0.1/32" → 32   (defaults to 32 when no prefix is given)
    prefixLen = cidr:
      if hasInfix "/" cidr
      then toInt (last (splitString "/" cidr))
      else 32;

    # ---------------------------------------------------------------------------
    # Container init script (runs *inside* the nspawn namespace).
    #
    # systemd-nspawn names the first virtual interface "host0".  We rename it
    # to "eth0" and configure the static IP (if any) before sourcing the NixOS
    # stage-2 init.  We *source* rather than *exec* so this shell process keeps
    # the SIGRTMIN+3 trap alive for clean container shutdown.
    # ---------------------------------------------------------------------------
    containerInitScript = pkgs.writeShellScript "dc-container-init" ''
      trap 'exit 0' SIGRTMIN+3

      IP=${pkgs.iproute2}/bin/ip

      # Veth / bridge mode: rename the default nspawn interface to eth0.
      if [ -n "''${DC_PRIVATE_NETWORK:-}" ] || [ -n "''${DC_BRIDGE:-}" ]; then
        if $IP link show host0 >/dev/null 2>&1; then
          $IP link set host0 name eth0
          $IP link set eth0 up
        fi

        # For veth mode, configure the static point-to-point link.
        if [ -n "''${DC_PRIVATE_NETWORK:-}" ]; then
          if [ -n "''${DC_LOCAL_ADDRESS:-}" ]; then
            $IP addr add "''${DC_LOCAL_ADDRESS}" dev eth0
          fi
          if [ -n "''${DC_HOST_ADDRESS:-}" ]; then
            HOST_IP="''${DC_HOST_ADDRESS%%/*}"
            $IP route add "''${HOST_IP}" dev eth0
            $IP route add default via "''${HOST_IP}"
          fi
        fi
      fi

      set +e
      # shellcheck disable=SC1090
      . "$1"
    '';

    # ---------------------------------------------------------------------------
    # NixOS module for the networking section of the bootstrap image.
    # ---------------------------------------------------------------------------
    networkModuleFor = ctr: {lib, ...}:
      lib.mkMerge [
        # ── veth / private-network mode ──────────────────────────────────────
        (lib.mkIf ctr.privateNetwork {
          networking.useDHCP = false;
          networking.useHostResolvConf = mkDefault true;
        })
        (lib.mkIf (ctr.privateNetwork && ctr.localAddress != null) {
          networking.interfaces.eth0.ipv4.addresses = [
            {
              address = bareIP ctr.localAddress;
              prefixLength = prefixLen ctr.localAddress;
            }
          ];
        })
        (lib.mkIf (ctr.privateNetwork && ctr.hostAddress != null && ctr.localAddress != null) {
          networking.defaultGateway = bareIP ctr.hostAddress;
        })
        # DHCP mode: localAddress is null, let the in-container DHCP client
        # configure the interface.  Typical use: kea with a static host entry
        # so the container always gets the same address.
        (lib.mkIf (ctr.privateNetwork && ctr.localAddress == null) {
          networking.interfaces.eth0.useDHCP = true;
        })

        # ── bridge mode ──────────────────────────────────────────────────────
        (lib.mkIf (ctr.hostBridge != null) {
          networking.useHostResolvConf = mkDefault true;
        })
        (lib.mkIf (ctr.hostBridge != null && ctr.localAddress == null) {
          networking.useDHCP = true;
        })
        (lib.mkIf (ctr.hostBridge != null && ctr.localAddress != null) {
          networking.useDHCP = false;
          networking.interfaces.eth0.ipv4.addresses = [
            {
              address = bareIP ctr.localAddress;
              prefixLength = prefixLen ctr.localAddress;
            }
          ];
        })
      ];

    # ---------------------------------------------------------------------------
    # Build the bootstrap NixOS system closure for a container.
    #
    # This closure is embedded in the host's config so it lands in the Nix store
    # as a normal derivation.  It is only ever used on the container's *first*
    # boot; after that Colmena (or another tool) replaces the system profile.
    # ---------------------------------------------------------------------------
    buildBootstrapSystem = _name: ctr:
      (pkgs.nixos {
        imports = [
          # Core container settings (pkgs.nixos returns the full eval object;
          # .toplevel is a shortcut for .config.system.build.toplevel)
          ({pkgs, lib, ...}: {
            boot.isContainer = true;

            services.openssh = {
              enable = true;
              settings = {
                PermitRootLogin = mkDefault "prohibit-password";
                PasswordAuthentication = mkDefault false;
                UseDns = false;
              };
            };

            users.users.root.openssh.authorizedKeys.keys = ctr.rootSSHKeys;

            # Allow root (and wheel) to talk to the host nix-daemon.
            nix.settings.trusted-users = ["root" "@wheel"];
            nix.settings.experimental-features = ["nix-command" "flakes"];
            nix.settings.extra-substituters = ctr.substituters;
            nix.settings.extra-trusted-public-keys = ctr.trustedPublicKeys;
            environment.variables.NIX_REMOTE = mkDefault "daemon";

            # boot.isContainer = true causes container-config.nix to be
            # imported, which already sets installBootLoader via mkDefault.
            # Do not set it here to avoid a unique-option conflict.

            system.stateVersion = lib.trivial.release;
          })

          # Networking
          (networkModuleFor ctr)

          # Caller-supplied extras (active only during bootstrap)
          ctr.extraInitialConfig
        ];
      }).toplevel;

    # ---------------------------------------------------------------------------
    # Pre-start script (runs on the host as root, before nspawn starts).
    #
    # Responsibilities:
    #   • Create the container's directory tree.
    #   • Register the profiles directory as a host GC root so deployed
    #     generations are not garbage-collected.
    #   • On first run, seed the system profile with the bootstrap image so
    #     nspawn has an init to execute.
    #   • Remove stale machined registrations and virtual interfaces.
    # ---------------------------------------------------------------------------
    makePreStartScript = name: ctr: bootstrapSystem:
      pkgs.writeShellScript "dc-pre-start-${name}" ''
        set -euo pipefail

        STATE="${cfg.stateDirectory}/${name}"
        ROOT="$STATE/root"
        PROFILES="$STATE/profiles"
        GCROOTS="$STATE/gcroots"

        # Directories that must exist inside the container root (mount points
        # and persistent state dirs that survive deployments).
        mkdir -p \
          "$ROOT/etc/ssh"                      \
          "$ROOT/var/log"                      \
          "$ROOT/var/lib"                      \
          "$ROOT/tmp"                          \
          "$ROOT/root"                         \
          "$ROOT/home"                         \
          "$ROOT/nix/store"                    \
          "$ROOT/nix/var/nix/profiles"         \
          "$ROOT/nix/var/nix/gcroots"          \
          "$ROOT/nix/var/nix/daemon-socket"    \
          "$PROFILES"                          \
          "$GCROOTS"

        # Tell the host nix GC to treat the container's profile generations as
        # roots so deployed systems are never collected from under us.
        mkdir -p /nix/var/nix/gcroots/deployable-containers
        ln -sfn "$PROFILES" "/nix/var/nix/gcroots/deployable-containers/${name}"

        # Pin the host's own running system as a GC root.  NixOS normally
        # creates these at boot/switch time but they may be absent on bare-metal
        # hosts or after a manual recovery.  Without them a container-triggered
        # GC (via the shared daemon socket) can collect the host OS.
        ln -sfn /run/current-system /nix/var/nix/gcroots/current-system
        ln -sfn /run/booted-system  /nix/var/nix/gcroots/booted-system

        # On first run there is no deployed system yet.  Seed the profile with
        # the bootstrap image so the container has something to boot.
        if [ ! -e "$PROFILES/system" ]; then
          echo "deployable-containers[${name}]: first boot — seeding bootstrap image"
          ${pkgs.nix}/bin/nix-env --profile "$PROFILES/system" --set "${bootstrapSystem}"
        fi

        # Clean up stale machined registration (harmless if absent).
        ${pkgs.systemd}/bin/machinectl terminate "${name}" 2>/dev/null || true

        # Remove stale virtual interfaces left by a previous (crashed) run.
        ${pkgs.iproute2}/bin/ip link del "ve-${name}" 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip link del "vb-${name}" 2>/dev/null || true
      '';

    # ---------------------------------------------------------------------------
    # Post-start script (runs on the host after nspawn signals readiness).
    #
    # For veth mode: brings up the host end of the pair and assigns the host IP.
    # ---------------------------------------------------------------------------
    makePostStartScript = name: ctr:
      pkgs.writeShellScript "dc-post-start-${name}" (
        if ctr.privateNetwork && ctr.hostAddress != null
        then ''
          set -euo pipefail

          HOST_IFACE="ve-${name}"

          # Wait up to 10 s for the kernel to expose the host end of the veth.
          for _i in $(seq 1 20); do
            ${pkgs.iproute2}/bin/ip link show "$HOST_IFACE" >/dev/null 2>&1 && break
            sleep 0.5
          done

          ${pkgs.iproute2}/bin/ip link set "$HOST_IFACE" up
          ${pkgs.iproute2}/bin/ip addr add "${ctr.hostAddress}" dev "$HOST_IFACE"
          ${optionalString (ctr.localAddress != null) ''
            # Static mode: add a host→container route for the known address.
            ${pkgs.iproute2}/bin/ip route add "${bareIP ctr.localAddress}" dev "$HOST_IFACE"
          ''}
        ''
        else "true"
      );

    # ---------------------------------------------------------------------------
    # Main start script.
    #
    # Resolves the *current* system profile (which may have been updated by
    # Colmena since the last boot) and hands it to systemd-nspawn as the init.
    # The /nix/store is mounted read-only; the host's nix-daemon socket is
    # shared so the container can receive deployed closures.
    # ---------------------------------------------------------------------------
    makeStartScript = name: ctr:
      let
        networkFlags = concatStringsSep " " (
          optional ctr.privateNetwork "--network-veth"
          ++ optional (ctr.hostBridge != null) "--network-bridge=${ctr.hostBridge}"
        );

        envFlags = concatStringsSep " " (
          optional ctr.privateNetwork "--setenv=DC_PRIVATE_NETWORK=1"
          ++ optional (ctr.hostAddress != null) "--setenv=DC_HOST_ADDRESS=${ctr.hostAddress}"
          ++ optional (ctr.localAddress != null) "--setenv=DC_LOCAL_ADDRESS=${ctr.localAddress}"
          ++ optional (ctr.hostBridge != null) "--setenv=DC_BRIDGE=${ctr.hostBridge}"
        );

        capabilityFlags = concatStringsSep " " (
          map (cap: "--capability=${cap}") ctr.capabilities
        );
      in
        pkgs.writeShellScript "dc-start-${name}" ''
          set -euo pipefail

          STATE="${cfg.stateDirectory}/${name}"

          # Follow the profile symlink chain to the concrete store path so that
          # nspawn receives an absolute /nix/store/… path that is valid both on
          # the host and inside the container (where /nix/store is bind-mounted).
          SYSTEM=$(${pkgs.coreutils}/bin/realpath "$STATE/profiles/system")

          exec ${pkgs.systemd}/bin/systemd-nspawn \
            --keep-unit \
            -M "${name}" \
            -D "$STATE/root" \
            --notify-ready=yes \
            --kill-signal=SIGRTMIN+3 \
            --bind-ro=/nix/store \
            --bind-ro=/nix/var/nix/daemon-socket \
            --bind="$STATE/profiles:/nix/var/nix/profiles" \
            --bind="$STATE/gcroots:/nix/var/nix/gcroots" \
            ${networkFlags} \
            ${envFlags} \
            ${capabilityFlags} \
            ${containerInitScript} \
            "$SYSTEM/init"
        '';

    # ---------------------------------------------------------------------------
    # Assemble the systemd service for one container.
    # ---------------------------------------------------------------------------
    makeService = name: ctr: let
      bootstrapSystem = buildBootstrapSystem name ctr;
    in {
      description = "Deployable Container '${name}'";
      wantedBy = optional ctr.autoStart "machines.target";
      after = ["network.target"];
      wants = ["network.target"];

      serviceConfig = {
        Type = "notify";

        # '+' prefix → run as root regardless of service user.
        ExecStartPre = "+${makePreStartScript name ctr bootstrapSystem}";
        ExecStart = makeStartScript name ctr;
        ExecStartPost = makePostStartScript name ctr;

        # nspawn exits 133 when the container reboots internally.
        # Treat it as a clean exit and restart the service so the container
        # comes back up running its latest deployed system.
        RestartForceExitStatus = "133";
        SuccessExitStatus = "133";
        Restart = "on-failure";
        RestartSec = "1s";
        TimeoutStartSec = ctr.timeoutStartSec;

        Slice = "machine.slice";
        Delegate = true;

        KillMode = "mixed";
        KillSignal = "SIGTERM";

        DevicePolicy = "closed";
        DeviceAllow = [
          "/dev/net/tun rwm"
          "char-pts rwm"
        ];

        SyslogIdentifier = "dc-${name}";
      };
    };
  in {
    # ── Option declarations ────────────────────────────────────────────────────

    options.deployableContainers = {
      stateDirectory = mkOption {
        type = types.str;
        default = "/var/lib/deployable-containers";
        description = "Base directory on the host for all container state.";
      };

      containers = mkOption {
        default = {};
        description = ''
          Deployable containers managed by this host.

          Each container is bootstrapped once with a minimal NixOS image built
          from the options declared here, then handed off to an external
          deployment tool (e.g. Colmena).  The host never modifies the
          container's NixOS config after the first boot.
        '';
        type = types.attrsOf (types.submodule ({name, ...}: {
          options = {
            rootSSHKeys = mkOption {
              type = types.listOf types.str;
              default = [];
              description = ''
                SSH public keys authorised for root login in the bootstrap image.
                Add your deployment key here so Colmena can reach the container
                for its first deployment.
              '';
              example = literalExpression ''[ "ssh-ed25519 AAAA..." ]'';
            };

            privateNetwork = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Create a private veth pair for this container.
                Mutually exclusive with `hostBridge`.
              '';
            };

            hostAddress = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "10.100.0.1/32";
              description = ''
                CIDR address assigned to the host end of the veth pair.
                Required when `privateNetwork = true` and you want the host to
                route traffic to the container.
              '';
            };

            localAddress = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "10.100.0.2/32";
              description = ''
                CIDR address assigned to the container's network interface.
                In veth mode this is the container end of the pair; in bridge
                mode it is the container's address on the bridge subnet.

                Set to `null` (the default) to use DHCP instead.  With kea on
                the host you can give the container a static DHCP binding so it
                always receives the same address, which is how the author
                typically uses this option.
              '';
            };

            hostBridge = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "br0";
              description = ''
                Attach the container to this host bridge instead of creating
                a dedicated veth pair.  Mutually exclusive with `privateNetwork`.
              '';
            };

            autoStart = mkOption {
              type = types.bool;
              default = true;
              description = "Start the container automatically at boot.";
            };

            timeoutStartSec = mkOption {
              type = types.str;
              default = "2min";
              description = "Timeout for the container to signal readiness.";
            };

            substituters = mkOption {
              type = types.listOf types.str;
              default = [];
              example = literalExpression ''[ "https://my-cache.example.com" ]'';
              description = ''
                Extra binary cache URLs added to the bootstrap image.
                Appended to the nixpkgs default (cache.nixos.org) via
                `extra-substituters`, so the default is never removed.
                Set the corresponding `trustedPublicKeys` for each cache.
              '';
            };

            trustedPublicKeys = mkOption {
              type = types.listOf types.str;
              default = [];
              example = literalExpression ''[ "my-cache.example.com:base64pubkey==" ]'';
              description = ''
                Public keys for the caches listed in `substituters`.
                Added via `extra-trusted-public-keys`.
              '';
            };

            capabilities = mkOption {
              type = types.listOf types.str;
              default = [];
              example = literalExpression ''[ "CAP_IPC_LOCK" ]'';
              description = ''
                Additional Linux capabilities to grant the container via
                <literal>systemd-nspawn --capability=</literal>.

                By default nspawn drops several capabilities including
                <literal>CAP_IPC_LOCK</literal>.  Add it here for workloads
                (e.g. cardano-node) that need to mlock memory for key
                security.
              '';
            };

            extraInitialConfig = mkOption {
              type = types.deferredModule;
              default = {};
              description = ''
                Additional NixOS configuration merged into the bootstrap image.

                This config is only ever active in the bootstrap image; it is
                not applied after the first Colmena deployment.  Use it for
                things that must be present before Colmena can reach the
                container (e.g. firewall rules, extra authorised keys).
              '';
            };
          };
        }));
      };
    };

    # ── Implementation ─────────────────────────────────────────────────────────

    config = mkIf (cfg.containers != {}) {
      assertions = lib.concatLists (lib.mapAttrsToList (name: ctr: [
        {
          assertion = !(ctr.privateNetwork && ctr.hostBridge != null);
          message = "deployableContainers.containers.${name}: `privateNetwork` and `hostBridge` are mutually exclusive.";
        }
      ]) cfg.containers);

      # machines.target groups all container services; wantedBy pulls it into
      # multi-user.target so containers start at boot when autoStart = true.
      systemd.targets.machines = {
        description = "Deployable Containers";
        wantedBy = ["multi-user.target"];
      };

      systemd.services =
        mapAttrs' (name: ctr:
          nameValuePair "deployable-container-${name}" (makeService name ctr))
        cfg.containers;

      # IP forwarding is required for container traffic to leave the host.
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = mkDefault true;
        "net.ipv6.conf.all.forwarding" = mkDefault true;
      };

      # Ensure the top-level state directory exists before any service runs.
      systemd.tmpfiles.rules = [
        "d ${cfg.stateDirectory} 0755 root root -"
      ];
    };
  };
}
