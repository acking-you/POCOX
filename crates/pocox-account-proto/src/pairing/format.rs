//! Pure formats shared by the backend and its pairing clients.

use base64::Engine as _;

/// Header every pairing request carries. A missing or unsupported value gets
/// 426 `pairing_client_upgrade_required` before any side effect.
pub const PAIRING_PROTOCOL_HEADER: &str = "x-pocox-pairing-protocol";

/// The pairing protocol this build speaks.
pub const PAIRING_PROTOCOL_VERSION: u32 = 1;

/// Prefix of a device secret: a client-generated random 256-bit bearer value.
pub const DEVICE_SECRET_PREFIX: &str = "pcxd1_";

/// The invitation URI a QR code carries, ahead of the compact code.
pub const PAIR_URI_PREFIX: &str = "pocox://pair?c=";

/// Characters in a normalized pairing code: 60 bits of Crockford Base32.
pub const CODE_LENGTH: usize = 12;

/// Longest device label the backend stores, in UTF-8 bytes.
pub const MAX_LABEL_BYTES: usize = 64;

/// Fold a typed pairing code to its 12 canonical characters, or `None` for
/// anything that cannot be one.
///
/// Ignores case and dashes, folds `I`/`L` to `1` and `O` to `0`, and rejects
/// every other character and length, so no malformed input reaches a lookup.
pub fn normalize_code(input: &str) -> Option<String> {
    let mut code = String::with_capacity(CODE_LENGTH);
    for raw in input.chars() {
        let folded = match raw.to_ascii_uppercase() {
            '-' => continue,
            'I' | 'L' => '1',
            'O' => '0',
            'U' => return None,
            other @ ('0'..='9' | 'A'..='Z') => other,
            _ => return None,
        };
        if code.len() == CODE_LENGTH {
            return None;
        }
        code.push(folded);
    }
    (code.len() == CODE_LENGTH).then_some(code)
}

/// A normalized code as people read it: `K7M2-F9QX-3RTB`.
pub fn display_code(code: &str) -> String {
    let mut out = String::with_capacity(code.len() + 2);
    for (index, ch) in code.chars().enumerate() {
        if index > 0 && index % 4 == 0 {
            out.push('-');
        }
        out.push(ch);
    }
    out
}

/// The unambiguous length-prefixed tuple encoding of the design's `encode(..)`.
pub fn encode_tuple(fields: &[&[u8]]) -> Vec<u8> {
    let size = fields.iter().map(|field| field.len() + 4).sum();
    let mut out = Vec::with_capacity(size);
    for field in fields {
        let len = u32::try_from(field.len()).expect("a tuple field fits in four gigabytes");
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(field);
    }
    out
}

/// [`encode_tuple`] with a leading domain-separation tag.
pub fn encode_tuple_with_tag(tag: &str, fields: &[&[u8]]) -> Vec<u8> {
    let mut all: Vec<&[u8]> = Vec::with_capacity(fields.len() + 1);
    all.push(tag.as_bytes());
    all.extend_from_slice(fields);
    encode_tuple(&all)
}

/// Whether `secret` has the shape of a device secret: the prefix plus 32 random
/// bytes in unpadded base64url.
pub fn secret_is_well_formed(secret: &str) -> bool {
    secret
        .strip_prefix(DEVICE_SECRET_PREFIX)
        .is_some_and(|body| parse_hardware_key(body).is_some())
}

/// Decode a hardware key from the wire: 32 bytes in unpadded base64url.
pub fn parse_hardware_key(key: &str) -> Option<[u8; 32]> {
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(key)
        .ok()?;
    <[u8; 32]>::try_from(bytes.as_slice()).ok()
}

/// Whether `id` may name an idempotent operation: a random id of 16 to 64
/// URL-safe characters.
pub fn is_operation_id(id: &str) -> bool {
    (16..=64).contains(&id.len())
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

/// A device label as stored, or `None` when empty, oversized or carrying
/// control characters.
pub fn parse_label(label: &str) -> Option<String> {
    let label = label.trim();
    let valid =
        !label.is_empty() && label.len() <= MAX_LABEL_BYTES && !label.chars().any(char::is_control);
    valid.then(|| label.to_string())
}

/// The key segment clients build their relay keys from for a pairing user.
pub fn relay_namespace_segment(user_id: &str) -> String {
    crate::key::NamespacedServiceId::namespace_of(user_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_fold_like_crockford_and_reject_everything_else() {
        assert_eq!(normalize_code("k7m2-f9qx-3rtb").as_deref(), Some("K7M2F9QX3RTB"));
        assert_eq!(normalize_code("ILO0-0000-0000").as_deref(), Some("110000000000"));
        assert_eq!(normalize_code("K7M2F9QX3RT"), None, "too short");
        assert_eq!(normalize_code("K7M2F9QX3RTBB"), None, "too long");
        assert_eq!(normalize_code("K7M2F9QX3RTU"), None, "U is outside the alphabet");
        assert_eq!(normalize_code("K7M2 F9QX 3RTB"), None, "spaces are not dashes");
        assert_eq!(display_code("K7M2F9QX3RTB"), "K7M2-F9QX-3RTB");
    }

    #[test]
    fn tuples_are_unambiguous() {
        assert_ne!(encode_tuple(&[b"ab", b"c"]), encode_tuple(&[b"a", b"bc"]));
        assert_ne!(
            encode_tuple_with_tag("code", &[b"x"]),
            encode_tuple_with_tag("lookup", &[b"x"])
        );
    }

    #[test]
    fn secrets_and_operation_ids_are_shape_checked() {
        let body = "A".repeat(43);
        assert!(secret_is_well_formed(&format!("pcxd1_{body}")));
        assert!(!secret_is_well_formed(&body));
        assert!(!secret_is_well_formed("pcxd1_short"));
        assert!(is_operation_id("0123456789abcdef"));
        assert!(!is_operation_id("short"));
        assert!(!is_operation_id("has spaces in the middle"));
    }
}
