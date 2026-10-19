use std::os::unix::fs::PermissionsExt;

use super::*;
use crate::{
    acp::{
        host::tests::{eventually, mock_binary},
        SourceId,
    },
    native_history::{ClaimError, ClaudeHistory, SessionClaim},
};

const SESSION: &str = "00000000-0000-4000-8000-000000000001";
const SOURCE: &str = "original-source";

fn script(root: &Path, name: &str, value: &Value) -> PathBuf {
    let path = root.join(name);
    let text = value.to_string().replace('\'', "'\\''");
    std::fs::write(&path, format!("#!/bin/sh\n/bin/cat >/dev/null\nprintf '%s\\n' '{text}'\n"))
        .expect("script");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).expect("executable");
    path
}

async fn fixture(delay: &str) -> (AgentHost, Identity, tempfile::TempDir) {
    let temp = tempfile::tempdir().expect("fixture");
    let root = temp.path().canonicalize().expect("canonical");
    let reader = script(
        &root,
        "reader",
        &json!({
            "sessionId":SESSION,"generation":SOURCE,"revision":"r1","sourceBytes":100,
            "cwd":root,"title":"fixture","updatedAt":1,"turns":[],"hasOlder":false,
            "nextBefore":null,"totalTurns":0,"truncated":false,
        }),
    );
    let probe = script(&root, "probe", &json!([]));
    let history = ClaudeHistory::new(reader, root.join("sdk.mjs"), root.clone())
        .expect("reader")
        .with_owner_probe(probe, root.clone());
    let program = mock_binary();
    let args = vec!["--profile".into(), "beta".into(), "--open-delay-ms".into(), delay.into()];
    let host = AgentHost::create_with_native_history(
        HostOptions {
            spec: AgentSpec {
                profile_id: "claude".into(),
                display_name: "Fixture".into(),
                program: program.to_string_lossy().into_owned(),
                args: args.clone(),
            },
            store: SessionStore::memory(SourceId::with_key(&"t".repeat(32), &program, &args)),
            program,
            path: None,
            env: Vec::new(),
            env_remove: Vec::new(),
        },
        None,
        None,
        Some(crate::native_history::NativeHistory::Claude(Arc::new(history))),
    );
    host.launch().await.expect("launch");
    let identity = Identity {
        host_id: Some(host.host_id().into()),
        generation: Some(host.state().generation),
    };
    (host, identity, temp)
}

#[tokio::test]
async fn unverified_loaded_writer_stays_blocked_until_verified_release() {
    let (host, identity, root) = fixture("0").await;
    assert_eq!(
        host.acquire_session(SESSION, SOURCE, &Identity::default())
            .await,
        Err(HostError::Stale)
    );
    assert_eq!(host.acquire_session(SESSION, "replaced", &identity).await, Err(HostError::Stale));
    assert!(host.state().sessions.is_empty());
    assert_eq!(host.acquire_session(SESSION, SOURCE, &identity).await, Err(HostError::ReadOnly));
    assert_eq!(
        host.prompt(SESSION, "must remain unsent", &[], None).await,
        Err(HostError::Loading)
    );
    assert!(host.state().sessions[SESSION].releasing);
    assert!(matches!(SessionClaim::acquire(root.path(), SESSION), Err(ClaimError::Busy)));
    assert_eq!(host.acquire_session(SESSION, SOURCE, &identity).await, Err(HostError::Loading));
    host.release_session(SESSION, &identity)
        .await
        .expect("verified close");
    assert!(!host.state().sessions.contains_key(SESSION));
    assert!(SessionClaim::acquire(root.path(), SESSION).is_ok());
    host.stop().await;
}

#[tokio::test]
async fn stopping_pending_acquire_reaps_before_releasing_its_claim() {
    let (host, identity, root) = fixture("8000").await;
    let acquire = tokio::spawn({
        let host = host.clone();
        async move { host.acquire_session(SESSION, SOURCE, &identity).await }
    });
    eventually(
        || {
            host.state()
                .sessions
                .get(SESSION)
                .is_some_and(|s| s.pending)
        },
        "load admitted",
    )
    .await;
    assert!(matches!(SessionClaim::acquire(root.path(), SESSION), Err(ClaimError::Busy)));
    let pid = host.inner.lifecycle.try_lock().err();
    assert!(pid.is_some(), "acquire pins its owning adapter");
    tokio::time::timeout(Duration::from_secs(5), host.stop())
        .await
        .expect("bounded stop");
    assert_eq!(acquire.await.expect("acquire task"), Err(HostError::NotReady));
    assert!(host.state().sessions.is_empty());
    assert!(SessionClaim::acquire(root.path(), SESSION).is_ok());
}

#[tokio::test]
async fn control_observation_never_loads_and_failed_probe_cannot_offer_acquire() {
    let (host, identity, root) = fixture("0").await;
    let view = host
        .session_control(SESSION, &identity)
        .await
        .expect("view");
    assert_eq!(view.session_id, SESSION);
    assert_eq!(view.host_id, host.host_id());
    assert_eq!(view.source_generation.as_deref(), Some(SOURCE));
    assert_eq!(view.status, "released");
    assert!(view.can_acquire);
    assert!(!view.can_continue && !view.can_release);
    assert!(host.state().sessions.is_empty(), "inspection never calls session/load");
    assert!(SessionClaim::acquire(root.path(), SESSION).is_ok(), "inspection never claims");
    script(root.path(), "probe", &json!({"not":"an inventory"}));
    let unknown = host
        .session_control(SESSION, &identity)
        .await
        .expect("unknown");
    assert_eq!(unknown.status, "unknown");
    assert!(!unknown.can_acquire);
    assert!(matches!(
        host.session_control(SESSION, &Identity::default()).await,
        Err(HostError::Stale)
    ));
    host.stop().await;
}

#[tokio::test]
async fn already_admitted_acquire_reuses_the_writer_with_full_response_identity() {
    let (host, identity, root) = fixture("0").await;
    let opened = host
        .new_session(&root.path().to_string_lossy(), Some(&identity))
        .await
        .expect("new");
    let id = opened["sessionId"].as_str().expect("id");
    let reused = host
        .acquire_session(id, SOURCE, &identity)
        .await
        .expect("same writer");
    assert_eq!(reused["sessionId"], id);
    assert_eq!(reused["hostId"], host.host_id());
    assert_eq!(reused["generation"], identity.generation.expect("generation"));
    assert_eq!(host.state().sessions.len(), 1);
    host.stop().await;
}
