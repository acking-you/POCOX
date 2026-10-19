//! One `Wire` implementation per OpenCode major version. Each is a type with
//! no values; `Dialect` picks one from the detected version and `dispatch!`
//! calls it through a closed `match`, so no call is virtual and no future is
//! boxed.

mod v1;
mod v2;

use serde::Deserialize;
use serde_json::Value;
pub(crate) use v1::V1;
pub(crate) use v2::V2;

use super::{
    catalog::Catalog,
    client::ClientError,
    events::Event,
    http::{Http, Native},
    schema::{CommandInput, MessagePage, Prompt, Session, Statuses},
};

/// Run `$body` with `$wire` naming the dialect's implementation.
macro_rules! dispatch {
    ($dialect:expr, $wire:ident => $body:expr) => {
        match $dialect {
            $crate::opencode::wire::Dialect::V1 => {
                use $crate::opencode::wire::{Wire as _, V1 as $wire};
                $body
            },
            $crate::opencode::wire::Dialect::V2 => {
                use $crate::opencode::wire::{Wire as _, V2 as $wire};
                $body
            },
        }
    };
}
pub(crate) use dispatch;

/// A parsed `opencode --version` line.
pub(crate) struct Version {
    text: String,
    major: u32,
    minor: u32,
}

impl Version {
    /// Accept `1.19.0`, `v1.19.0` or `opencode v2.0.21`.
    pub(crate) fn parse(line: &str) -> Option<Self> {
        let token = line.split_whitespace().next_back()?;
        let text = token.strip_prefix('v').unwrap_or(token);
        let mut numbers = text.split('.').map(str::parse::<u32>);
        let (Some(Ok(major)), Some(Ok(minor))) = (numbers.next(), numbers.next()) else {
            return None;
        };
        Some(Self {
            text: text.into(),
            major,
            minor,
        })
    }

    /// The version without the executable name or a leading `v`.
    pub(crate) fn into_text(self) -> String {
        self.text
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.text)
    }
}

/// The native readiness answer.
#[derive(Deserialize)]
pub(crate) struct Health {
    pub healthy: bool,
    pub version: String,
    /// The answering process, where the server reports it (2.x).
    #[serde(default)]
    pub pid: Option<u32>,
    /// Every address the server says it is reachable at (2.x).
    #[serde(default)]
    pub urls: Vec<String>,
}

/// A validated answer to one pending native request.
#[derive(Clone, Copy)]
pub(crate) enum Reply<'a> {
    /// `once`, `always` or `reject`.
    Permission(&'a str),
    /// Selected labels, one list per question.
    Question(&'a [Vec<String>]),
    /// Dismiss the question request.
    RejectQuestion,
}

/// The native routes and shapes of one OpenCode major version. Results use
/// the 1.x shapes the host already reads.
pub(crate) trait Wire {
    /// Oldest tested release; its major names this wire's version line.
    const MIN: (u32, u32);
    /// `opencode` arguments that print the native database path.
    const DATABASE: &'static [&'static str];
    /// Startup output that precedes the listener URL.
    const LISTENING: &'static str;
    const EVENTS: &'static [&'static str];
    /// This line's own clients share one per-user background server.
    const BACKGROUND_SERVER: bool;

    /// Whether `version` is a tested release of this wire's line.
    fn tested(version: &Version) -> bool {
        version.major == Self::MIN.0 && (version.major, version.minor) >= Self::MIN
    }

    /// Decode one SSE `data` payload; `None` is a frame the host ignores.
    fn event(data: &[u8]) -> Result<Option<Event>, ClientError>;

    async fn health(http: &Http<Native>) -> Result<Health, ClientError>;

    /// Make the server open its database without touching any session.
    async fn open(http: &Http<Native>) -> Result<(), ClientError>;

    /// Bounded session inventory, across every project when `directory` is
    /// absent.
    async fn sessions(
        http: &Http<Native>,
        directory: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Session>, ClientError>;

    /// One session's metadata; a missing ID is `Http(404)`.
    async fn session(http: &Http<Native>, id: &str) -> Result<Session, ClientError>;

    async fn create(http: &Http<Native>, directory: &str) -> Result<Session, ClientError>;

    async fn rename(
        http: &Http<Native>,
        id: &str,
        directory: &str,
        title: &str,
    ) -> Result<Session, ClientError>;

    /// Execution states known to this server; absent sessions are idle.
    async fn statuses(http: &Http<Native>, directory: &str) -> Result<Statuses, ClientError>;

    /// One history page, oldest message first, before public projection.
    async fn page(
        http: &Http<Native>,
        session: &str,
        directory: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<MessagePage, ClientError>;

    async fn catalog(http: &Http<Native>, directory: Option<&str>) -> Result<Catalog, ClientError>;

    async fn permissions(http: &Http<Native>, directory: &str) -> Result<Vec<Value>, ClientError>;

    async fn questions(http: &Http<Native>, directory: &str) -> Result<Vec<Value>, ClientError>;

    /// Admit one prompt. `select` sends the prompt's model and agent as a
    /// changed selection where the wire keeps them per session.
    async fn prompt(
        http: &Http<Native>,
        session: &str,
        directory: &str,
        prompt: &Prompt,
        select: bool,
    ) -> Result<(), ClientError>;

    /// Run a known command and wait for it, without a turn-length timeout.
    async fn command(
        http: &Http<Native>,
        session: &str,
        directory: &str,
        command: &CommandInput,
        select: bool,
    ) -> Result<(), ClientError>;

    /// Answer a pending request that belongs to `session`.
    async fn reply(
        http: &Http<Native>,
        session: &str,
        request: &str,
        directory: &str,
        reply: Reply<'_>,
    ) -> Result<(), ClientError>;

    /// Interrupt execution; `false` means nothing was running here.
    async fn abort(
        http: &Http<Native>,
        session: &str,
        directory: &str,
    ) -> Result<bool, ClientError>;
}

/// The native wire chosen for one detected version.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Dialect {
    /// OpenCode 1.19 and later 1.x releases.
    V1,
    /// OpenCode 2.x.
    V2,
}

