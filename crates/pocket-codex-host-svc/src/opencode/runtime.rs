//! Owned native `opencode serve`, its database claim, and bounded readiness.

use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};

use anyhow::{anyhow, ensure, Context, Result};
use pocket_codex_core::{process::process_start_time, provider::Secret};
use serde::Deserialize;
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    task::JoinHandle,
};

use super::client::Client;
use crate::{
    native_history::{ClaimError, SessionClaim},
    process::{self, AgentProcess, Spawned},
};

const PROBE_TIMEOUT: Duration = Duration::from_secs(15);

/// Exact child launch inputs. Debug deliberately omits environment values.
#[derive(Clone)]
pub struct Launch {
    /// Resolved executable or user-supplied wrapper.
    pub program: PathBuf,
    /// Child-only resolved PATH, when needed by a GUI host.
    pub path: Option<OsString>,
    /// Explicit child environment, also used by native discovery commands.
    pub env: Vec<(OsString, OsString)>,
}

/// Native executable facts; no credentials or provider configuration.
#[derive(Debug, Clone)]
pub struct Detection {
    /// Version reported by the executable itself.
    pub version: String,
    /// Canonical native database path, resolved by `opencode db path`.
    pub database: PathBuf,
}

impl Launch {
    /// Inspect this exact executable with this exact child environment.
    /// It must implement the native 1.19 API; no ACP fallback is attempted.
    pub async fn detect(&self) -> Result<Detection> {
        let version = self.text(&["--version"], 128).await?;
        let numbers: Vec<_> = version
            .trim_start_matches('v')
            .split('.')
            .take(2)
            .map(str::parse::<u32>)
            .collect::<std::result::Result<_, _>>()
            .context("OpenCode reported an unrecognized version")?;
        ensure!(
            numbers.len() == 2 && (numbers[0], numbers[1]) >= (1, 19),
            "OpenCode 1.19 or newer is required for native sessions"
        );
        let raw = self.text(&["db", "path"], 16 * 1024).await?;
        let database = canonical_database(Path::new(&raw))?;
        Ok(Detection {
            version,
            database,
        })
    }

    async fn text(&self, args: &[&str], limit: usize) -> Result<String> {
        let args = args.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        let bytes = process::inspect_output(
            &self.program,
            &args,
            self.path.as_ref(),
            &self.env,
            PROBE_TIMEOUT,
            limit,
        )
        .await
        .context("OpenCode executable inspection failed")?;
        let text = std::str::from_utf8(&bytes)
            .context("OpenCode inspection returned invalid text")?
            .trim();
        ensure!(
            !text.is_empty() && !text.contains(['\r', '\n']),
            "OpenCode inspection returned unexpected output"
        );
        Ok(text.into())
    }
}

fn canonical_database(path: &Path) -> Result<PathBuf> {
    ensure!(path.is_absolute(), "OpenCode must use a persistent absolute database path");
    if path.exists() {
        let path = path
            .canonicalize()
            .context("OpenCode database is unavailable")?;
        ensure!(path.is_file(), "OpenCode database is not a file");
        return Ok(path);
    }
    let parent = path
        .parent()
        .context("OpenCode database has no directory")?
        .canonicalize()
        .context("OpenCode data directory is unavailable")?;
    let name = path.file_name().context("OpenCode database has no name")?;
    Ok(parent.join(name))
}

/// One native server. The password stays exclusively in its private client.
pub struct Server {
    process: Option<AgentProcess>,
    claim: Option<SessionClaim>,
    output: Option<JoinHandle<()>>,
    /// Private authenticated HTTP client, never serialize it to a controller.
    pub client: Client,
    /// Native version and canonical source identity.
    pub detection: Detection,
    /// Unreaped leader PID; native children remain in its owned tree.
    pub pid: u32,
    /// Leader's creation time, for read-only ancestry checks.
    pub started: u64,
}

