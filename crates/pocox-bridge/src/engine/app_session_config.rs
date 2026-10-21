//! Per-thread runtime configuration (approval policy, sandbox, reviewer and
//! collaboration mode) and the model catalog.

use super::*;

/// The server-reported runtime configuration of a thread: what model /
/// effort / permissions its turns actually run with. All fields are optional
/// because servers of different vintages expose different subsets — absent
/// means "the server didn't say", never a guess.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ThreadRuntimeConfig {
    /// Effective model id (e.g. `gpt-5.5-codex`).
    pub model: Option<String>,
    /// Provider of the effective model (e.g. `openai`).
    pub model_provider: Option<String>,
    /// Effective reasoning effort (`low`/`medium`/`high`/…); `None` = model
    /// default.
    pub reasoning_effort: Option<String>,
    /// Effective approval policy (`untrusted`/`on-failure`/`on-request`/
    /// `never`/`granular`).
    pub approval_policy: Option<String>,
    /// Approval reviewer (`user` or `auto_review`), when reported.
    pub approvals_reviewer: Option<String>,
    /// Effective service tier, when reported.
    pub service_tier: Option<String>,
    /// Effective sandbox mode, normalized to the kebab wire strings the UI
    /// already speaks (`read-only`/`workspace-write`/`danger-full-access`/
    /// `external-sandbox`).
    pub sandbox_mode: Option<String>,
    /// Effective collaboration mode (`plan`/`default`) from a resume response
    /// or a `thread/settings/updated` notification.
    pub collaboration_mode: Option<String>,
    /// True once a live `thread/settings/updated` notification has been seen
    /// for this thread — the strongest confirmation the server applied a
    /// switch (vs. only the snapshot a start/resume response gave us).
    pub confirmed_by_update: bool,
}

/// Parse the runtime config out of a `thread/start` / `thread/resume`
/// response: top-level `model`, `modelProvider`, `reasoningEffort`,
/// `approvalPolicy` and `sandbox` (camelCase, v2 protocol). Absent fields stay
/// `None` so older servers degrade gracefully.
pub(super) fn runtime_config_from_response(res: &Value) -> ThreadRuntimeConfig {
    ThreadRuntimeConfig {
        model: nonempty_str(res.get("model")),
        model_provider: nonempty_str(res.get("modelProvider")),
        reasoning_effort: nonempty_str(res.get("reasoningEffort")),
        approval_policy: parse_approval_policy(res.get("approvalPolicy")),
        approvals_reviewer: parse_reviewer(res.get("approvalsReviewer")),
        service_tier: nonempty_str(res.get("serviceTier")),
        sandbox_mode: parse_sandbox_mode(res.get("sandbox")),
        collaboration_mode: parse_collaboration_mode(res.get("collaborationMode")),
        confirmed_by_update: false,
    }
}

/// Parse the runtime config out of a `thread/settings/updated` notification's
/// `threadSettings` object: `model`, `modelProvider`, `effort`,
/// `approvalPolicy`, `sandboxPolicy` and `collaborationMode`.
pub(super) fn runtime_config_from_settings(settings: &Value) -> ThreadRuntimeConfig {
    ThreadRuntimeConfig {
        model: nonempty_str(settings.get("model")),
        model_provider: nonempty_str(settings.get("modelProvider")),
        reasoning_effort: nonempty_str(settings.get("effort")),
        approval_policy: parse_approval_policy(settings.get("approvalPolicy")),
        approvals_reviewer: parse_reviewer(settings.get("approvalsReviewer")),
        service_tier: nonempty_str(settings.get("serviceTier")),
        sandbox_mode: parse_sandbox_mode(settings.get("sandboxPolicy")),
        collaboration_mode: parse_collaboration_mode(settings.get("collaborationMode")),
        confirmed_by_update: true,
    }
}

fn parse_reviewer(value: Option<&Value>) -> Option<String> {
    nonempty_str(value).map(|reviewer| match reviewer.as_str() {
        "guardian_subagent" => "auto_review".into(),
        _ => reviewer,
    })
}

