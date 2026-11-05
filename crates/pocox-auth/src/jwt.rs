//! Stateless HS256 session JWTs.

use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};

/// Claims carried in a session token.
///
/// A GitHub session is verified statelessly, so it never hits the database on
/// the hot path. A device session must also pass the database checks in
/// [`crate::Auth::authenticate_device`] on every route.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Claims {
    /// Internal user id (the relay-key namespace owner).
    pub sub: String,
    /// `pcxu:<user_id>` — the relay-key namespace prefix (informational; the
    /// namespace `/v1/relay` hands out is derived from [`Claims::sub`]).
    pub ns: String,
    /// Display name: a GitHub login, or a device's label.
    pub login: String,
    /// GitHub numeric account id. Present exactly on GitHub sessions.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gh_id: Option<i64>,
    /// Device id. Present exactly on device sessions, together with
    /// [`Self::dgen`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub did: Option<String>,
    /// Device session generation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dgen: Option<i64>,
    /// Issued-at (unix seconds).
    pub iat: i64,
    /// Expiry (unix seconds).
    pub exp: i64,
    /// Unique token id.
    pub jti: String,
}

/// Who a verified token speaks for: a closed set, so a mixed or incomplete
/// token cannot be read as either.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Principal<'a> {
    /// A GitHub account's shared session.
    GitHub {
        /// The GitHub numeric account id.
        gh_id: i64,
    },
    /// One device's session generation.
    Device {
        /// The device id.
        device_id: &'a str,
        /// The session generation.
        generation: i64,
    },
}

impl Claims {
    /// This token's principal, or `None` for a form that is neither GitHub
    /// (`gh_id` without device claims) nor pairing (`did` and `dgen` without
    /// `gh_id`).
    pub fn principal(&self) -> Option<Principal<'_>> {
        match (self.gh_id, self.did.as_deref(), self.dgen) {
            (Some(gh_id), None, None) => Some(Principal::GitHub {
                gh_id,
            }),
            (None, Some(device_id), Some(generation)) => Some(Principal::Device {
                device_id,
                generation,
            }),
            _ => None,
        }
    }
}

/// HS256 signer/verifier over a shared secret.
pub(crate) struct Jwt {
    enc: EncodingKey,
    dec: DecodingKey,
    validation: Validation,
}

impl Jwt {
    /// Build from the raw HS256 secret bytes.
    pub(crate) fn new(secret: &[u8]) -> Self {
        let mut validation = Validation::new(Algorithm::HS256);
        // We don't use the `aud` claim; don't require/validate it.
        validation.validate_aud = false;
        Self {
            enc: EncodingKey::from_secret(secret),
            dec: DecodingKey::from_secret(secret),
            validation,
        }
    }

    /// Sign `claims` into a compact JWT.
    pub(crate) fn issue(&self, claims: &Claims) -> Result<String, jsonwebtoken::errors::Error> {
        encode(&Header::new(Algorithm::HS256), claims, &self.enc)
    }

    /// Verify a token's signature and expiry, returning its claims.
    pub(crate) fn verify(&self, token: &str) -> Result<Claims, jsonwebtoken::errors::Error> {
        Ok(decode::<Claims>(token, &self.dec, &self.validation)?.claims)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claims(exp: i64) -> Claims {
        Claims {
            sub: "u1".to_string(),
            ns: "pcxu:u1".to_string(),
            login: "octocat".to_string(),
            gh_id: Some(42),
            did: None,
            dgen: None,
            iat: 0,
            exp,
            jti: "j1".to_string(),
        }
    }

    #[test]
    fn round_trips_a_valid_token() {
        let jwt = Jwt::new(b"secret");
        let token = jwt.issue(&claims(99_999_999_999)).expect("issue");
        let got = jwt.verify(&token).expect("verify");
        assert_eq!(got.sub, "u1");
        assert_eq!(got.gh_id, Some(42));
        assert_eq!(got.ns, "pcxu:u1");
    }

    #[test]
    fn a_legacy_github_token_keeps_its_form_and_mixed_forms_have_no_principal() {
        // A token issued before device claims existed has no such fields at all.
        let legacy = r#"{"sub":"u","ns":"pcxu:u","login":"o","gh_id":7,"iat":0,"exp":1,"jti":"j"}"#;
        let legacy: Claims = serde_json::from_str(legacy).expect("legacy claims");
        assert_eq!(
            legacy.principal(),
            Some(Principal::GitHub {
                gh_id: 7
            })
        );

        let with = |gh_id, did: Option<&str>, dgen| Claims {
            gh_id,
            did: did.map(str::to_string),
            dgen,
            ..claims(1)
        };
        assert_eq!(
            with(None, Some("d"), Some(3)).principal(),
            Some(Principal::Device {
                device_id: "d",
                generation: 3
            })
        );
        assert_eq!(with(Some(1), Some("d"), Some(3)).principal(), None, "mixed");
        assert_eq!(with(None, Some("d"), None).principal(), None, "no generation");
        assert_eq!(with(None, None, Some(3)).principal(), None, "no device");
        assert_eq!(with(None, None, None).principal(), None, "nothing");
    }

    #[test]
    fn rejects_a_token_signed_with_a_different_secret() {
        let token = Jwt::new(b"secret")
            .issue(&claims(99_999_999_999))
            .expect("issue");
        assert!(Jwt::new(b"other-secret").verify(&token).is_err());
    }

    #[test]
    fn rejects_an_expired_token() {
        let jwt = Jwt::new(b"secret");
        let token = jwt.issue(&claims(1)).expect("issue"); // exp in 1970
        assert!(jwt.verify(&token).is_err());
    }
}
