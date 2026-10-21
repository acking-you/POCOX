//! OpenCode 2's per-user background server (`opencode serve --service`).
//!
//! Its terminal app, `opencode run` and desktop app all connect to it, and it
//! keeps running after they exit. A host on the shared history attaches to it
//! instead of starting a second engine on that database. Like those clients
//! it may start it (`opencode service start`), but it never stops or signals
//! it.

use std::{
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use anyhow::{anyhow, bail, Context, Result};
use pocox_core::{process::process_start_time, provider::Secret};
use serde::Deserialize;

use super::{
    client::Client,
    ownership,
    runtime::{Detection, Launch},
    wire::{Dialect, Version},
};

/// The service's registration file, the one discovery contract OpenCode's own
/// clients read. It has no `Debug`: it holds the password.
struct Registration {
    id: Option<String>,
    url: String,
    pid: u32,
    password: Option<Secret>,
}

#[derive(Deserialize)]
struct Raw {
    id: Option<String>,
    url: String,
    pid: u32,
    password: Option<String>,
}

impl Registration {
    /// `None` when no service is registered. The file must be private to this
    /// user; a decode failure never echoes its contents (it holds a password).
    fn read(file: &Path) -> Result<Option<Self>> {
        let metadata = match std::fs::symlink_metadata(file) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => bail!("OpenCode's background server registration cannot be read"),
        };
        private(&metadata)?;
        anyhow::ensure!(
            metadata.len() <= 16 * 1024,
            "OpenCode's background server registration is unexpectedly large"
        );
        let bytes = match std::fs::read(file) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => bail!("OpenCode's background server registration cannot be read"),
        };
        let raw: Raw = serde_json::from_slice(&bytes)
            .map_err(|_| anyhow!("OpenCode's background server registration is not valid"))?;
        Ok(Some(Self {
            id: raw.id,
            url: raw.url,
            pid: raw.pid,
            password: raw.password.map(Secret::new),
        }))
    }
}

#[cfg(unix)]
fn private(metadata: &std::fs::Metadata) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    anyhow::ensure!(
        metadata.is_file()
            && metadata.uid() == nix::unistd::geteuid().as_raw()
            && metadata.mode() & 0o077 == 0,
        "OpenCode's background server registration is not a private file of this user"
    );
    Ok(())
}

#[cfg(not(unix))]
fn private(_: &std::fs::Metadata) -> Result<()> {
    bail!("OpenCode's background server is not supported on this platform")
}

/// The attached service, as it was validated. It holds no credential.
#[derive(Debug, Clone)]
pub struct Attachment {
    file: PathBuf,
    id: Option<String>,
    url: String,
    pid: u32,
    started: u64,
    address: SocketAddr,
}

/// Whether the attached service is still the registered one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    /// The registration still names the attached, running process.
    Current,
    /// No running service is registered (for example after
    /// `opencode service stop`).
    Gone,
    /// Another running service is registered: a client replaced it (a
    /// different version, `opencode service restart`, a changed setting).
    Replaced,
}

impl Attachment {
    /// The loopback address the service listens on.
    pub fn address(&self) -> SocketAddr {
        self.address
    }

    /// The service process.
    pub fn pid(&self) -> u32 {
        self.pid
    }

    /// The service process's creation time.
    pub fn started(&self) -> u64 {
        self.started
    }

    /// Compare the registration with the attached service afresh.
    pub async fn state(&self) -> State {
        let this = self.clone();
        tokio::task::spawn_blocking(move || {
            let alive = |pid, started| process_start_time(pid) == Some(started);
            match Registration::read(&this.file) {
                Ok(Some(found))
                    if found.id == this.id && found.pid == this.pid && found.url == this.url =>
                {
                    if alive(this.pid, this.started) {
                        State::Current
                    } else {
                        State::Gone
                    }
                },
                Ok(Some(found)) if process_start_time(found.pid).is_some() => State::Replaced,
                _ => State::Gone,
            }
        })
        .await
        .unwrap_or(State::Gone)
    }
}

/// Whether this version's own clients use the background server: a 2.x
/// release the user did not turn it off for (`opencode service set disabled
/// true`, after which they run private servers that hold the database only
/// while they are open, as 1.x does).
pub async fn enabled(launch: &Launch, detection: &Detection) -> Result<bool> {
    if !detection.dialect.background_server() {
        return Ok(false);
    }
    match launch
        .text_within(&["service", "get", "disabled"], 16, Duration::from_secs(15))
        .await
        .context("OpenCode did not report its background server setting")?
        .as_str()
    {
        "true" => Ok(false),
        "false" => Ok(true),
        _ => bail!("OpenCode reported an unexpected background server setting"),
    }
}

/// An attached service: its private client, identity and version.
pub(crate) struct Attached {
    pub client: Client,
    pub attachment: Attachment,
    pub version: String,
}

enum Probe {
    /// Not (yet) a running, answering service; starting or waiting may help.
    Retry(anyhow::Error),
    /// A running service this host must not attach to.
    Refuse(anyhow::Error),
}

