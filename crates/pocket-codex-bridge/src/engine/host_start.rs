//! Start a new host with the configuration its editor chose, as one
//! operation under the instance's lifecycle lease: the configuration
//! (model service, key and runtime) is committed, the host starts with
//! exactly that revision, and a failed start puts the previous saved
//! configuration back. So a new host never starts with another instance's
//! stale configuration, and a failed start never leaves its own behind.

use anyhow::{bail, Result};

use super::{
    host_lease::{self, Op},
    host_names,
    host_profiles::{self, Change, Runtime, RuntimeChange},
    runtime,
    serve::{self, Binary, CodexStart, ServeReport},
    serve_acp::{self, AcpServeReport},
    serve_opencode,
};

/// A started host.
#[derive(Debug, Clone)]
pub enum Started {
    /// A native Codex host.
    Codex(ServeReport),
    /// An ACP agent.
    Acp(AcpServeReport),
    /// A native OpenCode gateway and meta service.
    OpenCode(serve_opencode::Report),
}

/// Save `change` (with `runtime`) for `name` and start it.
pub fn start_configured(name: Option<&str>, runtime: Runtime, change: Change) -> Result<Started> {
    start_configured_checked(name, runtime, change, None, &|| Ok(()))
}

/// Remote start, rechecking authorization after waiting for the name/store.
pub(super) fn start_configured_checked(
    name: Option<&str>,
    runtime: Runtime,
    change: Change,
    expected_revision: Option<u64>,
    check: &dyn Fn() -> Result<()>,
) -> Result<Started> {
    start_checked_in(
        &runtime::support_dir()?,
        &host_profiles::root()?,
        name,
        runtime,
        change,
        expected_revision,
        check,
    )
}

#[cfg(test)]
fn start_in(
    support: &std::path::Path,
    profiles: &std::path::Path,
    name: Option<&str>,
    runtime: Runtime,
    change: Change,
) -> Result<Started> {
    start_checked_in(support, profiles, name, runtime, change, None, &|| Ok(()))
}

fn start_checked_in(
    support: &std::path::Path,
    profiles: &std::path::Path,
    name: Option<&str>,
    runtime: Runtime,
    change: Change,
    expected_revision: Option<u64>,
    check: &dyn Fn() -> Result<()>,
) -> Result<Started> {
    let fallback = match &runtime {
        Runtime::Codex {
            ..
        } => "default",
        Runtime::Acp(spec) => spec.profile_id.as_str(),
        Runtime::OpenCode {
            ..
        } => "opencode",
    };
    let requested = host_names::requested(name, fallback);
    let lease = host_lease::acquire_checked(&requested, Op::Start, check)?;
    if serve::codex_relaunch(&requested).is_some()
        || serve_acp::is_hosting(lease.name())
        || serve_opencode::is_hosting(lease.name())
    {
        bail!("`{requested}` is already hosting; edit it instead, or choose another name");
    }
    let change = Change {
        runtime: RuntimeChange::Set(runtime.clone()),
        ..change
    };
    // No host runs under the name, so whatever was saved for it before is
    // replaced; it comes back if the start fails.
    let (_, staged) = host_profiles::stage_checked_in(
        profiles,
        &requested,
        &change,
        expected_revision,
        runtime.engine(),
        check,
    )?;
    #[cfg(test)]
    tests::after_stage(&staged);
    // Exactly what this stage committed: a save made meanwhile (saves do
    // not take the lifecycle lease) never changes what this start runs.
    let started = staged.resolved().cloned().and_then(|provider| {
        #[cfg(test)]
        tests::launching(&provider);
        check()?;
        launch(&lease, support, profiles, &requested, runtime.clone(), provider)
    });
    match started {
        Ok(started) => {
            staged.finish();
            super::host_lifecycle::record_running_in(profiles, lease.name(), runtime);
            Ok(started)
        },
        Err(error) => {
            if let Err(rollback) = staged.rollback() {
                tracing::warn!(
                    error = %format!("{rollback:#}"),
                    "restoring the previous saved host configuration failed"
                );
            }
            Err(error)
        },
    }
}

