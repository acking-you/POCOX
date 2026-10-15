//! Closed native mutation surface. Options are per session, never global
//! configuration, and all provider selections come from the native catalog.

use std::sync::atomic::{AtomicU64, Ordering};

use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::{Catalog, Entry, Error, Host, Identity, Session, SessionAccess, Status};
use crate::opencode::{
    client::ClientError,
    schema::{Message, Prompt},
};

/// Selections for the next native prompt; absent values inherit OpenCode's
/// own configuration. Changing them never changes shared provider defaults.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Options {
    /// Exact `provider/model` catalog key.
    pub model: Option<String>,
    /// Exact native primary agent name.
    pub agent: Option<String>,
    /// Exact variant advertised for the selected model.
    pub variant: Option<String>,
}

impl Options {
    pub(super) fn restore(messages: &[Message]) -> Self {
        let Some(info) = messages
            .iter()
            .rev()
            .find(|m| m.info["role"] == "user")
            .map(|m| &m.info)
        else {
            return Self::default();
        };
        Self {
            model: info["model"]["providerID"]
                .as_str()
                .zip(info["model"]["modelID"].as_str())
                .map(|(provider, model)| format!("{provider}/{model}")),
            agent: info["agent"].as_str().map(str::to_owned),
            variant: info["variant"]
                .as_str()
                .or_else(|| info["model"]["variant"].as_str())
                .map(str::to_owned),
        }
    }

    fn validate(&self, catalog: &Catalog) -> Result<(), Error> {
        let model = self.model.as_deref().and_then(|key| catalog.model(key));
        if self.model.is_some() && model.is_none()
            || self
                .agent
                .as_ref()
                .is_some_and(|name| !catalog.agents.iter().any(|a| &a.name == name))
            || self
                .variant
                .as_ref()
                .is_some_and(|variant| !model.is_some_and(|m| m.variants.contains(variant)))
        {
            return Err(Error::InvalidInput);
        }
        Ok(())
    }
}

/// Text and inline image input; file paths and arbitrary native parts are not
/// accepted by the relay-facing gateway.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Input {
    /// User's prompt or known slash command.
    pub text: String,
    /// Explicit inline image data URLs.
    pub images: Vec<String>,
}

impl Input {
    fn parts(&self) -> Result<Vec<Value>, Error> {
        if self.text.len() > 1024 * 1024
            || self.images.len() > 16
            || self.text.trim().is_empty() && self.images.is_empty()
            || self.images.iter().map(String::len).sum::<usize>() > 40 * 1024 * 1024
        {
            return Err(Error::InvalidInput);
        }
        let mut parts = vec![];
        if !self.text.is_empty() {
            parts.push(json!({"type":"text","text":self.text}));
        }
        for image in &self.images {
            let mime = ["image/png", "image/jpeg", "image/webp", "image/gif"]
                .into_iter()
                .find(|mime| image.starts_with(&format!("data:{mime};base64,")))
                .ok_or(Error::InvalidInput)?;
            parts.push(json!({"type":"file","mime":mime,"url":image}));
        }
        Ok(parts)
    }
}

impl Host {
    async fn admitted(&self, session: &str, identity: &Identity) -> Result<Session, Error> {
        self.writable_source(identity).await?;
        let entries = self.0.sessions.lock().await;
        if !entries.get(session).is_some_and(|entry| !entry.released) {
            return Err(Error::ReadOnly);
        }
        drop(entries);
        self.session(session).await
    }

    /// Create an original native session under the selected existing project.
    /// Draft choices are validated and retained before the first prompt.
    pub async fn create(
        &self,
        directory: &str,
        options: Options,
        identity: &Identity,
    ) -> Result<Session, Error> {
        let _guard = self.0.mutation.lock().await;
        if directory.len() > 16 * 1024 || !std::path::Path::new(directory).is_absolute() {
            return Err(Error::InvalidInput);
        }
        self.writable_source(identity).await?;
        let catalog = self.catalog(Some(directory)).await?;
        options.validate(&catalog)?;
        self.reserve_session_slot(None).await?;
        self.writable_source(identity).await?;
        let session: Session = self
            .0
            .client
            .mutate(Method::POST, &["session"], Some(directory), &json!({}))
            .await?;
        self.0
            .sessions
            .lock()
            .await
            .insert(session.id.clone(), Entry {
                directory: session.directory.clone(),
                last_used: Some(std::time::Instant::now()),
                options,
                options_pending: true,
                ..Entry::default()
            });
        Ok(session)
    }

