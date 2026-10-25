//! Checking the downloaded release file against the signed manifest, and
//! keeping it open so it cannot change between the check and its use.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use anyhow::{ensure, Context, Result};
use ring::digest;

/// `path`, opened so nothing else can write or delete it while the handle
/// lives (on Windows), once its size and SHA-256 match the manifest's.
pub fn open_verified(path: &Path, size: u64, sha256: &str) -> Result<File> {
    let mut file =
        open_pinned(path).with_context(|| format!("opening the update {}", path.display()))?;
    ensure!(
        file.metadata()?.len() == size,
        "the downloaded update's size differs from the signed manifest"
    );
    let mut hash = digest::Context::new(&digest::SHA256);
    let mut buffer = vec![0; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hash.update(&buffer[..read]);
    }
    let actual: String = hash
        .finish()
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    ensure!(actual == sha256, "the downloaded update's checksum differs from the signed manifest");
    file.seek(SeekFrom::Start(0))?;
    Ok(file)
}

#[cfg(windows)]
fn open_pinned(path: &Path) -> std::io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;

    use windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ;
    // Others may read (and run) it, but not change, replace or delete it.
    std::fs::OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .open(path)
}

#[cfg(not(windows))]
fn open_pinned(path: &Path) -> std::io::Result<File> {
    File::open(path)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, reason = "test failures should fail at the observed boundary")]

    use super::*;

    #[test]
    fn only_the_manifests_exact_file_opens() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("update.zip");
        std::fs::write(&path, b"abc").unwrap();
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        let mut file = open_verified(&path, 3, sha).unwrap();
        let mut contents = String::new();
        file.read_to_string(&mut contents).unwrap();
        assert_eq!(contents, "abc", "the verified handle reads from the start");
        drop(file);
        assert!(open_verified(&path, 4, sha).is_err());
        assert!(open_verified(&path, 3, &"0".repeat(64)).is_err());
    }
}
