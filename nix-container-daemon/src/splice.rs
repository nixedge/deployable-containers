//! Bidirectional byte splice between two Unix sockets.

use std::io;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::thread;

/// Copy bytes in both directions between `client` and `daemon` until both
/// half-connections are closed, then return.
pub fn bidirectional(client: UnixStream, daemon: UnixStream) {
    let mut client_w = match client.try_clone() {
        Ok(s) => s,
        Err(e) => { tracing::error!("cloning client socket: {e}"); return; }
    };
    let mut daemon_w = match daemon.try_clone() {
        Ok(s) => s,
        Err(e) => { tracing::error!("cloning daemon socket: {e}"); return; }
    };
    let mut client_r = client;
    let mut daemon_r = daemon;

    let t = thread::spawn(move || {
        let _ = io::copy(&mut daemon_r, &mut client_w);
        let _ = client_w.shutdown(Shutdown::Write);
    });
    let _ = io::copy(&mut client_r, &mut daemon_w);
    let _ = daemon_w.shutdown(Shutdown::Write);
    let _ = t.join();
}
