//! Stored provider keys in text: which keys are accepted, and the
//! [`Redactor`] that keeps them out of anything shown or logged after a
//! launch (see [`pocox_core::redact`] for what it withholds).

use anyhow::{bail, Result};
pub use pocox_core::redact::Redactor;

use super::Resolved;

/// Refuse a key that is not one printable ASCII token, the only keys the
/// redactor's forms cover.
pub(super) fn check_key(key: &str) -> Result<()> {
    if key.is_empty() {
        bail!("the key is empty");
    }
    if !key
        .bytes()
        .all(|b| b.is_ascii_graphic() && b != b'"' && b != b'\\')
    {
        bail!(
            "the key may contain only printable ASCII characters without spaces, quotes or \
             backslashes"
        );
    }
    Ok(())
}

/// The redactor for the key of `resolved` (see
/// [`pocox_core::redact`]).
pub fn redactor(resolved: &Resolved) -> Redactor {
    let mut redactor = Redactor::new(resolved.endpoint.as_ref().and_then(|e| e.key.as_ref()));
    for (name, value) in &resolved.claude_env {
        if super::environment::variable(name).is_ok_and(|v| v.secret) {
            redactor.include(value);
        }
    }
    redactor
}

/// `text` with every stored secret of `resolved` removed, and bounded: for
/// errors shown or logged after a launch (child output may echo a key).
pub fn redact(text: &str, resolved: &Resolved) -> String {
    redactor(resolved).text(text)
}
