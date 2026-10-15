//! Host-resolved default projects and revision-checked project settings.
//!
//! Reads observe the file afresh, including legacy writers. New writers compare
//! and replace under a cross-process lock; a legacy writer that does not take
//! that lock retains its existing last-writer-wins behaviour.

use std::{
    fs::{File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::store::HostConfig;

/// The selected host folder. Inspecting it never creates it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DefaultProject {
    /// Absolute host path, never a controller-side path.
    pub path: String,
    /// No explicit folder was saved; the host resolved its OS default.
    pub automatic: bool,
    /// The path currently names a directory.
    pub exists: bool,
}

/// Additive `/projects` response; older clients still read [`HostConfig`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectsView {
    /// Existing persisted project settings.
    #[serde(flatten)]
    pub config: HostConfig,
    /// Opaque revision of the persisted settings, for compare-and-save.
    pub revision: String,
    /// Effective host default, without creating it.
    pub effective_default: DefaultProject,
}

/// A replacement of the project settings with optional legacy-compatible CAS.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ProjectsUpdate {
    /// Replacement settings.
    #[serde(flatten)]
    pub config: HostConfig,
    /// Required by new controllers; omitted by legacy clients.
    #[serde(default)]
    pub expected_revision: Option<String>,
}

/// Result of explicitly preparing the default folder for a new conversation.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct EnsuredProject {
    /// Canonical host working directory.
    pub path: String,
    /// This request created the automatic folder.
    pub created: bool,
    /// The host's automatic default was used.
    pub automatic: bool,
}

/// Project-setting errors that callers can handle without parsing IO text.
#[derive(Debug, thiserror::Error)]
pub enum ProjectError {
    /// Another controller changed the settings since they were read.
    #[error("project settings changed on another device; reload before saving")]
    Conflict {
        /// Latest settings, safe to return to the controller.
        current: Box<ProjectsView>,
    },
    /// An explicit default disappeared; never recreate it silently.
    #[error("the default project folder no longer exists: {0}")]
    Missing(String),
    /// An invalid path or an unsafe automatic-folder replacement.
    #[error("{0}")]
    Invalid(String),
}

/// The shared host-project settings, read afresh across app and CLI processes.
#[derive(Clone)]
pub struct HostStore {
    path: PathBuf,
    automatic: PathBuf,
}

impl HostStore {
    /// Open host settings using the current host OS's automatic project path.
    pub async fn open(path: PathBuf) -> Result<Self> {
        Self::open_with_default(path, pocket_codex_core::paths::default_project_dir()?).await
    }

