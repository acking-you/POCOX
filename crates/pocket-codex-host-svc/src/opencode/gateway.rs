//! Typed controller client for the restricted Pocket native gateway.

use reqwest::Method;
use serde_json::{json, Value};

use super::{
    catalog::Catalog,
    client::ClientError,
    events::EventStream,
    host::{Answer, Identity, Info, Input, Options, ReadResult, Snapshot},
    http::{Http, Pocket},
    schema::Session,
    wire::Dialect,
};
use crate::session_access::SessionAccess;

/// Controller transport over a resolved loopback or relay endpoint. This
/// client never receives or forwards the native server's private password.
#[derive(Clone)]
pub struct Gateway(Http<Pocket>);

impl Gateway {
    /// Use an already resolved loopback gateway endpoint.
    pub fn new(origin: &str) -> Result<Self, ClientError> {
        Ok(Self(Http::new(origin, None)?))
    }

    /// Verify the protocol before allowing any session operation.
    pub async fn info(&self) -> Result<Info, ClientError> {
        let info: Info = self.0.get(&["opencode", "v1", "info"], None, &[]).await?;
        if info.api != 1 || info.protocol != "opencode-http" {
            return Err(ClientError::InvalidResponse);
        }
        Ok(info)
    }

    async fn read<T: serde::de::DeserializeOwned>(
        &self,
        route: &str,
        directory: Option<&str>,
        identity: &Identity,
    ) -> Result<T, ClientError> {
        let read: ReadResult<T> = self
            .0
            .get(&["opencode", "v1", route], directory, &[])
            .await?;
        if &read.identity != identity {
            return Err(ClientError::Gateway {
                status: 409,
                code: "stale_host".into(),
            });
        }
        Ok(read.data)
    }

    /// Public native model, agent and command catalog for a project.
    pub async fn catalog(
        &self,
        directory: Option<&str>,
        identity: &Identity,
    ) -> Result<Catalog, ClientError> {
        self.read("catalog", directory, identity).await
    }

    /// Bounded original session inventory across all native projects.
    pub async fn sessions(
        &self,
        directory: Option<&str>,
        identity: &Identity,
    ) -> Result<Vec<Session>, ClientError> {
        self.read("sessions", directory, identity).await
    }

    /// Fresh native running inventory of the projects admitted by this host.
    pub async fn running(&self, identity: &Identity) -> Result<Vec<String>, ClientError> {
        self.read("running", None, identity).await
    }

    /// History, live overlay, pending requests and current admission.
    pub async fn snapshot(
        &self,
        session: &str,
        before: Option<&str>,
    ) -> Result<Snapshot, ClientError> {
        let mut query = vec![("sessionId", session)];
        if let Some(before) = before {
            query.push(("before", before));
        }
        self.0
            .get(&["opencode", "v1", "snapshot"], None, &query)
            .await
    }

    /// Inspect admission without loading a writer.
    pub async fn access(&self, session: &str) -> Result<SessionAccess, ClientError> {
        self.0
            .get(&["opencode", "v1", "access"], None, &[("sessionId", session)])
            .await
    }

    /// Safely open the exact original ID or return a follow-only view.
    pub async fn open(&self, session: &str, identity: &Identity) -> Result<Snapshot, ClientError> {
        self.0
            .mutate(
                Method::POST,
                &["opencode", "v1", "open"],
                None,
                &json!({"identity":identity,"sessionId":session}),
            )
            .await
    }

    /// Create on first send with validated draft-local choices.
    pub async fn create(
        &self,
        directory: &str,
        options: &Options,
        identity: &Identity,
    ) -> Result<Session, ClientError> {
        self.0
            .mutate(
                Method::POST,
                &["opencode", "v1", "create"],
                None,
                &json!({"identity":identity,"directory":directory,"options":options}),
            )
            .await
    }

    /// Relinquish this session's admission without stopping the shared server.
    pub async fn release(
        &self,
        session: &str,
        identity: &Identity,
    ) -> Result<SessionAccess, ClientError> {
        self.0
            .mutate(
                Method::POST,
                &["opencode", "v1", "release"],
                None,
                &json!({"identity":identity,"sessionId":session}),
            )
            .await
    }

    /// Set this session's next-prompt native choices.
    pub async fn options(
        &self,
        session: &str,
        options: &Options,
        identity: &Identity,
    ) -> Result<Options, ClientError> {
        self.0
            .mutate(
                Method::POST,
                &["opencode", "v1", "options"],
                None,
                &json!({"identity":identity,"sessionId":session,"options":options}),
            )
            .await
    }

    /// Send exactly once; transport failures never trigger an automatic retry.
    pub async fn prompt(
        &self,
        session: &str,
        input: &Input,
        expected_turn: Option<&str>,
        identity: &Identity,
    ) -> Result<String, ClientError> {
        let body: Value = self.0.mutate(Method::POST, &["opencode", "v1", "prompt"], None,
            &json!({"identity":identity,"sessionId":session,"input":input,"expectedTurn":expected_turn})).await?;
        body["turnId"]
            .as_str()
            .map(str::to_owned)
            .ok_or(ClientError::InvalidResponse)
    }

    /// Cancel the exact current original session turn.
    pub async fn cancel(
        &self,
        session: &str,
        turn: &str,
        identity: &Identity,
    ) -> Result<bool, ClientError> {
        let body: Value = self
            .0
            .mutate(
                Method::POST,
                &["opencode", "v1", "cancel"],
                None,
                &json!({"identity":identity,"sessionId":session,"turnId":turn}),
            )
            .await?;
        body["cancelled"]
            .as_bool()
            .ok_or(ClientError::InvalidResponse)
    }

    /// Rename an admitted original session.
    pub async fn rename(
        &self,
        session: &str,
        title: &str,
        identity: &Identity,
    ) -> Result<(), ClientError> {
        let _: Value = self
            .0
            .mutate(
                Method::POST,
                &["opencode", "v1", "rename"],
                None,
                &json!({"identity":identity,"sessionId":session,"title":title}),
            )
            .await?;
        Ok(())
    }

    /// Answer a fresh pending request belonging to this original session.
    pub async fn answer(
        &self,
        session: &str,
        request: &str,
        answer: &Answer,
        identity: &Identity,
    ) -> Result<(), ClientError> {
        let _: Value = self.0.mutate(Method::POST, &["opencode", "v1", "answer"], None,
            &json!({"identity":identity,"sessionId":session,"requestId":request,"answer":answer})).await?;
        Ok(())
    }

    /// Subscribe to public invalidations. Refetch merged windows; never append
    /// native deltas or accept a snapshot from another host incarnation.
    pub async fn events(
        &self,
        identity: &Identity,
        after: u64,
    ) -> Result<EventStream, ClientError> {
        self.0
            .event_source(
                &["opencode", "v1", "events"],
                &[
                    ("hostId", &identity.host_id),
                    ("generation", &identity.generation.to_string()),
                    ("after", &after.to_string()),
                ],
                Dialect::V1,
            )
            .await
    }
}
