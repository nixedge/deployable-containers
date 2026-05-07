use std::path::PathBuf;

use clap::Parser;

/// Restricted nix-daemon proxy for deployable containers.
///
/// Accepts Unix socket connections from containers, relays them to the
/// host nix-daemon, and blocks wopCollectGarbage (op 20) so containers
/// cannot trigger garbage collection on the host Nix store.
#[derive(Parser, Debug)]
#[command(version, about)]
pub struct Args {
    /// Unix socket path this proxy listens on.
    #[arg(long, default_value = "/run/nix-container-daemon/socket")]
    pub socket: PathBuf,

    /// Path to the upstream nix-daemon socket.
    #[arg(long, default_value = "/nix/var/nix/daemon-socket/socket")]
    pub daemon_socket: PathBuf,

    /// Unix permission bits for the listen socket (octal, e.g. 0666).
    #[arg(long, default_value = "0666", value_parser = parse_octal_mode)]
    pub socket_mode: u32,
}

fn parse_octal_mode(s: &str) -> Result<u32, String> {
    let digits = s.trim_start_matches("0o").trim_start_matches("0x");
    u32::from_str_radix(digits, 8).map_err(|e| format!("expected octal mode (e.g. 0666): {e}"))
}
