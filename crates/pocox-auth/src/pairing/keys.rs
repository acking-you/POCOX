//! Everything derived from `POCOX_PAIRING_SECRET`.
//!
//! ```text
//! code        = crockford(HMAC(pairing_secret, encode("code", device_id, generation)))[..12]
//! code_lookup =           HMAC(pairing_secret, encode("lookup", normalized_code))
//! hardware    =           HMAC(pairing_secret, encode("hardware", hardware_key))
//! ```
//!
//! Deriving a code lets a device retrieve it with no plaintext stored. Each use
//! has its own domain tag, so no value can stand in for another.

use hmac::{Hmac, Mac};
use pocox_account_proto::pairing::{encode_tuple_with_tag, normalize_code, CODE_LENGTH};
use sha2::{Digest as _, Sha256};

use super::ticket::PreviewTicket;

type HmacSha256 = Hmac<Sha256>;

/// Crockford's Base32 alphabet: no `I`, `L`, `O` or `U`.
const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Characters in a request's matching identifier.
const MATCHING_ID_LENGTH: usize = 6;

/// The backend's pairing key and what it derives. Holds the secret only in
/// memory and never prints it.
#[derive(Clone)]
pub struct PairingKeys {
    secret: Vec<u8>,
}

impl std::fmt::Debug for PairingKeys {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("PairingKeys(redacted)")
    }
}

/// SHA-256 of a device secret. The backend stores only this.
pub fn hash_device_secret(secret: &str) -> Vec<u8> {
    Sha256::digest(secret.as_bytes()).to_vec()
}

fn crockford(bytes: &[u8], length: usize) -> String {
    let mut out = String::with_capacity(length);
    let mut buffer = 0u32;
    let mut bits = 0u32;
    let mut input = bytes.iter();
    while out.len() < length {
        if bits < 5 {
            let Some(byte) = input.next() else {
                break;
            };
            buffer = (buffer << 8) | u32::from(*byte);
            bits += 8;
        }
        bits -= 5;
        out.push(char::from(CROCKFORD[((buffer >> bits) & 31) as usize]));
        buffer &= (1 << bits) - 1;
    }
    out
}

impl PairingKeys {
    /// Build from the raw pairing secret.
    pub fn new(secret: &[u8]) -> Self {
        Self {
            secret: secret.to_vec(),
        }
    }

    pub(super) fn mac(&self, tag: &str, fields: &[&[u8]]) -> [u8; 32] {
        let mut mac = HmacSha256::new_from_slice(&self.secret).expect("HMAC takes any key length");
        mac.update(&encode_tuple_with_tag(tag, fields));
        mac.finalize().into_bytes().into()
    }

    pub(super) fn verify_mac(&self, tag: &str, fields: &[&[u8]], expected: &[u8]) -> bool {
        let mut mac = HmacSha256::new_from_slice(&self.secret).expect("HMAC takes any key length");
        mac.update(&encode_tuple_with_tag(tag, fields));
        mac.verify_slice(expected).is_ok()
    }

    /// The normalized code of one code generation of a device.
    pub fn code(&self, device_id: &str, generation: i64) -> String {
        let digest = self.mac("code", &[device_id.as_bytes(), generation.to_string().as_bytes()]);
        crockford(&digest, CODE_LENGTH)
    }

    /// The lookup of a normalized code.
    pub fn code_lookup(&self, normalized_code: &str) -> Vec<u8> {
        self.mac("lookup", &[normalized_code.as_bytes()]).to_vec()
    }

    /// The lookup of one code generation of a device.
    pub fn device_code_lookup(&self, device_id: &str, generation: i64) -> Vec<u8> {
        self.code_lookup(&self.code(device_id, generation))
    }

    /// The lookup for a code as a user typed it, or `None` if it cannot be a
    /// code.
    pub fn typed_code_lookup(&self, typed: &str) -> Option<Vec<u8>> {
        normalize_code(typed).map(|code| self.code_lookup(&code))
    }

    /// The stored index of a hardware key. Backend binding keeps the same hint
    /// from becoming a cross-backend tracking identifier.
    pub fn hardware_lookup(&self, hardware_key: &[u8; 32]) -> Vec<u8> {
        self.mac("hardware", &[hardware_key]).to_vec()
    }

    /// The identifier both devices show for one recovery request.
    pub fn matching_id(&self, request_id: &str) -> String {
        crockford(&self.mac("match", &[request_id.as_bytes()]), MATCHING_ID_LENGTH)
    }

    /// A keyed hash of an address bucket, so limiter state holds no raw
    /// address.
    pub fn address_key(&self, bucket: &[u8]) -> [u8; 16] {
        let digest = self.mac("address", &[bucket]);
        let mut key = [0u8; 16];
        key.copy_from_slice(&digest[..16]);
        key
    }

    /// The non-secret value that detects a changed pairing key at startup.
    pub fn verification_value(&self) -> Vec<u8> {
        self.mac("verify", &[b"pocox.pairing.v1"]).to_vec()
    }

    /// Sign a preview ticket.
    pub fn sign_ticket(&self, ticket: &PreviewTicket) -> String {
        ticket.sign(self)
    }

    /// The ticket this string carries, if its signature holds and it is
    /// unexpired.
    pub fn verify_ticket(&self, ticket: &str, now: i64) -> Option<PreviewTicket> {
        PreviewTicket::verify(self, ticket, now)
    }
}

#[cfg(test)]
mod tests {
    use pocox_account_proto::pairing::normalize_code;

    use super::*;

    #[test]
    fn a_derived_code_is_canonical_and_keyed() {
        let keys = PairingKeys::new(b"secret");
        let code = keys.code("device", 1);
        assert_eq!(normalize_code(&code).as_deref(), Some(code.as_str()));
        assert_ne!(code, keys.code("device", 2), "a rotation changes the code");
        assert_ne!(code, keys.code("other", 1));
        assert_ne!(code, PairingKeys::new(b"other-secret").code("device", 1));
        assert_eq!(keys.typed_code_lookup(&code.to_lowercase()), Some(keys.code_lookup(&code)));
    }

    #[test]
    fn each_derivation_has_its_own_domain() {
        let keys = PairingKeys::new(b"secret");
        let hardware = [7u8; 32];
        assert_ne!(keys.hardware_lookup(&hardware), keys.code_lookup("x"));
        assert_ne!(keys.mac("lookup", &[b"x"]), keys.mac("hardware", &[b"x"]));
    }
}
