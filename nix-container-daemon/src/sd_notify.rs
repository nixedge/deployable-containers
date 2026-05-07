//! Minimal systemd SD_NOTIFY support.

use std::env;
use std::os::unix::net::UnixDatagram;

/// Send `READY=1` to systemd via `$NOTIFY_SOCKET`. No-op if the variable is unset.
pub fn ready() {
    let Ok(addr) = env::var("NOTIFY_SOCKET") else { return };
    // systemd abstract sockets start with '@'; replace with the NUL byte.
    let addr = match addr.strip_prefix('@') {
        Some(rest) => format!("\0{rest}"),
        None => addr,
    };
    if let Ok(sock) = UnixDatagram::unbound() {
        let _ = sock.send_to(b"READY=1", &addr);
    }
}
