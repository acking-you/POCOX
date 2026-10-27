//! Harness versions and updates, of this device or of a managed one: the
//! same calls for both, `service_key` naming the other device's management
//! entry (absent for this device). See `engine::harnesses`.

use anyhow::{anyhow, Result};

use crate::engine::execution::{self, Lane};
use crate::engine::harnesses::{self, Kind, SettingsChange};
use crate::engine::management_client as remote;

/// One harness of a device.
pub struct HarnessDto {
    /// `codex`, `opencode`, `claude` or `grok`.
    pub kind: String,
    /// Its executable was found.
    pub installed: bool,
    /// The installed version.
    pub version: Option<String>,
    /// The newest version its vendor publishes for this installation.
    pub latest: Option<String>,
    /// [`Self::latest`] is newer than [`Self::version`].
    pub update_available: bool,
    /// `npm`, `bun`, `pnpm`, `brew`, `standalone` or `own`.
    pub method: Option<String>,
    /// An update can be started.
    pub can_update: bool,
    /// `unmanaged`, `winget`, `bundled`, `version_unknown` or `check_failed`.
    pub problem: Option<String>,
    /// The device updates it by itself.
    pub auto_update: bool,
    /// Running services that use it.
    pub services: Vec<String>,
}

/// A service an update did not restart.
pub struct HarnessSkipDto {
    /// Instance name.
    pub name: String,
    /// `disabled`, `adopted`, `shared_server`, `other_install`, `changed`,
    /// `busy` or `failed`.
    pub reason: String,
}

/// Installer-reported measurements for the current download.
pub struct HarnessDownloadDto {
    /// Bytes received, when reported.
    pub downloaded_bytes: Option<i64>,
    /// Total bytes, when reported.
    pub total_bytes: Option<i64>,
    /// Bytes per second, when reported.
    pub bytes_per_second: Option<i64>,
    /// Percentage of the download, not of the entire update.
    pub percent: Option<u8>,
}

/// The running or most recent update of a device.
pub struct HarnessJobDto {
    /// Its number on that device.
    pub run: i64,
    /// The harness it updates.
    pub kind: String,
    /// `running`, `done` or `failed`.
    pub state: String,
    /// `stopping`, `updating`, `downloading`, `installing`, `verifying` or
    /// `restarting` while running.
    pub stage: Option<String>,
    /// Measurements reported by the installer, absent for silent installers.
    pub download: Option<HarnessDownloadDto>,
    /// Elapsed milliseconds measured on the host; absent on older hosts.
    pub elapsed_ms: Option<i64>,
    /// Started by the device's automatic update.
    pub automatic: bool,
    /// The version before it.
    pub from_version: Option<String>,
    /// The version after it.
    pub to_version: Option<String>,
    /// `unavailable`, `tool_missing`, `in_use`, `permission`, `timed_out`
    /// or `failed`.
    pub failure: Option<String>,
    /// Services restarted on the installed version.
    pub restarted: Vec<String>,
    /// Services not restarted, and why.
    pub not_restarted: Vec<HarnessSkipDto>,
    /// Unix milliseconds.
    pub started_at_ms: i64,
    /// Unix milliseconds.
    pub finished_at_ms: Option<i64>,
}

/// Every harness a device can host, with its update settings.
pub struct HarnessOverviewDto {
    /// In display order; none before the device first checked.
    pub harnesses: Vec<HarnessDto>,
    /// When the newest versions were last looked up (Unix milliseconds).
    pub checked_at_ms: Option<i64>,
    /// A lookup is running.
    pub checking: bool,
    /// Services that use an updated harness restart on the new version.
    pub restart_services: bool,
    /// The running or most recent update.
    pub job: Option<HarnessJobDto>,
}