    /// Open settings with a host-resolved automatic directory. This does not
    /// create the project folder; embedders and tests can supply their own
    /// home.
    pub async fn open_with_default(path: PathBuf, automatic: PathBuf) -> Result<Self> {
        if !automatic.is_absolute() {
            return Err(
                ProjectError::Invalid("automatic project path must be absolute".into()).into()
            );
        }
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .context("creating host-config directory")?;
        }
        Ok(Self {
            path,
            automatic,
        })
    }

    /// Legacy accessor. Read failures return no configured roots, never stale
    /// permissions. New callers use [`Self::view`] to surface the error.
    pub async fn get(&self) -> HostConfig {
        match self.view().await {
            Ok(view) => view.config,
            Err(error) => {
                tracing::warn!(%error, "reading host project settings failed");
                HostConfig::default()
            },
        }
    }

    /// Read settings and their effective default without creating directories.
    pub async fn view(&self) -> Result<ProjectsView> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || store.snapshot()).await?
    }

    /// Legacy unconditional replacement, retained for existing callers.
    pub async fn put(&self, config: HostConfig) -> Result<()> {
        self.update(ProjectsUpdate {
            config,
            expected_revision: None,
        })
        .await
        .map(drop)
    }

    /// Compare and atomically replace settings, serialized with other new
    /// writers. Explicit paths are saved without creating any directory.
    pub async fn update(&self, update: ProjectsUpdate) -> Result<ProjectsView> {
        self.update_checked(update, || Ok(())).await
    }

    /// Revalidate remote admission after waiting for the project-file lock.
    pub async fn update_checked(
        &self,
        update: ProjectsUpdate,
        check: impl FnOnce() -> Result<()> + Send + 'static,
    ) -> Result<ProjectsView> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            validate(&update.config)?;
            let _lock = store.lock()?;
            check()?;
            let current = store.snapshot()?;
            if update
                .expected_revision
                .as_ref()
                .is_some_and(|v| *v != current.revision)
            {
                return Err(ProjectError::Conflict {
                    current: Box::new(current),
                }
                .into());
            }
            store.write(&update.config)?;
            store.snapshot()
        })
        .await?
    }

    /// Roots for browsing/explicit file access: configured roots plus only
    /// the selected default, never the user's entire home or Documents folder.
    pub async fn effective_roots(&self) -> Result<Vec<String>> {
        let view = self.view().await?;
        let mut roots = view.config.project_roots;
        let default = &view.effective_default;
        let automatic_link = default.automatic
            && std::fs::symlink_metadata(&default.path)
                .is_ok_and(|meta| meta.file_type().is_symlink());
        if !automatic_link && !roots.contains(&default.path) {
            roots.push(view.effective_default.path);
        }
        Ok(roots)
    }

    /// Prepare the currently selected default on the host at first send.
    /// Automatic folders are created one level deep. Explicit missing folders
    /// and automatic symlinks fail rather than selecting an unintended cwd.
    pub async fn ensure_default(&self) -> Result<EnsuredProject> {
        self.ensure_default_checked(|| Ok(())).await
    }

    /// Prepare a default only while the remote admission is still valid.
    pub async fn ensure_default_checked(
        &self,
        check: impl FnOnce() -> Result<()> + Send + 'static,
    ) -> Result<EnsuredProject> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            let _lock = store.lock()?;
            check()?;
            let view = store.snapshot()?;
            let selected = &view.effective_default;
            let path = Path::new(&selected.path);
            let mut created = false;
            if selected.automatic {
                match std::fs::create_dir(path) {
                    Ok(()) => created = true,
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {},
                    Err(e) => return Err(e).context("creating the automatic project folder"),
                }
                let meta = std::fs::symlink_metadata(path)?;
                if meta.file_type().is_symlink() {
                    return Err(ProjectError::Invalid(
                        "automatic project folder is a symbolic link; choose an explicit folder"
                            .into(),
                    )
                    .into());
                }
            }
            if !path.is_dir() {
                return Err(ProjectError::Missing(selected.path.clone()).into());
            }
            Ok(EnsuredProject {
                // Keep the configured spelling, including ordinary Windows
                // drive paths; canonicalization would add a verbatim prefix.
                path: selected.path.clone(),
                created,
                automatic: selected.automatic,
            })
        })
        .await?
    }

    fn snapshot(&self) -> Result<ProjectsView> {
        let config: HostConfig = match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes).context("parsing host project settings")?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HostConfig::default(),
            Err(e) => return Err(e).context("reading host project settings"),
        };
        validate(&config)?;
        let path = config
            .default_project
            .as_deref()
            .map(Path::new)
            .unwrap_or(&self.automatic);
        let effective_default = DefaultProject {
            path: path.to_string_lossy().into_owned(),
            automatic: config.default_project.is_none(),
            exists: path.is_dir(),
        };
        let revision = pocket_codex_core::history_sync::digest_bytes(&serde_json::to_vec(&config)?);
        Ok(ProjectsView {
            config,
            revision,
            effective_default,
        })
    }

    fn lock(&self) -> Result<File> {
        let file = private_options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(self.path.with_extension("lock"))?;
        file.lock().context("locking host project settings")?;
        Ok(file)
    }

    fn write(&self, config: &HostConfig) -> Result<()> {
        let tmp = self
            .path
            .with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> Result<()> {
            let mut file = private_options().write(true).create_new(true).open(&tmp)?;
            file.write_all(&serde_json::to_vec_pretty(config)?)?;
            file.sync_all()?;
            std::fs::rename(&tmp, &self.path)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result.context("writing host project settings")
    }
}

fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

