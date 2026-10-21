//! Native inventory is positive ownership evidence, never an exclusive lease.

use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

use pocox_core::process::{process_identity, ProcessIdentity};
use serde::Deserialize;
use tokio::sync::Mutex;

use super::command;
use crate::sessions::{Holder, SessionLiveness};

const CACHE_TTL: Duration = Duration::from_secs(5);

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    pid: u32,
    session_id: String,
    cwd: PathBuf,
    started_at: u64,
    status: String,
}

struct Inventory {
    at: Instant,
    records: Vec<Record>,
}

pub(super) struct Probe {
    program: PathBuf,
    home: PathBuf,
    root: PathBuf,
    cache: Mutex<Option<Inventory>>,
}

impl Probe {
    pub(super) fn new(program: PathBuf, home: PathBuf, root: PathBuf) -> Self {
        Self {
            program,
            home,
            root,
            cache: Mutex::new(None),
        }
    }

    async fn inventory(&self) -> Option<Vec<Record>> {
        if !self.program.is_absolute() || !self.home.is_absolute() || !self.root.is_absolute() {
            return None;
        }
        let output = command::read_json_with_timeout(
            &self.program,
            &["--bare".into(), "agents".into(), "--json".into()],
            &[
                ("HOME".into(), self.home.as_os_str().to_owned()),
                ("CLAUDE_CONFIG_DIR".into(), self.root.as_os_str().to_owned()),
                ("DISABLE_TELEMETRY".into(), "1".into()),
            ],
            &serde_json::Value::Null,
            Duration::from_secs(5),
        )
        .await
        .ok()?;
        let records: Vec<Record> = serde_json::from_value(output).ok()?;
        (records.len() <= 1024).then_some(records)
    }

    pub(super) async fn unowned_sessions(
        &self,
        sessions: &[String],
    ) -> anyhow::Result<Vec<String>> {
        let records = self
            .inventory()
            .await
            .ok_or_else(|| anyhow::anyhow!("Claude ownership probe failed"))?;
        Ok(sessions
            .iter()
            .filter(|id| !records.iter().any(|r| r.session_id == **id))
            .cloned()
            .collect())
    }

    /// Fresh positive/negative evidence for an explicit handoff, never the
    /// display cache's failure-as-unknown projection.
    pub(super) async fn idle_owners(&self, session: &str) -> anyhow::Result<Vec<ProcessIdentity>> {
        self.owners(session, false).await
    }

    /// Verify all holders, optionally permitting a known running owner. This
    /// still refuses unknown statuses and never uses the display cache.
    pub(super) async fn owners(
        &self,
        session: &str,
        allow_running: bool,
    ) -> anyhow::Result<Vec<ProcessIdentity>> {
        anyhow::ensure!(uuid::Uuid::parse_str(session).is_ok(), "invalid native session id");
        let records = self.inventory().await.ok_or_else(|| {
            anyhow::anyhow!("Claude ownership could not be inspected; keep the session read-only")
        })?;
        let records: Vec<_> = records
            .into_iter()
            .filter(|r| r.session_id == session)
            .collect();
        anyhow::ensure!(records.len() <= 8, "too many native session owners");
        let program = self.program.clone();
        tokio::task::spawn_blocking(move || {
            let program = program
                .canonicalize()
                .map_err(|_| anyhow::anyhow!("Claude executable changed"))?;
            let mut owners = Vec::new();
            for record in records {
                anyhow::ensure!(
                    record.status == "idle"
                        || allow_running && matches!(record.status.as_str(), "busy" | "running"),
                    "Claude still has an active or unknown turn"
                );
                let process = process_identity(record.pid)
                    .ok_or_else(|| anyhow::anyhow!("Claude owner changed; refresh and retry"))?;
                let cwd = record
                    .cwd
                    .canonicalize()
                    .map_err(|_| anyhow::anyhow!("Claude owner directory changed"))?;
                anyhow::ensure!(
                    matches_identity(&record, &program, &cwd, &process),
                    "Claude owner identity changed"
                );
                anyhow::ensure!(!owners.contains(&process), "ambiguous Claude ownership");
                owners.push(process);
            }
            Ok(owners)
        })
        .await?
    }

