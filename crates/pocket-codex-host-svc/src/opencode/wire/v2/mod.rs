//! OpenCode 2 native wire. Requests go to `/api`; responses decode into typed
//! shapes that move into the 1.x forms the host reads.

mod events;
mod shape;
#[cfg(test)]
mod tests;

use std::{borrow::Cow, collections::BTreeMap};

use reqwest::{Method, RequestBuilder};
use serde::{de::IgnoredAny, Serialize};
use serde_json::Value;

use self::shape::{Data, Page};
use super::{Health, Reply, Wire};
use crate::opencode::{
    catalog::Catalog,
    client::ClientError,
    events::Event,
    http::{Http, Native, MAX_BODY, MAX_NATIVE_HISTORY_BODY, REQUEST_TIMEOUT},
    schema::{CommandInput, MessagePage, Prompt, Session, Status, Statuses},
};

/// OpenCode 2.x.
pub(crate) enum V2 {}

/// Location-scoped routes take the project here rather than `directory`.
const LOCATION: &str = "location[directory]";

impl Wire for V2 {
    const DATABASE: &'static [&'static str] = &["debug", "paths", "db"];
    const EVENTS: &'static [&'static str] = &["api", "event"];
    const LISTENING: &'static str = "server listening on ";
    const BACKGROUND_SERVER: bool = true;
    const MIN: (u32, u32) = (2, 0);

    fn event(data: &[u8]) -> Result<Option<Event>, ClientError> {
        events::decode(data)
    }

    async fn health(http: &Http<Native>) -> Result<Health, ClientError> {
        let info: shape::Info = http.get(&["api", "info"], None, &[]).await?;
        Ok(Health {
            healthy: true,
            version: info.version,
            pid: info.pid,
            urls: info.urls,
        })
    }

    async fn open(http: &Http<Native>) -> Result<(), ClientError> {
        let _: Page<IgnoredAny> = http
            .get(&["api", "session"], None, &[("limit", "1")])
            .await?;
        Ok(())
    }

    async fn sessions(
        http: &Http<Native>,
        directory: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Session>, ClientError> {
        let mut sessions = Vec::new();
        let mut cursor: Option<String> = None;
        while sessions.len() < limit {
            let wanted = limit - sessions.len();
            let mut request = http
                .request(Method::GET, &["api", "session"], directory)?
                .query(&[("limit", wanted)]);
            if let Some(cursor) = &cursor {
                request = request.query(&[("cursor", cursor)]);
            }
            let mut page: Page<shape::Session> = http
                .call(request.timeout(REQUEST_TIMEOUT), MAX_BODY)
                .await?;
            let next = page.next(wanted)?;
            sessions.extend(page.data.into_iter().take(wanted).map(Session::from));
            match next {
                Some(next) if Some(&next) == cursor.as_ref() => {
                    return Err(ClientError::InvalidResponse)
                },
                Some(next) => cursor = Some(next),
                None => break,
            }
        }
        Ok(sessions)
    }

    async fn session(http: &Http<Native>, id: &str) -> Result<Session, ClientError> {
        let session: Data<shape::Session> = http.get(&["api", "session", id], None, &[]).await?;
        Ok(session.data.into())
    }

    async fn create(http: &Http<Native>, directory: &str) -> Result<Session, ClientError> {
        #[derive(Serialize)]
        struct Create<'a> {
            location: Location<'a>,
        }
        #[derive(Serialize)]
        struct Location<'a> {
            directory: &'a str,
        }
        let body = Create {
            location: Location {
                directory,
            },
        };
        let session: Data<shape::Session> = http
            .mutate(Method::POST, &["api", "session"], None, &body)
            .await?;
        Ok(session.data.into())
    }

    async fn rename(
        http: &Http<Native>,
        id: &str,
        _directory: &str,
        title: &str,
    ) -> Result<Session, ClientError> {
        #[derive(Serialize)]
        struct Title<'a> {
            title: &'a str,
        }
        let _: IgnoredAny = http
            .mutate(Method::PATCH, &["api", "session", id], None, &Title {
                title,
            })
            .await?;
        Self::session(http, id).await
    }

    async fn statuses(http: &Http<Native>, _directory: &str) -> Result<Statuses, ClientError> {
        // Listed sessions run here, whatever their inner state; every other
        // session is idle. Retry is not reported on this route.
        let active: Data<BTreeMap<String, IgnoredAny>> =
            http.get(&["api", "session", "active"], None, &[]).await?;
        Ok(active
            .data
            .into_keys()
            .map(|id| (id, Status::Busy))
            .collect())
    }

    async fn page(
        http: &Http<Native>,
        session: &str,
        _directory: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<MessagePage, ClientError> {
        let mut request = http
            .request(Method::GET, &["api", "session", session, "message"], None)?
            .query(&[("limit", limit)]);
        if let Some(before) = before {
            request = request.query(&[("cursor", before)]);
        }
        let mut page: Page<shape::Message> = http
            .call(request.timeout(REQUEST_TIMEOUT), MAX_NATIVE_HISTORY_BODY)
            .await?;
        let next_before = page.next(limit)?;
        Ok(MessagePage {
            messages: shape::history(session, page.data),
            next_before,
        })
    }

    async fn catalog(http: &Http<Native>, directory: Option<&str>) -> Result<Catalog, ClientError> {
        let providers = located(http, &["api", "provider"], directory)?;
        let models = located(http, &["api", "model"], directory)?;
        let default = located(http, &["api", "model", "default"], directory)?;
        let agents = located(http, &["api", "agent"], directory)?;
        let commands = located(http, &["api", "command"], directory)?;
        let (providers, models, default, agents, commands) = tokio::try_join!(
            http.call::<Data<Vec<shape::Provider>>>(providers, MAX_BODY),
            http.call::<Data<Vec<shape::Model>>>(models, MAX_BODY),
            http.call::<shape::DefaultModel>(default, MAX_BODY),
            http.call::<Data<Vec<shape::Agent>>>(agents, MAX_BODY),
            http.call::<Data<Vec<shape::Command>>>(commands, MAX_BODY),
        )?;
        Ok(shape::catalog(providers.data, models.data, default, agents.data, commands.data))
    }

    async fn permissions(http: &Http<Native>, directory: &str) -> Result<Vec<Value>, ClientError> {
        let request = located(http, &["api", "permission", "request"], Some(directory))?;
        let pending: Data<Vec<shape::Permission>> = http.call(request, MAX_BODY).await?;
        Ok(pending
            .data
            .into_iter()
            .map(shape::Permission::into_native)
            .collect())
    }

    async fn questions(http: &Http<Native>, directory: &str) -> Result<Vec<Value>, ClientError> {
        let request = located(http, &["api", "form"], Some(directory))?;
        let pending: Data<Vec<shape::Form>> = http.call(request, MAX_BODY).await?;
        Ok(pending
            .data
            .into_iter()
            .map(shape::Form::into_native)
            .collect())
    }

    async fn prompt(
        http: &Http<Native>,
        session: &str,
        _directory: &str,
        prompt: &Prompt,
        select: bool,
    ) -> Result<(), ClientError> {
        #[derive(Serialize)]
        struct Body<'a> {
            #[serde(flatten)]
            input: Input<'a>,
            #[serde(skip_serializing_if = "Option::is_none")]
            id: Option<&'a str>,
        }
        let body = Body {
            input: Input::new(&prompt.parts, None),
            id: prompt.message_id.as_deref(),
        };
        if select {
            let model = prompt.model.as_ref().map(|model| ModelRef {
                id: &model.model_id,
                provider_id: &model.provider_id,
                variant: prompt.variant.as_deref(),
            });
            selection(http, session, model, prompt.agent.as_deref()).await?;
        }
        let _: IgnoredAny = http
            .mutate(Method::POST, &["api", "session", session, "prompt"], None, &body)
            .await?;
        Ok(())
    }

    async fn command(
        http: &Http<Native>,
        session: &str,
        _directory: &str,
        command: &CommandInput,
        select: bool,
    ) -> Result<(), ClientError> {
        #[derive(Serialize)]
        struct Body<'a> {
            name: &'a str,
            #[serde(flatten)]
            input: Input<'a>,
        }
        if select {
            let model = command
                .model
                .as_deref()
                .map(|key| {
                    // The catalog key is `provider/model`; provider IDs never
                    // contain a slash, model IDs may.
                    let (provider_id, id) = key.split_once('/').ok_or(ClientError::Preflight {
                        selection: "model",
                    })?;
                    Ok::<_, ClientError>(ModelRef {
                        id,
                        provider_id,
                        variant: command.variant.as_deref(),
                    })
                })
                .transpose()?;
            selection(http, session, model, command.agent.as_deref()).await?;
        }
        let request = http
            .request(Method::POST, &["api", "session", session, "command"], None)?
            .json(&Body {
                name: &command.command,
                input: Input::new(&command.parts, Some(&command.arguments)),
            });
        let _: IgnoredAny = http.call(request, MAX_BODY).await?;
        Ok(())
    }

    async fn reply(
        http: &Http<Native>,
        session: &str,
        request: &str,
        _directory: &str,
        reply: Reply<'_>,
    ) -> Result<(), ClientError> {
        let _: IgnoredAny = match reply {
            Reply::Permission(decision) => {
                #[derive(Serialize)]
                struct Decision<'a> {
                    decision: &'a str,
                }
                let path = ["api", "session", session, "permission", request, "reply"];
                http.mutate(Method::POST, &path, None, &Decision {
                    decision,
                })
                .await?
            },
            Reply::Question(answers) => {
                #[derive(Serialize)]
                struct Answer {
                    answer: serde_json::Map<String, Value>,
                }
                let form: Data<shape::Form> = http
                    .get(&["api", "session", session, "form", request], None, &[])
                    .await?;
                let answer = form.data.answer(answers)?;
                let path = ["api", "session", session, "form", request, "reply"];
                http.mutate(Method::POST, &path, None, &Answer {
                    answer,
                })
                .await?
            },
            Reply::RejectQuestion => {
                let request = http
                    .request(Method::DELETE, &["api", "session", session, "form", request], None)?
                    .timeout(REQUEST_TIMEOUT);
                http.call(request, MAX_BODY).await?
            },
        };
        Ok(())
    }

    async fn abort(
        http: &Http<Native>,
        session: &str,
        _directory: &str,
    ) -> Result<bool, ClientError> {
        let request = http
            .request(Method::POST, &["api", "session", session, "interrupt"], None)?
            .timeout(REQUEST_TIMEOUT);
        let result: shape::Interrupted = http.call(request, MAX_BODY).await?;
        Ok(result.interrupted)
    }
}

