//! Bounded device-control HTTP surface and safe, actionable failures.

use std::sync::Arc;

use anyhow::{Context, Result};
use axum::extract::{DefaultBodyLimit, Path, Query, Request, State};
use axum::http::{header, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Json, Router};
use pocox_host_svc::projects::{ProjectError, ProjectsUpdate};
use serde::Deserialize;

use super::{runtime, server, ApplyRequest, SaveRequest, StartRequest, StopRequest};
use crate::engine::{harnesses, host_services};

#[derive(Clone, Copy)]
pub(super) struct AdmissionToken {
    epoch: u64,
    generation: u64,
}
impl AdmissionToken {
    pub(super) fn check(self) -> Result<()> {
        if crate::engine::transport::is_current(self.epoch) && server::accepts(self.generation) {
            Ok(())
        } else {
            Err(Fault::ConnectionChanged.into())
        }
    }
}

#[derive(Debug)]
pub(super) enum Fault {
    ConnectionChanged,
    Busy,
    AlreadyRunning,
    HostStopped,
    IncarnationChanged,
    AuthenticationRequired,
    PreparationRequired,
    InvalidConfiguration,
    OutsideRoots,
    UpdateRunning,
    UpdateUnavailable,
}
impl Fault {
    fn details(&self) -> (StatusCode, &'static str, &'static str) {
        match self {
            Self::ConnectionChanged => (
                StatusCode::FORBIDDEN,
                "connection_changed",
                "Management was disabled or the connection changed. The operation may have \
                 completed; reconnect and refresh its state before deciding what to do next.",
            ),
            Self::Busy => (
                StatusCode::TOO_MANY_REQUESTS,
                "host_busy",
                "The host is handling other requests. Try again shortly.",
            ),
            Self::AlreadyRunning => (
                StatusCode::CONFLICT,
                "already_running",
                "This service is already running. Refresh it or choose another name.",
            ),
            Self::HostStopped => (
                StatusCode::NOT_FOUND,
                "host_stopped",
                "This service has stopped. Refresh its status.",
            ),
            Self::IncarnationChanged => (
                StatusCode::CONFLICT,
                "host_changed",
                "This service was replaced or restarted. Refresh before changing it.",
            ),
            Self::AuthenticationRequired => (
                StatusCode::UNPROCESSABLE_ENTITY,
                "host_login_required",
                "Complete Codex sign-in on the host computer first.",
            ),
            Self::PreparationRequired => (
                StatusCode::UNPROCESSABLE_ENTITY,
                "prepare_required",
                "Prepare the Claude adapter on this computer before starting.",
            ),
            Self::InvalidConfiguration => (
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_configuration",
                "Review and save this service's configuration before starting.",
            ),
            Self::OutsideRoots => (
                StatusCode::FORBIDDEN,
                "outside_project_roots",
                "Choose a folder within the host's configured project folders.",
            ),
            Self::UpdateRunning => (
                StatusCode::CONFLICT,
                "update_running",
                "Another agent update is running on this computer. Refresh when it finishes.",
            ),
            Self::UpdateUnavailable => (
                StatusCode::UNPROCESSABLE_ENTITY,
                "update_unavailable",
                "This agent is not installed on this computer, or its installation cannot be \
                 updated from here.",
            ),
        }
    }
}
impl std::fmt::Display for Fault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.details().2)
    }
}
impl std::error::Error for Fault {}