    /// Set next-prompt options for this admitted original session only.
    pub async fn set_options(
        &self,
        session: &str,
        options: Options,
        identity: &Identity,
    ) -> Result<Options, Error> {
        let _guard = self.0.mutation.lock().await;
        let session = self.admitted(session, identity).await?;
        options.validate(&self.catalog(Some(&session.directory)).await?)?;
        if let Some(entry) = self.0.sessions.lock().await.get_mut(&session.id) {
            entry.last_used = Some(std::time::Instant::now());
            entry.options = options.clone();
            entry.options_pending = true;
        }
        self.0.live.invalidate(&session.id).await;
        Ok(options)
    }

    /// Relinquish this host's per-session admission while retaining the shared
    /// native server. There is no native per-session close/lease to invent.
    pub async fn release(
        &self,
        session: &str,
        identity: &Identity,
    ) -> Result<SessionAccess, Error> {
        let _guard = self.0.mutation.lock().await;
        let session = self.admitted(session, identity).await?;
        if self.status(&session).await?.running() {
            return Err(Error::Busy);
        }
        {
            let mut entries = self.0.sessions.lock().await;
            let entry = entries.get_mut(&session.id).ok_or(Error::ReadOnly)?;
            if entry.turn.is_some() {
                return Err(Error::Busy);
            }
            entry.released = true;
        }
        self.0.live.invalidate(&session.id).await;
        self.access_to(&session).await
    }

    /// Submit exactly once. An expected turn supplements that same confirmed
    /// native execution; its absence requests a fresh idle turn.
    pub async fn prompt(
        &self,
        session: &str,
        input: Input,
        expected_turn: Option<&str>,
        identity: &Identity,
    ) -> Result<String, Error> {
        let parts = input.parts()?;
        let _guard = self.0.mutation.lock().await;
        let metadata = self.admitted(session, identity).await?;
        let status = self.status(&metadata).await?;
        let options = {
            let entries = self.0.sessions.lock().await;
            let entry = entries.get(session).ok_or(Error::ReadOnly)?;
            if let Some(expected) = expected_turn {
                if !status.running() || entry.turn.as_deref() != Some(expected) {
                    return Err(Error::TurnChanged);
                }
            } else if status.running() || entry.turn.is_some() || matches!(status, Status::Unknown)
            {
                return Err(Error::Busy);
            }
            entry.options.clone()
        };
        let catalog = self.catalog(Some(&metadata.directory)).await?;
        options.validate(&catalog)?;
        let command = input.text.strip_prefix('/').and_then(|text| {
            let (name, arguments) = text.split_once(char::is_whitespace).unwrap_or((text, ""));
            catalog
                .commands
                .iter()
                .find(|command| command.name == name)
                .map(|_| (name, arguments))
        });
        // Native commands enter their own execution path, not a running turn's
        // prompt supplement path. Plain unknown slash text stays ordinary text.
        if expected_turn.is_some() && command.is_some() {
            return Err(Error::Busy);
        }
        self.writable_source(identity).await?;
        let message_id = message_id();
        let turn = expected_turn.unwrap_or(&message_id).to_owned();
        let sequence = self.0.live.sequence().await;
        if let Some(entry) = self.0.sessions.lock().await.get_mut(session) {
            entry.last_used = Some(std::time::Instant::now());
            if expected_turn.is_none() {
                entry.turn = Some(turn.clone());
                entry.dispatched = sequence;
            }
            entry.operation_error = None;
        }
        if let Some((command, arguments)) = command {
            let body = json!({"messageID":message_id,"command":command,"arguments":arguments,
                "model":options.model,"agent":options.agent,"variant":options.variant,
                "parts":parts.into_iter().filter(|part| part["type"] == "file").collect::<Vec<_>>()});
            self.dispatch_command(session, &metadata.directory, body);
        } else {
            let body = Prompt {
                message_id: Some(message_id),
                model: options
                    .model
                    .as_deref()
                    .and_then(|key| catalog.model(key))
                    .map(|model| model.selection()),
                agent: options.agent,
                variant: options.variant,
                parts,
            };
            let result = self
                .0
                .client
                .mutate::<Value>(
                    Method::POST,
                    &["session", session, "prompt_async"],
                    Some(&metadata.directory),
                    &body,
                )
                .await;
            if let Err(error) = result {
                self.record_failure(session, &error, expected_turn.is_none())
                    .await;
                return Err(error.into());
            }
        }
        if let Some(entry) = self.0.sessions.lock().await.get_mut(session) {
            entry.options_pending = false;
        }
        self.0.live.invalidate(session).await;
        Ok(turn)
    }

