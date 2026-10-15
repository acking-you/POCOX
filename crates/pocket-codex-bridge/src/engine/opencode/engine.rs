//! Native implementation of the shared session operation boundary.

use serde_json::Value;

use super::{
    super::{
        app_session::{
            ModelInfo, OlderPage, ThreadHistory, ThreadItem, ThreadMeta, ThreadRuntimeConfig,
            TurnItemsPage,
        },
        session_engine::{
            Capabilities, Protocol, SessionEngine, StartOptions, Supplement, TurnOptions,
        },
    },
    *,
};

/// External OpenCode HTTP/SSE engine, independent of ACP.
pub struct OpenCodeEngine;

impl SessionEngine for OpenCodeEngine {
    fn protocol(&self) -> Protocol {
        Protocol::OpenCode
    }
    fn connect(&self, service: String, port: u16) -> Result<()> {
        connect(&service, port, &transport::resolve_owned_blocking()?)
    }
    fn is_connected(&self, service: &str) -> bool {
        is_connected(service)
    }
    fn disconnect(&self, service: &str) {
        disconnect(service);
    }
    fn probe_reason(&self, service: String) -> Result<Option<String>> {
        Ok(probe_reason(&service, &transport::resolve_owned_blocking()?))
    }
    fn subscribe_events(&self, service: &str) -> Result<broadcast::Receiver<AppEvent>> {
        Ok(conn(service)?.tx.subscribe())
    }
    fn capabilities(&self, service: &str) -> Capabilities {
        let mut caps = Capabilities {
            provider: "opencode".into(),
            provider_name: "OpenCode".into(),
            profile_id: "opencode".into(),
            protocol: Protocol::OpenCode.id().into(),
            session_reopen: "native".into(),
            session_list: "native".into(),
            history_scope: "full".into(),
            running_inventory: "engine".into(),
            ..Capabilities::default()
        };
        let Ok(link) = conn(service) else { return caps };
        let view = lock(&link.shared);
        if !view.healthy {
            return caps;
        }
        caps.generation = view.info.identity.generation;
        caps.negotiated = true;
        caps.external_writer_monitor = true;
        caps.local_sessions = true;
        caps.image_input = view.image_input;
        caps.steer = true;
        caps.rename = true;
        caps.model_catalog = true;
        caps.session_config = true;
        caps.permission_options = true;
        caps.commands = true;
        caps.draft_options = true;
        caps.question_multiple = true;
        caps
    }
    fn thread_list(&self, service: &str) -> Result<Vec<ThreadMeta>> {
        let link = conn(service)?;
        let identity = link.identity();
        let sessions = block(link.client.sessions(None, &identity))?;
        link.commit(&identity, |_| ())?;
        Ok(sessions
            .into_iter()
            .filter(|s| s.time.archived.is_none())
            .map(|s| ThreadMeta {
                id: s.id,
                preview: s.title.clone(),
                name: Some(s.title),
                thread_source: None,
                parent_thread_id: s.parent_id,
                cwd: s.directory,
                updated_at: i64::try_from(s.time.updated / 1000).unwrap_or(i64::MAX),
            })
            .collect())
    }
    fn model_list(&self, service: &str) -> Result<Vec<ModelInfo>> {
        models_for_project(service, None)
    }
    fn thread_start(&self, service: &str, options: StartOptions) -> Result<String> {
        ops::start(service, options)
    }
    fn thread_resume(&self, service: &str, session: &str) -> Result<()> {
        open(service, session).map(|_| ())
    }
    fn thread_read(&self, service: &str, session: &str, _: bool) -> Result<ThreadHistory> {
        ops::read(service, session)
    }
    fn thread_older_page(&self, service: &str, session: &str) -> Result<OlderPage> {
        ops::older(service, session)
    }
    fn thread_turn_page(
        &self,
        service: &str,
        session: &str,
        turn: &str,
        more: bool,
        delta: bool,
    ) -> Result<TurnItemsPage> {
        paging::read(service, session, turn, more, delta)
    }
    fn thread_turn_items(
        &self,
        service: &str,
        session: &str,
        turn: &str,
    ) -> Result<Vec<ThreadItem>> {
        paging::read(service, session, turn, false, false).map(|p| p.items)
    }
    fn thread_runtime_config(&self, service: &str, session: &str) -> Option<ThreadRuntimeConfig> {
        let link = conn(service).ok()?;
        let view = lock(&link.shared);
        let snapshot = view.sessions.get(session)?;
        Some(ThreadRuntimeConfig {
            model: snapshot.options.model.clone(),
            ..ThreadRuntimeConfig::default()
        })
    }
    fn turn_start(&self, service: &str, session: &str, options: TurnOptions) -> Result<()> {
        ops::prompt(service, session, options)
    }
    fn turn_steer(
        &self,
        service: &str,
        session: &str,
        turn: Option<&str>,
        text: &str,
        images: &[String],
    ) -> Result<String> {
        match ops::supplement(service, session, turn, text, images)? {
            Supplement::Injected(turn) => Ok(turn),
            Supplement::PromptRequired => bail!("there is no running OpenCode turn"),
        }
    }
    fn turn_supplement(
        &self,
        service: &str,
        session: &str,
        turn: Option<&str>,
        text: &str,
        images: &[String],
    ) -> Result<Supplement> {
        ops::supplement(service, session, turn, text, images)
    }
    fn turn_interrupt(&self, service: &str, session: &str, turn: Option<String>) -> Result<()> {
        ops::cancel(service, session, turn)
    }
    fn respond_approval(&self, service: &str, id: &str, decision: &str) -> Result<()> {
        ops::answer(service, id, Some(decision), None)
    }
    fn respond_user_input(&self, service: &str, id: &str, answers: &str) -> Result<()> {
        ops::answer(service, id, None, Some(answers))
    }
    fn set_thread_name(&self, service: &str, session: &str, name: &str) -> Result<()> {
        let link = conn(service)?;
        let identity = link.identity();
        block(link.client.rename(session, name, &identity))?;
        link.commit(&identity, |_| ())
    }
    fn running_threads(&self, service: &str) -> Result<Vec<String>> {
        let link = conn(service)?;
        let identity = link.identity();
        let running = block(link.client.running(&identity))?;
        link.commit(&identity, |_| ())?;
        Ok(running)
    }
    fn session_settings(&self, service: &str, session: &str) -> Option<Value> {
        refresh_settings(service, session).ok()
    }
    fn set_session_config(
        &self,
        service: &str,
        session: &str,
        id: &str,
        value: &str,
    ) -> Result<()> {
        settings::set(service, session, id, value)
    }
}

/// Read the native model catalog in a draft or session's project scope.
pub fn models_for_project(service: &str, directory: Option<&str>) -> Result<Vec<ModelInfo>> {
    Ok(super::catalog(service, directory)?
        .models
        .into_iter()
        .map(|model| ModelInfo {
            id: model.key(),
            display_name: model.name,
            description: model.provider_name,
            supported_reasoning_efforts: vec![],
            default_reasoning_effort: None,
            supported_service_tiers: vec![],
            default_service_tier: None,
            is_default: false,
        })
        .collect())
}
