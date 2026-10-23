//! Project-scoped image copies for agents' filesystem tools.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, ensure, Context};
use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::Json;
use serde::Deserialize;

use crate::file_routes::{self, UploadResponse};
use crate::{file_links, fs, sessions, ApiError, AppState};

/// A session's verified cwd wins over a draft's explicitly selected project.
#[derive(Default, Deserialize)]
pub(super) struct ImageUploadQuery {
    thread: Option<String>,
    project: Option<String>,
}

pub(super) async fn upload(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    Query(query): Query<ImageUploadQuery>,
    body: Bytes,
) -> Result<Json<UploadResponse>, ApiError> {
    let project = project_dir(&state, query).await?;
    let path = tokio::task::spawn_blocking(move || attachment_dir(&project)).await??;
    let path = file_routes::save_upload(&path, &name, &body).await?;
    Ok(Json(UploadResponse {
        path: path.display().to_string(),
        size: body.len() as u64,
    }))
}

async fn project_dir(state: &AppState, query: ImageUploadQuery) -> anyhow::Result<PathBuf> {
    if let Some(thread) = query.thread {
        let cwd = match &state.session_dirs {
            Some(dirs) => dirs.session_dir(&thread).await?,
            None => {
                tokio::task::spawn_blocking(move || {
                    let rollout = sessions::rollout_path(&thread)?;
                    Ok::<_, anyhow::Error>(pocox_codex::rollout::read_session_info(&rollout)?.cwd)
                })
                .await??
            },
        };
        return cwd.map(PathBuf::from).ok_or_else(|| {
            anyhow!("{}: missing working directory", file_links::SESSION_NOT_FOUND)
        });
    }
    if let Some(project) = query.project {
        let default = state.host.view().await?.effective_default;
        if project == default.path {
            let ensured = state.host.ensure_default().await?;
            ensure!(ensured.path == project, "project settings changed; retry the image upload");
            return Ok(PathBuf::from(ensured.path));
        }
        let roots = state.host.effective_roots().await?;
        return tokio::task::spawn_blocking(move || {
            let project = PathBuf::from(project);
            ensure!(
                project.is_absolute() && fs::within_roots(&project, &roots),
                "path is outside the configured project roots"
            );
            Ok(project)
        })
        .await?;
    }
    // This preserves the existing default-project policy: automatic folders
    // may be created; a missing explicit folder must never be recreated.
    Ok(PathBuf::from(state.host.ensure_default().await?.path))
}

fn attachment_dir(project: &std::path::Path) -> anyhow::Result<PathBuf> {
    ensure!(project.is_absolute() && project.is_dir(), "image project is not a directory");
    let project = project.canonicalize().context("resolving image project")?;
    let dir = project.join(".pocket-attachments");
    match std::fs::create_dir(&dir) {
        Ok(()) => {},
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {},
        Err(error) => return Err(error).context("creating image attachments directory"),
    }
    let metadata = std::fs::symlink_metadata(&dir)?;
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "image attachments directory must not be a symbolic link"
    );
    ensure!(
        dir.canonicalize()?.parent() == Some(project.as_path()),
        "image attachments directory escapes its project"
    );
    Ok(dir)
}

#[cfg(test)]
mod tests;
