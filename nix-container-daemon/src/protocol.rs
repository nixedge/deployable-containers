//! Nix worker protocol wire format.
//!
//! Implements just enough of the protocol to relay connections between
//! containers and the host nix-daemon while intercepting wopCollectGarbage
//! and wopAddIndirectRoot.

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;

use crate::error::{ProtocolError, Result};

// ── Protocol constants ────────────────────────────────────────────────────────

pub const WORKER_MAGIC_1: u64 = 0x6e697863;
pub const WORKER_MAGIC_2: u64 = 0x6478696f;

const STDERR_NEXT: u64 = 0x6f6c6d67;
const STDERR_READ: u64 = 0x64617461;
const STDERR_WRITE: u64 = 0x64617416;
pub(crate) const STDERR_LAST: u64 = 0x616c7473;
const STDERR_ERROR: u64 = 0x63787470;
const STDERR_START_ACTIVITY: u64 = 0x53545254;
const STDERR_STOP_ACTIVITY: u64 = 0x53544f50;
const STDERR_RESULT: u64 = 0x52534c54;

pub const OP_ADD_INDIRECT_ROOT: u64 = 12;
pub const OP_SET_OPTIONS: u64 = 19;
pub const OP_COLLECT_GARBAGE: u64 = 20;

// ── Wire primitives ───────────────────────────────────────────────────────────

pub fn read_u64(s: &mut UnixStream) -> io::Result<u64> {
    let mut b = [0u8; 8];
    s.read_exact(&mut b)?;
    Ok(u64::from_le_bytes(b))
}

pub fn write_u64(s: &mut UnixStream, n: u64) -> io::Result<()> {
    s.write_all(&n.to_le_bytes())
}

fn relay_u64(src: &mut UnixStream, dst: &mut UnixStream) -> io::Result<u64> {
    let n = read_u64(src)?;
    write_u64(dst, n)?;
    Ok(n)
}

/// Relay a nix string: uint64 length + body padded to 8-byte boundary.
fn relay_string(src: &mut UnixStream, dst: &mut UnixStream) -> io::Result<()> {
    let len = relay_u64(src, dst)? as usize;
    let padded = (len + 7) & !7;
    let mut buf = vec![0u8; padded];
    src.read_exact(&mut buf)?;
    dst.write_all(&buf)
}

/// Relay a nix string list: uint64 count + count × string.
fn relay_string_list(src: &mut UnixStream, dst: &mut UnixStream) -> io::Result<()> {
    let count = relay_u64(src, dst)?;
    for _ in 0..count {
        relay_string(src, dst)?;
    }
    Ok(())
}

/// Relay Logger::Fields: uint64 count + per-field (uint64 type + uint64-or-string).
fn relay_fields(src: &mut UnixStream, dst: &mut UnixStream) -> Result<()> {
    let count = relay_u64(src, dst)?;
    for _ in 0..count {
        match relay_u64(src, dst)? {
            0 => { relay_u64(src, dst)?; }    // tInt
            1 => { relay_string(src, dst)?; } // tString
            t => return Err(ProtocolError::UnknownFieldType(t)),
        }
    }
    Ok(())
}

/// Write a nix string (length + body + padding) to `dst`.
fn write_nix_str(dst: &mut UnixStream, s: &[u8]) -> io::Result<()> {
    write_u64(dst, s.len() as u64)?;
    dst.write_all(s)?;
    if s.len() % 8 != 0 {
        dst.write_all(&[0u8; 7][..8 - s.len() % 8])?;
    }
    Ok(())
}

/// Relay a NixStringWithoutContext: string + context string-set (protocol minor ≥ 31).
fn relay_nix_str_no_ctx(src: &mut UnixStream, dst: &mut UnixStream, minor: u64) -> io::Result<()> {
    relay_string(src, dst)?;
    if minor >= 31 {
        let n = relay_u64(src, dst)?;
        for _ in 0..n {
            relay_string(src, dst)?;
        }
    }
    Ok(())
}

/// Write a NixStringWithoutContext: string + empty context (protocol minor ≥ 31).
fn write_nix_str_no_ctx(dst: &mut UnixStream, s: &[u8], minor: u64) -> io::Result<()> {
    write_nix_str(dst, s)?;
    if minor >= 31 {
        write_u64(dst, 0)?; // empty context string-set
    }
    Ok(())
}

// ── Handshake ─────────────────────────────────────────────────────────────────