struct ApiError(anyhow::Error);
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut current = None;
        let mut revision = None;
        let refused = self
            .0
            .downcast_ref::<harnesses::Refusal>()
            .map(|refusal| match refusal {
                harnesses::Refusal::Running => Fault::UpdateRunning,
                harnesses::Refusal::Unavailable | harnesses::Refusal::Unsupported => {
                    Fault::UpdateUnavailable
                },
            });
        let (status, code, message) = if let Some(fault) = self.0.downcast_ref::<Fault>() {
            fault.details()
        } else if let Some(fault) = refused {
            fault.details()
        } else if let Some(conflict) = self
            .0
            .downcast_ref::<crate::engine::host_profiles::RevisionConflict>()
        {
            revision = Some(conflict.current);
            (
                StatusCode::CONFLICT,
                "configuration_changed",
                "Another device saved this service. Reload before saving.",
            )
        } else if let Some(project) = self.0.downcast_ref::<ProjectError>() {
            match project {
                ProjectError::Conflict {
                    current: view,
                } => {
                    current = Some(view.as_ref().clone());
                    (
                        StatusCode::CONFLICT,
                        "project_changed",
                        "Another device changed the project folder. Reload before saving.",
                    )
                },
                ProjectError::Missing(_) => (
                    StatusCode::NOT_FOUND,
                    "project_missing",
                    "The default project folder no longer exists. Choose another folder.",
                ),
                ProjectError::Invalid(_) => (
                    StatusCode::BAD_REQUEST,
                    "invalid_project",
                    "Choose an absolute host folder; automatic folders must not be symbolic links.",
                ),
            }
        } else {
            // Child errors may quote URLs, environment values or arbitrary
            // provider output. Never echo them across the management boundary.
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "host_operation_failed",
                "The host could not complete the operation. Refresh its status; check the host's \
                 diagnostics if it persists.",
            )
        };
        (
            status,
            Json(serde_json::json!({
                "code": code, "message": message,
                "currentRevision": revision, "current": current,
            })),
        )
            .into_response()
    }
}
impl From<anyhow::Error> for ApiError {
    fn from(value: anyhow::Error) -> Self {
        Self(value)
    }
}

#[derive(Clone)]
struct Admission {
    token: AdmissionToken,
    limit: Arc<tokio::sync::Semaphore>,
}
async fn run<T: Send + 'static>(
    state: Admission,
    operation: impl FnOnce(AdmissionToken) -> Result<T> + Send + 'static,
) -> Result<Json<T>, ApiError> {
    let permit = state
        .limit
        .clone()
        .try_acquire_owned()
        .map_err(|_| anyhow::Error::from(Fault::Busy))?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        state.token.check()?;
        let value = operation(state.token)?;
        // Never deliver a completed old-account response into a new context.
        state.token.check()?;
        Ok::<T, anyhow::Error>(value)
    })
    .await
    .context("host management worker failed")?
    .map(Json)
    .map_err(Into::into)
}

#[derive(Deserialize)]
struct Folder {
    path: String,
}