/// A counter, byte count or timestamp as a Dart integer; beyond `i64` it
/// saturates.
fn signed(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

impl From<harnesses::Overview> for HarnessOverviewDto {
    fn from(value: harnesses::Overview) -> Self {
        Self {
            harnesses: value
                .harnesses
                .into_iter()
                .map(|harness| HarnessDto {
                    kind: harness.kind,
                    installed: harness.installed,
                    version: harness.version,
                    latest: harness.latest,
                    update_available: harness.update_available,
                    method: harness.method,
                    can_update: harness.can_update,
                    problem: harness.problem,
                    auto_update: harness.auto_update,
                    services: harness.services,
                })
                .collect(),
            checked_at_ms: value.checked_at_ms.map(signed),
            checking: value.checking,
            restart_services: value.restart_services,
            job: value.job.map(|job| HarnessJobDto {
                run: signed(job.run),
                kind: job.kind,
                state: job.state,
                stage: job.stage,
                download: job.download.map(|download| HarnessDownloadDto {
                    downloaded_bytes: download.downloaded_bytes.map(signed),
                    total_bytes: download.total_bytes.map(signed),
                    bytes_per_second: download.bytes_per_second.map(signed),
                    percent: download.percent,
                }),
                elapsed_ms: job.elapsed_ms.map(signed),
                automatic: job.automatic,
                from_version: job.from_version,
                to_version: job.to_version,
                failure: job.failure,
                restarted: job.restarted,
                not_restarted: job
                    .not_restarted
                    .into_iter()
                    .map(|skipped| HarnessSkipDto {
                        name: skipped.name,
                        reason: skipped.reason,
                    })
                    .collect(),
                started_at_ms: signed(job.started_at_ms),
                finished_at_ms: job.finished_at_ms.map(signed),
            }),
        }
    }
}

fn kind(label: &str) -> Result<Kind> {
    Kind::parse(label).ok_or_else(|| anyhow!("unknown harness `{label}`"))
}

/// This device's refusals in the shape a managed computer's take
/// (`code (status): message`), so the app reads both alike.
fn local<T>(result: Result<T>) -> Result<T> {
    result.map_err(|error| match error.downcast_ref::<harnesses::Refusal>() {
        Some(refusal) => {
            let (status, code) = match refusal {
                harnesses::Refusal::Running => (409, "update_running"),
                harnesses::Refusal::Unavailable | harnesses::Refusal::Unsupported => {
                    (422, "update_unavailable")
                },
            };
            remote::RemoteError {
                status,
                code: code.into(),
                message: refusal.to_string(),
            }
            .into()
        },
        None => error,
    })
}

/// A device's harnesses as last checked; a stale check starts one on that
/// device. `None` when the other device's POCOX has no harness management.
pub async fn harness_overview(service_key: Option<String>) -> Result<Option<HarnessOverviewDto>> {
    execution::run(Lane::Read, move || {
        let overview = match service_key {
            None => Some(local(harnesses::overview())?),
            Some(key) => remote::harnesses(&key)?,
        };
        Ok(overview.map(Into::into))
    })
    .await
}

/// Look up a device's installed and newest harness versions now.
pub async fn harness_check(service_key: Option<String>) -> Result<HarnessOverviewDto> {
    execution::run(Lane::Background, move || {
        Ok(match service_key {
            None => local(harnesses::check())?,
            Some(key) => remote::harnesses_check(&key)?,
        }
        .into())
    })
    .await
}

/// Start updating one harness on a device; read its progress with
/// [`harness_overview`]. A lost answer is never sent again by itself.
pub async fn harness_update(
    service_key: Option<String>,
    kind_label: String,
) -> Result<HarnessOverviewDto> {
    execution::run(Lane::Control, move || {
        let kind = kind(&kind_label)?;
        Ok(match service_key {
            None => local(harnesses::update(kind))?,
            Some(key) => remote::harness_update(&key, kind)?,
        }
        .into())
    })
    .await
}

/// Change a device's own update settings: one harness's automatic update
/// (`kind_label` with `auto_update`) and/or restarting its services.
pub async fn harness_settings(
    service_key: Option<String>,
    kind_label: Option<String>,
    auto_update: Option<bool>,
    restart_services: Option<bool>,
) -> Result<HarnessOverviewDto> {
    execution::run(Lane::Control, move || {
        let change = SettingsChange {
            kind: kind_label.as_deref().map(kind).transpose()?,
            auto_update,
            restart_services,
        };
        Ok(match service_key {
            None => local(harnesses::set(&change))?,
            Some(key) => remote::harness_settings(&key, &change)?,
        }
        .into())
    })
    .await
}
