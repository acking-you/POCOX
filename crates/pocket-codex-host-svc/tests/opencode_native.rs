//! Opt-in tests against an installed native binary and disposable data only.
#![cfg(unix)]

use std::{ffi::OsString, path::PathBuf, time::Duration};

use pocket_codex_host_svc::{
    opencode::{
        ownership::{Evidence, Source},
        runtime::{Launch, Server},
        schema::Session,
    },
    process,
};
use serde_json::{json, Value};

#[path = "opencode_fixture/model.rs"]
mod model_fixture;

fn fixture(root: &std::path::Path) -> Launch {
    let program =
        PathBuf::from(std::env::var_os("PCX_OPENCODE_BIN").expect("set PCX_OPENCODE_BIN"));
    let mut env: Vec<(OsString, OsString)> = Vec::new();
    for (key, directory) in [
        ("HOME", "home"),
        ("OPENCODE_TEST_HOME", "home"),
        ("XDG_DATA_HOME", "data"),
        ("XDG_CONFIG_HOME", "config"),
        ("XDG_CACHE_HOME", "cache"),
        ("XDG_STATE_HOME", "state"),
        ("OPENCODE_CONFIG_DIR", "config"),
    ] {
        let path = root.join(directory);
        std::fs::create_dir_all(&path).expect("fixture directory");
        env.push((key.into(), path.into_os_string()));
    }
    let config = root.join("config.json");
    std::fs::write(&config, "{}").expect("empty isolated config");
    env.extend([
        ("OPENCODE_DB".into(), root.join("data/opencode/fixture.db").into_os_string()),
        ("OPENCODE_CONFIG".into(), config.into_os_string()),
        ("OPENCODE_CONFIG_CONTENT".into(), "{\"plugin\":[]}".into()),
        ("OPENCODE_DISABLE_PROJECT_CONFIG".into(), "true".into()),
        ("OPENCODE_DISABLE_MODELS_FETCH".into(), "true".into()),
        ("OPENCODE_DISABLE_AUTOUPDATE".into(), "true".into()),
        ("OPENCODE_PURE".into(), "true".into()),
    ]);
    Launch {
        program,
        path: None,
        env,
    }
}

#[tokio::test]
#[ignore = "requires PCX_OPENCODE_BIN pointing to installed OpenCode 1.19+"]
async fn native_lifecycle_original_session_and_external_database_holder() {
    let root = tempfile::tempdir().expect("disposable source");
    let launch = fixture(root.path());
    let mut server = Server::start(&launch).await.expect("native start");
    let source =
        Source::new(server.detection.database.clone(), server.pid, server.started).expect("source");
    assert_eq!(source.inspect().await, Evidence::Clear, "owned native database handle is visible");
    assert!(Server::start(&launch).await.is_err(), "a second Pocket server cannot own this source");
    let directory = root.path().join("中文 project");
    std::fs::create_dir(&directory).expect("project");
    let directory = directory.to_str().expect("UTF-8");
    let session: Session = server
        .client
        .mutate(
            reqwest::Method::POST,
            &["session"],
            Some(directory),
            &json!({"title":"Native lifecycle fixture"}),
        )
        .await
        .expect("create original session");
    let mut events = server.client.events(None).await.expect("global events");
    let event = tokio::time::timeout(Duration::from_secs(5), events.next())
        .await
        .expect("connection event deadline")
        .expect("event")
        .expect("event frame");
    assert_eq!(event.kind, "server.connected");
    drop(events);
    let _: Value = server
        .client
        .mutate(
            reqwest::Method::POST,
            &["session", &session.id, "message"],
            Some(directory),
            &json!({"noReply":true,"parts":[{"type":"text","text":"Original session fixture"}]}),
        )
        .await
        .expect("persist user input without any model call");
    let page = server
        .client
        .messages(&session.id, directory, None)
        .await
        .expect("native history");
    assert!(page.messages.iter().any(|m| m
        .parts
        .iter()
        .any(|p| p["text"] == "Original session fixture")));

    // This independently owned fixture only opens the same SQLite database;
    // it performs no write. Even an idle holder prevents a false free claim.
    let script = "import sqlite3,sys,time; \
                  c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True); c.execute('select \
                  count(*) from session').fetchone(); print('ready',flush=True); time.sleep(60)";
    let process::Spawned {
        mut process,
        stdin,
        mut stdout,
    } = process::spawn(
        std::path::Path::new("/usr/bin/python3"),
        &["-c".into(), script.into(), server.detection.database.display().to_string()],
        None,
        &[],
    )
    .expect("outside reader");
    drop(stdin);
    use tokio::io::AsyncReadExt;
    let mut ready = [0u8; 6];
    tokio::time::timeout(Duration::from_secs(10), stdout.read_exact(&mut ready))
        .await
        .expect("reader ready deadline")
        .expect("reader ready");
    let evidence = source.inspect().await;
    assert!(
        matches!(evidence, Evidence::External(ref holders) if holders.iter().any(|h| Some(h.pid) == process.id())),
        "a foreign source holder stays follow-only: {evidence:?}"
    );
    assert!(process.stop(Duration::from_millis(50)).await);
    assert_eq!(source.inspect().await, Evidence::Clear);
    server.stop().await.expect("confirmed native stop");
    let mut resumed = Server::start(&launch).await.expect("restart same source");
    let original: Session = resumed
        .client
        .get(&["session", &session.id], Some(directory), &[])
        .await
        .expect("original session");
    assert_eq!(original.id, session.id);
    assert_eq!(
        resumed
            .client
            .messages(&session.id, directory, None)
            .await
            .expect("retained history")
            .messages
            .len(),
        page.messages.len()
    );
    resumed.stop().await.expect("stop restarted native server");
}