pub(in crate::engine) fn router(epoch: u64, generation: u64) -> Router {
    Router::new()
        .route(
            pocox_core::device::ROUTE,
            get(|State(s): State<Admission>| {
                run(s, |_| Ok(pocox_core::device::DeviceMetadata::current()))
            }),
        )
        .route(
            "/manage/v1/runtimes",
            get(|State(s): State<Admission>| {
                run(s, |_| crate::engine::management_runtimes::detect())
            }),
        )
        .route(
            "/manage/v1/claude/prepare",
            get(|State(s): State<Admission>| {
                run(s, |_| Ok(crate::engine::management_runtimes::progress()))
            })
            .post(|State(s): State<Admission>, Json(_): Json<serde_json::Value>| {
                run(s, |_| Ok(crate::engine::management_runtimes::prepare()))
            }),
        )
        .route("/manage/v1/device", get(|State(s): State<Admission>| run(s, |_| super::device())))
        // Harness updates name a kind only; this computer owns the installer.
        .route("/manage/v1/harnesses", get(|State(s): State<Admission>| run(s, |_| harnesses::overview())))
        .route(
            "/manage/v1/harnesses/check",
            post(|State(s): State<Admission>, Json(_): Json<serde_json::Value>| {
                run(s, |_| harnesses::check())
            }),
        )
        .route(
            "/manage/v1/harnesses/settings",
            put(|State(s): State<Admission>, Json(body): Json<harnesses::SettingsChange>| {
                run(s, move |_| harnesses::set(&body))
            }),
        )
        .route(
            "/manage/v1/harnesses/{kind}/update",
            post(
                |State(s): State<Admission>,
                 Path(kind): Path<harnesses::Kind>,
                 Json(_): Json<serde_json::Value>| {
                    run(s, move |_| harnesses::update(kind))
                },
            ),
        )
        .route(
            "/manage/v1/hosts",
            post(|State(s): State<Admission>, Json(body): Json<StartRequest>| {
                run(s, move |token| super::start(body, token))
            }),
        )
        .route(
            "/manage/v1/hosts/{name}",
            get(|State(s): State<Admission>, Path(name): Path<String>| {
                run(s, move |_| super::host(&name))
            })
            .put(
                |State(s): State<Admission>,
                 Path(name): Path<String>,
                 Json(body): Json<SaveRequest>| {
                    run(s, move |token| super::save(&name, body, token))
                },
            ),
        )
        .route(
            "/manage/v1/hosts/{name}/start",
            post(
                |State(s): State<Admission>,
                 Path(name): Path<String>,
                 Json(body): Json<super::StartSavedRequest>| {
                    run(s, move |token| super::start_saved(&name, body, token))
                },
            ),
        )
        .route(
            "/manage/v1/hosts/{name}/apply",
            post(
                |State(s): State<Admission>,
                 Path(name): Path<String>,
                 Json(body): Json<ApplyRequest>| {
                    run(s, move |token| super::apply(&name, body, token))
                },
            ),
        )
        .route(
            "/manage/v1/hosts/{name}/stop",
            post(
                |State(s): State<Admission>,
                 Path(name): Path<String>,
                 Json(body): Json<StopRequest>| {
                    run(s, move |token| super::stop_host(&name, body, token))
                },
            ),
        )
        .route(
            "/projects",
            get(|State(s): State<Admission>| {
                run(s, |_| runtime::runtime().block_on(host_services::host_store()?.view()))
            })
            .put(|State(s): State<Admission>, Json(body): Json<ProjectsUpdate>| {
                run(s, move |token| {
                    runtime::runtime().block_on(
                        host_services::host_store()?.update_checked(body, move || token.check()),
                    )
                })
            }),
        )
        .route(
            "/projects/default/ensure",
            post(|State(s): State<Admission>, Json(_): Json<serde_json::Value>| {
                run(s, |token| {
                    runtime::runtime().block_on(
                        host_services::host_store()?.ensure_default_checked(move || token.check()),
                    )
                })
            }),
        )
        .route(
            "/fs/list",
            get(|State(s): State<Admission>, Query(folder): Query<Folder>| {
                run(s, move |_| {
                    let roots = runtime::runtime()
                        .block_on(host_services::host_store()?.effective_roots())?;
                    let path = std::path::Path::new(&folder.path);
                    if !pocox_host_svc::fs::within_roots(path, &roots) {
                        return Err(Fault::OutsideRoots.into());
                    }
                    let entries = pocox_host_svc::fs::list_subdirs(path)?;
                    Ok(serde_json::json!({"path": folder.path, "entries": entries}))
                })
            }),
        )
        .layer(DefaultBodyLimit::max(64 * 1024))
        .with_state(Admission {
            token: AdmissionToken {
                epoch,
                generation,
            },
            limit: Arc::new(tokio::sync::Semaphore::new(8)),
        })
        .merge(crate::engine::agent_tools::routes::router(
            Arc::new(move || {
                AdmissionToken {
                    epoch,
                    generation,
                }
                .check()
                .is_ok()
            }),
            epoch,
        ))
        .layer(middleware::from_fn(loopback_only))
}

/// Controllers reach this entry through a loopback tunnel and send neither an
/// `Origin` nor a foreign `Host`; a request with either came from a browser
/// page (cross-site, or DNS rebinding) and is refused.
async fn loopback_only(request: Request, next: Next) -> Response {
    let headers = request.headers();
    let host = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok());
    if headers.contains_key(header::ORIGIN) || !host.is_some_and(loopback_host) {
        return StatusCode::FORBIDDEN.into_response();
    }
    next.run(request).await
}

