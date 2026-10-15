//! A custom model provider an agent host can be pointed at: its API
//! protocol, base URL, optional default model and key.
//!
//! These are engine-neutral values. Each engine maps them onto its own,
//! actually supported configuration mechanism (`pocket-codex-codex` for
//! native Codex and the Claude adapter); an
//! engine that cannot speak a protocol refuses it there.

use std::fmt;

/// The wire API a custom provider speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ApiProtocol {
    /// OpenAI Responses (`POST <base>/responses`).
    Responses,
    /// Anthropic Messages (`POST <base>/messages`).
    AnthropicMessages,
    /// OpenAI Chat Completions (`POST <base>/chat/completions`).
    ChatCompletions,
}

impl ApiProtocol {
    /// Every protocol, in display order.
    pub const ALL: [ApiProtocol; 3] =
        [ApiProtocol::Responses, ApiProtocol::AnthropicMessages, ApiProtocol::ChatCompletions];

    /// Stable wire / storage name.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Responses => "responses",
            Self::AnthropicMessages => "anthropic-messages",
            Self::ChatCompletions => "chat-completions",
        }
    }

    /// Parse a stable name; `None` for anything else.
    pub fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.as_str() == raw)
    }
}

impl fmt::Display for ApiProtocol {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A secret value (an API key). Its `Debug` and `Display` never show it, so
/// it can sit in option structs that are logged; only [`Secret::expose`]
/// hands the value to the one place that needs it (a child environment).
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    /// Wrap `value`.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// The value itself.
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// Whether it is empty.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(<redacted>)")
    }
}

impl fmt::Display for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

/// One custom provider, validated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderEndpoint {
    /// The API it speaks.
    pub protocol: ApiProtocol,
    /// Its base URL, as validated by [`validate_base_url`].
    pub base_url: String,
    /// Its key, if it needs one.
    pub key: Option<Secret>,
    /// The model to use by default, when the engine needs one named.
    pub model: Option<String>,
}

impl ProviderEndpoint {
    /// A fingerprint of what this provider is — protocol, URL and model,
    /// never the key — for deriving identities that must change when the
    /// provider does.
    pub fn fingerprint(&self) -> String {
        format!(
            "{}\n{}\n{}",
            self.protocol.as_str(),
            self.base_url,
            self.model.as_deref().unwrap_or_default()
        )
    }
}

/// Why a base URL was refused. The message never repeats the URL, which
/// may hold a credential the user pasted by mistake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UrlError {
    /// Empty after trimming.
    Empty,
    /// Not an absolute URL.
    Malformed,
    /// Neither `http` nor `https`.
    Scheme,
    /// No host.
    Host,
    /// A user name or password inside the URL.
    Credentials,
    /// A `#fragment`, which no HTTP API receives.
    Fragment,
}

impl fmt::Display for UrlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Empty => "the provider base URL is required",
            Self::Malformed => "the provider base URL is not an absolute URL",
            Self::Scheme => "the provider base URL must start with http:// or https://",
            Self::Host => "the provider base URL has no host",
            Self::Credentials => {
                "the provider base URL must not contain a user name or password; enter the key \
                 separately"
            },
            Self::Fragment => "the provider base URL must not contain a #fragment",
        })
    }
}

impl std::error::Error for UrlError {}

/// Validate a provider base URL and return it as given, minus surrounding
/// whitespace and one trailing `/`. Nothing is appended or substituted (no
/// `/v1`, `/responses` or `/messages`): the URL is the provider's base as
/// its documentation names it. Loopback and private hosts are allowed.
pub fn validate_base_url(raw: &str) -> Result<String, UrlError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(UrlError::Empty);
    }
    if trimmed.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(UrlError::Malformed);
    }
    let parsed = url::Url::parse(trimmed).map_err(|_| UrlError::Malformed)?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(UrlError::Scheme);
    }
    if parsed.host_str().is_none_or(str::is_empty) {
        return Err(UrlError::Host);
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(UrlError::Credentials);
    }
    if parsed.fragment().is_some() {
        return Err(UrlError::Fragment);
    }
    Ok(trimmed.strip_suffix('/').unwrap_or(trimmed).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocols_round_trip_their_names() {
        for protocol in ApiProtocol::ALL {
            assert_eq!(ApiProtocol::parse(protocol.as_str()), Some(protocol));
        }
        assert_eq!(ApiProtocol::parse("chat"), None);
        assert_eq!(ApiProtocol::parse(""), None);
    }

    #[test]
    fn secrets_are_never_formatted() {
        let secret = Secret::new("sk-very-secret");
        assert_eq!(format!("{secret:?}"), "Secret(<redacted>)");
        assert_eq!(secret.to_string(), "<redacted>");
        let endpoint = ProviderEndpoint {
            protocol: ApiProtocol::Responses,
            base_url: "https://api.example.com/v1".into(),
            key: Some(secret.clone()),
            model: None,
        };
        assert!(!format!("{endpoint:?}").contains("sk-very-secret"));
        assert!(!endpoint.fingerprint().contains("sk-very-secret"));
        assert_eq!(secret.expose(), "sk-very-secret");
    }

    #[test]
    fn base_urls_are_kept_as_given() {
        assert_eq!(
            validate_base_url(" https://api.example.com/v1/ ").as_deref(),
            Ok("https://api.example.com/v1")
        );
        // Nothing is appended or substituted.
        assert_eq!(
            validate_base_url("https://gw.example.com").as_deref(),
            Ok("https://gw.example.com")
        );
        // Deliberate local endpoints are normal.
        assert_eq!(
            validate_base_url("http://127.0.0.1:8080/v1").as_deref(),
            Ok("http://127.0.0.1:8080/v1")
        );
        assert_eq!(
            validate_base_url("http://localhost:11434/v1").as_deref(),
            Ok("http://localhost:11434/v1")
        );
    }

    #[test]
    fn unsafe_or_unsupported_urls_are_refused_without_echo() {
        assert_eq!(validate_base_url("  "), Err(UrlError::Empty));
        assert_eq!(validate_base_url("api.example.com/v1"), Err(UrlError::Malformed));
        assert_eq!(validate_base_url("ftp://example.com"), Err(UrlError::Scheme));
        assert_eq!(validate_base_url("file:///etc/passwd"), Err(UrlError::Scheme));
        assert_eq!(validate_base_url("https://u:sk-1@example.com/v1"), Err(UrlError::Credentials));
        assert_eq!(validate_base_url("https://u@example.com/v1"), Err(UrlError::Credentials));
        assert_eq!(validate_base_url("https://example.com/v1#x"), Err(UrlError::Fragment));
        assert_eq!(validate_base_url("https://exa mple.com"), Err(UrlError::Malformed));
        let message = UrlError::Credentials.to_string();
        assert!(!message.contains("sk-1"));
    }
}
