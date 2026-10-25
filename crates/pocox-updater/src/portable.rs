//! A portable copy's update. The release archive is unpacked into the app's
//! own folder before the app quits ([`unpack`]), so every later move is a
//! rename on one volume. Once the app has quit, each of the archive's
//! top-level entries takes the place of the app's entry of that name
//! ([`swap`]), and every move is undone if one fails. Entries the archive
//! does not have, such as the user's own files, stay as they are.

use std::ffi::OsString;
use std::fs::File;
use std::path::{Component, Path};
use std::time::{Duration, Instant};

use anyhow::{bail, ensure, Context, Result};

/// The folder in the app's directory holding an update in progress: the
/// unpacked release (`new`) and, once swapped, the replaced files (`old`).
pub const STAGING: &str = ".pocox-update";

/// Unpacks `archive` into `into`. Refuses entries that would land outside
/// it, links, and an entry for the staging folder itself.
pub fn unpack(archive: &File, into: &Path) -> Result<()> {
    let mut zip = zip::ZipArchive::new(archive).context("reading the update archive")?;
    std::fs::create_dir_all(into)?;
    for index in 0..zip.len() {
        let mut entry = zip.by_index(index)?;
        let name = entry.name()?.into_owned();
        let relative = entry
            .enclosed_name()
            .with_context(|| format!("the update archive has an unsafe path: {name}"))?;
        ensure!(!entry.is_symlink(), "the update archive has a link: {name}");
        let top = relative
            .components()
            .find(|part| !matches!(part, Component::CurDir));
        ensure!(
            top.is_none_or(|part| part.as_os_str() != STAGING),
            "the update archive has an unexpected entry: {name}"
        );
        let target = into.join(&relative);
        if entry.is_dir() {
            std::fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file =
            File::create(&target).with_context(|| format!("unpacking {}", target.display()))?;
        std::io::copy(&mut entry, &mut file)
            .with_context(|| format!("unpacking {}", target.display()))?;
    }
    Ok(())
}

/// One move [`swap`] made, so it can be undone.
enum Step {
    /// The app's entry of this name went into `old`.
    Aside(OsString),
    /// The new entry of this name went into the app's folder.
    In(OsString),
}

/// Moves each top-level entry of `new` into `app_dir`, first moving the
/// app's entry of that name into `old`. A move that fails, as when a
/// virus scan still holds a fresh file, is retried for `patience`. If one
/// still fails, every move so far is undone.
pub fn swap(app_dir: &Path, new: &Path, old: &Path, patience: Duration) -> Result<()> {
    let mut names = std::fs::read_dir(new)?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<std::io::Result<Vec<_>>>()?;
    names.sort();
    std::fs::create_dir_all(old)?;
    let mut done = Vec::new();
    for name in &names {
        if let Err(error) = replace(app_dir, new, old, name, patience, &mut done) {
            let failures = undo(app_dir, new, old, &done, patience);
            if failures.is_empty() {
                return Err(
                    error.context("the app's files could not be replaced, so they were kept")
                );
            }
            bail!(
                "the app's files could not be replaced ({error:#}), and these could not be put \
                 back: {}",
                failures.join("; ")
            );
        }
    }
    Ok(())
}

fn replace(
    app_dir: &Path,
    new: &Path,
    old: &Path,
    name: &OsString,
    patience: Duration,
    done: &mut Vec<Step>,
) -> Result<()> {
    let current = app_dir.join(name);
    if current.symlink_metadata().is_ok() {
        rename(&current, &old.join(name), patience)?;
        done.push(Step::Aside(name.clone()));
    }
    rename(&new.join(name), &current, patience)?;
    done.push(Step::In(name.clone()));
    Ok(())
}

/// Reverses `done`, returning what could not be reversed.
fn undo(app_dir: &Path, new: &Path, old: &Path, done: &[Step], patience: Duration) -> Vec<String> {
    done.iter()
        .rev()
        .filter_map(|step| {
            let (from, to) = match step {
                Step::In(name) => (app_dir.join(name), new.join(name)),
                Step::Aside(name) => (old.join(name), app_dir.join(name)),
            };
            rename(&from, &to, patience)
                .err()
                .map(|error| format!("{error:#}"))
        })
        .collect()
}

fn rename(from: &Path, to: &Path, patience: Duration) -> Result<()> {
    let deadline = Instant::now() + patience;
    loop {
        let Err(error) = std::fs::rename(from, to) else {
            return Ok(());
        };
        if error.kind() == std::io::ErrorKind::NotFound || Instant::now() >= deadline {
            return Err(error)
                .with_context(|| format!("moving {} to {}", from.display(), to.display()));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Removes an update's staging folder, as far as nothing holds it open.
pub fn clear(staging: &Path) {
    let _ = std::fs::remove_dir_all(staging);
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, reason = "test failures should fail at the observed boundary")]

    use std::io::Write;

    use super::*;

    fn archive(path: &Path, entries: &[(&str, &str)]) -> File {
        let mut zip = zip::ZipWriter::new(File::create(path).unwrap());
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for (name, contents) in entries {
            zip.start_file(*name, options).unwrap();
            zip.write_all(contents.as_bytes()).unwrap();
        }
        zip.finish().unwrap();
        File::open(path).unwrap()
    }

    fn read(path: &Path) -> String {
        std::fs::read_to_string(path).unwrap()
    }

    /// An app folder with the old release and a file of the user's own.
    fn installed(dir: &Path) -> std::path::PathBuf {
        let app = dir.join("POCOX");
        std::fs::create_dir_all(app.join("data")).unwrap();
        std::fs::write(app.join("pocox.exe"), "old app").unwrap();
        std::fs::write(app.join("data/app.so"), "old code").unwrap();
        std::fs::write(app.join("data/retired.dat"), "old data").unwrap();
        std::fs::write(app.join("notes.txt"), "mine").unwrap();
        app
    }

    const RELEASE: &[(&str, &str)] = &[
        ("pocox.exe", "new app"),
        ("data/app.so", "new code"),
        ("pocox-updater.exe", "new helper"),
    ];

    #[test]
    fn the_archives_entries_replace_the_apps_and_nothing_else() {
        let dir = tempfile::tempdir().unwrap();
        let app = installed(dir.path());
        let staging = app.join(STAGING);
        let zip = archive(&dir.path().join("update.zip"), RELEASE);
        unpack(&zip, &staging.join("new")).unwrap();
        swap(&app, &staging.join("new"), &staging.join("old"), Duration::ZERO).unwrap();

        assert_eq!(read(&app.join("pocox.exe")), "new app");
        assert_eq!(read(&app.join("data/app.so")), "new code");
        assert_eq!(read(&app.join("pocox-updater.exe")), "new helper");
        assert!(!app.join("data/retired.dat").exists(), "a folder is replaced whole");
        assert_eq!(read(&app.join("notes.txt")), "mine", "the user's own files stay");
        assert_eq!(read(&staging.join("old/pocox.exe")), "old app");
        clear(&staging);
        assert!(!staging.exists());
    }

    #[test]
    fn entries_outside_the_folder_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let into = dir.path().join("a/b");
        for name in ["../../escaped.txt", ".pocox-update/new/pocox.exe"] {
            let zip = archive(&dir.path().join("evil.zip"), &[(name, "x")]);
            assert!(unpack(&zip, &into).is_err(), "{name}");
        }
        assert!(!dir.path().join("escaped.txt").exists());
    }

    #[cfg(windows)]
    #[test]
    fn a_failed_swap_puts_every_file_back() {
        use std::os::windows::fs::OpenOptionsExt;

        let dir = tempfile::tempdir().unwrap();
        let app = installed(dir.path());
        let staging = app.join(STAGING);
        let zip = archive(&dir.path().join("update.zip"), RELEASE);
        unpack(&zip, &staging.join("new")).unwrap();
        // Held without delete sharing: it cannot be moved, as when a process
        // of the old version is still running from it. Entries move in name
        // order, so `data` and `pocox-updater.exe` have moved by then.
        let held = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(app.join("pocox.exe"))
            .unwrap();
        let error =
            swap(&app, &staging.join("new"), &staging.join("old"), Duration::from_millis(200))
                .unwrap_err();
        drop(held);

        assert!(format!("{error:#}").contains("were kept"), "{error:#}");
        assert_eq!(read(&app.join("pocox.exe")), "old app");
        assert_eq!(read(&app.join("data/app.so")), "old code");
        assert_eq!(read(&app.join("data/retired.dat")), "old data");
        assert!(!app.join("pocox-updater.exe").exists());
        assert_eq!(read(&staging.join("new/pocox-updater.exe")), "new helper");
    }
}