fn launch(
    lease: &host_lease::Lease,
    support: &std::path::Path,
    profiles: &std::path::Path,
    requested: &str,
    runtime: Runtime,
    provider: host_profiles::Resolved,
) -> Result<Started> {
    match runtime {
        Runtime::OpenCode {
            binary,
            separate_history,
        } => serve_opencode::start_locked(lease, binary.as_deref(), separate_history, provider)
            .map(Started::OpenCode),
        Runtime::Codex {
            port,
            binary,
            proxy,
        } => {
            let start = CodexStart {
                port,
                binary: Binary::Requested(binary),
                name: requested.to_string(),
                proxy,
                provider: Some(provider),
            };
            serve::serve_start_locked(lease, support, profiles, start).map(Started::Codex)
        },
        Runtime::Acp(spec) => {
            serve_acp::start_locked(lease, spec, Some(provider), profiles).map(Started::Acp)
        },
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    #[test]
    fn revoked_start_does_not_save_a_profile_or_launch() {
        let root = tempfile::tempdir().expect("temp");
        let error = super::start_checked_in(
            root.path(),
            &root.path().join("profiles"),
            Some("revoked-new-host"),
            super::Runtime::OpenCode {
                binary: None,
                separate_history: false,
            },
            super::Change {
                input: super::host_profiles::ProfileInput {
                    source: super::host_profiles::Source::Inherited,
                    protocol: None,
                    base_url: None,
                    model: None,
                    claude_env: None,
                },
                key: super::host_profiles::KeyChange::Keep,
                runtime: super::RuntimeChange::Keep,
            },
            None,
            &|| anyhow::bail!("revoked"),
        )
        .expect_err("refused");
        assert_eq!(error.to_string(), "revoked");
        assert!(!root.path().join("profiles").exists());
    }


    use pocket_codex_core::provider::{ApiProtocol, Secret};

    use super::*;
    use crate::engine::host_profiles::{Engine, KeyChange, ProfileInput, Resolved, Source, Staged};

    type Hook = Box<dyn FnOnce()>;

    thread_local! {
        static AFTER_STAGE: RefCell<Option<Hook>> = RefCell::new(None);
        static LAUNCHED: RefCell<Option<Resolved>> = const { RefCell::new(None) };
    }

    /// Runs this thread's pending hook between the commit and the launch.
    pub(super) fn after_stage(_staged: &Staged) {
        if let Some(hook) = AFTER_STAGE.with(|h| h.borrow_mut().take()) {
            hook();
        }
    }

    /// Records the configuration handed to the launch.
    pub(super) fn launching(provider: &Resolved) {
        LAUNCHED.with(|s| *s.borrow_mut() = Some(provider.clone()));
    }

    fn custom(url: &str, key: &str) -> Change {
        Change {
            input: ProfileInput {
                claude_env: None,
                source: Source::Custom,
                protocol: Some(ApiProtocol::Responses),
                base_url: Some(url.into()),
                model: None,
            },
            key: KeyChange::Replace(Secret::new(key)),
            runtime: RuntimeChange::Keep,
        }
    }

    #[test]
    fn a_failed_start_puts_the_previous_configuration_back() {
        let support = tempfile::tempdir().expect("support");
        let profiles = support.path().join("hosting");
        let before = custom("https://before.example.com", "sk-before");
        host_profiles::save_in(&profiles, "start-test", &before, None, Engine::Codex)
            .expect("saved before");
        let missing = support.path().join("no-codex").display().to_string();
        let err = start_in(
            support.path(),
            &profiles,
            Some("start-test"),
            Runtime::Codex {
                port: 0,
                binary: Some(missing),
                proxy: None,
            },
            custom("https://after.example.com", "sk-after"),
        )
        .expect_err("no codex there");
        assert!(err.to_string().contains("could not find the codex binary"), "{err}");
        let restored = host_profiles::get_in(&profiles, "start-test").expect("get");
        assert_eq!(restored.base_url.as_deref(), Some("https://before.example.com"));
        assert!(restored.runtime.is_none(), "the failed runtime was not kept");
        let key = host_profiles::resolve_in(&profiles, "start-test")
            .expect("resolve")
            .endpoint
            .and_then(|e| e.key)
            .map(|k| k.expose().to_string());
        assert_eq!(key.as_deref(), Some("sk-before"));
        assert!(!serve::is_hosting_codex("start-test"));
    }

    #[test]
    fn a_save_between_commit_and_launch_never_changes_what_starts() {
        let support = tempfile::tempdir().expect("support");
        let profiles = support.path().join("hosting");
        let meanwhile = profiles.clone();
        // Saves take no lifecycle lease, so one can land right after the
        // start committed its own configuration.
        AFTER_STAGE.with(|h| {
            *h.borrow_mut() = Some(Box::new(move || {
                host_profiles::save_in(
                    &meanwhile,
                    "start-race",
                    &custom("https://other.example.com", "sk-other"),
                    None,
                    Engine::Codex,
                )
                .expect("a save meanwhile");
            }))
        });
        let missing = support.path().join("no-codex").display().to_string();
        start_in(
            support.path(),
            &profiles,
            Some("start-race"),
            Runtime::Codex {
                port: 0,
                binary: Some(missing),
                proxy: None,
            },
            custom("https://mine.example.com", "sk-mine"),
        )
        .expect_err("no codex there");
        let launched = LAUNCHED
            .with(|s| s.borrow_mut().take())
            .expect("a launch was attempted");
        let endpoint = launched.endpoint.expect("custom");
        assert_eq!(endpoint.base_url, "https://mine.example.com");
        assert_eq!(endpoint.key.as_ref().map(Secret::expose), Some("sk-mine"));
        // The failed start's rollback leaves the newer save alone.
        let kept = host_profiles::get_in(&profiles, "start-race").expect("get");
        assert_eq!(kept.base_url.as_deref(), Some("https://other.example.com"));
    }

    #[test]
    fn an_invalid_configuration_starts_nothing() {
        let support = tempfile::tempdir().expect("support");
        let profiles = support.path().join("hosting");
        let mut change = custom("ftp://bad.example.com", "k");
        change.key = KeyChange::Keep;
        let err = start_in(
            support.path(),
            &profiles,
            Some("start-invalid"),
            Runtime::Codex {
                port: 0,
                binary: None,
                proxy: None,
            },
            change,
        )
        .expect_err("invalid");
        assert!(!err.to_string().is_empty());
        assert_eq!(
            host_profiles::get_in(&profiles, "start-invalid")
                .expect("get")
                .revision,
            0
        );
    }
}
