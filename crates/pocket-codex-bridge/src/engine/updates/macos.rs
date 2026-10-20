//! macOS: the new bundle comes out of the release's signed, notarized disk
//! image, proves to be POCOX from the release team, and replaces the running
//! bundle once the app has quit through its normal path.
use std::{
    path::{Path, PathBuf},
    process::Command,
};

use super::{Failure, Kind};

/// The Developer ID team every release is signed by (`APPLE_TEAM_ID`).
pub const TEAM_ID: &str = "5T7QB722FM";
/// The application's bundle identifier, the same for every build.
pub const BUNDLE_ID: &str = "io.github.ackingyou.pocketCodex";

fn verification(detail: impl std::fmt::Display) -> Failure {
    Failure::new(Kind::Verification, detail)
}

fn run(program: &str, args: &[&str]) -> Result<std::process::Output, Failure> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|error| verification(format!("{program}: {error}")))?;
    if !output.status.success() {
        return Err(verification(format!(
            "{program} {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    Ok(output)
}

fn path_str(path: &Path) -> Result<&str, Failure> {
    path.to_str()
        .ok_or_else(|| verification(format!("{} is not UTF-8", path.display())))
}

/// The running application bundle, when this is one.
pub fn current_bundle() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let bundle = exe.parent()?.parent()?.parent()?;
    (bundle.extension()? == "app").then(|| bundle.to_path_buf())
}

/// Whether this user may swap `bundle`: not run from a translocated
/// (read-only, randomized) copy, and its folder is writable.
pub fn can_replace(bundle: &Path) -> bool {
    if bundle.to_string_lossy().contains("/AppTranslocation/") {
        return false;
    }
    let Some(folder) = bundle.parent() else {
        return false;
    };
    let probe = folder.join(format!(".pocox-update-{}", std::process::id()));
    let writable = std::fs::write(&probe, b"").is_ok();
    let _ = std::fs::remove_file(&probe);
    writable && bundle.is_dir()
}

/// Copies the app out of `image` into `work`, once it proves to be POCOX
/// `version` signed by [`TEAM_ID`] and accepted by Gatekeeper.
pub fn stage(image: &Path, work: &Path, version: &semver::Version) -> Result<PathBuf, Failure> {
    let mount = work.join("mount");
    std::fs::create_dir_all(&mount).map_err(verification)?;
    run("/usr/bin/hdiutil", &[
        "attach",
        "-nobrowse",
        "-readonly",
        "-noautoopen",
        "-mountpoint",
        path_str(&mount)?,
        path_str(image)?,
    ])?;
    let staged = copy_app(&mount, work);
    let _ = Command::new("/usr/bin/hdiutil")
        .args(["detach", "-force"])
        .arg(&mount)
        .output();
    let staged = staged?;
    verify_bundle(&staged, version)?;
    Ok(staged)
}

fn copy_app(mount: &Path, work: &Path) -> Result<PathBuf, Failure> {
    let apps: Vec<PathBuf> = std::fs::read_dir(mount)
        .map_err(verification)?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "app") && !path.is_symlink())
        .collect();
    let [app] = apps.as_slice() else {
        return Err(verification("the disk image does not hold exactly one application"));
    };
    let name = app
        .file_name()
        .ok_or_else(|| verification("the application has no name"))?;
    let staged = work.join(name);
    if staged.exists() {
        std::fs::remove_dir_all(&staged).map_err(verification)?;
    }
    run("/usr/bin/ditto", &[path_str(app)?, path_str(&staged)?])?;
    Ok(staged)
}

/// Fails unless `app` is intact, signed by [`TEAM_ID`], notarized, and
/// POCOX `version`.
pub fn verify_bundle(app: &Path, version: &semver::Version) -> Result<(), Failure> {
    let path = path_str(app)?;
    run("/usr/bin/codesign", &["--verify", "--deep", "--strict", path])?;
    let details = run("/usr/bin/codesign", &["-dv", "--verbose=2", path])?;
    // codesign prints the details on stderr.
    if !String::from_utf8_lossy(&details.stderr).contains(&format!("TeamIdentifier={TEAM_ID}")) {
        return Err(verification("the application is not signed by the POCOX team"));
    }
    // Gatekeeper's own verdict: Developer ID signed and notarized.
    run("/usr/sbin/spctl", &["--assess", "--type", "execute", path])?;
    let plist = format!("{path}/Contents/Info.plist");
    let read = |key: &str| -> Result<String, Failure> {
        let output = run("/usr/bin/plutil", &["-extract", key, "raw", &plist])?;
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    };
    let (id, short) = (read("CFBundleIdentifier")?, read("CFBundleShortVersionString")?);
    if id != BUNDLE_ID || short != version.to_string() {
        return Err(verification(format!("expected {BUNDLE_ID} {version}, found {id} {short}")));
    }
    Ok(())
}

/// Waits for the app (`$1`) to exit, then swaps the staged bundle (`$3`) in
/// for the running one (`$2`), putting the old one back if that fails, and
/// opens whichever is in place. Gives up untouched if the app never exits.
pub const SCRIPT: &str = r#"#!/bin/bash
pid="$1"; target="$2"; staged="$3"; work="$4"
for _ in $(seq 1 600); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.2
done
kill -0 "$pid" 2>/dev/null && exit 1
[ -d "$staged" ] || exit 0
previous="$target.previous-$$"
if mv "$target" "$previous"; then
  if mv "$staged" "$target"; then
    rm -rf "$previous"
  else
    mv "$previous" "$target"
  fi
fi
open "$target"
rm -rf "$work"
"#;
