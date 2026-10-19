//! OpenCode 1.19+ native wire: the routes and shapes the host reads as is.

use reqwest::Method;
use serde::{de::IgnoredAny, Deserialize, Serialize};
use serde_json::Value;

use super::{Health, Reply, Wire};
use crate::opencode::{
    catalog::{Catalog, Providers},
    client::ClientError,
    events::Event,
    http::{decode, Http, Native, MAX_BODY, MAX_NATIVE_HISTORY_BODY, REQUEST_TIMEOUT},
    schema::{CommandInput, Message, MessagePage, Prompt, Session, Statuses},
};

/// OpenCode 1.19 and later 1.x releases.
pub(crate) enum V1 {}

#[derive(Deserialize)]
#[serde(untagged)]
enum Envelope {
    Global { directory: Option<String>, payload: Event },
    Instance(Event),
}

#[derive(Serialize)]
struct Empty {}

impl Wire for V1 {
    const DATABASE: &'static [&'static str] = &["db", "path"];
    const EVENTS: &'static [&'static str] = &["global", "event"];
    const LISTENING: &'static str = "opencode server listening on ";
    const BACKGROUND_SERVER: bool = false;
    const MIN: (u32, u32) = (1, 19);

    fn event(data: &[u8]) -> Result<Option<Event>, ClientError> {
        Ok(Some(match serde_json::from_slice(data).map_err(|_| ClientError::InvalidResponse)? {
            Envelope::Global {
                directory,
                mut payload,
            } => {
                payload.directory = directory;
                payload
            },
            Envelope::Instance(event) => event,
        }))
    }

    async fn health(http: &Http<Native>) -> Result<Health, ClientError> {
        http.get(&["global", "health"], None, &[]).await
    }

    async fn open(http: &Http<Native>) -> Result<(), ClientError> {
        let _: Vec<Session> = http.get(&["session"], None, &[("limit", "1")]).await?;
        Ok(())
    }

    async fn sessions(
        http: &Http<Native>,
        directory: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Session>, ClientError> {
        http.get(&["experimental", "session"], directory, &[("limit", &limit.to_string())])
            .await
    }

    async fn session(http: &Http<Native>, id: &str) -> Result<Session, ClientError> {
        http.get(&["session", id], None, &[]).await
    }

    async fn create(http: &Http<Native>, directory: &str) -> Result<Session, ClientError> {
        http.mutate(Method::POST, &["session"], Some(directory), &Empty {})
            .await
    }

    async fn rename(
        http: &Http<Native>,
        id: &str,
        directory: &str,
        title: &str,
    ) -> Result<Session, ClientError> {
        #[derive(Serialize)]
        struct Title<'a> {
            title: &'a str,
        }
        http.mutate(Method::PATCH, &["session", id], Some(directory), &Title {
            title,
        })
        .await
    }

    async fn statuses(http: &Http<Native>, directory: &str) -> Result<Statuses, ClientError> {
        http.get(&["session", "status"], Some(directory), &[]).await
    }

    async fn page(
        http: &Http<Native>,
        session: &str,
        directory: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<MessagePage, ClientError> {
        let mut request = http
            .request(Method::GET, &["session", session, "message"], Some(directory))?
            .query(&[("limit", limit)]);
        if let Some(before) = before {
            request = request.query(&[("before", before)]);
        }
        let response = request
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(ClientError::from)?;
        let next_before = response
            .headers()
            .get("x-next-cursor")
            .map(|value| {
                value
                    .to_str()
                    .map(str::to_owned)
                    .map_err(|_| ClientError::InvalidResponse)
            })
            .transpose()?;
        if next_before
            .as_ref()
            .is_some_and(|cursor| cursor.len() > 4096)
        {
            return Err(ClientError::InvalidResponse);
        }
        let messages: Vec<Message> = decode::<Native, _>(response, MAX_NATIVE_HISTORY_BODY).await?;
        Ok(MessagePage {
            messages,
            next_before,
        })
    }

    async fn catalog(http: &Http<Native>, directory: Option<&str>) -> Result<Catalog, ClientError> {
        let (providers, agents, commands) = tokio::try_join!(
            http.get::<Providers>(&["provider"], directory, &[]),
            http.get::<Vec<Value>>(&["agent"], directory, &[]),
            http.get::<Vec<Value>>(&["command"], directory, &[]),
        )?;
        Ok(Catalog::public(providers, agents, commands))
    }

    async fn permissions(http: &Http<Native>, directory: &str) -> Result<Vec<Value>, ClientError> {
        http.get(&["permission"], Some(directory), &[]).await
    }

    async fn questions(http: &Http<Native>, directory: &str) -> Result<Vec<Value>, ClientError> {
        http.get(&["question"], Some(directory), &[]).await
    }

    async fn prompt(
        http: &Http<Native>,
        session: &str,
        directory: &str,
        prompt: &Prompt,
        _select: bool,
    ) -> Result<(), ClientError> {
        let _: IgnoredAny = http
            .mutate(Method::POST, &["session", session, "prompt_async"], Some(directory), prompt)
            .await?;
        Ok(())
    }

    async fn command(
        http: &Http<Native>,
        session: &str,
        directory: &str,
        command: &CommandInput,
        _select: bool,
    ) -> Result<(), ClientError> {
        let request = http
            .request(Method::POST, &["session", session, "command"], Some(directory))?
            .json(command);
        let _: IgnoredAny = http.call(request, MAX_BODY).await?;
        Ok(())
    }

    async fn reply(
        http: &Http<Native>,
        _session: &str,
        request: &str,
        directory: &str,
        reply: Reply<'_>,
    ) -> Result<(), ClientError> {
        #[derive(Serialize)]
        struct Permission<'a> {
            reply: &'a str,
        }
        #[derive(Serialize)]
        struct Question<'a> {
            answers: &'a [Vec<String>],
        }
        let directory = Some(directory);
        let _: IgnoredAny = match reply {
            Reply::Permission(reply) => {
                let path = ["permission", request, "reply"];
                http.mutate(Method::POST, &path, directory, &Permission {
                    reply,
                })
                .await?
            },
            Reply::Question(answers) => {
                let path = ["question", request, "reply"];
                http.mutate(Method::POST, &path, directory, &Question {
                    answers,
                })
                .await?
            },
            Reply::RejectQuestion => {
                let path = ["question", request, "reject"];
                http.mutate(Method::POST, &path, directory, &Empty {})
                    .await?
            },
        };
        Ok(())
    }

    async fn abort(
        http: &Http<Native>,
        session: &str,
        directory: &str,
    ) -> Result<bool, ClientError> {
        http.mutate(Method::POST, &["session", session, "abort"], Some(directory), &Empty {})
            .await
    }
}
