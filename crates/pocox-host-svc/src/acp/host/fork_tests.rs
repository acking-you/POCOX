//! Forking a Grok session, against the mock agent's `--grok` mode and a real
//! Grok reader over a fixture home (`tests/fork_live.rs` runs the real agents).

use super::tests::{mock_binary, start_mock};
use super::*;
use crate::acp::SourceId;
use crate::native_history::{GrokHistory, NativeHistory};

const SOURCE: &str = "01a15501-b678-7db0-b062-a1f5b1edc8d1";
/// What the mock says it created.
const FORK: &str = "01a15501-b678-7db0-b062-a1f5b1edc8d2";

fn prompt(index: u64) -> Value {
    json!({"method": "session/update", "params": {"sessionId": SOURCE, "update": {
        "sessionUpdate": "user_message_chunk", "_meta": {"promptIndex": index},
        "content": {"type": "text", "text": format!("prompt {index}")}}}})
}

fn ended(id: &str) -> Value {
    json!({"method": "_x.ai/session/update", "params": {"sessionId": SOURCE, "update": {
        "sessionUpdate": "turn_completed", "prompt_id": id, "stop_reason": "end_turn"}}})
}

fn compacted() -> Value {
    json!({"method": "_x.ai/session/update", "params": {"sessionId": SOURCE, "update": {
        "sessionUpdate": "compaction_checkpoint", "checkpoint_id": "c"}}})
}

struct Fixture {
    host: AgentHost,
    home: tempfile::TempDir,
    cwd: tempfile::TempDir,
    log: PathBuf,
}

impl Fixture {
    async fn new(answer: Option<&str>) -> Self {
        let home = tempfile::tempdir().expect("home");
        let cwd = tempfile::tempdir().expect("cwd");
        let log = home.path().join("fork-request.json");
        let mut args = vec!["--grok".into(), "--fork-log".into(), log.display().to_string()];
        if let Some(answer) = answer {
            args.extend(["--fork-answer".into(), answer.into()]);
        }
        let program = mock_binary();
        let reader = GrokHistory::new(home.path().to_path_buf()).expect("reader");
        let host = AgentHost::create_with_native_history(
            HostOptions {
                store: SessionStore::memory(SourceId::with_key(&"k".repeat(32), &program, &args)),
                spec: AgentSpec {
                    profile_id: "grok".into(),
                    display_name: "Grok".into(),
                    program: program.to_string_lossy().into_owned(),
                    args,
                },
                program,
                path: None,
                env: Vec::new(),
                env_remove: Vec::new(),
            },
            None,
            None,
            Some(NativeHistory::Grok(Arc::new(reader))),
        );
        host.launch().await.expect("launch");
        Self {
            host,
            home,
            cwd,
            log,
        }
    }

    /// Store a session with `lines` as its update log.
    fn session(&self, id: &str, lines: &[Value]) {
        let dir = self.home.path().join("sessions/bucket").join(id);
        std::fs::create_dir_all(&dir).expect("session");
        let summary = json!({"info": {"id": id, "cwd": self.cwd.path()}, "generated_title": "Title",
            "created_at": "2026-10-19T16:32:18Z", "updated_at": "2026-10-19T16:32:19Z"});
        std::fs::write(dir.join("summary.json"), summary.to_string()).expect("summary");
        let log: String = lines.iter().map(|line| format!("{line}\n")).collect();
        std::fs::write(dir.join("updates.jsonl"), log).expect("log");
    }

    fn identity(&self) -> Identity {
        Identity {
            host_id: Some(self.host.host_id().to_string()),
            generation: Some(self.host.state().generation),
        }
    }

    async fn fork(&self, through: Option<&str>) -> Result<Value, HostError> {
        self.host
            .fork_session(SOURCE, through, &self.identity())
            .await
    }

    /// What the agent was asked, consumed: `None` when nothing reached it.
    fn asked(&self) -> Option<Value> {
        let text = std::fs::read_to_string(&self.log).ok()?;
        std::fs::remove_file(&self.log).expect("consume");
        serde_json::from_str(&text).ok()
    }
}