/// A location-scoped read.
fn located(
    http: &Http<Native>,
    path: &[&str],
    directory: Option<&str>,
) -> Result<RequestBuilder, ClientError> {
    let mut request = http.request(Method::GET, path, None)?;
    if let Some(directory) = directory {
        request = request.query(&[(LOCATION, directory)]);
    }
    Ok(request.timeout(REQUEST_TIMEOUT))
}

/// Prompt text and attachments. The host admits only inline image data URLs,
/// which V2 decodes and sniffs itself.
#[derive(Serialize)]
struct Input<'a> {
    text: Cow<'a, str>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    files: Vec<File<'a>>,
}

#[derive(Serialize)]
struct File<'a> {
    uri: &'a str,
}

impl<'a> Input<'a> {
    /// `text` replaces the parts' own text, as a command's arguments do.
    fn new(parts: &'a [Value], text: Option<&'a str>) -> Self {
        let files = parts
            .iter()
            .filter(|part| part["type"] == "file")
            .filter_map(|part| part["url"].as_str())
            .map(|uri| File {
                uri,
            })
            .collect();
        Self {
            text: text.map_or_else(|| joined(parts), Cow::Borrowed),
            files,
        }
    }
}

fn joined(parts: &[Value]) -> Cow<'_, str> {
    let mut texts = parts.iter().filter_map(|part| part["text"].as_str());
    let first = texts.next().unwrap_or_default();
    match texts.next() {
        None => Cow::Borrowed(first),
        Some(second) => Cow::Owned(
            [first, second]
                .into_iter()
                .chain(texts)
                .collect::<Vec<_>>()
                .join("\n"),
        ),
    }
}

#[derive(Serialize)]
struct ModelRef<'a> {
    id: &'a str,
    #[serde(rename = "providerID")]
    provider_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    variant: Option<&'a str>,
}

/// V2 keeps model and agent on the session, so a changed selection is sent
/// before the prompt. Any failure here means the prompt was never sent.
async fn selection(
    http: &Http<Native>,
    session: &str,
    model: Option<ModelRef<'_>>,
    agent: Option<&str>,
) -> Result<(), ClientError> {
    #[derive(Serialize)]
    struct Model<'a> {
        model: ModelRef<'a>,
    }
    #[derive(Serialize)]
    struct Agent<'a> {
        agent: &'a str,
    }
    if let Some(model) = model {
        let path = ["api", "session", session, "model"];
        http.mutate::<IgnoredAny>(Method::POST, &path, None, &Model {
            model,
        })
        .await
        .map_err(|_| ClientError::Preflight {
            selection: "model",
        })?;
    }
    if let Some(agent) = agent {
        let path = ["api", "session", session, "agent"];
        http.mutate::<IgnoredAny>(Method::POST, &path, None, &Agent {
            agent,
        })
        .await
        .map_err(|_| ClientError::Preflight {
            selection: "agent",
        })?;
    }
    Ok(())
}
