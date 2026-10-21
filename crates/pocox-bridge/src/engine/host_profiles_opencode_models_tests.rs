use pocox_core::provider::Secret;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinHandle,
};

use super::*;

async fn fixture(responses: Vec<String>) -> (String, JoinHandle<Vec<String>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let url = format!("http://{}/nested/v1", listener.local_addr().expect("address"));
    let task = tokio::spawn(async move {
        let mut requests = Vec::new();
        for response in responses {
            let (mut socket, _) = listener.accept().await.expect("accept");
            let mut bytes = Vec::new();
            while !bytes.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                socket.read_exact(&mut byte).await.expect("request");
                bytes.extend(byte);
                assert!(bytes.len() < 8192);
            }
            requests.push(String::from_utf8(bytes).expect("ASCII request"));
            socket
                .write_all(response.as_bytes())
                .await
                .expect("response");
        }
        requests
    });
    (url, task)
}

fn response(body: Value) -> String {
    let body = body.to_string();
    format!(
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: \
         close\r\n\r\n{body}",
        body.len()
    )
}

fn endpoint(url: String, protocol: ApiProtocol) -> ProviderEndpoint {
    ProviderEndpoint {
        protocol,
        base_url: url,
        model: Some("manual-alias".into()),
        key: Some(Secret::new("fixture-secret")),
    }
}

#[tokio::test]
async fn anthropic_pages_use_same_origin_key_and_preserve_all_model_ids() {
    let (url, server) = fixture(vec![
        response(json!({"data":[{"id":"vendor/first","display_name":"First","options":{"apiKey":"untrusted"}}],"has_more":true,"last_id":"vendor/first"})),
        response(json!({"data":[{"id":"second","display_name":"Second"},{"id":"retired","lifecycle":"retired"}],"has_more":false})),
    ]).await;
    let route = endpoint(url, ApiProtocol::AnthropicMessages);
    let models = discover(&route).await.expect("complete catalog");
    assert_eq!(
        models,
        serde_json::from_value::<Map<String, Value>>(
            json!({"vendor/first":{"name":"First"},"second":{"name":"Second"}})
        )
        .expect("map")
    );
    let requests = server.await.expect("server");
    assert!(requests[0].starts_with("GET /nested/v1/models?limit=1000 HTTP/1.1"));
    assert!(requests[1].contains("after_id=vendor%2Ffirst"));
    for request in requests {
        assert!(request.contains("x-api-key: fixture-secret\r\n"));
        assert!(request.contains("anthropic-version: 2023-06-01\r\n"));
        assert!(!request.contains("authorization:"));
    }
    let mut resolved = super::super::tests::resolved(ApiProtocol::AnthropicMessages);
    resolved.endpoint = Some(route);
    let env = super::super::environment_with_models(&resolved, "native", None, models)
        .expect("environment");
    let config: Value = serde_json::from_str(env[0].1.to_str().expect("UTF8")).expect("json");
    let provider = &config["provider"]["pocox-native-first-authority"];
    assert_eq!(provider["models"].as_object().expect("models").len(), 3);
    assert_eq!(provider["models"]["manual-alias"]["name"], "manual-alias");
    assert_eq!(config["model"], "pocox-native-first-authority/manual-alias");
}

#[tokio::test]
async fn openai_protocols_use_bearer_and_exact_prefixed_models_route() {
    for protocol in [ApiProtocol::Responses, ApiProtocol::ChatCompletions] {
        let (url, server) = fixture(vec![response(
            json!({"object":"list","data":[{"id":"model-a"},{"id":"model-b"}]}),
        )])
        .await;
        let models = discover(&endpoint(url, protocol)).await.expect("catalog");
        assert_eq!(models.len(), 2);
        let request = &server.await.expect("server")[0];
        assert!(request.starts_with("GET /nested/v1/models HTTP/1.1"));
        assert!(request.contains("authorization: Bearer fixture-secret\r\n"));
        assert!(!request.contains("x-api-key"));
    }
}