fn validate(config: &HostConfig) -> Result<()> {
    for path in config
        .project_roots
        .iter()
        .chain(config.default_project.iter())
    {
        if !Path::new(path).is_absolute() {
            return Err(ProjectError::Invalid(
                "project folders must be absolute host paths".into(),
            )
            .into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn open(dir: &Path) -> HostStore {
        HostStore::open_with_default(dir.join("host.json"), dir.join("PocketCodex"))
            .await
            .expect("store")
    }

    #[tokio::test]
    async fn unreadable_policy_never_creates_a_fallback_project() {
        let dir = tempfile::tempdir().expect("temp");
        let store = open(dir.path()).await;
        std::fs::write(dir.path().join("host.json"), b"broken").expect("write");
        assert!(store.view().await.is_err());
        assert!(store.effective_roots().await.is_err());
        assert!(store.ensure_default().await.is_err());
        assert!(!dir.path().join("PocketCodex").exists());
        assert_eq!(std::fs::read(dir.path().join("host.json")).expect("kept"), b"broken");
    }

    #[tokio::test]
    async fn controllers_observe_changes_and_refuse_stale_saves() {
        let dir = tempfile::tempdir().expect("temp");
        let one = open(dir.path()).await;
        let two = open(dir.path()).await;
        let before = two.view().await.expect("before");
        let config = HostConfig {
            project_roots: vec![dir.path().to_string_lossy().into_owned()],
            default_project: Some(dir.path().join("chosen").to_string_lossy().into_owned()),
        };
        let saved = one
            .update(ProjectsUpdate {
                config: config.clone(),
                expected_revision: Some(before.revision.clone()),
            })
            .await
            .expect("save");
        assert_eq!(two.view().await.expect("other process").config, config);
        let error = two
            .update(ProjectsUpdate {
                config: HostConfig::default(),
                expected_revision: Some(before.revision),
            })
            .await
            .expect_err("stale");
        let ProjectError::Conflict {
            current,
        } = error.downcast_ref::<ProjectError>().expect("typed")
        else {
            panic!("not a conflict");
        };
        assert_eq!(current.as_ref(), &saved);
        // A legacy process rewrites the file without a revision field.
        std::fs::write(dir.path().join("host.json"), b"{}").expect("legacy write");
        assert_eq!(one.view().await.expect("fresh read").config, HostConfig::default());
        assert!(two
            .update(ProjectsUpdate {
                config,
                expected_revision: Some(saved.revision),
            })
            .await
            .is_err());
    }

    #[tokio::test]
    async fn simultaneous_compare_and_save_has_only_one_winner() {
        let dir = tempfile::tempdir().expect("temp");
        let one = open(dir.path()).await;
        let two = open(dir.path()).await;
        let revision = one.view().await.expect("view").revision;
        let update = |leaf: &str| ProjectsUpdate {
            config: HostConfig {
                project_roots: vec![],
                default_project: Some(dir.path().join(leaf).to_string_lossy().into_owned()),
            },
            expected_revision: Some(revision.clone()),
        };
        let (a, b) = tokio::join!(one.update(update("one")), two.update(update("two")));
        assert_ne!(a.is_ok(), b.is_ok());
    }

    #[tokio::test]
    async fn explicit_missing_default_is_not_recreated_or_replaced() {
        let dir = tempfile::tempdir().expect("temp");
        let store = open(dir.path()).await;
        let missing = dir.path().join("removed-project");
        store
            .put(HostConfig {
                project_roots: vec![],
                default_project: Some(missing.to_string_lossy().into_owned()),
            })
            .await
            .expect("save");
        let error = store.ensure_default().await.expect_err("missing");
        assert!(matches!(error.downcast_ref::<ProjectError>(), Some(ProjectError::Missing(_))));
        assert!(!missing.exists());
        assert!(!dir.path().join("PocketCodex").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn automatic_symlink_does_not_grant_access_to_another_folder() {
        let dir = tempfile::tempdir().expect("temp");
        let store = open(dir.path()).await;
        std::os::unix::fs::symlink(dir.path(), dir.path().join("PocketCodex")).expect("link");
        assert!(store.ensure_default().await.is_err());
        assert!(store.effective_roots().await.expect("roots").is_empty());
    }
}