    fn dispatch_command(&self, session: &str, directory: &str, body: Value) {
        let weak = std::sync::Arc::downgrade(&self.0);
        let client = self.0.client.clone();
        let stop = self.0.stop.clone();
        let session = session.to_owned();
        let directory = directory.to_owned();
        tokio::spawn(async move {
            // JSON null is not an omitted optional native field.
            let mut body = body;
            if let Some(fields) = body.as_object_mut() {
                fields.retain(|_, value| !value.is_null());
            }
            let result = tokio::select! {
                _ = stop.cancelled() => return,
                result = client.command(&session, &directory, &body) => result,
            };
            if let Some(inner) = weak.upgrade() {
                let host = Host(inner);
                if let Err(error) = result {
                    host.record_failure(&session, &error, true).await;
                }
                host.0.live.invalidate(&session).await;
            }
        });
    }

    async fn record_failure(&self, session: &str, error: &ClientError, new_turn: bool) {
        if let Some(entry) = self.0.sessions.lock().await.get_mut(session) {
            entry.operation_error = Some(error.to_string());
            // A transport failure can follow acceptance. Keep that turn
            // unconfirmed until a native idle transition or explicit abort.
            if new_turn && matches!(error, ClientError::Http(code) if (400..500).contains(code)) {
                entry.turn = None;
            }
        }
        self.0.live.invalidate(session).await;
    }

    /// Abort only the admitted session and exact current host turn.
    pub async fn cancel(
        &self,
        session: &str,
        turn: &str,
        identity: &Identity,
    ) -> Result<bool, Error> {
        let _guard = self.0.mutation.lock().await;
        let metadata = self.admitted(session, identity).await?;
        self.status(&metadata).await?;
        if self
            .0
            .sessions
            .lock()
            .await
            .get(session)
            .and_then(|entry| entry.turn.as_deref())
            != Some(turn)
        {
            return Err(Error::TurnChanged);
        }
        let resolved = abort_execution(&self.0.client, &metadata).await?;
        if resolved {
            if let Some(entry) = self.0.sessions.lock().await.get_mut(session) {
                entry.turn = None;
                entry.operation_error = None;
            }
        }
        self.0.live.invalidate(session).await;
        Ok(resolved)
    }

    /// Rename an admitted original session through the native session route.
    pub async fn rename(
        &self,
        session: &str,
        title: &str,
        identity: &Identity,
    ) -> Result<(), Error> {
        if title.trim().is_empty() || title.len() > 4096 {
            return Err(Error::InvalidInput);
        }
        let _guard = self.0.mutation.lock().await;
        let metadata = self.admitted(session, identity).await?;
        let _: Session = self
            .0
            .client
            .mutate(
                Method::PATCH,
                &["session", session],
                Some(&metadata.directory),
                &json!({"title":title}),
            )
            .await?;
        Ok(())
    }

    /// Answer a freshly verified permission/request belonging to this session.
    /// The closed reply shape cannot modify provider auth or global settings.
    pub async fn answer(
        &self,
        session: &str,
        request: &str,
        answer: Answer,
        identity: &Identity,
    ) -> Result<(), Error> {
        let _guard = self.0.mutation.lock().await;
        let metadata = self.admitted(session, identity).await?;
        let (kind, action, body) = answer.wire()?;
        let pending: Vec<Value> = self
            .0
            .client
            .get(&[kind], Some(&metadata.directory), &[])
            .await?;
        if !pending
            .iter()
            .any(|p| p["id"] == request && p["sessionID"] == session)
        {
            return Err(Error::TurnChanged);
        }
        let _: Value = self
            .0
            .client
            .mutate(Method::POST, &[kind, request, action], Some(&metadata.directory), &body)
            .await?;
        self.0.live.invalidate(session).await;
        Ok(())
    }
}