/// Attach to the registered service, starting it once when none answers.
/// `opencode service start` reuses any compatible running service and never
/// replaces one.
pub(crate) async fn attach(launch: &Launch, detection: &Detection) -> Result<Attached> {
    let state = launch
        .text_within(&["debug", "paths", "state"], 16 * 1024, Duration::from_secs(15))
        .await
        .context("OpenCode did not report its state directory")?;
    let file = Path::new(&state).join(registration_name(&detection.version));
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut started = false;
    loop {
        match probe(&file, detection).await {
            Ok(attached) => return Ok(attached),
            Err(Probe::Refuse(error)) => return Err(error),
            Err(Probe::Retry(error)) if !started => {
                tracing::info!("starting OpenCode's background server: {error:#}");
                launch
                    .text_within(&["service", "start"], 4096, Duration::from_secs(60))
                    .await
                    .context("OpenCode could not start its background server")?;
                started = true;
            },
            Err(Probe::Retry(error)) if Instant::now() >= deadline => {
                return Err(error.context("OpenCode's background server did not become ready"));
            },
            Err(Probe::Retry(_)) => tokio::time::sleep(Duration::from_millis(250)).await,
        }
    }
}

async fn probe(file: &Path, detection: &Detection) -> Result<Attached, Probe> {
    let path = file.to_path_buf();
    let registration = tokio::task::spawn_blocking(move || Registration::read(&path))
        .await
        .map_err(|_| Probe::Retry(anyhow!("registration read was cancelled")))?
        .map_err(Probe::Refuse)?
        .ok_or_else(|| Probe::Retry(anyhow!("no background server is registered")))?;
    let address = loopback(&registration.url).map_err(Probe::Refuse)?;
    let client = Client::new(&registration.url, registration.password, detection.dialect)
        .map_err(|error| Probe::Refuse(error.into()))?;
    let health = client
        .health()
        .await
        .map_err(|error| Probe::Retry(error.into()))?;
    if !health.healthy || health.pid != Some(registration.pid) {
        return Err(Probe::Retry(anyhow!("the registered background server is not answering")));
    }
    let speaks = Version::parse(&health.version)
        .is_some_and(|version| Dialect::detect(&version).0 == detection.dialect);
    if !speaks {
        return Err(Probe::Refuse(anyhow!(
            "OpenCode's background server runs OpenCode {}, which this host's OpenCode {} cannot \
             speak; stop it with `opencode service stop`",
            health.version,
            detection.version
        )));
    }
    if health.urls.iter().any(|url| loopback(url).is_err()) {
        return Err(Probe::Refuse(anyhow!(
            "OpenCode's background server is reachable from other devices (remote access or its \
             hostname setting), so this host cannot tell its clients apart; give this host its \
             own history"
        )));
    }
    client
        .open_source()
        .await
        .map_err(|error| Probe::Retry(error.into()))?;
    let started = process_start_time(registration.pid)
        .ok_or_else(|| Probe::Retry(anyhow!("the background server has exited")))?;
    if !ownership::holds(&detection.database, registration.pid).await {
        return Err(Probe::Refuse(anyhow!(
            "OpenCode's background server does not use this host's history; give this host its \
             own history"
        )));
    }
    Ok(Attached {
        client,
        attachment: Attachment {
            file: file.to_path_buf(),
            id: registration.id,
            url: registration.url,
            pid: registration.pid,
            started,
            address,
        },
        version: health.version,
    })
}

/// A plain `http://<loopback IP>:<port>` origin.
fn loopback(url: &str) -> Result<SocketAddr> {
    let parsed = url::Url::parse(url).context("OpenCode reported an invalid server address")?;
    let ip = parsed
        .host_str()
        .map(|host| host.trim_matches(['[', ']']))
        .and_then(|host| host.parse::<IpAddr>().ok());
    match (ip, parsed.port()) {
        (Some(ip), Some(port))
            if parsed.scheme() == "http"
                && ip.is_loopback()
                && port > 0
                && matches!(parsed.path(), "" | "/")
                && parsed.username().is_empty()
                && parsed.password().is_none()
                && parsed.query().is_none() =>
        {
            Ok(SocketAddr::new(ip, port))
        },
        _ => bail!("OpenCode's background server is not a private loopback endpoint"),
    }
}

/// The registration file of the version's release channel: `service.json`
/// for releases and the dev, beta and next channels, as OpenCode names it.
fn registration_name(version: &str) -> String {
    let channel = version
        .strip_prefix("0.0.0-")
        .and_then(|rest| rest.rsplit_once('-'))
        .map(|(channel, _)| channel);
    match channel {
        None | Some("latest" | "dev" | "beta" | "next") => "service.json".into(),
        Some(channel) => format!(
            "service-{}.json",
            channel
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                    c
                } else {
                    '-'
                })
                .collect::<String>()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_private_loopback_registration_is_attached() {
        assert!(loopback("http://127.0.0.1:49374").is_ok());
        assert!(loopback("http://[::1]:49374/").is_ok());
        for url in [
            "http://0.0.0.0:49374",
            "http://192.168.1.2:49374",
            "https://abc.opentunnel.example",
            "http://localhost:49374",
            "http://user:pw@127.0.0.1:49374",
        ] {
            assert!(loopback(url).is_err(), "{url}");
        }
        assert_eq!(registration_name("2.0.32"), "service.json");
        assert_eq!(registration_name("0.0.0-beta-19507"), "service.json");
        assert_eq!(registration_name("0.0.0-local-3"), "service-local.json");

        let dir = tempfile::tempdir().expect("temp dir");
        let file = dir.path().join("service.json");
        assert!(Registration::read(&file).expect("absent").is_none());
        std::fs::write(&file, br#"{"url":"http://127.0.0.1:1","pid":"SECRET-ECHO"}"#)
            .expect("write");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).expect("chmod");
            assert!(Registration::read(&file).is_err(), "readable by others");
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).expect("chmod");
        }
        let error = Registration::read(&file)
            .err()
            .expect("invalid")
            .to_string();
        assert!(!error.contains("SECRET-ECHO"), "{error}");
    }
}
