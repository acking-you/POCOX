use futures::StreamExt;

use super::*;
use crate::{
    acp::{api, ClientError, GatewayClient, SourceId},
    native_history::ClaudeHistory,
};

const SESSION: &str = "00000000-0000-4000-8000-000000000001";

struct ServerGuard(tokio::task::AbortHandle);
impl Drop for ServerGuard {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn host(reader: ClaudeHistory) -> AgentHost {
    let program = PathBuf::from("/must-never-start-an-agent");
    let store = SessionStore::memory(SourceId::with_key(&"x".repeat(32), &program, &[]));
    AgentHost::create_with_native_history(
        HostOptions {
            spec: AgentSpec {
                profile_id: "fixture".into(),
                display_name: "Fixture".into(),
                program: program.to_string_lossy().into(),
                args: Vec::new(),
            },
            program,
            path: None,
            env: Vec::new(),
            env_remove: Vec::new(),
            store,
        },
        None,
        None,
        Some(crate::native_history::NativeHistory::Claude(Arc::new(reader))),
    )
}

#[tokio::test]
async fn browsing_cannot_admit_a_foreign_session_even_without_a_running_agent() {
    let host = host(
        ClaudeHistory::new("/node".into(), "/sdk.mjs".into(), "/root".into()).expect("source"),
    );
    assert_eq!(host.open_session(SESSION, None).await, Err(HostError::ReadOnly));
    assert_eq!(host.info()["nativeHistory"], true);
    assert!(host.state().sessions.is_empty());
    assert!(host.inner.store.entries().is_empty());
    let stale = Identity {
        host_id: Some("another-host".into()),
        generation: Some(0),
    };
    assert_eq!(host.open_session(SESSION, Some(&stale)).await, Err(HostError::Stale));
    assert!(host
        .prompt(SESSION, "must not send", &[], None)
        .await
        .is_err());
}

#[cfg(unix)]
#[tokio::test]
#[ignore = "requires PCX_TEST_NODE pointing to Node.js 22+"]
async fn gateway_native_browse_pages_and_follows_with_no_acp_process() {
    let fixture = tempfile::tempdir().expect("fixture");
    let root = fixture.path().join("claude");
    let project = root.join("projects/fixture");
    std::fs::create_dir_all(&project).expect("projects");
    let transcript = project.join(format!("{SESSION}.jsonl"));
    std::fs::write(&transcript, "header\nfirst\n").expect("transcript");
    let sdk = fixture.path().join("sdk.mjs");
    std::fs::write(&sdk, r#"
        export async function listSessions({offset}) { return offset ? [] : [await getSessionInfo('00000000-0000-4000-8000-000000000001')]; }
        export async function getSessionInfo(sessionId) { return {sessionId, cwd:'/fixture', summary:'Native fixture', lastModified:1000}; }
        export async function getSessionMessages() { return [
            {type:'user', uuid:'00000000-0000-4000-8000-000000000002', message:{content:'First native prompt'}},
            {type:'assistant', uuid:'00000000-0000-4000-8000-000000000003', message:{content:'First native reply'}},
            {type:'user', uuid:'00000000-0000-4000-8000-000000000004', message:{content:'Second native prompt'}},
            {type:'assistant', uuid:'00000000-0000-4000-8000-000000000005', message:{content:'Second native reply'}}]; }
        export function query() { throw Error('must never resume'); }
    "#).expect("SDK fixture");
    let reader =
        ClaudeHistory::new(std::env::var_os("PCX_TEST_NODE").expect("Node").into(), sdk, root)
            .expect("reader");
    let host = host(reader);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let serving = tokio::spawn(api::serve(listener, host.clone()));
    let _guard = ServerGuard(serving.abort_handle());
    let client = GatewayClient::new(&format!("http://{address}")).expect("client");
    let identity = Identity {
        host_id: Some(host.host_id().into()),
        generation: Some(0),
    };
    let result = async {
        assert!(matches!(client.open_session(SESSION, Some(&identity)).await,
            Err(ClientError::Host {code,..}) if code == "native_read_only"));
        let list = client.sessions(None).await.expect("native inventory");
        assert_eq!(list["source"], "native");
        assert_eq!(list["sessions"][0]["title"], "Native fixture");
        let tail = client
            .history(SESSION, None, None, Some(1))
            .await
            .expect("tail");
        assert_eq!(tail["window"][0]["id"], "native:00000000-0000-4000-8000-000000000004");
        assert_eq!(tail["hasOlder"], true);
        let older = client
            .history(SESSION, Some("native:00000000-0000-4000-8000-000000000004"), None, Some(1))
            .await
            .expect("older");
        assert_eq!(older["window"][0]["items"][0]["text"], "First native prompt");
        let turn = client
            .history(SESSION, None, Some("native:00000000-0000-4000-8000-000000000002"), None)
            .await
            .expect("selected turn");
        assert_eq!(turn["window"], older["window"]);
        let mut updates = client
            .native_events(SESSION, host.host_id(), 0)
            .await
            .expect("follow");
        let first = updates.next().await.expect("event").expect("body");
        assert_eq!(first["liveness"]["turn_state"], "unknown");
        assert_eq!(first["liveness"]["allows_resume"], false);
        std::fs::write(&transcript, "header\nfirst\nsecond\n").expect("append");
        let next = updates.next().await.expect("event").expect("body");
        assert_ne!(first["history_revision"], next["history_revision"]);
        assert!(host.state().sessions.is_empty());
        assert!(host.inner.store.entries().is_empty());
    };
    let completed = tokio::time::timeout(Duration::from_secs(15), result).await;
    serving.abort();
    let _ = serving.await;
    completed.expect("bounded native browse");
}