#[tokio::test]
async fn a_fork_sends_only_grok_s_own_parameters_and_checks_what_it_stored() {
    let fixture = Fixture::new(None).await;
    let cwd = fixture.cwd.path().to_str().expect("path");
    fixture.session(SOURCE, &[prompt(0), ended("turn-0"), prompt(1), ended("turn-1")]);
    fixture.session(FORK, &[prompt(0), ended("turn-0")]);
    assert_eq!(fixture.host.info()["fork"], json!({"supported": true, "throughTurn": true}));

    let answer = fixture.fork(Some("turn-0")).await.expect("fork");
    assert_eq!(
        fixture.asked().expect("asked"),
        json!({"sourceSessionId": SOURCE, "sourceCwd": cwd, "newCwd": cwd, "targetPromptIndex": 0}),
        "no prompt, model or id of ours travels with a fork"
    );
    assert_eq!(answer["outcome"], "created");
    assert_eq!(answer["sessionId"], FORK);
    assert_eq!(answer["forkedFrom"], SOURCE);
    assert_eq!(answer["cwd"], cwd);
    assert_eq!(answer["boundaryConfirmed"], true, "the store ends at the turn");
    assert_eq!(answer["lastTurnInterrupted"], false);

    // A turn named by the reader's own id: Grok would cut at the second prompt,
    // and the stored fork holds one.
    let reader = GrokHistory::new(fixture.home.path().to_path_buf()).expect("reader");
    let second = reader.prompts(SOURCE).await.expect("marks")[1].turn.clone();
    let answer = fixture.fork(Some(&second)).await.expect("fork");
    assert_eq!(fixture.asked().expect("asked")["targetPromptIndex"], 1);
    assert_eq!(answer["boundaryConfirmed"], false, "the store does not end there");

    // The latest state names no boundary, and an unfinished copy says so.
    fixture.session(FORK, &[prompt(0), ended("turn-0"), prompt(1)]);
    let answer = fixture.fork(None).await.expect("fork");
    assert!(fixture
        .asked()
        .expect("asked")
        .get("targetPromptIndex")
        .is_none());
    assert_eq!(answer["boundaryConfirmed"], true);
    assert_eq!(answer["lastTurnInterrupted"], true);
}

#[tokio::test]
async fn a_boundary_must_be_a_finished_turn_with_no_compaction_after_it() {
    let fixture = Fixture::new(None).await;
    fixture.session(SOURCE, &[
        prompt(0),
        ended("turn-0"),
        prompt(1),
        compacted(),
        ended("turn-1"),
        prompt(2),
    ]);
    fixture.session(FORK, &[prompt(0), ended("turn-0"), prompt(1), ended("turn-1")]);

    let error = fixture
        .fork(Some("turn-0"))
        .await
        .expect_err("compacted later");
    assert!(matches!(error, HostError::Unsupported(_)), "{error}");
    let reader = GrokHistory::new(fixture.home.path().to_path_buf()).expect("reader");
    let running = reader.prompts(SOURCE).await.expect("marks")[2].turn.clone();
    let error = fixture
        .fork(Some(&running))
        .await
        .expect_err("still running");
    assert!(matches!(error, HostError::Busy), "{error}");
    let error = fixture
        .fork(Some("no-such-turn"))
        .await
        .expect_err("unknown");
    assert!(matches!(error, HostError::InvalidInput(_)), "{error}");
    assert!(fixture.asked().is_none(), "none of these reached the agent");

    // Compaction during the boundary turn only summarizes what the fork keeps.
    let answer = fixture.fork(Some("turn-1")).await.expect("fork");
    assert_eq!(fixture.asked().expect("asked")["targetPromptIndex"], 1);
    assert_eq!(answer["boundaryConfirmed"], true);
}

#[tokio::test]
async fn a_refusal_creates_nothing_and_an_unclear_answer_stays_unknown() {
    let fixture = Fixture::new(None).await;
    let error = fixture.fork(None).await.expect_err("no such source");
    assert!(matches!(error, HostError::Agent(_)), "{error}");
    assert!(fixture.asked().is_none(), "Grok would leave an empty directory behind");

    fixture.session(SOURCE, &[prompt(0), ended("turn-0")]);
    let stale = Identity {
        host_id: Some("another".into()),
        generation: Some(1),
    };
    let error = fixture
        .host
        .fork_session(SOURCE, None, &stale)
        .await
        .expect_err("stale");
    assert!(matches!(error, HostError::Stale), "{error}");
    assert!(fixture.asked().is_none());

    let older = Fixture::new(Some("missing")).await;
    older.session(SOURCE, &[prompt(0), ended("turn-0")]);
    let error = older.fork(None).await.expect_err("no such method");
    assert!(matches!(error, HostError::Unsupported(_)), "{error}");

    let failing = Fixture::new(Some("internal")).await;
    failing.session(SOURCE, &[prompt(0), ended("turn-0")]);
    let answer = failing.fork(None).await.expect("not a refusal");
    assert_eq!(answer["outcome"], "unknown", "it may follow the copy");
}

#[tokio::test]
async fn an_agent_this_host_has_not_verified_is_never_asked() {
    let program = mock_binary();
    let spec = AgentSpec {
        profile_id: "custom".into(),
        display_name: "Custom".into(),
        program: program.to_string_lossy().into_owned(),
        args: Vec::new(),
    };
    let host = start_mock(program, spec).await;
    assert_eq!(host.info()["fork"], json!({"supported": false, "throughTurn": false}));
    let identity = Identity {
        host_id: Some(host.host_id().to_string()),
        generation: Some(host.state().generation),
    };
    let error = host
        .fork_session(SOURCE, None, &identity)
        .await
        .expect_err("unverified");
    assert!(matches!(error, HostError::Unsupported(_)), "{error}");
}
