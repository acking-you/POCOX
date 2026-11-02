//! Branch a session through the native server's own fork. It only reads the
//! source's rows and writes a new session's, but it writes them: another
//! process on the database is another engine beside it, and this host could not
//! write the result anyway, so a held source is refused. A running turn is
//! refused too, unless the fork stops before it: the copy would keep an
//! unfinished message and a tool forever "running".

use serde::{Deserialize, Serialize};

use super::{Error, Host, Identity, Session, Status};

/// Most history pages searched for a boundary.
const MAX_BOUNDARY_PAGES: usize = 512;

/// A new session branched from another.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Forked {
    /// The new session; it holds no admission until it is opened.
    pub session: Session,
    /// It ends at the requested turn (true with none asked).
    pub boundary_confirmed: bool,
}

/// Where a fork through a turn stops.
struct Boundary {
    /// The next user message: OpenCode copies up to but not including it, and
    /// the last turn has none.
    before: Option<String>,
    /// When the turn's user message was created, which the copy keeps.
    created: u64,
}

impl Host {
    /// Branch `session` through `through_turn` (a turn's user message,
    /// inclusive) or whole. Nothing is sent, resumed or written to the source.
    /// A refusal is an `Err` other than [`Error::ForkUnknown`]: nothing was
    /// created.
    pub async fn fork(
        &self,
        session: &str,
        through_turn: Option<&str>,
        expected: &Identity,
    ) -> Result<Forked, Error> {
        let _guard = self.0.mutation.lock().await;
        self.identity(expected)?;
        if !self.0.client.forks() {
            return Err(Error::InvalidInput);
        }
        let metadata = self.session(session).await?;
        self.clear_source(expected).await?;
        let status = self.status(&metadata).await?;
        if matches!(status, Status::Unknown) {
            return Err(Error::NotReady);
        }
        let running = status.running()
            || self
                .0
                .sessions
                .lock()
                .await
                .get(session)
                .is_some_and(|entry| entry.turn.is_some());
        let boundary = match through_turn {
            Some(turn) => Some(self.fork_boundary(&metadata, turn, running).await?),
            None if running => return Err(Error::Busy),
            None => None,
        };
        self.clear_source(expected).await?;
        let before = boundary.as_ref().and_then(|at| at.before.as_deref());
        let fork =
            self.0
                .client
                .fork_session(session, &metadata.directory, before)
                .await
                .map_err(|error| {
                    if error.not_sent() {
                        Error::Native(error)
                    } else {
                        Error::ForkUnknown
                    }
                })?;
        let boundary_confirmed = match boundary {
            Some(at) => self.ends_at(&fork, at.created).await,
            None => true,
        };
        Ok(Forked {
            session: fork,
            boundary_confirmed,
        })
    }

    async fn clear_source(&self, expected: &Identity) -> Result<(), Error> {
        self.writable_source(expected)
            .await
            .map_err(|error| match error {
                Error::ReadOnly => Error::SourceHeld,
                error => error,
            })
    }

    /// Search back from the newest message for `turn`, remembering the user
    /// message after it and whether the newest message kept has finished. A
    /// cursor walks real history, because OpenCode does not refuse a message it
    /// does not know: it compares ids and copies accordingly.
    async fn fork_boundary(
        &self,
        session: &Session,
        turn: &str,
        running: bool,
    ) -> Result<Boundary, Error> {
        let mut cursor: Option<String> = None;
        let mut before: Option<String> = None;
        let mut at_cut = true;
        let mut unfinished = false;
        for _ in 0..MAX_BOUNDARY_PAGES {
            let page = self
                .0
                .client
                .messages(&session.id, &session.directory, cursor.as_deref())
                .await?;
            for message in page.messages.iter().rev() {
                let info = &message.info;
                let user = info["role"] == "user";
                if at_cut {
                    unfinished = !user && info["time"]["completed"].is_null();
                    at_cut = false;
                }
                if info["id"] == turn {
                    let created = info["time"]["created"].as_u64();
                    let (true, Some(created)) = (user, created) else {
                        return Err(Error::InvalidInput);
                    };
                    if running && (before.is_none() || unfinished) {
                        return Err(Error::Busy);
                    }
                    return Ok(Boundary {
                        before,
                        created,
                    });
                }
                if user {
                    before = info["id"].as_str().map(str::to_owned);
                    at_cut = true;
                }
            }
            cursor = page.next_before;
            if cursor.is_none() {
                break;
            }
        }
        Err(Error::InvalidInput)
    }

    /// Whether `fork`'s newest user message is the one created at `created`.
    /// False when that cannot be read.
    async fn ends_at(&self, fork: &Session, created: u64) -> bool {
        self.0
            .client
            .messages(&fork.id, &fork.directory, None)
            .await
            .is_ok_and(|page| {
                page.messages
                    .iter()
                    .rev()
                    .find(|message| message.info["role"] == "user")
                    .is_some_and(|message| message.info["time"]["created"] == created)
            })
    }
}
