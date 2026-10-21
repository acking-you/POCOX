//! Cooperative admission between POCOX hosts, not a lock honored by native
//! CLIs.

use std::{
    fs::{self, File, OpenOptions, TryLockError},
    path::{Path, PathBuf},
};

use pocox_core::history_sync::digest_bytes;

/// Why a POCOX session claim could not be acquired.
#[derive(Debug, thiserror::Error)]
pub enum ClaimError {
    /// Another POCOX host still holds this session's claim.
    #[error("another POCOX host still owns this session; release it there before taking over")]
    Busy,
    /// The source or claim storage cannot be verified or locked.
    #[error("session ownership could not be verified; keep viewing read-only")]
    Unavailable,
}

/// A nonblocking, cross-process claim for one provider source and session.
///
/// Independent native clients do not honor this lock. The caller must also
/// verify that the old writer released the session, and retain this value
/// until its own writer has closed. Dropping the descriptor releases the
/// claim even after a crash; the lock file itself must never be unlinked.
pub struct SessionClaim {
    _file: File,
}

impl SessionClaim {
    /// Claim `session` beneath an existing canonical provider `source` (a
    /// config directory or database file). No native transcript is modified.
    /// Alternate paths to the same source use the same adjacent lock file.
    /// This operation alone does not authorize a native resume.
    pub fn acquire(source: &Path, session: &str) -> Result<Self, ClaimError> {
        if session.is_empty() || session.len() > 1024 || !source.is_absolute() {
            return Err(ClaimError::Unavailable);
        }
        let path = claim_path(source, session).map_err(|_| ClaimError::Unavailable)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(nix::libc::O_NOFOLLOW);
        }
        // The directory is private and the stable inode is essential: deleting
        // a held lock would let another process acquire a different inode.
        if fs::symlink_metadata(&path).is_ok_and(|meta| !meta.file_type().is_file()) {
            return Err(ClaimError::Unavailable);
        }
        let file = options.open(&path).map_err(|_| ClaimError::Unavailable)?;
        if !file.metadata().is_ok_and(|meta| meta.is_file()) {
            return Err(ClaimError::Unavailable);
        }
        match file.try_lock() {
            Ok(()) => Ok(Self {
                _file: file,
            }),
            Err(TryLockError::WouldBlock) => Err(ClaimError::Busy),
            Err(TryLockError::Error(_)) => Err(ClaimError::Unavailable),
        }
    }
}

fn claim_path(source: &Path, session: &str) -> std::io::Result<PathBuf> {
    let source = source.canonicalize()?;
    let metadata = fs::metadata(&source)?;
    let base = if metadata.is_dir() {
        source.as_path()
    } else if metadata.is_file() {
        source
            .parent()
            .ok_or_else(|| std::io::Error::other("source has no parent"))?
    } else {
        return Err(std::io::Error::other("unsupported native source"));
    };
    let directory = base.join(".pocox-writers");
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    match builder.create(&directory) {
        Ok(()) => {},
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {},
        Err(error) => return Err(error),
    }
    if !fs::symlink_metadata(&directory)?.file_type().is_dir() {
        return Err(std::io::Error::other("claim directory was replaced"));
    }
    let source = source.as_os_str().as_encoded_bytes();
    let mut key = Vec::with_capacity(source.len() + session.len() + 1);
    key.extend_from_slice(source);
    key.push(0);
    key.extend_from_slice(session.as_bytes());
    Ok(directory.join(format!("{}.lock", digest_bytes(&key))))
}

#[cfg(test)]
mod tests;