fn loopback_host(host: &str) -> bool {
    let name = match host.rsplit_once(':') {
        Some((name, port)) if port.bytes().all(|b| b.is_ascii_digit()) => name,
        _ => host,
    };
    ["127.0.0.1", "localhost", "[::1]"]
        .iter()
        .any(|allowed| name.eq_ignore_ascii_case(allowed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn withdrawn_management_rejects_reads_and_mutations() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let url = format!("http://{}", listener.local_addr().expect("address"));
        let app = router(crate::engine::transport::epoch().wrapping_add(1), u64::MAX);
        let task = tokio::spawn(async move { axum::serve(listener, app).await.expect("serve") });
        let client = reqwest::Client::builder()
            .no_proxy()
            .build()
            .expect("client");
        // What a browser page can send: a cross-site simple request, or one
        // through a rebinding name.
        for request in [
            client
                .post(format!("{url}/projects/default/ensure"))
                .header("origin", "https://untrusted.example")
                .body("{}"),
            client
                .post(format!("{url}/services/v1/consents/x"))
                .header("host", "rebound.example")
                .json(&serde_json::json!({"decision": "allow_once"})),
        ] {
            let response = request.send().await.expect("browser request");
            assert_eq!(response.status(), StatusCode::FORBIDDEN);
        }
        let response = client
            .post(format!("{url}/manage/v1/claude/prepare"))
            .body("{}")
            .send()
            .await
            .expect("simple request");
        assert_eq!(response.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
        for request in [
            client.get(format!("{url}/host/device")),
            client.get(format!("{url}/manage/v1/device")),
            client
                .post(format!("{url}/projects/default/ensure"))
                .json(&serde_json::json!({})),
            client
                .post(format!("{url}/manage/v1/claude/prepare"))
                .json(&serde_json::json!({})),
            client
                .post(format!("{url}/manage/v1/hosts/stale/stop"))
                .json(&serde_json::json!({"expectedIncarnation":"old"})),
            client
                .post(format!("{url}/manage/v1/harnesses/codex/update"))
                .json(&serde_json::json!({})),
            client
                .put(format!("{url}/manage/v1/harnesses/settings"))
                .json(&serde_json::json!({"kind":"codex","autoUpdate":true})),
        ] {
            let response = request.send().await.expect("response");
            assert_eq!(response.status(), StatusCode::FORBIDDEN);
            let value: serde_json::Value = response.json().await.expect("JSON");
            assert_eq!(value["code"], "connection_changed");
        }
        task.abort();
    }

    #[tokio::test]
    async fn failures_are_actionable_and_never_echo_untrusted_child_output() {
        let cases = [
            (
                anyhow::anyhow!("upstream https://user:password@host/?key=private"),
                StatusCode::INTERNAL_SERVER_ERROR,
                "host_operation_failed",
            ),
            (
                ProjectError::Missing("private-path".into()).into(),
                StatusCode::NOT_FOUND,
                "project_missing",
            ),
            (
                ProjectError::Invalid("private-value".into()).into(),
                StatusCode::BAD_REQUEST,
                "invalid_project",
            ),
            (
                crate::engine::host_profiles::RevisionConflict {
                    current: 9,
                }
                .into(),
                StatusCode::CONFLICT,
                "configuration_changed",
            ),
            (harnesses::Refusal::Running.into(), StatusCode::CONFLICT, "update_running"),
            (
                harnesses::Refusal::Unavailable.into(),
                StatusCode::UNPROCESSABLE_ENTITY,
                "update_unavailable",
            ),
        ];
        for (error, status, code) in cases {
            let response = ApiError(error).into_response();
            assert_eq!(response.status(), status);
            let bytes = axum::body::to_bytes(response.into_body(), 4096)
                .await
                .expect("bounded body");
            let value: serde_json::Value = serde_json::from_slice(&bytes).expect("JSON");
            assert_eq!(value["code"], code);
            assert!(!String::from_utf8_lossy(&bytes).contains("private"));
            if code == "configuration_changed" {
                assert_eq!(value["currentRevision"], 9);
            }
        }
    }
}
