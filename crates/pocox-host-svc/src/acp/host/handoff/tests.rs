use super::*;
use crate::acp::host::tests::{eventually, mock_binary, outcome, start_mock};

async fn fixture(extra: &[&str]) -> (AgentHost, String, Identity, tempfile::TempDir) {
    let program = mock_binary();
    let mut args = vec!["--profile".into(), "beta".into()];
    args.extend(extra.iter().map(|s| s.to_string()));
    let host = start_mock(program.clone(), AgentSpec {
        profile_id: "mock".into(),
        display_name: "Mock".into(),
        program: program.to_string_lossy().into_owned(),
        args,
    })
    .await;
    let cwd = tempfile::tempdir().expect("cwd");
    let opened = host
        .new_session(&cwd.path().to_string_lossy(), None)
        .await
        .expect("new");
    let session = opened["sessionId"].as_str().expect("id").to_string();
    let identity = Identity {
        host_id: Some(host.host_id().into()),
        generation: Some(host.state().generation),
    };
    (host, session, identity, cwd)
}

#[tokio::test]
async fn running_or_stale_release_leaves_the_original_session_usable() {
    let (host, session, identity, _cwd) = fixture(&[]).await;
    let turn = host
        .prompt(&session, "slow", &[], None)
        .await
        .expect("turn");
    assert_eq!(host.release_session(&session, &identity).await, Err(HostError::Busy));
    assert!(!host.state().sessions[&session].pending);
    let stale = Identity {
        generation: Some(0),
        ..identity.clone()
    };
    assert_eq!(host.release_session(&session, &stale).await, Err(HostError::Stale));
    assert_eq!(host.release_session(&session, &Identity::default()).await, Err(HostError::Stale));
    host.cancel(&session, Some(&turn), None)
        .await
        .expect("cancel");
    eventually(|| outcome(&host, &session, &turn).is_some(), "turn ended").await;
    let released = host
        .release_session(&session, &identity)
        .await
        .expect("release");
    assert_eq!(released["sessionId"], session);
    assert_eq!(released["released"], true);
    assert!(!host.state().sessions.contains_key(&session));
    assert_eq!(
        host.prompt(&session, "not admitted", &[], None).await,
        Err(HostError::UnknownSession)
    );
    assert_eq!(host.info()["generation"], identity.generation.expect("generation"));
    let other = host
        .new_session(&_cwd.path().to_string_lossy(), None)
        .await
        .expect("adapter still usable");
    assert_ne!(other["sessionId"], session);
    host.stop().await;
}

#[tokio::test]
async fn disconnect_during_close_cannot_reopen_admission_or_cancel_cleanup() {
    let (host, session, identity, _cwd) = fixture(&["--close-delay-ms", "400"]).await;
    let closing = tokio::spawn({
        let (host, session) = (host.clone(), session.clone());
        async move { host.release_session(&session, &identity).await }
    });
    eventually(|| host.state().sessions[&session].releasing, "close admitted").await;
    assert_eq!(host.prompt(&session, "must stay unsent", &[], None).await, Err(HostError::Loading));
    assert_eq!(host.open_session(&session, None).await, Err(HostError::Loading));
    closing.abort();
    let _ = closing.await;
    assert!(host.set_mode(&session, "code", None).await.is_err());
    eventually(|| !host.state().sessions.contains_key(&session), "owned close completed").await;
    assert!(host
        .state()
        .transcript_ref(&session)
        .expect("transcript")
        .turns
        .is_empty());
    host.stop().await;
}

#[tokio::test]
async fn failed_close_stays_read_only_and_does_not_touch_another_session() {
    let (host, session, identity, cwd) = fixture(&["--fail-close"]).await;
    let other = host
        .new_session(&cwd.path().to_string_lossy(), None)
        .await
        .expect("other");
    assert!(matches!(host.release_session(&session, &identity).await, Err(HostError::Agent(_))));
    assert_eq!(host.prompt(&session, "must not send", &[], None).await, Err(HostError::Loading));
    assert_eq!(host.set_mode(&session, "code", None).await, Err(HostError::Loading));
    assert_eq!(
        host.set_config_option(&session, "model", "large-2", None)
            .await,
        Err(HostError::Loading)
    );
    assert!(host.state().sessions[&session].releasing);
    let other = other["sessionId"].as_str().expect("id");
    let turn = host
        .prompt(other, "hello", &[], None)
        .await
        .expect("other usable");
    eventually(|| outcome(&host, other, &turn).is_some(), "other replied").await;
    assert!(matches!(host.release_session(&session, &identity).await, Err(HostError::Agent(_))));
    host.stop().await;
}

#[tokio::test]
async fn gateway_requires_both_identity_fields_before_release() {
    use crate::acp::{api, ClientError, GatewayClient};
    let (host, session, identity, _cwd) = fixture(&[]).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("listener");
    let origin = format!("http://{}", listener.local_addr().expect("address"));
    let server = tokio::spawn(api::serve(listener, host.clone()));
    let response = reqwest::Client::new()
        .post(format!("{origin}/acp/v1/sessions/release"))
        .json(&json!({"sessionId":session}))
        .send()
        .await
        .expect("missing identity");
    assert!(response.status().is_client_error());
    assert!(!host.state().sessions[&session].pending);
    let client = GatewayClient::new(&origin).expect("client");
    let other = Identity {
        host_id: Some("replacement".into()),
        ..identity.clone()
    };
    assert!(matches!(client.release_session(&session, &other).await,
        Err(ClientError::Host { status:409, code, .. }) if code == "stale_host"));
    assert!(!host.state().sessions[&session].pending);
    let view = client
        .session_control(&session, &identity)
        .await
        .expect("control");
    assert_eq!(view.status, "owned");
    assert!(view.can_continue);
    assert!(!view.can_acquire);
    let continued = client
        .open_session(&session, Some(&identity))
        .await
        .expect("continue");
    assert_eq!(continued["sessionId"], session);
    assert_eq!(continued["hostId"], host.host_id());
    assert_eq!(continued["generation"], identity.generation.expect("generation"));
    assert!(matches!(client.session_control(&session, &other).await,
        Err(ClientError::Host { status:409, code, .. }) if code == "stale_host"));
    let released = client
        .release_session(&session, &identity)
        .await
        .expect("release");
    assert_eq!(released["sessionId"], session);
    assert_eq!(released["hostId"], host.host_id());
    assert_eq!(released["released"], true);
    host.stop().await;
    server.abort();
    let _ = server.await;
}
