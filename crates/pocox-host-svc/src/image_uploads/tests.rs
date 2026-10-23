use super::*;
use crate::projects::HostStore;
use crate::store::{ConfigStore, HostConfig};

struct SessionDirs(String);

#[async_trait::async_trait]
impl file_links::SessionDirResolver for SessionDirs {
    async fn session_dir(&self, session: &str) -> anyhow::Result<Option<String>> {
        Ok((session == "known").then(|| self.0.clone()))
    }
}

#[tokio::test]
async fn uploads_use_the_session_or_selected_project_and_preserve_legacy_routes() {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path().join("projects");
    let default = root.join("default");
    let selected = root.join("selected");
    let session = temp.path().join("session-outside-roots");
    let uploads = temp.path().join("legacy-uploads");
    for dir in [&default, &selected, &session] {
        std::fs::create_dir_all(dir).expect("project");
    }
    let host = HostStore::open_with_default(temp.path().join("host.json"), default.clone())
        .await
        .expect("host");
    host.put(HostConfig {
        project_roots: vec![root.display().to_string()],
        default_project: Some(default.display().to_string()),
    })
    .await
    .expect("host config");
    let state = Arc::new(AppState {
        codex: Arc::new(crate::app_server::CodexReader::new(
            "127.0.0.1:1".parse().expect("address"),
        )),
        store: Arc::new(
            ConfigStore::open(temp.path().join("threads.json"))
                .await
                .expect("store"),
        ),
        host: Arc::new(host),
        uploads_dir: Some(uploads.clone()),
        session_dirs: Some(Arc::new(SessionDirs(session.display().to_string()))),
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("listener");
    let address = listener.local_addr().expect("address");
    let app = crate::generic_routes().with_state(state.clone());
    let server = tokio::spawn(async move { axum::serve(listener, app).await });
    let client = reqwest::Client::builder()
        .no_proxy()
        .build()
        .expect("client");
    let endpoint = format!("http://{address}/uploads/images/shot.png");
    for (query, expected) in [
        (vec![], default.clone()),
        (vec![("project", selected.display().to_string())], selected.clone()),
        (vec![("thread", "known".into()), ("project", default.display().to_string())], session),
    ] {
        let response = client
            .post(&endpoint)
            .query(&query)
            .body("image bytes")
            .send()
            .await
            .expect("upload");
        assert!(response.status().is_success(), "{}", response.status());
        let body: serde_json::Value = response.json().await.expect("response");
        let path = PathBuf::from(body["path"].as_str().expect("path"));
        assert!(path.starts_with(
            expected
                .canonicalize()
                .expect("project")
                .join(".pocket-attachments")
        ));
        assert_eq!(std::fs::read(path).expect("saved bytes"), b"image bytes");
    }
    let response = client
        .post(format!("http://{address}/uploads/old.png"))
        .body("legacy")
        .send()
        .await
        .expect("legacy upload");
    assert!(response.status().is_success());
    let body: serde_json::Value = response.json().await.expect("legacy response");
    assert!(PathBuf::from(body["path"].as_str().expect("path")).starts_with(&uploads));

    for project in [
        temp.path().display().to_string(),
        root.join("../escape").display().to_string(),
        "relative".into(),
    ] {
        let response = client
            .post(&endpoint)
            .query(&[("project", project)])
            .body("must not write")
            .send()
            .await
            .expect("refused upload");
        assert_eq!(response.status(), reqwest::StatusCode::FORBIDDEN);
    }
    let response = client
        .post(&endpoint)
        .query(&[("thread", "missing")])
        .body("must not write")
        .send()
        .await
        .expect("missing session");
    assert_eq!(response.status(), reqwest::StatusCode::NOT_FOUND);

    std::fs::remove_dir_all(&default).expect("remove default fixture");
    let response = client
        .post(&endpoint)
        .body("must not recreate")
        .send()
        .await
        .expect("missing project");
    assert_eq!(response.status(), reqwest::StatusCode::NOT_FOUND);
    assert!(!default.exists());
    assert!(!temp.path().join(".pocket-attachments").exists());
    server.abort();
    let _ = server.await;
}

#[cfg(unix)]
#[test]
fn attachment_directories_cannot_redirect_writes_outside_the_project() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project = temp.path().join("project");
    let outside = temp.path().join("outside");
    std::fs::create_dir(&project).expect("project");
    std::fs::create_dir(&outside).expect("outside");
    std::os::unix::fs::symlink(&outside, project.join(".pocket-attachments")).expect("symlink");
    assert!(attachment_dir(&project).is_err());
    assert_eq!(
        std::fs::read_dir(outside)
            .expect("outside contents")
            .count(),
        0
    );
}