    pub(super) async fn inspect(&self, session: &str) -> SessionLiveness {
        if uuid::Uuid::parse_str(session).is_err() {
            return unknown(session);
        }
        let mut cached = self.cache.lock().await;
        if cached
            .as_ref()
            .is_none_or(|value| value.at.elapsed() >= CACHE_TTL)
        {
            // Cache failures too, but never reuse older successful evidence.
            let records = self.inventory().await.unwrap_or_default();
            *cached = Some(Inventory {
                at: Instant::now(),
                records,
            });
        }
        let records: Vec<_> = cached
            .as_ref()
            .into_iter()
            .flat_map(|value| &value.records)
            .filter(|record| record.session_id == session)
            .take(9)
            .cloned()
            .collect();
        drop(cached);
        let program = self.program.clone();
        let id = session.to_owned();
        tokio::task::spawn_blocking(move || inspect_records(&id, &program, &records))
            .await
            .unwrap_or_else(|_| unknown(session))
    }

    pub(super) async fn inspect_fresh(&self, session: &str) -> SessionLiveness {
        if uuid::Uuid::parse_str(session).is_err() {
            return unknown(session);
        }
        let Some(records) = self.inventory().await else { return unknown(session) };
        let records: Vec<_> = records
            .into_iter()
            .filter(|r| r.session_id == session)
            .collect();
        if records.is_empty() {
            let mut view = unknown(session);
            view.safety = "nativeUnowned".into();
            return view;
        }
        let program = self.program.clone();
        let id = session.to_owned();
        tokio::task::spawn_blocking(move || inspect_records(&id, &program, &records))
            .await
            .unwrap_or_else(|_| unknown(session))
    }
}

fn inspect_records(
    session: &str,
    program: &std::path::Path,
    records: &[Record],
) -> SessionLiveness {
    let mut result = unknown(session);
    if records.is_empty() || records.len() > 8 {
        return result;
    }
    let Ok(program) = program.canonicalize() else { return result };
    let mut states = Vec::new();
    for record in records {
        let Some(process) = process_identity(record.pid) else { return unknown(session) };
        let Ok(cwd) = record.cwd.canonicalize() else { return unknown(session) };
        if !matches_identity(record, &program, &cwd, &process) {
            return unknown(session);
        }
        if result
            .holders
            .iter()
            .any(|owner: &Holder| owner.pid == record.pid)
        {
            return unknown(session);
        }
        result.holders.push(Holder {
            pid: record.pid,
            name: "Claude Code".into(),
        });
        states.push(record.status.as_str());
    }
    result.held_open = true;
    if states
        .iter()
        .any(|state| matches!(*state, "busy" | "running"))
    {
        result.turn_state = "running".into();
        result.safety = "nativeOwnedRunning".into();
    } else if states.iter().all(|state| *state == "idle") {
        result.turn_state = "idle".into();
        result.safety = "nativeOwnedIdle".into();
    }
    result
}

fn matches_identity(
    record: &Record,
    program: &std::path::Path,
    cwd: &std::path::Path,
    process: &ProcessIdentity,
) -> bool {
    // CLI metadata is millisecond wall time; OS creation time has second
    // precision. A larger discrepancy (including clock changes) is unknown.
    record.started_at > 0
        && process.started > 0
        && record.pid == process.pid
        && (record.started_at / 1000).abs_diff(process.started) <= 1
        && process.executable == program
        && process.cwd == cwd
}

pub(super) fn unknown(session: &str) -> SessionLiveness {
    SessionLiveness {
        thread_id: session.into(),
        turn_state: "unknown".into(),
        held_open: false,
        safety: "nativeUnknown".into(),
        allows_resume: false,
        requires_takeover: false,
        holders: Vec::new(),
    }
}

#[cfg(test)]
mod tests;