/// Relay the full nix worker-protocol handshake between `client` and `daemon`.
///
/// Wire sequence (protocol 1.38 / nix 2.31.4):
///   C→D  WORKER_MAGIC_1 + clientVersion
///   D→C  WORKER_MAGIC_2 + daemonVersion
///   C→D  client feature set (string list)
///   D→C  daemon feature set (string list)
///   C→D  cpuAffinity + reserveSpace
///   D→C  daemonNixVersion + remoteTrustsUs
///   D→C  initial STDERR_LAST
///
/// Returns the negotiated protocol minor version.
pub fn relay_handshake(client: &mut UnixStream, daemon: &mut UnixStream) -> Result<u64> {
    // C→D
    let magic1 = read_u64(client)?;
    let client_ver = read_u64(client)?;
    write_u64(daemon, magic1)?;
    write_u64(daemon, client_ver)?;

    // D→C
    let magic2 = read_u64(daemon)?;
    let daemon_ver = read_u64(daemon)?;
    write_u64(client, magic2)?;
    write_u64(client, daemon_ver)?;

    if magic1 != WORKER_MAGIC_1 || magic2 != WORKER_MAGIC_2 {
        return Err(ProtocolError::MagicMismatch);
    }

    let minor = (client_ver & 0xff).min(daemon_ver & 0xff);

    // Feature exchange (minor >= 38)
    if minor >= 38 {
        relay_string_list(client, daemon)?;
        relay_string_list(daemon, client)?;
    }

    // C→D post-handshake
    if minor >= 14 {
        let affinity = relay_u64(client, daemon)?;
        if affinity != 0 {
            relay_u64(client, daemon)?; // affinity mask (obsolete, never non-zero in practice)
        }
    }
    if minor >= 11 {
        relay_u64(client, daemon)?; // reserveSpace (obsolete)
    }

    // D→C ClientHandshakeInfo
    if minor >= 33 {
        relay_string(daemon, client)?; // daemonNixVersion
    }
    if minor >= 35 {
        relay_u64(daemon, client)?; // remoteTrustsUs
    }

    // Daemon sends an initial STDERR_LAST before the op loop begins.
    relay_stderr_to_last(daemon, client, minor)?;

    Ok(minor)
}

// ── SetOptions relay ──────────────────────────────────────────────────────────

/// Relay the arguments for wopSetOptions (op 19).
///
/// 12 fixed uint64 fields, then uint64 override count, then key/value string pairs.
pub fn relay_set_options_args(client: &mut UnixStream, daemon: &mut UnixStream) -> io::Result<()> {
    for _ in 0..12 {
        relay_u64(client, daemon)?;
    }
    let n_overrides = relay_u64(client, daemon)?;
    for _ in 0..n_overrides {
        relay_string(client, daemon)?; // key
        relay_string(client, daemon)?; // value
    }
    Ok(())
}

// ── STDERR frame relay ────────────────────────────────────────────────────────

/// Relay daemon STDERR frames to the client until STDERR_LAST or STDERR_ERROR.
pub fn relay_stderr_to_last(daemon: &mut UnixStream, client: &mut UnixStream, minor: u64) -> Result<()> {
    loop {
        let marker = relay_u64(daemon, client)?;
        match marker {
            STDERR_LAST => return Ok(()),
            STDERR_ERROR => {
                relay_stderr_error_body(daemon, client, minor)?;
                return Err(ProtocolError::DaemonError);
            }
            STDERR_NEXT | STDERR_WRITE => {
                relay_string(daemon, client)?;
            }
            STDERR_READ => {
                relay_u64(daemon, client)?;      // requested length
                relay_string(client, daemon)?;   // data from client
            }
            STDERR_START_ACTIVITY => {
                relay_u64(daemon, client)?;    // activityId
                relay_u64(daemon, client)?;    // verbosity
                relay_u64(daemon, client)?;    // ActivityType
                relay_string(daemon, client)?; // text
                relay_fields(daemon, client)?; // fields
                relay_u64(daemon, client)?;    // parent activityId
            }
            STDERR_STOP_ACTIVITY => {
                relay_u64(daemon, client)?; // activityId
            }
            STDERR_RESULT => {
                relay_u64(daemon, client)?;    // activityId
                relay_u64(daemon, client)?;    // ResultType
                relay_fields(daemon, client)?; // fields
            }
            other => return Err(ProtocolError::UnknownStderrMarker(other)),
        }
    }
}

/// Relay the body of a STDERR_ERROR frame.
fn relay_stderr_error_body(daemon: &mut UnixStream, client: &mut UnixStream, minor: u64) -> Result<()> {
    relay_string(daemon, client)?;                  // type ("Error", plain string)
    relay_u64(daemon, client)?;                     // level
    relay_string(daemon, client)?;                  // removed name field ("Error")
    relay_nix_str_no_ctx(daemon, client, minor)?;   // message (NixStringWithoutContext)
    let have_pos = relay_u64(daemon, client)?;
    if have_pos != 0 {
        relay_u64(daemon, client)?;    // line
        relay_u64(daemon, client)?;    // column
        relay_string(daemon, client)?; // file
    }
    let n_traces = relay_u64(daemon, client)?;
    for _ in 0..n_traces {
        let have_hint = relay_u64(daemon, client)?;
        if have_hint != 0 {
            relay_nix_str_no_ctx(daemon, client, minor)?; // hint
        }
    }
    Ok(())
}

