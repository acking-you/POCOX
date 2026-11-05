//! Preview tickets: what a user confirmed, signed and bound to who confirmed
//! it.

use base64::Engine as _;
use serde::{Deserialize, Serialize};

use super::keys::PairingKeys;

/// How long a preview stays confirmable.
pub const PREVIEW_TICKET_TTL_SECS: i64 = 5 * 60;

const TICKET_TAG: &str = "ticket";

/// Everything a link or restore revalidates in its committing transaction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviewTicket {
    /// The device that previewed.
    pub caller_device_id: String,
    /// Its session generation at the time.
    pub caller_generation: i64,
    /// Its group's membership revision at the time.
    pub source_revision: i64,
    /// The device whose code was entered.
    pub target_device_id: String,
    /// That code's generation. A rotation invalidates the ticket.
    pub code_generation: i64,
    /// The group the user saw.
    pub user_id: String,
    /// That group's membership revision.
    pub revision: i64,
    /// Expiry (unix seconds).
    pub exp: i64,
}

impl PreviewTicket {
    pub(super) fn sign(&self, keys: &PairingKeys) -> String {
        let encoder = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let payload = serde_json::to_vec(self).expect("a ticket is plain JSON");
        let signature = keys.mac(TICKET_TAG, &[&payload]);
        format!("{}.{}", encoder.encode(&payload), encoder.encode(signature))
    }

    pub(super) fn verify(keys: &PairingKeys, ticket: &str, now: i64) -> Option<Self> {
        let decoder = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let (payload, signature) = ticket.split_once('.')?;
        let payload = decoder.decode(payload).ok()?;
        let signature = decoder.decode(signature).ok()?;
        if !keys.verify_mac(TICKET_TAG, &[&payload], &signature) {
            return None;
        }
        let ticket: Self = serde_json::from_slice(&payload).ok()?;
        (ticket.exp > now).then_some(ticket)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ticket(exp: i64) -> PreviewTicket {
        PreviewTicket {
            caller_device_id: "caller".into(),
            caller_generation: 1,
            source_revision: 0,
            target_device_id: "target".into(),
            code_generation: 1,
            user_id: "user".into(),
            revision: 3,
            exp,
        }
    }

    #[test]
    fn a_ticket_verifies_until_it_expires_and_only_under_its_key() {
        let keys = PairingKeys::new(b"secret");
        let signed = keys.sign_ticket(&ticket(100));
        assert_eq!(keys.verify_ticket(&signed, 99), Some(ticket(100)));
        assert_eq!(keys.verify_ticket(&signed, 100), None, "expired");
        assert_eq!(PairingKeys::new(b"other").verify_ticket(&signed, 99), None);
    }

    #[test]
    fn a_tampered_ticket_does_not_verify() {
        let keys = PairingKeys::new(b"secret");
        let signed = keys.sign_ticket(&ticket(100));
        let (_, signature) = signed.split_once('.').expect("signed form");
        let encoder = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let forged_payload = serde_json::to_vec(&PreviewTicket {
            user_id: "someone-else".into(),
            ..ticket(100)
        })
        .expect("json");
        let forged = format!("{}.{signature}", encoder.encode(forged_payload));
        assert_eq!(keys.verify_ticket(&forged, 99), None);
        assert_eq!(keys.verify_ticket("garbage", 99), None);
    }
}
