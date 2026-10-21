//! Native turns use the existing history window reconciliation protocol.

use std::collections::BTreeMap;

use anyhow::{ensure, Result};
use async_trait::async_trait;
use pocox_core::history_sync::{HistoryWindow, WindowQuery};
use serde_json::json;

use super::{NativeHistory, NativePage};
use crate::history_sync::SessionHistorySource;

#[async_trait]
impl SessionHistorySource for NativeHistory {
    fn provider(&self) -> &'static str {
        NativeHistory::provider(self)
    }

    async fn read_window(&self, query: &WindowQuery) -> Result<HistoryWindow> {
        query.validate()?;
        ensure!(
            query.group.is_none() && query.projection.is_none(),
            "unsupported native projection"
        );
        ensure!(
            matches!(query.collection.as_str(), "metadata" | "turns"),
            "unsupported native collection"
        );
        ensure!(query.collection != "metadata" || query.cursor.is_none(), "metadata has no cursor");
        let page = self
            .read_page(
                &query.session,
                query.cursor.as_deref(),
                if query.collection == "metadata" { 1 } else { query.limit as usize },
            )
            .await?;
        window(page, self.provider(), query.collection == "metadata")
    }
}

fn window(page: NativePage, provider: &str, metadata_only: bool) -> Result<HistoryWindow> {
    let mut metadata = json!({
        "sessionId": page.session_id, "cwd": page.cwd, "title": page.title,
        "updatedAt": page.updated_at, "revision": page.revision,
        "truncated": page.truncated, "totalTurns": page.total_turns,
        "hasOlder": page.has_older, "nextCursor": page.next_before,
        // Reading a persisted source does not establish current ownership.
        "readOnly": true,
    });
    let mut documents = BTreeMap::new();
    let mut order = Vec::new();
    if metadata_only {
        metadata["hasOlder"] = json!(false);
        metadata["nextCursor"] = json!(null);
        order.push("metadata".into());
        documents.insert("metadata".into(), metadata.clone());
    } else {
        for turn in page.turns {
            let id = turn.id.clone();
            ensure!(
                documents
                    .insert(id.clone(), serde_json::to_value(turn)?)
                    .is_none(),
                "duplicate native turn"
            );
            order.push(id);
        }
    }
    let result = HistoryWindow {
        provider: provider.into(),
        generation: page.generation,
        metadata,
        order,
        documents,
    };
    result.validate()?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use pocox_core::history_sync::{apply, reconcile};

    use super::*;

    #[test]
    fn readonly_native_window_retains_source_and_omission_metadata() {
        let page = NativePage {
            session_id: "session".into(),
            generation: "source".into(),
            revision: "revision".into(),
            source_bytes: 100,
            cwd: "/project".into(),
            title: "title".into(),
            updated_at: 10,
            turns: vec![],
            has_older: true,
            next_before: Some("boundary".into()),
            total_turns: Some(30),
            truncated: true,
        };
        let result = window(page, "claude/native-v1", false).expect("window");
        assert_eq!(result.metadata["readOnly"], true);
        assert_eq!(result.metadata["nextCursor"], "boundary");
        assert_eq!(result.metadata["truncated"], true);
        let response = reconcile(&result, None).expect("reconcile");
        assert_eq!(apply(None, &response).expect("apply"), result);
    }
}
