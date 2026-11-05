//! Pairing-code login against a real relay and through the real accept loop.
//!
//! One test binary, so the support module is compiled once and nothing in it
//! can be dead code in a binary that happens not to use it.

mod support;

mod admission;
mod links;
mod principals;
mod recovery;
mod relay_answers;
mod revocation;
mod secret_overlap;