#[tokio::test]
#[ignore = "requires PCX_OPENCODE_BIN pointing to installed OpenCode 1.19+"]
async fn native_gateway_original_admission_and_closed_mutation_routes() {
    use pocket_codex_host_svc::opencode::{
        api,
        host::{Host, Snapshot},
    };
    use tokio::io::AsyncReadExt;

    let root = tempfile::tempdir().expect("disposable source");
    let server = Server::start(&fixture(root.path()))
        .await
        .expect("native start");
    let database = server.detection.database.clone();
    let host = Host::new(server).await.expect("host stream ready");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("listener");
    let origin = format!("http://{}", listener.local_addr().expect("address"));
    let serving = tokio::spawn(api::serve(listener, host.clone()));
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(10))
        .build()
        .expect("http");
    let identity = host.info().identity;
    let gateway =
        pocket_codex_host_svc::opencode::gateway::Gateway::new(&origin).expect("gateway client");
    assert_eq!(gateway.info().await.expect("gateway protocol").identity, identity);
    gateway
        .catalog(None, &identity)
        .await
        .expect("identity-pinned public catalog");
    let mut stale_read = identity.clone();
    stale_read.host_id = "obsolete-controller-host".into();
    assert!(matches!(gateway.catalog(None, &stale_read).await,
        Err(pocket_codex_host_svc::opencode::client::ClientError::Gateway { code, .. }) if code == "stale_host"));

    let mut invalidations = gateway.events(&identity, 0).await.expect("gateway events");
    let change = tokio::time::timeout(Duration::from_secs(5), invalidations.next())
        .await
        .expect("initial invalidation deadline")
        .expect("event")
        .expect("event frame");
    assert_eq!(change.kind, "changed");
    assert!(change.properties["sequence"].as_u64().is_some());
    drop(invalidations);
    let directory = root.path().join("project");
    std::fs::create_dir(&directory).expect("project");
    let created = http
        .post(format!("{origin}/opencode/v1/create"))
        .json(&json!({"identity":identity,"directory":directory,"options":{}}))
        .send()
        .await
        .expect("create");
    assert_eq!(created.status(), 200);
    let session: Session = created.json().await.expect("session");
    let mutation = json!({"identity":identity,"sessionId":session.id});
    let opened: Snapshot = http
        .post(format!("{origin}/opencode/v1/open"))
        .json(&mutation)
        .send()
        .await
        .expect("open")
        .error_for_status()
        .expect("open status")
        .json()
        .await
        .expect("snapshot");
    assert_eq!(opened.session.id, session.id);
    assert_eq!(opened.access.mode, "write");
    assert_eq!(opened.access.exclusion, "pocket");
    assert!(opened.window.connected);

    for path in [
        "/provider",
        "/config",
        "/opencode/v1/native/config",
        "/opencode/v1/auth",
        "/opencode/v1/shell",
    ] {
        assert_eq!(
            http.get(format!("{origin}{path}"))
                .send()
                .await
                .expect("closed route")
                .status(),
            404,
            "{path}"
        );
    }
    let mut stale = mutation.clone();
    stale["identity"]["hostId"] = json!("previous host");
    let mut stale_identity = identity.clone();
    stale_identity.host_id = "previous host".into();
    assert!(matches!(gateway.release(&session.id, &stale_identity).await,
        Err(pocket_codex_host_svc::opencode::client::ClientError::Gateway { code, status: 409 }) if code == "stale_host"));
    assert_eq!(
        http.post(format!("{origin}/opencode/v1/release"))
            .json(&stale)
            .send()
            .await
            .expect("stale mutation")
            .status(),
        409
    );
    let released: Value = http
        .post(format!("{origin}/opencode/v1/release"))
        .json(&mutation)
        .send()
        .await
        .expect("release")
        .error_for_status()
        .expect("release status")
        .json()
        .await
        .expect("access");
    assert_eq!(released["reason"], "released_here");

    let script = "import sqlite3,sys,time; \
                  c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True); c.execute('select \
                  count(*) from session').fetchone(); print('ready',flush=True); time.sleep(60)";
    let process::Spawned {
        mut process,
        stdin,
        mut stdout,
    } = process::spawn(
        std::path::Path::new("/usr/bin/python3"),
        &["-c".into(), script.into(), database.display().to_string()],
        None,
        &[],
    )
    .expect("isolated outside reader");
    drop(stdin);
    let mut ready = [0; 6];
    tokio::time::timeout(Duration::from_secs(10), stdout.read_exact(&mut ready))
        .await
        .expect("fixture deadline")
        .expect("fixture ready");
    let followed: Snapshot = http
        .post(format!("{origin}/opencode/v1/open"))
        .json(&mutation)
        .send()
        .await
        .expect("follow open")
        .error_for_status()
        .expect("follow status")
        .json()
        .await
        .expect("follow snapshot");
    assert_eq!(followed.access.reason, "external_source_open");
    assert_eq!(followed.access.turn, "unknown");
    assert_eq!(followed.access.mode, "follow");
    let mut rename = mutation.clone();
    rename["title"] = json!("MUST NOT CHANGE");
    assert_eq!(
        http.post(format!("{origin}/opencode/v1/rename"))
            .json(&rename)
            .send()
            .await
            .expect("blocked rename")
            .status(),
        409
    );
    assert!(process.stop(Duration::from_millis(50)).await);
    let resumed: Snapshot = http
        .post(format!("{origin}/opencode/v1/open"))
        .json(&mutation)
        .send()
        .await
        .expect("resume")
        .error_for_status()
        .expect("resume status")
        .json()
        .await
        .expect("resumed snapshot");
    assert_eq!(resumed.session.id, session.id);
    assert_eq!(resumed.access.mode, "write");
    assert_ne!(resumed.session.title, "MUST NOT CHANGE");
    let mut events = gateway
        .events(&identity, host.live().sequence().await)
        .await
        .expect("controller stream before stopping");
    host.stop().await.expect("native stopped");
    tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(event) = events.next().await {
            match event {
                Ok(_) => {},
                Err(pocket_codex_host_svc::opencode::client::ClientError::EventStreamEnded) => {
                    break;
                },
                Err(error) => panic!("unexpected final stream error: {error}"),
            }
        }
    })
    .await
    .expect("stopping ends existing SSE even while the gateway listener is retained");
    assert!(gateway.info().await.is_err(), "a stopped host cannot report a healthy handshake");
    assert!(gateway.events(&identity, 0).await.is_err(), "a stopped host rejects new streams");
    serving.abort();
    let _ = serving.await;
}

