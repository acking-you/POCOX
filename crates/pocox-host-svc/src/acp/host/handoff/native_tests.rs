//! Opt-in installed-runtime test. Its parent supplies only disposable paths
//! and a deterministic loopback model endpoint, never a user's credentials.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures::FutureExt;

use super::*;
use crate::acp::host::tests::{eventually, outcome};
use crate::acp::schema::TurnOutcome;
use crate::acp::{AgentSpec, HostOptions, SessionStore, SourceId};
use crate::native_history::{ClaimError, ClaudeHistory, SessionClaim};

fn path(key: &str) -> PathBuf {
    let path = PathBuf::from(std::env::var_os(key).expect(key));
    assert!(path.is_absolute(), "fixture paths must be absolute");
    path
}

fn fixture_host(root: &Path, cli: &Path) -> AgentHost {
    let node = path("POCOX_TEST_NODE");
    let adapter = path("POCOX_TEST_CLAUDE_ADAPTER");
    let endpoint = std::env::var("POCOX_TEST_MODEL_ENDPOINT").expect("local model");
    assert!(endpoint.starts_with("http://127.0.0.1:"));
    let config = root.join("config");
    let home = root.join("home");
    let reader = ClaudeHistory::from_adapter(node.clone(), &adapter, config.clone())
        .expect("reader")
        .with_owner_probe(cli.to_path_buf(), home.clone());
    let args = vec![adapter.to_string_lossy().into_owned()];
    let store = SessionStore::memory(SourceId::with_key(&"f".repeat(32), &node, &args));
    let env = vec![
        ("HOME".into(), home.into_os_string()),
        ("CLAUDE_CONFIG_DIR".into(), config.into_os_string()),
        ("CLAUDE_CODE_EXECUTABLE".into(), cli.as_os_str().to_owned()),
        ("ANTHROPIC_BASE_URL".into(), endpoint.into()),
        ("ANTHROPIC_API_KEY".into(), "pcx-disposable-fixture-key".into()),
        ("DISABLE_TELEMETRY".into(), "1".into()),
        ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(), "1".into()),
        ("CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF".into(), "1".into()),
        ("CLAUDE_CODE_SIMPLE".into(), "1".into()),
        ("CLAUDE_CODE_SAFE_MODE".into(), "1".into()),
    ];
    AgentHost::create_with_native_history(
        HostOptions {
            spec: AgentSpec {
                profile_id: "claude".into(),
                display_name: "Isolated Claude".into(),
                program: node.to_string_lossy().into_owned(),
                args,
            },
            program: node,
            path: Some("/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin".into()),
            env,
            env_remove: Vec::new(),
            store,
        },
        None,
        None,
        Some(crate::native_history::NativeHistory::Claude(Arc::new(reader))),
    )
}

fn identity(host: &AgentHost) -> Identity {
    Identity {
        host_id: Some(host.host_id().into()),
        generation: Some(host.state().generation),
    }
}

async fn reply(host: &AgentHost, session: &str, marker: &str) {
    let turn = host
        .prompt(
            session,
            &format!("What is 2 + 2? Reply with one digit. {marker}"),
            &[],
            Some(&identity(host)),
        )
        .await
        .expect("prompt");
    eventually(|| outcome(host, session, &turn).is_some(), "fixture reply").await;
    assert_eq!(
        outcome(host, session, &turn),
        Some(TurnOutcome::Stopped {
            stop_reason: "end_turn".into(),
        })
    );
    let history = host
        .history(session, None, Some(&turn), None)
        .expect("history");
    assert!(
        history["window"][0]["items"]
            .as_array()
            .expect("items")
            .iter()
            .any(|item| item["text"].as_str() == Some("4")),
        "exact model reply: {history}"
    );
}

