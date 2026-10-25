//! Applies a verified POCOX release on Windows once the app has quit: the
//! installer over an installed copy, or the portable archive's files swapped
//! into a portable copy's folder. Then it reopens the app.
//!
//! The app writes a [`request::Request`] beside the downloaded file and runs
//! the helper's `--prepare` mode, which starts a worker that outlives the
//! app. The worker pins the app's process, checks the file against the
//! signed manifest's size and SHA-256, and readies the update before it
//! acknowledges. That means unpacking and checking the new version for a
//! portable copy, and taking the administrator prompt for an installer. Only
//! then may the app quit, so any failure up to that point leaves the app
//! running and is reported there. A swap that fails after the app has quit
//! puts the old files back, and the app reopens either way.
//!
//! [`package`], [`portable`], [`request`] and [`status`] are plain file
//! work, tested on every platform; the process handoff is Windows only.
pub mod package;
pub mod portable;
pub mod request;
pub mod status;
#[cfg(windows)]
mod windows;

#[cfg(windows)]
pub use windows::run;