impl Dialect {
    const ALL: [Self; 2] = [Self::V1, Self::V2];

    /// The wire for `version`: the newest whose line starts at or below it,
    /// else the oldest. An untested version is not refused; it gets a notice.
    pub(crate) fn detect(version: &Version) -> (Self, Option<String>) {
        let dialect = Self::ALL
            .into_iter()
            .rev()
            .find(|dialect| version.major >= dialect.min().0)
            .unwrap_or(Self::V1);
        let notice = (!dispatch!(dialect, W => W::tested(version))).then(|| {
            let (major, minor) = dialect.min();
            if (version.major, version.minor) < (major, minor) {
                format!(
                    "OpenCode {version} is older than {major}.{minor}, the oldest version tested \
                     with native hosting; some features may not work. Update OpenCode if \
                     something fails."
                )
            } else {
                format!(
                    "OpenCode {version} is newer than the versions tested with native hosting; \
                     some features may not work."
                )
            }
        });
        (dialect, notice)
    }

    fn min(self) -> (u32, u32) {
        dispatch!(self, W => W::MIN)
    }

    pub(crate) fn database(self) -> &'static [&'static str] {
        dispatch!(self, W => W::DATABASE)
    }

    pub(crate) fn background_server(self) -> bool {
        dispatch!(self, W => W::BACKGROUND_SERVER)
    }

    pub(crate) fn listening(self) -> &'static str {
        dispatch!(self, W => W::LISTENING)
    }

    pub(crate) fn events(self) -> &'static [&'static str] {
        dispatch!(self, W => W::EVENTS)
    }

    pub(crate) fn event(self, data: &[u8]) -> Result<Option<Event>, ClientError> {
        dispatch!(self, W => W::event(data))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_line_selects_its_wire_and_untested_versions_only_warn() {
        let detect = |line| {
            let (dialect, notice) = Dialect::detect(&Version::parse(line).expect("version"));
            (dialect, notice.is_some())
        };
        assert_eq!(detect("1.19.0"), (Dialect::V1, false));
        assert_eq!(detect("v1.20.3"), (Dialect::V1, false));
        assert_eq!(detect("opencode v2.0.21"), (Dialect::V2, false));
        assert_eq!(detect("1.18.35"), (Dialect::V1, true));
        assert_eq!(detect("0.9.1"), (Dialect::V1, true));
        assert_eq!(detect("3.0.0"), (Dialect::V2, true));
        assert!(Version::parse("opencode").is_none());
        assert_eq!(
            Version::parse("opencode v2.0.21")
                .map(Version::into_text)
                .as_deref(),
            Some("2.0.21")
        );
    }
}
