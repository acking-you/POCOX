//! Open-session registrations of Grok's terminal clients, verified against
//! the OS: `$GROK_HOME/active_sessions.json` (`xai-grok-active-sessions`),
//! `[{session_id, pid, cwd, opened_at}]`. The TUI and `grok -p` register;
//! a crash leaves its entry behind until the next registration prunes dead
//! PIDs. `grok agent stdio` (editors, and POCOX's own host) never registers,
//! so this is positive evidence only, never an exclusive lease.

use std::{
    io::Read,
    path::PathBuf,
    time::{Duration, Instant},
};

use anyhow::{anyhow, ensure, Result};
use chrono::{DateTime, Utc};
use pocox_core::process::{pid_alive, process_identity, ProcessIdentity};
use serde::Deserialize;
use tokio::sync::Mutex;

use crate::sessions::{Holder, SessionLiveness};

const FILE: &str = "active_sessions.json";
const MAX_BYTES: u64 = 1024 * 1024;
const MAX_RECORDS: usize = 1024;
const CACHE_TTL: Duration = Duration::from_secs(5);
/// Registration happens after the process starts; OS start times have
/// second precision.
const START_SLACK_SECS: i64 = 2;

#[derive(Clone, Deserialize)]
struct Record {
    session_id: String,
    pid: u32,
    opened_at: DateTime<Utc>,
}

/// What one registration says about its session today.
enum Holding {
    /// The registering process is gone: a leftover of a crash.
    Stale,
    /// The registering Grok client still runs.
    Live(ProcessIdentity),
    /// A process runs under that PID but cannot be shown to be the client.
    Unverifiable,
}

pub(crate) struct Probe {
    home: PathBuf,
    cache: Mutex<Option<(Instant, Option<Vec<Record>>)>>,
}

impl Probe {
    pub(super) fn new(home: PathBuf) -> Self {
        Self {
            home,
            cache: Mutex::new(None),
        }
    }

    /// The registrations, `None` when the file cannot be read or parsed. A
    /// missing file means nothing is registered.
    fn records(&self) -> Option<Vec<Record>> {
        let path = self.home.join(FILE);
        let file = match std::fs::File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Some(Vec::new()),
            Err(_) => return None,
        };
        let mut bytes = Vec::new();
        file.take(MAX_BYTES + 1).read_to_end(&mut bytes).ok()?;
        if bytes.len() as u64 > MAX_BYTES {
            return None;
        }
        let records: Vec<Record> = serde_json::from_slice(&bytes).ok()?;
        (records.len() <= MAX_RECORDS).then_some(records)
    }

    async fn fresh(&self) -> Option<Vec<Record>> {
        let probe = Self::new(self.home.clone());
        tokio::task::spawn_blocking(move || probe.records())
            .await
            .ok()
            .flatten()
    }

    /// Live verified holders of `session`; an unverifiable one is an error,
    /// never an absent owner.
    pub(super) async fn owners(&self, session: &str) -> Result<Vec<ProcessIdentity>> {
        let records = self.fresh().await.ok_or_else(|| {
            anyhow!("Grok's open-session registry could not be read; keep the session read-only")
        })?;
        let session = session.to_owned();
        tokio::task::spawn_blocking(move || {
            let mut owners = Vec::new();
            for record in records.iter().filter(|r| r.session_id == session) {
                match holding(record) {
                    Holding::Stale => {},
                    Holding::Live(process) => {
                        ensure!(owners.len() < 8, "too many native session owners");
                        owners.push(process);
                    },
                    Holding::Unverifiable => {
                        return Err(anyhow!("a Grok session owner could not be verified"))
                    },
                }
            }
            Ok(owners)
        })
        .await?
    }

    pub(super) async fn unowned_sessions(&self, sessions: &[String]) -> Result<Vec<String>> {
        let mut free = Vec::new();
        for session in sessions {
            if self.owners(session).await?.is_empty() {
                free.push(session.clone());
            }
        }
        Ok(free)
    }

    /// Display evidence, cached briefly; failures read as unknown.
    pub(super) async fn inspect(&self, session: &str) -> SessionLiveness {
        let records = {
            let mut cache = self.cache.lock().await;
            if cache
                .as_ref()
                .is_none_or(|(at, _)| at.elapsed() >= CACHE_TTL)
            {
                *cache = Some((Instant::now(), self.fresh().await));
            }
            cache.as_ref().and_then(|(_, records)| records.clone())
        };
        evaluate(session, records).await
    }

    /// Fresh evidence for an explicit handoff: no registration of a live
    /// client is reported as unowned.
    pub(super) async fn inspect_fresh(&self, session: &str) -> SessionLiveness {
        evaluate(session, self.fresh().await).await
    }
}

async fn evaluate(session: &str, records: Option<Vec<Record>>) -> SessionLiveness {
    let unknown = super::super::ownership::unknown(session);
    let Some(records) = records else { return unknown };
    let records: Vec<Record> = records
        .into_iter()
        .filter(|r| r.session_id == session)
        .take(9)
        .collect();
    let id = session.to_owned();
    tokio::task::spawn_blocking(move || {
        let mut view = super::super::ownership::unknown(&id);
        for record in &records {
            match holding(record) {
                Holding::Stale => {},
                Holding::Live(process) => view.holders.push(Holder {
                    pid: process.pid,
                    name: "Grok".into(),
                }),
                Holding::Unverifiable => return super::super::ownership::unknown(&id),
            }
        }
        if view.holders.is_empty() {
            view.safety = "nativeUnowned".into();
        } else {
            // The client has the session open; whether a turn runs there
            // is not recorded.
            view.held_open = true;
            view.safety = "nativeOwned".into();
        }
        view
    })
    .await
    .unwrap_or(unknown)
}

fn holding(record: &Record) -> Holding {
    if !pid_alive(record.pid) {
        return Holding::Stale;
    }
    let Some(process) = process_identity(record.pid) else { return Holding::Unverifiable };
    let grok = process
        .executable
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with("grok") || name.starts_with("xai-grok"));
    let started_before = i64::try_from(process.started)
        .is_ok_and(|started| started <= record.opened_at.timestamp() + START_SLACK_SECS);
    if grok && started_before {
        Holding::Live(process)
    } else {
        // A reused PID or an unrecognized client: not provably free.
        Holding::Unverifiable
    }
}
