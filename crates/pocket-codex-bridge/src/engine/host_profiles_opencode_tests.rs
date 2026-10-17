use pocket_codex_core::provider::{ProviderEndpoint, Secret};

use super::*;
use crate::engine::host_profiles::{
    get_in, resolve_in, save_in, stage_in, Change, KeyChange, ProfileInput, Runtime, RuntimeChange,
};

pub(super) fn resolved(protocol: ApiProtocol) -> Resolved {
    Resolved {
        source: Source::Custom,
        endpoint: Some(ProviderEndpoint {
            protocol,
            base_url: "https://model.example/v1".into(),
            model: Some("vendor/model".into()),
            key: Some(Secret::new("sk-private")),
        }),
        authority: Some("first-authority".into()),
        ..Resolved::inherited()
    }
}

fn config(resolved: &Resolved, inherited: Option<&str>) -> Value {
    let env =
        environment(resolved, "my-host", inherited.map(OsStr::new)).expect("native environment");
    assert_eq!(env.len(), 1, "no HOME, auth or database redirection");
    assert_eq!(env[0].0, "OPENCODE_CONFIG_CONTENT");
    serde_json::from_str(env[0].1.to_str().expect("UTF-8")).expect("config")
}

#[test]
fn native_protocols_use_distinct_bundled_sdks_and_exact_model_routing() {
    for (protocol, npm) in [
        (ApiProtocol::Responses, "@ai-sdk/openai"),
        (ApiProtocol::AnthropicMessages, "@ai-sdk/anthropic"),
        (ApiProtocol::ChatCompletions, "@ai-sdk/openai-compatible"),
    ] {
        let resolved = resolved(protocol);
        let value = config(&resolved, None);
        let id = "pocket-my-host-first-authority";
        assert_eq!(value["enabled_providers"], json!([id]));
        assert_eq!(value["model"], format!("{id}/vendor/model"));
        assert_eq!(value["small_model"], value["model"]);
        let provider = &value["provider"][id];
        assert_eq!(provider["npm"], npm);
        assert_eq!(
            provider["options"],
            json!({
                "baseURL":"https://model.example/v1", "apiKey":"sk-private"
            })
        );
        assert_eq!(provider["env"], json!([]));
        assert_eq!(provider["models"], json!({"vendor/model":{"name":"vendor/model"}}));
        assert!(!format!("{resolved:?}").contains("sk-private"));
    }
}

#[test]
fn existing_native_config_and_substitutions_survive_the_child_override() {
    let inherited = r#"{
      // User policy and provider configuration must survive.
      "permission":{"bash":"ask"}, "instructions":["RULES.md"],
      "provider":{"anthropic":{"options":{"apiKey":"{env:OLD_KEY}"}}},
      "model":"old/model", "small_model":"old/small", "enabled_providers":["old"],
    }"#;
    let value = config(&resolved(ApiProtocol::Responses), Some(inherited));
    assert_eq!(value["permission"], json!({"bash":"ask"}));
    assert_eq!(value["instructions"], json!(["RULES.md"]));
    assert_eq!(value["provider"]["anthropic"]["options"]["apiKey"], "{env:OLD_KEY}");
    assert_eq!(value["enabled_providers"], json!(["pocket-my-host-first-authority"]));
    assert!(environment(&Resolved::inherited(), "my-host", Some(OsStr::new("untouched")))
        .expect("inherited does not parse or replace native env")
        .is_empty());
}

#[test]
fn malformed_config_and_missing_or_expandable_values_fail_without_echoing_secrets() {
    let mut route = resolved(ApiProtocol::Responses);
    for text in ["{private-secret", "[]", "{provider: false}"] {
        let error = environment(&route, "my-host", Some(OsStr::new(text))).expect_err("invalid");
        assert!(!format!("{error:#}").contains("private-secret"));
    }
    for field in ["key", "model", "url"] {
        let mut bad = route.clone();
        let endpoint = bad.endpoint.as_mut().expect("endpoint");
        match field {
            "key" => endpoint.key = Some(Secret::new("{file:/private-secret}")),
            "model" => endpoint.model = Some("{env:private-secret}".into()),
            _ => endpoint.base_url = "https://${private-secret}/v1".into(),
        }
        let error = environment(&bad, "my-host", None).expect_err("substitution refused");
        assert!(!format!("{error:#}").contains("private-secret"));
    }
    route.endpoint.as_mut().expect("endpoint").key = None;
    assert!(environment(&route, "my-host", None).is_err());
    route.endpoint.as_mut().expect("endpoint").model = None;
    assert!(environment(&route, "my-host", None).is_err());
}

fn change(protocol: ApiProtocol, model: Option<&str>, key: KeyChange) -> Change {
    Change {
        input: ProfileInput {
            source: Source::Custom,
            protocol: Some(protocol),
            base_url: Some("https://model.example/v1".into()),
            model: model.map(str::to_string),
            claude_env: None,
        },
        key,
        runtime: RuntimeChange::Set(Runtime::OpenCode {
            binary: None,
            separate_history: false,
        }),
    }
}

#[test]
fn native_profiles_validate_before_save_and_rollback_to_the_exact_previous_route() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let engine = Engine::OpenCode;
    let mut update =
        change(ApiProtocol::Responses, None, KeyChange::Replace(Secret::new("key-one")));
    assert!(save_in(root, "host", &update, Some(0), engine).is_err());
    assert_eq!(get_in(root, "host").expect("get").revision, 0);
    update.input.model = Some("model-one".into());
    update.key = KeyChange::Keep;
    assert!(save_in(root, "host", &update, Some(0), engine).is_err());
    update.key = KeyChange::Replace(Secret::new("key-one"));
    let first = save_in(root, "host", &update, Some(0), engine).expect("save");
    let original = resolve_in(root, "host").expect("resolve");
    update.key = KeyChange::Keep;
    let kept = save_in(root, "host", &update, Some(first.revision), engine).expect("keep");
    assert_eq!(resolve_in(root, "host").expect("resolve").authority, original.authority);
    let failed = change(
        ApiProtocol::AnthropicMessages,
        Some("model-two"),
        KeyChange::Replace(Secret::new("key-two")),
    );
    let (_, staged) = stage_in(root, "host", &failed, Some(kept.revision), engine).expect("stage");
    let next = resolve_in(root, "host").expect("resolve");
    assert_ne!(next.authority, original.authority);
    staged.rollback().expect("rollback");
    let restored = resolve_in(root, "host").expect("resolve");
    assert_eq!(config(&restored, None), config(&original, None));
    update.key = KeyChange::Remove;
    assert!(save_in(root, "host", &update, None, engine).is_err());
    assert_eq!(resolve_in(root, "host").expect("unchanged").endpoint, original.endpoint);
}
