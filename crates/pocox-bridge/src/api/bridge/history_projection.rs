//! Identity-only history projection; transcript bodies stay with their owner.
use super::*;
use crate::engine::{
    execution::{self, Lane},
    history_projection,
};

/// Merge paged and live identities off the UI thread. Returned indices address
/// the current rows followed by incoming rows; shared IDs retain current rows.
pub async fn history_merge(
    current_ids: Vec<String>,
    current_turns: Vec<String>,
    incoming_ids: Vec<String>,
    incoming_turns: Vec<String>,
    turn_order: Vec<String>,
    older_page: bool,
) -> Result<Vec<u32>> {
    execution::run(Lane::Cpu, move || {
        history_projection::merge(
            &current_ids,
            &current_turns,
            &incoming_ids,
            &incoming_turns,
            &turn_order,
            older_page,
        )
    })
    .await
}
