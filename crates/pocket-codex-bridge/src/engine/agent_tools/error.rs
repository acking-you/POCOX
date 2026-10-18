//! Failures the tools report, each saying what to do next.

/// Why a tool call did not complete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolError {
    /// The user switched the tools off on this device.
    Off,
    /// No POCOX process serves the tools here.
    NotHosting,
    /// The request itself is wrong.
    Invalid(String),
    /// The user declined.
    Declined,
    /// Another POCOX process publishes this device's name.
    Conflict(String),
    /// No such share, connection or service.
    NotFound(String),
    /// It belongs to another owner; only the user can end it.
    NotOwner,
    /// The caller's token ended while the call ran (its harness stopped, or
    /// the user revoked it).
    Revoked,
    /// The change could not be saved, so it was not made.
    NotSaved,
    /// The account or relay changed while the request ran.
    ContextChanged,
    /// The relay cannot be reached or refused.
    Relay(String),
}

impl ToolError {
    /// Stable code for programs.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Off => "tools_off",
            Self::NotHosting => "not_hosting",
            Self::Invalid(_) => "invalid_request",
            Self::Declined => "declined",
            Self::Conflict(_) => "name_conflict",
            Self::NotFound(_) => "not_found",
            Self::NotOwner => "not_owner",
            Self::Revoked => "token_revoked",
            Self::NotSaved => "not_saved",
            Self::ContextChanged => "connection_changed",
            Self::Relay(_) => "relay_unavailable",
        }
    }

    /// What happened and what to do next, for the model and the user.
    pub fn message(&self) -> String {
        match self {
            Self::Off => "Agent tools are switched off on this device. The user can switch them \
                          on in POCOX settings or with `pocox tools enable`."
                .into(),
            Self::NotHosting => "POCOX is not running on this computer. Start the POCOX app, or \
                                 `pocox serve --allow-remote-management`."
                .into(),
            Self::Invalid(why) => why.clone(),
            Self::Declined => {
                "The user declined sharing this. Do not retry unless the user asks.".into()
            },
            Self::Conflict(why) => why.clone(),
            Self::NotFound(what) => {
                format!("{what} was not found. Call `services` to see what exists.")
            },
            Self::NotOwner => {
                "That belongs to another owner. Only the user can end it, in POCOX.".into()
            },
            Self::Revoked => "This harness no longer has access to the POCOX tools: it was \
                              stopped, or the user revoked its access."
                .into(),
            Self::NotSaved => "POCOX could not save this change, so nothing changed. Check the \
                               disk, then try again."
                .into(),
            Self::ContextChanged => "The account or relay changed while this ran, so nothing was \
                                     shared. Refresh, then try again."
                .into(),
            Self::Relay(why) => format!("The relay is unavailable: {why}. Try again later."),
        }
    }
}

impl std::fmt::Display for ToolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for ToolError {}

/// A share that could not finish yet; repeating the same call continues it.
#[derive(Debug, Clone, PartialEq)]
pub enum Pending {
    /// The user has not answered yet.
    WaitingForUser,
    /// The first port does not answer yet.
    WaitingForPort(u16),
}

impl Pending {
    /// Stable status for programs.
    pub fn status(&self) -> &'static str {
        match self {
            Self::WaitingForUser => "waiting_for_user",
            Self::WaitingForPort(_) => "waiting_for_port",
        }
    }

    /// What to tell the model.
    pub fn message(&self) -> String {
        match self {
            Self::WaitingForUser => "The user is being asked in POCOX whether to share this. Tell \
                                     the user to answer there, then call `connect` again with the \
                                     same arguments."
                .into(),
            Self::WaitingForPort(port) => format!(
                "Nothing answers on port {port} yet. Make sure the server is starting, then call \
                 `connect` again with the same arguments."
            ),
        }
    }
}