/// A non-empty string field, else `None`.
pub(super) fn nonempty_str(v: Option<&Value>) -> Option<String> {
    v.and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// An approval policy value: the plain wire string (`never`, `on-request`, …),
/// or the tag of the externally-tagged object form (`{"granular": {…}}` →
/// `granular`).
pub(super) fn parse_approval_policy(v: Option<&Value>) -> Option<String> {
    let v = v?;
    if let Some(s) = v.as_str() {
        return Some(s.to_string()).filter(|s| !s.is_empty());
    }
    v.as_object()?.keys().next().cloned()
}

/// Migrate a legacy approval-policy wire value before sending it to codex.
/// codex removed the `OnFailure` variant — its enum now aliases `on-failure` to
/// `OnRequest`, and the app-server's v2 protocol enum only accepts
/// `untrusted`/`on-request`/`granular`/`never`, rejecting a bare `on-failure`
/// with "unknown variant". A thread persisted (or a UI preset built) before the
/// codex bump can still hand us `on-failure`, so normalize it to `on-request`
/// (codex's own alias target) at the send boundary. Other values pass through.
pub(super) fn normalize_approval_policy(policy: &str) -> &str {
    match policy {
        "on-failure" => "on-request",
        other => other,
    }
}

/// A sandbox policy value, normalized to the kebab strings the UI speaks. The
/// v2 protocol sends a camelCase-tagged object (`{"type": "readOnly", …}`);
/// tolerate a legacy kebab tag or a bare string too, and pass unknown tags
/// through verbatim (forward-compat).
pub(super) fn parse_sandbox_mode(v: Option<&Value>) -> Option<String> {
    let v = v?;
    let tag = v
        .as_str()
        .or_else(|| v.get("type").and_then(Value::as_str))
        .filter(|s| !s.is_empty())?;
    Some(
        match tag {
            "readOnly" => "read-only",
            "workspaceWrite" => "workspace-write",
            "dangerFullAccess" => "danger-full-access",
            "externalSandbox" => "external-sandbox",
            other => other,
        }
        .to_string(),
    )
}

/// A collaboration mode value: the `mode` field of the `{mode, settings}`
/// object (`plan`/`default`), or a bare string.
pub(super) fn parse_collaboration_mode(v: Option<&Value>) -> Option<String> {
    let v = v?;
    v.as_str()
        .or_else(|| v.get("mode").and_then(Value::as_str))
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Update the per-thread runtime config from a live `thread/settings/updated`
/// notification (the full effective snapshot — replace wholesale).
pub(super) fn track_runtime_config(
    configs: &Mutex<HashMap<String, ThreadRuntimeConfig>>,
    inbound: &Inbound,
) {
    if inbound.method != "thread/settings/updated" {
        return;
    }
    let Some(params) = inbound.params.as_ref() else {
        return;
    };
    let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
        return;
    };
    let Some(settings) = params.get("threadSettings") else {
        return;
    };
    configs
        .lock()
        .expect("runtime_config poisoned")
        .insert(thread_id.to_string(), runtime_config_from_settings(settings));
}

/// Record the runtime config a `thread/start` / `thread/resume` response
/// reported for `thread_id` (no-op if the session is gone). Preserve the last
/// collaboration mode only when a legacy response omits it. Explicit nulls
/// clear cached values so changes made by another client aren't served stale.
pub(super) fn record_runtime_config(service_key: &str, thread_id: &str, res: &Value) {
    if let Some(s) = sessions()
        .lock()
        .expect("sessions poisoned")
        .get(service_key)
    {
        let mut cfg = runtime_config_from_response(res);
        let mut map = s.runtime_config.lock().expect("runtime_config poisoned");
        if let Some(prev) = map.get(thread_id) {
            if res.get("collaborationMode").is_none() {
                cfg.collaboration_mode = prev.collaboration_mode.clone();
            }
            cfg.confirmed_by_update = prev.confirmed_by_update;
        }
        map.insert(thread_id.to_string(), cfg);
    }
}

/// The runtime config last seen for `thread_id` (from a start/resume response
/// or a live settings update).
pub fn thread_runtime_config(service_key: &str, thread_id: &str) -> Option<ThreadRuntimeConfig> {
    sessions()
        .lock()
        .expect("sessions poisoned")
        .get(service_key)
        .and_then(|s| {
            s.runtime_config
                .lock()
                .expect("runtime_config poisoned")
                .get(thread_id)
                .cloned()
        })
}

/// List the models the app-server offers (hidden ones filtered out).
pub fn model_list(service_key: &str) -> Result<Vec<ModelInfo>> {
    let client = client_for(service_key)?;
    let res = runtime::runtime().block_on(client.request("model/list", json!({})))?;
    let data = res
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    Ok(data
        .iter()
        .filter(|m| !m.get("hidden").and_then(Value::as_bool).unwrap_or(false))
        .filter_map(|m| {
            let id = m.get("id").and_then(Value::as_str)?.to_string();
            let supported_reasoning_efforts = parse_supported_efforts(m);
            let default_reasoning_effort = m
                .get("defaultReasoningEffort")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            Some(ModelInfo {
                display_name: m
                    .get("displayName")
                    .and_then(Value::as_str)
                    .unwrap_or(&id)
                    .to_string(),
                description: m
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                supported_reasoning_efforts,
                default_reasoning_effort,
                supported_service_tiers: parse_service_tiers(m),
                default_service_tier: nonempty_str(m.get("defaultServiceTier")),
                is_default: m.get("isDefault").and_then(Value::as_bool).unwrap_or(false),
                id,
            })
        })
        .collect())
}

pub(super) fn parse_service_tiers(model: &Value) -> Vec<String> {
    let mut tiers: Vec<String> = model
        .get("serviceTiers")
        .and_then(Value::as_array)
        .map(|tiers| {
            tiers
                .iter()
                .filter_map(|tier| nonempty_str(tier.get("id")))
                .collect()
        })
        .unwrap_or_default();
    // Match ModelPreset::supports_fast_mode for older catalogs too.
    let legacy_fast = model
        .get("additionalSpeedTiers")
        .and_then(Value::as_array)
        .is_some_and(|tiers| tiers.iter().any(|tier| tier.as_str() == Some("fast")));
    if legacy_fast && !tiers.iter().any(|tier| tier == "priority") {
        tiers.push("priority".into());
    }
    tiers
}

/// Pull a model's supported reasoning-effort ids out of
/// `supportedReasoningEfforts`.
///
/// Each entry is a `ReasoningEffortOption` object (`{reasoningEffort,
/// description}`), so read the `reasoningEffort` field; a bare string is also
/// accepted in case an older server sends the legacy shape. An empty / absent
/// list yields `vec![]`, which the UI reads as "offer all known levels".
pub(super) fn parse_supported_efforts(model: &Value) -> Vec<String> {
    model
        .get("supportedReasoningEfforts")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|v| {
                    v.get("reasoningEffort")
                        .and_then(Value::as_str)
                        .or_else(|| v.as_str())
                        .map(str::to_string)
                })
                .collect()
        })
        .unwrap_or_default()
}

pub(super) fn insert_execution_options(
    params: &mut serde_json::Map<String, Value>,
    reviewer: Option<String>,
    tier: Option<String>,
) -> Result<()> {
    if let Some(reviewer) = reviewer {
        anyhow::ensure!(
            matches!(reviewer.as_str(), "user" | "auto_review"),
            "unsupported approvals reviewer"
        );
        params.insert("approvalsReviewer".into(), json!(reviewer));
    }
    if let Some(tier) = tier {
        params.insert("serviceTier".into(), json!(tier));
    }
    Ok(())
}

// New servers expose these fields on Thread itself. Presence, including null,
// takes precedence over cached start/resume values; older servers omit them.
pub(super) fn runtime_config_with_thread(
    mut cached: ThreadRuntimeConfig,
    thread: Option<&Value>,
) -> ThreadRuntimeConfig {
    if let Some(thread) = thread {
        if let Some(model) = thread.get("model") {
            cached.model = nonempty_str(Some(model));
        }
        if let Some(effort) = thread.get("reasoningEffort") {
            cached.reasoning_effort = nonempty_str(Some(effort));
        }
        if let Some(provider) = thread.get("modelProvider") {
            cached.model_provider = nonempty_str(Some(provider));
        }
    }
    cached
}