#[tokio::test]
#[ignore = "requires PCX_OPENCODE_BIN pointing to installed OpenCode 1.19+"]
async fn native_host_stream_options_permissions_questions_commands_and_cancel() {
    use pocket_codex_host_svc::opencode::host::{Answer, Host, Input, Options, Snapshot};
    async fn until(host: &Host, id: &str, ready: impl Fn(&Snapshot) -> bool) -> Snapshot {
        let mut last = None;
        let result = tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let snapshot = host.snapshot(id, None).await.expect("snapshot");
                if ready(&snapshot) {
                    return snapshot;
                }
                last = Some(snapshot);
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await;
        assert!(result.is_ok(), "native transition deadline; last snapshot: {last:?}");
        result.expect("native transition")
    }
    fn text(snapshot: &Snapshot) -> String {
        snapshot
            .window
            .messages
            .iter()
            .filter(|m| m.info["role"] == "assistant")
            .flat_map(|m| &m.parts)
            .filter(|part| part["type"] == "text")
            .filter_map(|part| part["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }
    let model_service = model_fixture::start().await;
    let root = tempfile::tempdir().expect("disposable source");
    let mut launch = fixture(root.path());
    launch
        .env
        .retain(|(key, _)| key != "OPENCODE_CONFIG_CONTENT");
    launch.env.push(("OPENCODE_CONFIG_CONTENT".into(), json!({
        "plugin":[],"model":"fixture/test","permission":{"bash":"ask"},
        "command":{"fixture":{"template":"COMMAND_FIXTURE $ARGUMENTS","description":"Isolated command"}},
        "provider":{"fixture":{"npm":"@ai-sdk/openai-compatible","options":{"baseURL":model_service.address,"apiKey":"fixture-only"},
            "models":{"test":{"name":"Fixture test","limit":{"context":32000,"output":1024},"variants":{"careful":{"temperature":0.1}}}}}}
    }).to_string().into()));
    let server = Server::start(&launch).await.expect("native start");
    let native = server.client.clone();
    let host = Host::new(server).await.expect("host ready");
    let directory = root.path().join("project");
    std::fs::create_dir(&directory).expect("project");
    let directory = directory.to_str().expect("UTF8");
    let catalog = host.catalog(Some(directory)).await.expect("catalog");
    assert!(catalog
        .model("fixture/test")
        .expect("native model")
        .variants
        .contains(&"careful".into()));
    assert!(catalog
        .commands
        .iter()
        .any(|command| command.name == "fixture"));
    let identity = host.info().identity;
    let options = Options {
        model: Some("fixture/test".into()),
        agent: Some("build".into()),
        variant: Some("careful".into()),
    };
    let session = host
        .create(directory, options.clone(), &identity)
        .await
        .expect("session");
    let input = |text: &str| Input {
        text: text.into(),
        images: vec![],
    };
    let first = host
        .prompt(&session.id, input("HOLD_FIXTURE"), None, &identity)
        .await
        .expect("prompt");
    let streaming = until(&host, &session.id, |s| text(s).contains("NATIVE_PREFIX ")).await;
    assert!(!text(&streaming).contains("COMPLETE"));
    assert_eq!(streaming.turn_id.as_deref(), Some(first.as_str()));
    let persisted = native
        .messages(&session.id, directory, None)
        .await
        .expect("persisted history");
    assert!(
        !persisted
            .messages
            .iter()
            .flat_map(|m| &m.parts)
            .any(|p| p["text"]
                .as_str()
                .is_some_and(|t| t.contains("NATIVE_PREFIX"))),
        "the live prefix is still absent from native persisted history"
    );
    assert!(host
        .prompt(&session.id, input("new turn must queue"), None, &identity)
        .await
        .is_err());
    assert_eq!(
        host.prompt(&session.id, input("SUPPLEMENT_FIXTURE"), Some(&first), &identity)
            .await
            .expect("supplement"),
        first
    );
    model_service.gate.notify_waiters();
    let settled = until(&host, &session.id, |s| s.access.turn == "idle").await;
    assert!(text(&settled).contains("NATIVE_PREFIX COMPLETE"));
    assert!(!text(&settled).contains("NATIVE_PREFIX NATIVE_PREFIX"));
    assert_eq!(settled.options, options);
    host.prompt(&session.id, input("PERMISSION_FIXTURE"), None, &identity)
        .await
        .expect("permission prompt");
    let pending = until(&host, &session.id, |s| !s.permissions.is_empty()).await;
    let request = pending.permissions[0]["id"]
        .as_str()
        .expect("permission id");
    host.answer(
        &session.id,
        request,
        Answer::Permission {
            reply: "once".into(),
        },
        &identity,
    )
    .await
    .expect("permission reply");
    until(&host, &session.id, |s| s.access.turn == "idle").await;
    host.prompt(&session.id, input("QUESTION_FIXTURE"), None, &identity)
        .await
        .expect("question prompt");
    let pending = until(&host, &session.id, |s| !s.questions.is_empty()).await;
    assert_eq!(pending.questions[0]["questions"][0]["multiple"], true);
    let request = pending.questions[0]["id"].as_str().expect("question id");
    host.answer(
        &session.id,
        request,
        Answer::Question {
            answers: vec![vec!["A".into(), "B".into()]],
        },
        &identity,
    )
    .await
    .expect("question reply");
    until(&host, &session.id, |s| s.access.turn == "idle").await;
    host.prompt(&session.id, input("/fixture arguments"), None, &identity)
        .await
        .expect("native command");
    let command = until(&host, &session.id, |s| s.access.turn == "idle").await;
    assert!(command.operation_error.is_none(), "{:?}", command.operation_error);
    assert!(command
        .window
        .messages
        .iter()
        .flat_map(|m| &m.parts)
        .any(|p| p["text"]
            .as_str()
            .is_some_and(|t| t.contains("COMMAND_FIXTURE arguments"))));
    let cancelled = host
        .prompt(&session.id, input("HOLD_FIXTURE cancellation"), None, &identity)
        .await
        .expect("cancel prompt");
    until(&host, &session.id, |s| {
        s.turn_id.as_deref() == Some(&cancelled) && s.access.turn == "running"
    })
    .await;
    assert!(host
        .cancel(&session.id, &cancelled, &identity)
        .await
        .expect("cancel"));
    model_service.gate.notify_waiters();
    until(&host, &session.id, |s| s.access.turn == "idle").await;
    host.stop().await.expect("native cleanup");
}