// ── Op denial ─────────────────────────────────────────────────────────────────

/// Read and discard a single nix string from `src` (e.g. to consume an op
/// argument before sending a denial without forwarding anything to the daemon).
pub fn discard_string(src: &mut UnixStream) -> io::Result<()> {
    let len = read_u64(src)? as usize;
    let padded = (len + 7) & !7;
    let mut buf = vec![0u8; padded];
    src.read_exact(&mut buf)?;
    Ok(())
}

/// Synthesise a STDERR_ERROR response denying an operation with `msg`.
pub fn deny_op(client: &mut UnixStream, minor: u64, msg: &[u8]) -> io::Result<()> {
    write_u64(client, STDERR_ERROR)?;
    write_nix_str(client, b"Error")?;              // type
    write_u64(client, 0)?;                         // level = lvlError
    write_nix_str(client, b"Error")?;              // removed name field
    write_nix_str_no_ctx(client, msg, minor)?;     // message
    write_u64(client, 0)?;                         // havePos = false
    write_u64(client, 0)?;                         // nrTraces = 0
    client.flush()
}

pub fn deny_gc(client: &mut UnixStream, minor: u64) -> io::Result<()> {
    deny_op(client, minor, b"you are not privileged to collect garbage")
}

pub fn deny_add_indirect_root(client: &mut UnixStream, minor: u64) -> io::Result<()> {
    deny_op(client, minor, b"containers may not create GC roots on the host")
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use std::io::Read;
    use std::os::unix::net::UnixStream;

    use super::*;

    fn pair() -> (UnixStream, UnixStream) {
        UnixStream::pair().unwrap()
    }

    #[test]
    fn u64_round_trip() {
        let (mut a, mut b) = pair();
        write_u64(&mut a, 0xdead_beef_cafe_babe).unwrap();
        assert_eq!(read_u64(&mut b).unwrap(), 0xdead_beef_cafe_babe);
    }

    #[test]
    fn discard_string_advances_exactly_past_padded_body() {
        let (mut a, mut b) = pair();
        // "hello" = 5 bytes → padded to 8; sentinel follows immediately.
        write_nix_str(&mut a, b"hello").unwrap();
        write_u64(&mut a, 0xAB_CD).unwrap(); // sentinel
        discard_string(&mut b).unwrap();
        assert_eq!(read_u64(&mut b).unwrap(), 0xAB_CD, "sentinel must be next after discard");
    }

    #[test]
    fn discard_string_handles_8byte_aligned_payload() {
        let (mut a, mut b) = pair();
        // "12345678" is exactly 8 bytes → no padding.
        write_nix_str(&mut a, b"12345678").unwrap();
        write_u64(&mut a, 0xFF_00).unwrap();
        discard_string(&mut b).unwrap();
        assert_eq!(read_u64(&mut b).unwrap(), 0xFF_00);
    }

    #[test]
    fn deny_gc_is_parseable_as_daemon_error() {
        // The denial must be structurally valid: relay_stderr_to_last must be
        // able to parse it and return DaemonError (not an IO/protocol error).
        let (mut a, mut b) = pair();
        deny_gc(&mut a, 38).unwrap();
        drop(a);
        let (mut sink, _sink_b) = pair();
        let result = relay_stderr_to_last(&mut b, &mut sink, 38);
        assert!(
            matches!(result, Err(ProtocolError::DaemonError)),
            "expected DaemonError, got {result:?}"
        );
    }

    #[test]
    fn deny_gc_message_contains_not_privileged() {
        let (mut a, mut b) = pair();
        deny_gc(&mut a, 0).unwrap();
        drop(a);
        let mut buf = Vec::new();
        b.read_to_end(&mut buf).unwrap();
        assert!(
            String::from_utf8_lossy(&buf).contains("not privileged"),
            "GC denial must contain 'not privileged'"
        );
    }

    #[test]
    fn deny_add_indirect_root_message_contains_gc_roots() {
        let (mut a, mut b) = pair();
        deny_add_indirect_root(&mut a, 0).unwrap();
        drop(a);
        let mut buf = Vec::new();
        b.read_to_end(&mut buf).unwrap();
        assert!(
            String::from_utf8_lossy(&buf).contains("GC roots"),
            "AddIndirectRoot denial must mention 'GC roots'"
        );
    }
}
