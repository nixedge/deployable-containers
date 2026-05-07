mod cli;
mod error;
mod protocol;
mod proxy;
mod sd_notify;
mod splice;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::thread;

use anyhow::{Context, Result};
use clap::Parser;
use tracing::{error, info};
use tracing_subscriber::EnvFilter;

use cli::Args;

fn main() -> Result<()> {
    let args = Args::parse();

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .with_ansi(false)
        .without_time() // journald adds its own timestamps
        .init();

    info!(
        socket = %args.socket.display(),
        daemon_socket = %args.daemon_socket.display(),
        "starting"
    );

    if args.socket.exists() {
        fs::remove_file(&args.socket)
            .with_context(|| format!("removing stale socket {}", args.socket.display()))?;
    }

    let listener = UnixListener::bind(&args.socket)
        .with_context(|| format!("binding socket {}", args.socket.display()))?;

    fs::set_permissions(&args.socket, fs::Permissions::from_mode(args.socket_mode))
        .with_context(|| format!("setting permissions on {}", args.socket.display()))?;

    sd_notify::ready();
    info!("ready");

    for stream in listener.incoming() {
        match stream {
            Ok(client) => {
                let daemon_socket = args.daemon_socket.clone();
                thread::spawn(move || proxy::handle(client, &daemon_socket));
            }
            Err(e) => error!("accept: {e}"),
        }
    }

    Ok(())
}
