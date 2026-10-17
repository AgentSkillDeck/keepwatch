//! The keepwatch core for Linux and Windows, shared by the `keepwatch` CLI
//! and, on Linux, the `keepwatch-tray` app. Everything that reads the system
//! is bounded and treats what it reads as untrusted data.
#![deny(unsafe_code)]

pub mod agents;
pub mod apps;
pub mod cli;
pub mod duration;
pub mod inhibit;
pub mod lid;
pub mod lock;
pub mod ports;
pub mod power;
pub mod privacy;
pub mod procs;
pub mod session;
pub mod util;
#[cfg(windows)]
pub mod win;

pub const VERSION: &str = "0.3.0";