impl Server {
    /// Start a claimed native source on an automatically chosen loopback port.
    /// A second Pocket host cannot start against the same canonical source.
    pub async fn start(launch: &Launch) -> Result<Self> {
        let detection = launch.detect().await?;
        let database = detection.database.clone();
        let claim = tokio::task::spawn_blocking(move || {
            let parent = database
                .parent()
                .ok_or_else(|| anyhow!("database has no parent"))?;
            SessionClaim::acquire(parent, &format!("opencode-server:{}", database.display()))
                .map_err(|error| match error {
                    ClaimError::Busy => anyhow!(
                        "opencode_already_hosted: this native source already has a Pocket host"
                    ),
                    ClaimError::Unavailable => {
                        anyhow!("OpenCode source ownership cannot be verified")
                    },
                })
        })
        .await??;
        let password = Secret::new(format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        ));
        let mut env = launch.env.clone();
        env.retain(|(key, _)| {
            key != "OPENCODE_SERVER_PASSWORD" && key != "OPENCODE_SERVER_USERNAME"
        });
        env.push(("OPENCODE_SERVER_PASSWORD".into(), password.expose().into()));
        env.push(("OPENCODE_SERVER_USERNAME".into(), "opencode".into()));
        let Spawned {
            mut process,
            stdin,
            stdout,
        } = process::spawn(
            &launch.program,
            &["serve".into(), "--hostname".into(), "127.0.0.1".into(), "--port".into(), "0".into()],
            launch.path.as_ref(),
            &env,
        )?;
        drop(stdin);
        let result = async {
            let pid = process.id().context("OpenCode process has no identity")?;
            let started =
                process_start_time(pid).context("OpenCode process identity is unavailable")?;
            let mut reader = BufReader::new(stdout);
            let origin = tokio::time::timeout(Duration::from_secs(25), listening(&mut reader))
                .await
                .context("OpenCode server did not become ready")??;
            let client = Client::new(&origin, Some(password))?;
            #[derive(Deserialize)]
            struct Health {
                healthy: bool,
                version: String,
            }
            let health: Health = client.get(&["global", "health"], None, &[]).await?;
            ensure!(
                health.healthy && health.version == detection.version,
                "OpenCode readiness returned a different runtime"
            );
            // Initialize the native source before admission inspects its open
            // database handles. This request never restores or prompts a session.
            let _: Vec<super::schema::Session> =
                client.get(&["session"], None, &[("limit", "1")]).await?;
            let output = tokio::spawn(async move {
                let mut discard = [0u8; 8192];
                while matches!(reader.read(&mut discard).await, Ok(n) if n > 0) {}
            });
            Ok::<_, anyhow::Error>((client, pid, started, output))
        }
        .await;
        match result {
            Ok((client, pid, started, output)) => Ok(Self {
                process: Some(process),
                claim: Some(claim),
                output: Some(output),
                client,
                detection,
                pid,
                started,
            }),
            Err(error) => {
                if !process.stop(Duration::from_millis(100)).await {
                    cleanup(process, claim, None);
                }
                Err(error)
            },
        }
    }

    /// Stop this owned server only. Retain the claim when exit is uncertain.
    pub async fn stop(&mut self) -> Result<()> {
        if let Some(process) = self.process.as_mut() {
            ensure!(
                process.stop(Duration::from_millis(100)).await,
                "OpenCode has not confirmed exit; its source remains claimed"
            );
        }
        self.process = None;
        if let Some(output) = self.output.take() {
            output.abort();
        }
        self.claim = None;
        Ok(())
    }
}

async fn listening(reader: &mut BufReader<tokio::process::ChildStdout>) -> Result<String> {
    let mut total = 0usize;
    loop {
        let mut line = Vec::new();
        let count = (&mut *reader)
            .take(8193)
            .read_until(b'\n', &mut line)
            .await?;
        total += count;
        ensure!(
            count > 0 && count <= 8192 && total <= 64 * 1024,
            "OpenCode startup output did not identify a bounded listener"
        );
        let Some(raw) = std::str::from_utf8(&line)
            .ok()
            .and_then(|line| line.trim().strip_prefix("opencode server listening on "))
        else {
            continue;
        };
        let origin = url::Url::parse(raw).context("OpenCode reported an invalid listener")?;
        ensure!(
            origin.scheme() == "http"
                && origin.host_str() == Some("127.0.0.1")
                && origin.port().is_some_and(|p| p > 0)
                && origin.path() == "/"
                && origin.username().is_empty()
                && origin.password().is_none()
                && origin.query().is_none()
                && origin.fragment().is_none(),
            "OpenCode listener is not a private loopback endpoint"
        );
        return Ok(origin.to_string());
    }
}

static CLEANUPS: AtomicUsize = AtomicUsize::new(0);

/// Failed or abandoned starts whose owned process has not confirmed exit yet.
/// App quit must remain pending while this is nonzero.
pub fn pending_cleanup() -> usize {
    CLEANUPS.load(Ordering::SeqCst)
}

fn cleanup(mut process: AgentProcess, claim: SessionClaim, output: Option<JoinHandle<()>>) {
    CLEANUPS.fetch_add(1, Ordering::SeqCst);
    if let Ok(runtime) = tokio::runtime::Handle::try_current() {
        runtime.spawn(async move {
            let _claim = claim;
            while !process.stop(Duration::from_millis(100)).await {
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            if let Some(output) = output {
                output.abort();
            }
            CLEANUPS.fetch_sub(1, Ordering::SeqCst);
        });
    } else {
        // AgentProcess signals its own group on drop. Future admission still
        // inspects native database holders before allowing any session write.
        drop(process);
        if let Some(output) = output {
            output.abort();
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let (Some(process), Some(claim)) = (self.process.take(), self.claim.take()) {
            cleanup(process, claim, self.output.take());
        }
    }
}
