//! Closed `/opencode/v1` gateway. There is deliberately no raw native proxy,
//! configuration, credentials, filesystem, shell or administrative endpoint.

use std::{convert::Infallible, sync::Arc};

use axum::{
    extract::{DefaultBodyLimit, Query, State},
    http::StatusCode,
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::{broadcast::error::RecvError, mpsc, Semaphore};
use tokio_stream::wrappers::ReceiverStream;

use super::{
    catalog::Catalog,
    client::ClientError,
    host::{Answer, Error, Host, Identity, Info, Input, Options, ReadResult, Snapshot},
    live::Change,
    schema::Session,
};
use crate::session_access::SessionAccess;

#[derive(Clone)]
struct Api {
    host: Host,
    streams: Arc<Semaphore>,
}

struct Failure(Error);

impl From<Error> for Failure {
    fn from(error: Error) -> Self {
        Self(error)
    }
}

impl IntoResponse for Failure {
    fn into_response(self) -> Response {
        let status = match &self.0 {
            Error::Stale | Error::ReadOnly | Error::Busy | Error::TurnChanged => {
                StatusCode::CONFLICT
            },
            Error::NotReady => StatusCode::SERVICE_UNAVAILABLE,
            Error::InvalidInput => StatusCode::BAD_REQUEST,
            Error::Capacity => StatusCode::TOO_MANY_REQUESTS,
            Error::SessionNotFound | Error::Native(ClientError::Http(404)) => StatusCode::NOT_FOUND,
            Error::Native(_) => StatusCode::BAD_GATEWAY,
        };
        (status, Json(json!({"code":self.0.code(),"message":self.0.to_string()}))).into_response()
    }
}

/// Relay-facing routes for one owned native service. Only typed public
/// operations are available; the native endpoint/password remain private.
pub fn router(host: Host) -> Router {
    Router::new()
        .route("/opencode/v1/info", get(info))
        .route("/opencode/v1/events", get(events))
        .route("/opencode/v1/catalog", get(catalog))
        .route("/opencode/v1/sessions", get(sessions))
        .route("/opencode/v1/running", get(running))
        .route("/opencode/v1/snapshot", get(snapshot))
        .route("/opencode/v1/access", get(access))
        .route("/opencode/v1/open", post(open))
        .route("/opencode/v1/create", post(create))
        .route("/opencode/v1/release", post(release))
        .route("/opencode/v1/options", post(options))
        .route("/opencode/v1/prompt", post(prompt).layer(DefaultBodyLimit::max(48 * 1024 * 1024)))
        .route("/opencode/v1/cancel", post(cancel))
        .route("/opencode/v1/rename", post(rename))
        .route("/opencode/v1/answer", post(answer))
        .with_state(Api {
            host,
            streams: Arc::new(Semaphore::new(16)),
        })
}

/// Serve a gateway listener; its owner separately owns the native lifetime.
pub async fn serve(listener: tokio::net::TcpListener, host: Host) -> anyhow::Result<()> {
    Ok(axum::serve(listener, router(host)).await?)
}

async fn info(State(api): State<Api>) -> Result<Json<Info>, Failure> {
    if api.host.is_stopped() {
        return Err(Error::NotReady.into());
    }
    Ok(Json(api.host.info()))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Project {
    directory: Option<String>,
}

async fn catalog(
    State(api): State<Api>,
    Query(project): Query<Project>,
) -> Result<Json<ReadResult<Catalog>>, Failure> {
    Ok(Json(ReadResult {
        identity: api.host.info().identity,
        data: api.host.catalog(project.directory.as_deref()).await?,
    }))
}

async fn sessions(
    State(api): State<Api>,
    Query(project): Query<Project>,
) -> Result<Json<ReadResult<Vec<Session>>>, Failure> {
    Ok(Json(ReadResult {
        identity: api.host.info().identity,
        data: api.host.sessions(project.directory.as_deref()).await?,
    }))
}

async fn running(State(api): State<Api>) -> Result<Json<ReadResult<Vec<String>>>, Failure> {
    Ok(Json(ReadResult {
        identity: api.host.info().identity,
        data: api.host.running().await?,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Read {
    session_id: String,
    before: Option<String>,
}

async fn snapshot(
    State(api): State<Api>,
    Query(read): Query<Read>,
) -> Result<Json<Snapshot>, Failure> {
    if read
        .before
        .as_ref()
        .is_some_and(|cursor| cursor.len() > 4096)
    {
        return Err(Error::InvalidInput.into());
    }
    Ok(Json(
        api.host
            .snapshot(&read.session_id, read.before.as_deref())
            .await?,
    ))
}

async fn access(
    State(api): State<Api>,
    Query(read): Query<Read>,
) -> Result<Json<SessionAccess>, Failure> {
    Ok(Json(api.host.access(&read.session_id).await?))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionMutation {
    identity: Identity,
    session_id: String,
}

async fn open(
    State(api): State<Api>,
    Json(body): Json<SessionMutation>,
) -> Result<Json<Snapshot>, Failure> {
    Ok(Json(api.host.open(&body.session_id, &body.identity).await?))
}

async fn release(
    State(api): State<Api>,
    Json(body): Json<SessionMutation>,
) -> Result<Json<SessionAccess>, Failure> {
    Ok(Json(api.host.release(&body.session_id, &body.identity).await?))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Create {
    identity: Identity,
    directory: String,
    options: Options,
}

async fn create(
    State(api): State<Api>,
    Json(body): Json<Create>,
) -> Result<Json<Session>, Failure> {
    Ok(Json(
        api.host
            .create(&body.directory, body.options, &body.identity)
            .await?,
    ))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SetOptions {
    identity: Identity,
    session_id: String,
    options: Options,
}

async fn options(
    State(api): State<Api>,
    Json(body): Json<SetOptions>,
) -> Result<Json<Options>, Failure> {
    Ok(Json(
        api.host
            .set_options(&body.session_id, body.options, &body.identity)
            .await?,
    ))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Prompt {
    identity: Identity,
    session_id: String,
    input: Input,
    expected_turn: Option<String>,
}

async fn prompt(State(api): State<Api>, Json(body): Json<Prompt>) -> Result<Json<Value>, Failure> {
    let turn = api
        .host
        .prompt(&body.session_id, body.input, body.expected_turn.as_deref(), &body.identity)
        .await?;
    Ok(Json(json!({"turnId":turn})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cancel {
    identity: Identity,
    session_id: String,
    turn_id: String,
}

async fn cancel(State(api): State<Api>, Json(body): Json<Cancel>) -> Result<Json<Value>, Failure> {
    let cancelled = api
        .host
        .cancel(&body.session_id, &body.turn_id, &body.identity)
        .await?;
    Ok(Json(json!({"cancelled":cancelled})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Rename {
    identity: Identity,
    session_id: String,
    title: String,
}

async fn rename(State(api): State<Api>, Json(body): Json<Rename>) -> Result<Json<Value>, Failure> {
    api.host
        .rename(&body.session_id, &body.title, &body.identity)
        .await?;
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Reply {
    identity: Identity,
    session_id: String,
    request_id: String,
    answer: Answer,
}

async fn answer(State(api): State<Api>, Json(body): Json<Reply>) -> Result<Json<Value>, Failure> {
    api.host
        .answer(&body.session_id, &body.request_id, body.answer, &body.identity)
        .await?;
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Events {
    host_id: String,
    generation: u64,
    after: u64,
}

async fn events(State(api): State<Api>, Query(query): Query<Events>) -> Result<Response, Failure> {
    if api.host.is_stopped() {
        return Err(Error::NotReady.into());
    }
    let info = api.host.info();
    if query.host_id != info.identity.host_id || query.generation != info.identity.generation {
        return Err(Error::Stale.into());
    }
    let permit = api
        .streams
        .try_acquire_owned()
        .map_err(|_| Failure(Error::Capacity))?;
    let mut receiver = api.host.live().subscribe();
    let sequence = api.host.live().sequence().await;
    let (sender, stream) = mpsc::channel::<Result<Event, Infallible>>(16);
    tokio::spawn(async move {
        let _permit = permit;
        let mut after = query.after;
        if sequence != after {
            if sender
                .send(Ok(sse(Change {
                    sequence,
                    session_id: None,
                })))
                .await
                .is_err()
            {
                return;
            }
            after = sequence;
        }
        loop {
            // Axum connections can outlive the listener task. The stream
            // owns a Host clone, so dropping a registration never closes
            // this receiver; stop must explicitly end the controller stream.
            let next = tokio::select! {
                _ = api.host.stopped() => break,
                _ = sender.closed() => break,
                next = receiver.recv() => next,
            };
            let change = match next {
                Ok(change) if change.sequence > after => change,
                Ok(_) => continue,
                Err(RecvError::Lagged(_)) => Change {
                    sequence: api.host.live().sequence().await,
                    session_id: None,
                },
                Err(RecvError::Closed) => break,
            };
            after = change.sequence;
            let sent = tokio::select! {
                _ = api.host.stopped() => break,
                sent = sender.send(Ok(sse(change))) => sent,
            };
            if sent.is_err() {
                break;
            }
        }
    });
    Ok(Sse::new(ReceiverStream::new(stream))
        .keep_alive(KeepAlive::default())
        .into_response())
}

fn sse(change: Change) -> Event {
    Event::default().id(change.sequence.to_string()).data(
        json!({"type":"changed","properties":{
        "sequence":change.sequence,"sessionID":change.session_id}})
        .to_string(),
    )
}
