//! Files that only their owner may read: relay keys, tokens, host state.
//!
//! Every crate that persists such a file starts from [`private_options`], so
//! the creation mode is decided once instead of in a `#[cfg(unix)]` block at
//! each call site.

use std::fs::OpenOptions;

/// [`OpenOptions`] whose newly created files are `0o600` on Unix. Other
/// platforms inherit the profile directory's ACL. The caller still chooses the
/// access and creation flags; the mode only applies when a file is created.
#[must_use]
pub fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    owner_only(&mut options);
    options
}

#[cfg(unix)]
fn owner_only(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt as _;
    options.mode(0o600);
}

#[cfg(not(unix))]
fn owner_only(_options: &mut OpenOptions) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn created_files_are_private_to_their_owner() {
        let path = std::env::temp_dir().join(format!("pocox-private-{}", std::process::id()));
        let _ = std::fs::remove_file(&path);
        private_options()
            .write(true)
            .create_new(true)
            .open(&path)
            .expect("create");
        #[cfg(unix)]
        let mode = {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::metadata(&path)
                .expect("metadata")
                .permissions()
                .mode()
        };
        std::fs::remove_file(&path).expect("remove");
        #[cfg(unix)]
        assert_eq!(mode & 0o777, 0o600, "group and others get nothing");
    }
}
