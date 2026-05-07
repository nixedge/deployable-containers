//! Per-connection proxy handler.

use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result};
use tracing::{debug, info, warn};

use crate::{protocol, splice};

static NEXT_ID: AtomicU64 = AtomicU64::new(0);

/// Entry point for a new client connection.  Opens the daemon socket, then
/// calls [`run`].  Logs errors and returns.
pub fn handle(client: UnixStream, daemon_socket: &Path) {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let span = tracing::info_span!("conn", id);
    let _guard = span.enter();

    let daemon = match UnixStream::connect(daemon_socket) {
        Ok(s) => s,
        Err(e) => {
            warn!("connecting to daemon at {}: {e}", daemon_socket.display());
            return;
        }
    };

    if let Err(e) = run(client, daemon) {
        if is_disconnect(&e) {
            debug!("client disconnected: {e:#}");
        } else {
            warn!("connection error: {e:#}");
        }
    }
}

/// Drive one connection to completion given pre-connected client and daemon
/// streams.  Separated from [`handle`] so tests can inject a fake daemon.
fn run(mut client: UnixStream, mut daemon: UnixStream) -> Result<()> {
    info!("accepted");

    let minor = protocol::relay_handshake(&mut client, &mut daemon)
        .context("handshake")?;
    debug!(minor, "handshake complete");

    let op1 = protocol::read_u64(&mut client).context("reading first op")?;
    debug!(op = op1, "first op");

    if let Some(done) = deny_if_blocked(op1, &mut client, minor, "")? {
        return Ok(done);
    }

    protocol::write_u64(&mut daemon, op1).context("forwarding first op")?;

    if op1 == protocol::OP_SET_OPTIONS {
        debug!("relaying SetOptions");
        protocol::relay_set_options_args(&mut client, &mut daemon)
            .context("relaying SetOptions args")?;
        protocol::relay_stderr_to_last(&mut daemon, &mut client, minor)
            .context("relaying SetOptions response")?;

        let op2 = protocol::read_u64(&mut client).context("reading second op")?;
        debug!(op = op2, "second op");

        if let Some(done) = deny_if_blocked(op2, &mut client, minor, " (after SetOptions)")? {
            return Ok(done);
        }

        protocol::write_u64(&mut daemon, op2).context("forwarding second op")?;
    }

    debug!("splicing");
    splice::bidirectional(client, daemon);
    debug!("splice complete");

    Ok(())
}

/// Check `op` against the blocked list.  If blocked, consume any arguments,
/// send a denial, and return `Ok(Some(()))`.  Returns `Ok(None)` if the op
/// is allowed and should be forwarded.  The `ctx` string is appended to the
/// log message (e.g. " (after SetOptions)").
fn deny_if_blocked(
    op: u64,
    client: &mut UnixStream,
    minor: u64,
    ctx: &str,
) -> Result<Option<()>> {
    match op {
        protocol::OP_COLLECT_GARBAGE => {
            warn!("blocking wopCollectGarbage{ctx}");
            // wopCollectGarbage takes structured args; GC denial is sent before
            // we read them — the client reads the error and closes the connection.
            protocol::deny_gc(client, minor).context("sending GC denial")?;
            Ok(Some(()))
        }
        protocol::OP_ADD_INDIRECT_ROOT => {
            warn!("blocking wopAddIndirectRoot{ctx}");
            // Consume the single path-string argument so the client can read
            // our error response cleanly rather than getting a broken pipe.
            protocol::discard_string(client).context("discarding AddIndirectRoot path")?;
            protocol::deny_add_indirect_root(client, minor)
                .context("sending AddIndirectRoot denial")?;
            Ok(Some(()))
        }
        _ => Ok(None),
    }
}

