//! The Windows handoff: the helper's modes, the processes they hold, and
//! the version check on the result.
mod handoff;
mod process;
mod version;

pub use handoff::run;