#[tokio::test]
#[ignore = "requires POCOX_TEST_CLAUDE_* paths and isolated loopback Messages fixture"]
async fn native_claude_release_and_contended_original_session_acquire() {
    let root = path("POCOX_TEST_FIXTURE_ROOT");
    for dir in ["home", "config", "work"] {
        std::fs::create_dir_all(root.join(dir)).expect("fixture directory");
    }
    let cli = path("POCOX_TEST_CLAUDE_CLI");
    let hosts = [fixture_host(&root, &cli), fixture_host(&root, &cli), fixture_host(&root, &cli)];
    let run = std::panic::AssertUnwindSafe(async {
        for host in &hosts {
            host.launch().await.expect("adapter launch");
        }
        let owner = &hosts[0];
        let opened = owner
            .new_session(&root.join("work").to_string_lossy(), Some(&identity(owner)))
            .await
            .expect("new");
        let session = opened["sessionId"].as_str().expect("session");
        reply(owner, session, "SEED").await;
        let admitted = owner
            .session_access(session, &identity(owner))
            .await
            .expect("fresh admission");
        assert_eq!(admitted.mode, "write");
        assert!(admitted.can_release);
        let outside = hosts[1]
            .session_open(session, &identity(&hosts[1]))
            .await
            .expect("external idle follow");
        assert_eq!(outside.mode, "follow");
        assert_eq!(outside.reason, "external_idle");
        assert!(hosts[1].state().sessions.is_empty());
        let Some(reader) = &owner.inner.native_history else { panic!("reader") };
        let page = reader
            .read_page(session, None, 1)
            .await
            .expect("native page");
        // Bypass POCOX admission in this disposable fixture to reproduce an
        // independent native client opening an already admitted UUID.
        let (_, outside_peer, _) = hosts[1].ready().expect("outside fixture peer");
        outside_peer
            .request(
                "session/load",
                json!({"sessionId":session,
            "cwd":root.join("work"),"mcpServers":[]}),
                Some(Duration::from_secs(20)),
            )
            .await
            .expect("independent original-session load");
        assert_eq!(
            owner
                .prompt(session, "MUST NOT SEND", &[], Some(&identity(owner)))
                .await,
            Err(HostError::ReadOnly)
        );
        assert_eq!(
            owner
                .session_access(session, &identity(owner))
                .await
                .expect("second owner access")
                .mode,
            "follow"
        );
        outside_peer
            .request("session/close", json!({"sessionId":session}), Some(Duration::from_secs(20)))
            .await
            .expect("close only the fixture's outside writer");
        reply(owner, session, "AFTER_EXTERNAL_RELEASE").await;
        assert!(matches!(
            SessionClaim::acquire(&root.join("config"), session),
            Err(ClaimError::Busy)
        ));
        assert!(hosts[1]
            .acquire_session(session, &page.generation, &identity(&hosts[1]))
            .await
            .is_err());
        assert!(hosts[1].state().sessions.is_empty());
        let admitted = owner
            .session_access(session, &identity(owner))
            .await
            .expect("owner access");
        let released = owner
            .session_release(&admitted)
            .await
            .expect("owner release");
        assert_eq!(released.reason, "released_here");
        assert_eq!(
            owner
                .session_access(session, &identity(owner))
                .await
                .expect("read released access")
                .reason,
            "released_here"
        );
        assert!(reader
            .idle_owners(session)
            .await
            .expect("released inventory")
            .is_empty());
        assert_eq!(
            hosts[1]
                .acquire_session(session, "outdated", &identity(&hosts[1]))
                .await,
            Err(HostError::Stale)
        );
        assert!(hosts[1].state().sessions.is_empty());
        let ids = [identity(&hosts[1]), identity(&hosts[2])];
        let (a, b) = tokio::join!(
            hosts[1].session_open(session, &ids[0]),
            hosts[2].session_open(session, &ids[1])
        );
        let a = a.expect("first automatic opener");
        let b = b.expect("second automatic opener");
        assert_ne!(a.mode == "write", b.mode == "write", "exactly one successor: {a:?}, {b:?}");
        let (winner, loser, answer) =
            if a.mode == "write" { (&hosts[1], &hosts[2], a) } else { (&hosts[2], &hosts[1], b) };
        assert_eq!(answer.session_id, session);
        assert!(loser.state().sessions.is_empty());
        assert_eq!(
            reader
                .idle_owners(session)
                .await
                .expect("successor inventory")
                .len(),
            1
        );
        reply(winner, session, "SUCCESSOR").await;
        assert_eq!(
            owner.prompt(session, "must not send", &[], None).await,
            Err(HostError::UnknownSession)
        );
        let admitted = winner
            .session_access(session, &identity(winner))
            .await
            .expect("successor access");
        winner
            .session_release(&admitted)
            .await
            .expect("successor release");
        let reopened = owner
            .session_open(session, &identity(owner))
            .await
            .expect("explicit continue here");
        assert_eq!(reopened.mode, "write");
        assert_eq!(reopened.session_id, session);
        reply(owner, session, "AUTOMATIC_ORIGINAL_RESUME").await;
        owner
            .session_release(&reopened)
            .await
            .expect("final owner release");
        assert!(reader
            .idle_owners(session)
            .await
            .expect("final inventory")
            .is_empty());
        assert!(SessionClaim::acquire(&root.join("config"), session).is_ok());
        std::fs::write(
            root.join("result.json"),
            json!({
                "session_id":session, "original_session_restored":true,
                "exact_seed_and_successor_reply":true, "one_contender_admitted":true,
                "old_writer_rejected":true, "verified_release":true,
                "automatic_open":true,"released_here_preserved":true,"external_idle_follow":true,
            })
            .to_string(),
        )
        .expect("fixture evidence");
    })
    .catch_unwind()
    .await;
    for host in &hosts {
        host.stop().await;
    }
    if let Err(panic) = run {
        std::panic::resume_unwind(panic);
    }
}

