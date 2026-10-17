//! Ephemeral pairing trust and bounded transfers; local library journals persist.

#[cfg(test)]
mod account_tests;
pub mod accounts;
pub mod clock;
pub mod connection;
pub mod driver;
pub mod headless;
#[cfg(test)]
mod headless_tests;
pub mod library_guard;
pub mod mailbox;
pub mod manifest;
pub mod native_io;
#[cfg(any(windows, target_os = "macos"))]
pub mod native_mtp;
pub mod native_process;
pub mod planner;
mod qr;
pub mod read_model;
#[cfg(test)]
mod read_model_tests;
pub mod receiver;
pub mod recovery;
pub mod runtime;
mod session;
pub mod source_names;
pub mod space_budget;
pub mod staging;
pub mod tcp;
#[cfg(test)]
mod tests;
pub mod usb;
#[cfg(test)]
mod usb_tests;
pub mod wire;
pub mod work;
pub use qr::{Invitation, Qr};
pub use session::{PeerInfo, Session, SessionState};

#[derive(Debug, PartialEq, Eq)]
pub enum SessionError {
    InvalidQr,
    VersionMismatch,
    Expired,
    Consumed,
    Terminal,
    Protocol,
    Authentication,
    Tls,
    Bounds,
    NotConfirmed,
    Io,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Sender,
    Receiver,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(
    deny_unknown_fields,
    tag = "kind",
    content = "address",
    rename_all = "snake_case"
)]
pub enum Transport {
    Tcp(std::net::SocketAddr),
    Usb,
}

pub const MAX_CIPHERTEXT: usize = 65_536;
pub const MAX_PAYLOAD: usize = 65_536;
pub const MAX_BUFFER: usize = 262_144;
pub const MAX_CONTROL: usize = 4_096;
