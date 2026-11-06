//! Pure encodings the backend and its clients must agree on, here because both
//! the account protocol crate and the device store need them.

/// Prefix of a device secret: a client-generated random 256-bit bearer value.
pub const DEVICE_SECRET_PREFIX: &str = "pcxd1_";

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