#[tokio::test]
async fn discovery_never_follows_redirects_or_exposes_response_bodies() {
    let destination = TcpListener::bind("127.0.0.1:0").await.expect("destination");
    let (url, server) = fixture(vec![format!(
        "HTTP/1.1 302 Found\r\nLocation: http://{}/private\r\nContent-Length: 14\r\nConnection: \
         close\r\n\r\nfixture-secret",
        destination.local_addr().expect("addr")
    )])
    .await;
    let error = discover(&endpoint(url.clone(), ApiProtocol::Responses))
        .await
        .expect_err("no redirect")
        .to_string();
    assert!(error.contains("HTTP 302"));
    assert!(!error.contains("fixture-secret") && !error.contains(&url));
    server.await.expect("server");
    assert!(tokio::time::timeout(Duration::from_millis(30), destination.accept())
        .await
        .is_err());
}

#[tokio::test]
async fn bad_catalog_is_explicit_default_only_fallback_without_secret_leaks() {
    let (url, server) = fixture(vec!["HTTP/1.1 401 Unauthorized\r\nContent-Length: \
                                      14\r\nConnection: close\r\n\r\nfixture-secret"
        .into()])
    .await;
    let mut resolved = super::super::tests::resolved(ApiProtocol::Responses);
    resolved.endpoint = Some(endpoint(url.clone(), ApiProtocol::Responses));
    let (env, problem) = super::super::discover_environment(&resolved, "native", None)
        .await
        .expect("default remains usable");
    let config: Value = serde_json::from_str(env[0].1.to_str().expect("UTF8")).expect("json");
    assert_eq!(
        config["provider"]["pocox-native-first-authority"]["models"]
            .as_object()
            .expect("models")
            .len(),
        1
    );
    let problem = problem.expect("visible failure");
    assert!(problem.contains("HTTP 401") && problem.contains("Only the configured default"));
    assert!(!problem.contains("fixture-secret") && !problem.contains(&url));
    server.await.expect("server");
}

#[tokio::test]
async fn invalid_injected_and_oversized_catalogs_are_rejected() {
    let bodies = [
        json!({"data":[{"id":"{file:/private}"}]}),
        json!({"data":[{"id":"${SECRET}"}]}),
        json!({"data":[{"id":"line\nbreak"}]}),
        json!({"data":[]}),
        json!({"data":[{"id":"a"}],"has_more":true}),
    ];
    for body in bodies {
        let (url, server) = fixture(vec![response(body)]).await;
        assert!(discover(&endpoint(url, ApiProtocol::Responses))
            .await
            .is_err());
        server.await.expect("server");
    }
    let body =
        json!({"data":(0..=MAX_MODELS).map(|i|json!({"id":format!("m{i}")})).collect::<Vec<_>>()});
    let (url, server) = fixture(vec![response(body)]).await;
    assert!(discover(&endpoint(url, ApiProtocol::Responses))
        .await
        .expect_err("limit")
        .to_string()
        .contains("model limit"));
    server.await.expect("server");
    let (url, server) = fixture(vec![format!(
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        MAX_BYTES + 1
    )])
    .await;
    assert!(discover(&endpoint(url, ApiProtocol::Responses))
        .await
        .expect_err("limit")
        .to_string()
        .contains("byte limit"));
    server.await.expect("server");
}

#[tokio::test]
async fn repeated_pagination_is_rejected_instead_of_returning_partial_catalog() {
    let page = response(json!({"data":[{"id":"same"}],"has_more":true,"last_id":"same"}));
    let (url, server) = fixture(vec![page.clone(), page]).await;
    assert!(discover(&endpoint(url, ApiProtocol::AnthropicMessages))
        .await
        .expect_err("loop")
        .to_string()
        .contains("repeated a page"));
    server.await.expect("server");
}