#[tokio::test]
#[ignore = "requires POCOX_TEST_CLAUDE_* paths and isolated loopback Messages fixture"]
async fn native_claude_session_stays_writable_across_a_cli_update() {
    let root = path("POCOX_TEST_FIXTURE_ROOT");
    for dir in ["home", "config", "work", "versions"] {
        std::fs::create_dir_all(root.join(dir)).expect("fixture directory");
    }
    // Two versions and the link an update repoints, as the native installer
    // lays them out. Each copy is a fresh binary, slow on its first launch.
    let installed = path("POCOX_TEST_CLAUDE_CLI").canonicalize().expect("CLI");
    let (old, new) = (root.join("versions/old"), root.join("versions/new"));
    std::fs::copy(&installed, &old).expect("old version");
    std::fs::copy(&installed, &new).expect("new version");
    let current = root.join("claude");
    std::os::unix::fs::symlink(&old, &current).expect("link");
    let hosts = [fixture_host(&root, &current), fixture_host(&root, &current)];
    let run = std::panic::AssertUnwindSafe(async {
        for host in &hosts {
            host.launch().await.expect("adapter launch");
        }
        let owner = &hosts[0];
        let opened = owner
            .new_session(&root.join("work").to_string_lossy(), Some(&identity(owner)))
            .await
            .expect("new");
        let session = opened["sessionId"].as_str().expect("session");
        reply(owner, session, "SEED").await;

        let next = root.join("claude.next");
        std::os::unix::fs::symlink(&new, &next).expect("next link");
        std::fs::rename(&next, &current).expect("update");
        reply(owner, session, "AFTER_UPDATE").await;
        std::fs::remove_file(&old).expect("old version removed");
        reply(owner, session, "AFTER_REMOVAL").await;

        let outside = hosts[1]
            .session_open(session, &identity(&hosts[1]))
            .await
            .expect("follow");
        assert_eq!(outside.reason, "external_idle", "{outside:?}");
        // A second writer on the new version is still refused.
        let (_, outside_peer, _) = hosts[1].ready().expect("outside fixture peer");
        outside_peer
            .request(
                "session/load",
                json!({"sessionId":session,"cwd":root.join("work"),"mcpServers":[]}),
                Some(Duration::from_secs(60)),
            )
            .await
            .expect("independent original-session load");
        assert_eq!(
            owner
                .prompt(session, "MUST NOT SEND", &[], Some(&identity(owner)))
                .await,
            Err(HostError::ReadOnly)
        );
        outside_peer
            .request("session/close", json!({"sessionId":session}), Some(Duration::from_secs(20)))
            .await
            .expect("close only the fixture's outside writer");
        reply(owner, session, "AFTER_OUTSIDE_RELEASE").await;

        let access = owner
            .session_access(session, &identity(owner))
            .await
            .expect("access");
        assert_eq!(access.mode, "write", "{access:?}");
        let released = owner.session_release(&access).await.expect("hand back");
        assert_eq!(released.reason, "released_here");
    })
    .catch_unwind()
    .await;
    for host in &hosts {
        host.stop().await;
    }
    if let Err(panic) = run {
        std::panic::resume_unwind(panic);
    }
}
