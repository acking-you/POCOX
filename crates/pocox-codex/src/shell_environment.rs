//! Resolve a GUI host's shell PATH and selected child-only environment values.

use std::{
    collections::HashSet,
    ffi::{OsStr, OsString},
    fs::File,
    io::Read,
    os::unix::{ffi::OsStringExt, fs::PermissionsExt, process::CommandExt},
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use anyhow::{bail, Context, Result};
use nix::{
    sys::signal::{killpg, Signal},
    unistd::Pid,
};
use rustix::process::{waitid, WaitId, WaitIdOptions};

const MAX_PATH_BYTES: u64 = 128 * 1024;

#[cfg(target_os = "macos")]
pub(crate) fn child_path() -> Option<OsString> {
    use std::{io::IsTerminal, sync::OnceLock};

    // Terminal launches already have the user's selected tool versions.
    if std::io::stdin().is_terminal() {
        return None;
    }
    static PATH: OnceLock<Option<OsString>> = OnceLock::new();
    PATH.get_or_init(resolve_current_path).clone()
}

#[cfg(target_os = "macos")]
fn resolve_current_path() -> Option<OsString> {
    let inherited = std::env::var_os("PATH");
    let shell = current_shell();
    let environment = std::env::vars_os().collect::<Vec<_>>();
    match resolve_path(&shell, &environment, inherited.as_deref(), Duration::from_secs(3)) {
        Ok(path) => Some(path),
        Err(cause) => {
            tracing::warn!(?shell, cause = %format!("{cause:#}"), "shell PATH probe failed; Codex will inherit the original PATH");
            None
        },
    }
}

#[cfg(target_os = "macos")]
fn current_shell() -> std::path::PathBuf {
    std::env::var_os("SHELL")
        .map(std::path::PathBuf::from)
        .or_else(|| {
            nix::unistd::User::from_uid(nix::unistd::Uid::current())
                .ok()
                .flatten()
                .map(|user| user.shell)
        })
        .unwrap_or_else(|| "/bin/zsh".into())
}

#[cfg(target_os = "macos")]
pub(crate) fn child_variables(names: &[&str]) -> Result<Vec<(OsString, OsString)>> {
    let environment = std::env::vars_os().collect::<Vec<_>>();
    resolve_variables(&current_shell(), &environment, names, Duration::from_secs(3))
}

/// Read only named variables; startup output and unrelated secrets never enter
/// the result. Explicit inherited values win over shell defaults.
fn resolve_variables(
    shell: &Path,
    environment: &[(OsString, OsString)],
    names: &[&str],
    timeout: Duration,
) -> Result<Vec<(OsString, OsString)>> {
    if names.iter().any(|name| {
        name.is_empty()
            || !name
                .bytes()
                .enumerate()
                .all(|(i, b)| b == b'_' || b.is_ascii_uppercase() || (i > 0 && b.is_ascii_digit()))
    }) {
        bail!("invalid shell environment variable name");
    }
    let inherited: Vec<_> = environment
        .iter()
        .filter(|(key, _)| names.iter().any(|name| key == name))
        .cloned()
        .collect();
    if inherited.len() == names.len() || names.is_empty() {
        return Ok(inherited);
    }
    if !shell.is_absolute() {
        bail!("login shell must be an absolute path");
    }
    let directory = tempfile::Builder::new()
        .permissions(std::fs::Permissions::from_mode(0o700))
        .tempdir()
        .context("creating private shell environment output")?;
    let output = directory.path().join("environment");
    let mut script = String::from("umask 077; { ");
    for name in names {
        script.push_str(&format!(
            "if [ \"${{{name}+x}}\" = x ]; then printf '%s\\0%s\\0' '{name}' \"${name}\"; fi; "
        ));
    }
    script.push_str("} > \"$POCOX_ENV_FILE\"");
    let child = Command::new(shell)
        .args(["-ilc", &script])
        .env_clear()
        .envs(environment.iter().map(|(k, v)| (k, v)))
        .env("POCOX_ENV_FILE", &output)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .context("starting login shell")?;
    let mut probe = Probe(child);
    probe.wait(timeout)?;
    drop(probe);
    let mut bytes = Vec::new();
    File::open(output)?
        .take(MAX_PATH_BYTES)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 == MAX_PATH_BYTES || (!bytes.is_empty() && bytes.last() != Some(&0)) {
        bail!("invalid shell environment output");
    }
    let mut values = Vec::new();
    if bytes.is_empty() {
        return Ok(inherited);
    }
    let fields = bytes[..bytes.len() - 1]
        .split(|byte| *byte == 0)
        .collect::<Vec<_>>();
    if fields.len() % 2 != 0 {
        bail!("invalid shell environment output");
    }
    for pair in fields.chunks_exact(2) {
        let [key, value] = [pair[0], pair[1]];
        if !names.iter().any(|name| name.as_bytes() == key)
            || values
                .iter()
                .any(|(prior, _): &(OsString, OsString)| prior.as_encoded_bytes() == key)
        {
            bail!("invalid shell environment output");
        }
        values.push((OsString::from_vec(key.to_vec()), OsString::from_vec(value.to_vec())));
    }
    for (key, value) in inherited {
        values.retain(|(name, _)| name != &key);
        values.push((key, value));
    }
    Ok(values)
}

fn resolve_path(
    shell: &Path,
    environment: &[(OsString, OsString)],
    inherited: Option<&OsStr>,
    timeout: Duration,
) -> Result<OsString> {
    if !shell.is_absolute() {
        bail!("login shell must be an absolute path");
    }
    let directory = tempfile::Builder::new()
        .permissions(std::fs::Permissions::from_mode(0o700))
        .tempdir()
        .context("creating shell PATH output directory")?;
    let output = directory.path().join("path");
    let child = Command::new(shell)
        .args(["-ilc", "/usr/bin/printenv PATH > \"$POCOX_PATH_FILE\""])
        .env_clear()
        .envs(environment.iter().map(|(key, value)| (key, value)))
        .env("POCOX_PATH_FILE", &output)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        // Set before exec, so startup commands never share the App's group.
        .process_group(0)
        .spawn()
        .context("starting login shell")?;
    let mut probe = Probe(child);
    probe.wait(timeout)?;
    // Also clean up ordinary background children left by a successful shell.
    drop(probe);

    let mut bytes = Vec::new();
    File::open(&output)
        .context("opening shell PATH output")?
        .take(MAX_PATH_BYTES)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 == MAX_PATH_BYTES {
        bail!("shell PATH output exceeds the size limit");
    }
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    if bytes.is_empty() || bytes.contains(&0) {
        bail!("shell returned an empty or invalid PATH");
    }
    merge_path(inherited, &OsString::from_vec(bytes))
}

struct Probe(Child);

impl Probe {
    fn wait(&mut self, timeout: Duration) -> Result<()> {
        let pid = rustix::process::Pid::from_child(&self.0);
        let deadline = Instant::now() + timeout;
        loop {
            // Leave the leader waitable until its group is killed. Reaping it
            // here would let its PID be reused before Drop signals the group.
            match waitid(
                WaitId::Pid(pid),
                WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
            ) {
                Ok(Some(status)) => {
                    if status.exit_status() == Some(0) {
                        return Ok(());
                    }
                    bail!("login shell exited unsuccessfully");
                },
                Ok(None) | Err(rustix::io::Errno::INTR) => {},
                Err(cause) => return Err(cause).context("waiting for login shell"),
            }
            if Instant::now() >= deadline {
                bail!("login shell probe timed out");
            }
            thread::sleep(
                Duration::from_millis(10).min(deadline.saturating_duration_since(Instant::now())),
            );
        }
    }
}

impl Drop for Probe {
    fn drop(&mut self) {
        if let Ok(pid) = i32::try_from(self.0.id()) {
            let _ = killpg(Pid::from_raw(pid), Signal::SIGKILL);
        }
        // The leader may have changed its own group in a startup script.
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn merge_path(inherited: Option<&OsStr>, shell: &OsStr) -> Result<OsString> {
    let mut seen = HashSet::new();
    // Preserve explicit inherited tool choices (including terminal launches
    // with redirected stdin); only append directories missing from GUI PATH.
    let entries = inherited
        .into_iter()
        .chain(Some(shell))
        .flat_map(std::env::split_paths)
        .filter(|entry| !entry.as_os_str().is_empty() && seen.insert(entry.clone()));
    let path = std::env::join_paths(entries)?;
    if path.is_empty() {
        bail!("shell returned no PATH directories");
    }
    Ok(path)
}

#[cfg(test)]
#[path = "shell_environment_tests.rs"]
mod tests;