/// Typed replies accepted by the native gateway.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum Answer {
    /// Native permission response: once, always, or reject.
    Permission {
        /// Exact native response value.
        reply: String,
    },
    /// Ordered answers to native questions, with multiple labels when allowed.
    Question {
        /// One list per native question.
        answers: Vec<Vec<String>>,
    },
    /// Explicitly skip/reject the native question request.
    RejectQuestion,
}

impl Answer {
    fn wire(self) -> Result<(&'static str, &'static str, Value), Error> {
        match self {
            Self::Permission {
                reply,
            } if matches!(reply.as_str(), "once" | "always" | "reject") => {
                Ok(("permission", "reply", json!({"reply":reply})))
            },
            Self::Question {
                answers,
            } if answers.len() <= 64
                && answers
                    .iter()
                    .all(|a| a.len() <= 64 && a.iter().all(|s| s.len() <= 16 * 1024)) =>
            {
                Ok(("question", "reply", json!({"answers":answers})))
            },
            Self::RejectQuestion => Ok(("question", "reject", json!({}))),
            _ => Err(Error::InvalidInput),
        }
    }
}

fn message_id() -> String {
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
        * 4096;
    let previous = LAST
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |last| Some(now.max(last + 1)))
        .unwrap_or_else(|value| value);
    let number = now.max(previous + 1) & 0xffff_ffff_ffff;
    format!("msg_{number:012x}{}", &uuid::Uuid::new_v4().simple().to_string()[..14])
}

async fn abort_execution(client: &super::Client, session: &Session) -> Result<bool, Error> {
    let cancelled = client
        .mutate::<bool>(
            Method::POST,
            &["session", &session.id, "abort"],
            Some(&session.directory),
            &json!({}),
        )
        .await?;
    if cancelled {
        return Ok(true);
    }
    // A false acknowledgement alone says nothing about an uncertain prompt.
    // A fresh idle response after abort is required before permitting Retry.
    let statuses: super::Statuses = client
        .get(&["session", "status"], Some(&session.directory), &[])
        .await?;
    Ok(matches!(statuses.get(&session.id).unwrap_or(&Status::Idle), Status::Idle))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_input_cannot_read_files_or_expand_arbitrary_native_parts() {
        for url in ["file:///etc/passwd", "http://localhost/private", "data:text/html;base64,AA=="]
        {
            assert!(Input {
                text: String::new(),
                images: vec![url.into()]
            }
            .parts()
            .is_err());
        }
        assert!(Input {
            text: String::new(),
            images: vec!["data:image/png;base64,AA==".into()]
        }
        .parts()
        .is_ok());
        let first = message_id();
        let second = message_id();
        assert_eq!(first.len(), 30);
        assert!(first < second);
    }

    #[tokio::test]
    async fn abort_false_resolves_only_with_fresh_positive_idle_evidence() {
        use axum::{
            routing::{get, post},
            Json, Router,
        };
        for (status, expected) in [
            (json!({}), true),
            (json!({"ses_test":{"type":"busy"}}), false),
            (json!({"ses_test":{"type":"future"}}), false),
        ] {
            let router = Router::new()
                .route("/session/ses_test/abort", post(|| async { Json(false) }))
                .route(
                    "/session/status",
                    get(move || {
                        let status = status.clone();
                        async { Json(status) }
                    }),
                );
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
                .await
                .expect("valid test fixture");
            let client = super::super::Client::new(
                &format!("http://{}/", listener.local_addr().expect("valid test fixture")),
                None,
            )
            .expect("valid test fixture");
            let task = tokio::spawn(async move {
                axum::serve(listener, router)
                    .await
                    .expect("valid test fixture");
            });
            let session = serde_json::from_value(json!({"id":"ses_test","title":"Test","directory":"/project","time":{"created":0,"updated":0}})).expect("valid test fixture");
            assert_eq!(
                abort_execution(&client, &session)
                    .await
                    .expect("valid test fixture"),
                expected
            );
            task.abort();
        }
    }
}
