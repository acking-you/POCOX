//! Bound retained admission state without forgetting a running turn or unsent
//! options. Evicted IDs require an explicit open before they can write again.

use std::collections::{BTreeMap, BTreeSet};

use super::{Entry, Error, Host, Status, Statuses, Value};

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
    for (_, directory) in &candidates {
        if !checked.insert(directory) {
            continue;
        }
        let (statuses, permissions, questions) = tokio::try_join!(
            client.get::<Statuses>(&["session", "status"], Some(directory), &[]),
            client.get::<Vec<Value>>(&["permission"], Some(directory), &[]),
            client.get::<Vec<Value>>(&["question"], Some(directory), &[]),
        )?;
        if permissions
            .iter()
            .chain(&questions)
            .any(|request| request["sessionID"].as_str().is_none())
        {
            return Err(Error::NotReady);
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
    Err(Error::Capacity)
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
}
