//! The version an executable reports: its `ProductVersion` resource, which
//! the Flutter build sets to the pubspec's version (`0.7.7+45`).

use std::ffi::c_void;
use std::path::Path;
use std::ptr::read_unaligned;

use anyhow::{ensure, Result};
use windows_sys::Win32::Storage::FileSystem::{
    GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW,
};

use super::process::wide;

/// Fails unless `app` reports release `version`, whatever its build number.
pub fn expect(app: &Path, version: &str) -> Result<()> {
    let found = product_version(app)?;
    let release = found
        .split_once('+')
        .map_or(found.as_str(), |(release, _)| release);
    ensure!(
        release.trim() == version,
        "{} reports version {found}, not the expected {version}",
        app.display()
    );
    Ok(())
}

fn product_version(app: &Path) -> Result<String> {
    let path = wide(app);
    // SAFETY: `path` is a terminated string that outlives the call.
    let size = unsafe { GetFileVersionInfoSizeW(path.as_ptr(), std::ptr::null_mut()) };
    ensure!(size > 0, "{} has no version information", app.display());
    let mut info = vec![0u8; size as usize];
    // SAFETY: `info` holds `size` writable bytes for the call.
    let read = unsafe { GetFileVersionInfoW(path.as_ptr(), 0, size, info.as_mut_ptr().cast()) };
    ensure!(read != 0, "reading {}'s version: {}", app.display(), std::io::Error::last_os_error());
    let (table, length) = query(&info, r"\VarFileInfo\Translation")?;
    ensure!(length >= 4, "{} has no version language", app.display());
    // SAFETY: the table holds at least one (language, code page) pair of
    // u16s inside `info`, possibly unaligned.
    let (language, code_page) = unsafe {
        (read_unaligned(table.cast::<u16>()), read_unaligned(table.cast::<u16>().add(1)))
    };
    let key = format!(r"\StringFileInfo\{language:04x}{code_page:04x}\ProductVersion");
    let (text, length) = query(&info, &key)?;
    let units: Vec<u16> = (0..length as usize)
        // SAFETY: a string value is `length` UTF-16 units inside `info`,
        // possibly unaligned.
        .map(|index| unsafe { read_unaligned(text.cast::<u16>().add(index)) })
        .collect();
    Ok(String::from_utf16(&units)?
        .trim_end_matches('\0')
        .trim()
        .to_string())
}

/// Where the value `key` sits in the version resource `info`, and its length
/// (bytes for binary values, UTF-16 units for strings).
fn query(info: &[u8], key: &str) -> Result<(*const c_void, u32)> {
    let name = wide(key);
    let mut value = std::ptr::null_mut();
    let mut length = 0u32;
    // SAFETY: `info` is the resource GetFileVersionInfoW filled and `name` a
    // terminated string; both outlive the call. A success points `value`
    // into `info`.
    let found =
        unsafe { VerQueryValueW(info.as_ptr().cast(), name.as_ptr(), &mut value, &mut length) };
    ensure!(found != 0 && !value.is_null(), "the version resource has no {key}");
    Ok((value.cast_const(), length))
}
