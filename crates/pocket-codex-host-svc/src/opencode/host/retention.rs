//! Bound retained admission state without forgetting a running turn or unsent
//! options. Evicted IDs require an explicit open before they can write again.

use std::collections::{BTreeMap, BTreeSet};

use super::{Entry, Error, Host, Status};

const LIMIT: usize = 256;

fn candidates(entries: &BTreeMap<String, Entry>) -> Vec<(String, String)> {
    let mut candidates: Vec<_> = entries
        .iter()
        .filter(|(_, entry)| entry.turn.is_none() && !entry.options_pending)
        .collect();
    candidates.sort_by_key(|(_, entry)| (!entry.released, entry.last_used));
    candidates
        .into_iter()
        .map(|(id, entry)| (id.clone(), entry.directory.clone()))
        .collect()
}

impl Host {
    // Caller holds the mutation lock across reservation and insertion.
    pub(super) async fn reserve_session_slot(&self, existing: Option<&str>) -> Result<(), Error> {
        if let Some(id) = reserve_slot(&self.0.client, &self.0.sessions, existing).await? {
            self.0.live.invalidate(&id).await;
        }
        Ok(())
    }
}

async fn reserve_slot(
    client: &super::Client,
    sessions: &tokio::sync::Mutex<BTreeMap<String, Entry>>,
    existing: Option<&str>,
) -> Result<Option<String>, Error> {
    let candidates = {
        let entries = sessions.lock().await;
        if entries.len() < LIMIT || existing.is_some_and(|id| entries.contains_key(id)) {
            return Ok(None);
        }
        candidates(&entries)
    };
    let mut checked = BTreeSet::new();
    let mut unavailable = None;
    for (_, directory) in &candidates {
        if !checked.insert(directory) {
            continue;
        }
        let state = tokio::try_join!(
            client.statuses(directory),
            client.permissions(directory),
            client.questions(directory),
        );
        let (statuses, permissions, questions) = match state {
            Ok(state) => state,
            Err(error) => {
                // Unverifiable state protects this directory, not every other
                // project's independently confirmed idle session.
                unavailable.get_or_insert(Error::Native(error));
                continue;
            },
        };
        if permissions
            .iter()
            .chain(&questions)
            .any(|request| request["sessionID"].as_str().is_none())
        {
            unavailable.get_or_insert(Error::NotReady);
            continue;
        }
        for (id, candidate_directory) in &candidates {
            if candidate_directory != directory
                || !matches!(statuses.get(id).unwrap_or(&Status::Idle), Status::Idle)
                || permissions
                    .iter()
                    .chain(&questions)
                    .any(|request| request["sessionID"].as_str() == Some(id))
            {
                continue;
            }
            let removed = {
                let mut entries = sessions.lock().await;
                if entries
                    .get(id)
                    .is_some_and(|entry| entry.turn.is_none() && !entry.options_pending)
                {
                    entries.remove(id);
                    true
                } else {
                    false
                }
            };
            if !removed {
                continue;
            }
            return Ok(Some(id.clone()));
        }
    }
    Err(unavailable.unwrap_or(Error::Capacity))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eviction_keeps_unconfirmed_turns_and_unpersisted_options() {
        let mut entries = BTreeMap::new();
        entries.insert("running".into(), Entry {
            turn: Some("turn".into()),
            ..Entry::default()
        });
        entries.insert("pending".into(), Entry {
            options_pending: true,
            ..Entry::default()
        });
        entries.insert("idle".into(), Entry::default());
        entries.insert("released".into(), Entry {
            released: true,
            ..Entry::default()
        });
        assert_eq!(
            candidates(&entries)
                .into_iter()
                .map(|(id, _)| id)
                .collect::<Vec<_>>(),
            ["released", "idle"]
        );
    }

    #[tokio::test]
    async fn the_257th_session_evicts_only_confirmed_inactive_state() {
        use axum::{routing::get, Json, Router};
        use serde_json::json;
        let router = Router::new()
            .route("/session/status", get(|| async { Json(json!({"000":{"type":"busy"}})) }))
            .route("/permission", get(|| async { Json(json!([{"sessionID":"001"}])) }))
            .route("/question", get(|| async { Json(json!([{"sessionID":"002"}])) }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("valid test fixture");
        let client = super::super::Client::new(
            &format!("http://{}/", listener.local_addr().expect("valid test fixture")),
            None,
            crate::opencode::wire::Dialect::V1,
        )
        .expect("valid test fixture");
        let server = tokio::spawn(async move {
            axum::serve(listener, router)
                .await
                .expect("valid test fixture");
        });
        let entries = tokio::sync::Mutex::new(
            (0..LIMIT)
                .map(|n| {
                    (format!("{n:03}"), Entry {
                        directory: "/project".into(),
                        released: true,
                        ..Entry::default()
                    })
                })
                .collect(),
        );
        assert_eq!(
            reserve_slot(&client, &entries, None)
                .await
                .expect("valid test fixture")
                .as_deref(),
            Some("003")
        );
        let mut remaining = entries.lock().await;
        for id in ["000", "001", "002"] {
            assert!(remaining.contains_key(id));
        }
        remaining.insert("257".into(), Entry {
            options_pending: true,
            ..Entry::default()
        });
        assert_eq!(remaining.len(), LIMIT);
        for entry in remaining.values_mut() {
            entry.turn = Some("unconfirmed".into());
        }
        drop(remaining);
        assert!(matches!(reserve_slot(&client, &entries, None).await, Err(Error::Capacity)));
        assert!(reserve_slot(&client, &entries, Some("257"))
            .await
            .expect("valid test fixture")
            .is_none());
        server.abort();
    }

    #[tokio::test]
    async fn an_unverifiable_directory_does_not_block_other_safe_candidates() {
        use axum::{
            extract::Query, http::StatusCode, response::IntoResponse, routing::get, Json, Router,
        };
        use serde_json::json;
        for malformed in [false, true] {
            let router = Router::new()
                .route(
                    "/session/status",
                    get(move |Query(query): Query<BTreeMap<String, String>>| async move {
                        if !malformed && query.get("directory").map(String::as_str) == Some("/bad")
                        {
                            return (StatusCode::SERVICE_UNAVAILABLE, Json(json!({})))
                                .into_response();
                        }
                        Json(json!({})).into_response()
                    }),
                )
                .route(
                    "/permission",
                    get(move |Query(query): Query<BTreeMap<String, String>>| async move {
                        Json(
                            if malformed
                                && query.get("directory").map(String::as_str) == Some("/bad")
                            {
                                json!([{"id":"missing-session-id"}])
                            } else {
                                json!([])
                            },
                        )
                    }),
                )
                .route("/question", get(|| async { Json(json!([])) }));
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
                .await
                .expect("fixture");
            let client = super::super::Client::new(
                &format!("http://{}/", listener.local_addr().expect("fixture")),
                None,
                crate::opencode::wire::Dialect::V1,
            )
            .expect("fixture");
            let server = tokio::spawn(async move {
                axum::serve(listener, router).await.expect("fixture");
            });
            let entries = tokio::sync::Mutex::new(
                (0..LIMIT)
                    .map(|n| {
                        (format!("{n:03}"), Entry {
                            directory: if n == 0 { "/bad" } else { "/good" }.into(),
                            ..Entry::default()
                        })
                    })
                    .collect(),
            );
            assert_eq!(
                reserve_slot(&client, &entries, None)
                    .await
                    .expect("healthy project provides room")
                    .as_deref(),
                Some("001")
            );
            let mut remaining = entries.lock().await;
            assert!(remaining.contains_key("000"), "unverifiable entry stays protected");
            remaining.insert("001".into(), Entry::default());
            for entry in remaining.values_mut() {
                entry.directory = "/bad".into();
            }
            drop(remaining);
            assert!(reserve_slot(&client, &entries, None).await.is_err());
            assert_eq!(entries.lock().await.len(), LIMIT, "no unverified eviction");
            server.abort();
        }
    }
}
