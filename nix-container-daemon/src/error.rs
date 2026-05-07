use thiserror::Error;

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("I/O error")]
    Io(#[from] std::io::Error),

    #[error("protocol magic mismatch")]
    MagicMismatch,

    #[error("unknown STDERR marker {0:#010x}")]
    UnknownStderrMarker(u64),

    #[error("unknown field type {0}")]
    UnknownFieldType(u64),

    #[error("daemon returned an error response")]
    DaemonError,
}

pub type Result<T> = std::result::Result<T, ProtocolError>;