/// Returns true if the error is a normal client disconnect rather than a
/// genuine protocol fault, so we can log it at DEBUG instead of WARN.
fn is_disconnect(e: &anyhow::Error) -> bool {
    e.chain().any(|cause| {
        cause
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| {
                matches!(
                    io.kind(),
                    std::io::ErrorKind::BrokenPipe
                        | std::io::ErrorKind::ConnectionReset
                        | std::io::ErrorKind::UnexpectedEof
                )
            })
    })
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::os::unix::net::UnixStream;

    use super::*;
    use crate::protocol::{self, STDERR_LAST, WORKER_MAGIC_1, WORKER_MAGIC_2};

    fn pair() -> (UnixStream, UnixStream) {
        UnixStream::pair().unwrap()
    }

    // ── deny_if_blocked unit tests ────────────────────────────────────────────
    //
    // These test the blocking logic in isolation, without a handshake.

    #[test]
    fn gc_is_blocked_and_denial_contains_not_privileged() {
        let (mut proxy_side, mut container_side) = pair();
        let result = deny_if_blocked(protocol::OP_COLLECT_GARBAGE, &mut proxy_side, 0, "")
            .unwrap();
        assert!(result.is_some(), "GC should be blocked");
        drop(proxy_side);
        let mut buf = Vec::new();
        container_side.read_to_end(&mut buf).unwrap();
        assert!(
            String::from_utf8_lossy(&buf).contains("not privileged"),
            "denial must contain 'not privileged'"
        );
    }

    #[test]
    fn add_indirect_root_is_blocked_and_denial_mentions_gc_roots() {
        let (mut proxy_side, mut container_side) = pair();
        // Container writes the path argument before the proxy reads it.
        write_nix_string(&mut container_side, b"/tmp/test-root");
        let result =
            deny_if_blocked(protocol::OP_ADD_INDIRECT_ROOT, &mut proxy_side, 0, "").unwrap();
        assert!(result.is_some(), "AddIndirectRoot should be blocked");
        drop(proxy_side);
        let mut buf = Vec::new();
        container_side.read_to_end(&mut buf).unwrap();
        assert!(
            String::from_utf8_lossy(&buf).contains("GC roots"),
            "denial must mention 'GC roots'"
        );
    }

    #[test]
    fn unblocked_ops_return_none() {
        let (mut proxy_side, _container_side) = pair();
        for op in [1u64, 9, 11, 19, 36] {
            let result = deny_if_blocked(op, &mut proxy_side, 0, "").unwrap();
            assert!(result.is_none(), "op {op} should not be blocked");
        }
    }

    // ── Integration tests — full proxy run() with a fake daemon ───────────────
    //
    // Uses protocol minor 11 (simplest version): only reserveSpace in
    // post-handshake, no feature exchange, no ClientHandshakeInfo fields.
    // The real-daemon compatibility is covered by the NixOS VM test.

    const MINOR: u64 = 11;
    const VERSION: u64 = (1u64 << 8) | MINOR;

    /// Perform the daemon side of a minor-11 handshake.
    fn fake_daemon_handshake(mut d: UnixStream) {
        let _ = protocol::read_u64(&mut d).unwrap(); // MAGIC1
        let _ = protocol::read_u64(&mut d).unwrap(); // client_ver
        protocol::write_u64(&mut d, WORKER_MAGIC_2).unwrap();
        protocol::write_u64(&mut d, VERSION).unwrap();
        let _ = protocol::read_u64(&mut d).unwrap(); // reserveSpace
        protocol::write_u64(&mut d, STDERR_LAST).unwrap(); // initial STDERR_LAST
    }

    /// Perform the client side of a minor-11 handshake; returns the stream
    /// ready for op writes.
    fn client_handshake(c: &mut UnixStream) {
        protocol::write_u64(c, WORKER_MAGIC_1).unwrap();
        protocol::write_u64(c, VERSION).unwrap();
        let _ = protocol::read_u64(c).unwrap(); // MAGIC2
        let _ = protocol::read_u64(c).unwrap(); // daemon_ver
        protocol::write_u64(c, 0).unwrap(); // reserveSpace
        assert_eq!(protocol::read_u64(c).unwrap(), STDERR_LAST);
    }

    /// Write 13 zero u64s representing an empty wopSetOptions argument block
    /// (12 fixed fields + override count=0).
    fn write_empty_set_options(c: &mut UnixStream) {
        for _ in 0..13 {
            protocol::write_u64(c, 0).unwrap();
        }
    }

    /// Write a nix string (length-prefixed, padded to 8 bytes).
    fn write_nix_string(dst: &mut UnixStream, s: &[u8]) {
        protocol::write_u64(dst, s.len() as u64).unwrap();
        let padded = (s.len() + 7) & !7;
        let mut buf = vec![0u8; padded];
        buf[..s.len()].copy_from_slice(s);
        dst.write_all(&buf).unwrap();
    }

    /// Spin up a proxy thread with a fake daemon and return the client stream
    /// after the handshake is complete.
    fn setup_with_daemon<F>(daemon_fn: F) -> UnixStream
    where
        F: FnOnce(UnixStream) + Send + 'static,
    {
        let (client_test, client_proxy) = pair();
        let (daemon_proxy, daemon_test) = pair();
        std::thread::spawn(move || daemon_fn(daemon_test));
        std::thread::spawn(move || { let _ = run(client_proxy, daemon_proxy); });
        let mut c = client_test;
        client_handshake(&mut c);
        c
    }

    #[test]
    fn gc_denied_as_first_op() {
        let mut c = setup_with_daemon(fake_daemon_handshake);
        protocol::write_u64(&mut c, protocol::OP_COLLECT_GARBAGE).unwrap();
        drop_write_shutdown(&mut c);
        let buf = read_all(c);
        assert!(
            String::from_utf8_lossy(&buf).contains("not privileged"),
            "GC denial must contain 'not privileged'"
        );
    }

    #[test]
    fn add_indirect_root_denied_as_first_op() {
        let mut c = setup_with_daemon(fake_daemon_handshake);
        protocol::write_u64(&mut c, protocol::OP_ADD_INDIRECT_ROOT).unwrap();
        write_nix_string(&mut c, b"/nix/var/nix/gcroots/auto/malicious");
        drop_write_shutdown(&mut c);
        let buf = read_all(c);
        assert!(
            String::from_utf8_lossy(&buf).contains("GC roots"),
            "AddIndirectRoot denial must mention 'GC roots'"
        );
    }

    #[test]
    fn gc_denied_after_set_options() {
        let mut c = setup_with_daemon(|mut d| {
            fake_daemon_handshake(d.try_clone().unwrap());
            // Daemon must read the forwarded SetOptions op + args, then respond.
            let _ = protocol::read_u64(&mut d).unwrap(); // op=19
            for _ in 0..13 { let _ = protocol::read_u64(&mut d).unwrap(); } // args
            protocol::write_u64(&mut d, STDERR_LAST).unwrap(); // SetOptions response
            // GC denial is synthesised by the proxy; daemon side is now done.
        });
        protocol::write_u64(&mut c, protocol::OP_SET_OPTIONS).unwrap();
        write_empty_set_options(&mut c);
        // Read the SetOptions STDERR_LAST response the proxy relays back
        assert_eq!(protocol::read_u64(&mut c).unwrap(), STDERR_LAST);
        // Now send GC as op2
        protocol::write_u64(&mut c, protocol::OP_COLLECT_GARBAGE).unwrap();
        drop_write_shutdown(&mut c);
        let buf = read_all(c);
        assert!(
            String::from_utf8_lossy(&buf).contains("not privileged"),
            "GC denial after SetOptions must contain 'not privileged'"
        );
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    fn drop_write_shutdown(s: &mut UnixStream) {
        s.shutdown(std::net::Shutdown::Write).unwrap();
    }

    fn read_all(mut s: UnixStream) -> Vec<u8> {
        let mut buf = Vec::new();
        s.read_to_end(&mut buf).unwrap();
        buf
    }
}
