//! One fixed header followed by raw media bytes; JSON is reserved for control.
use super::{Envelope, Message, SessionError, MEDIA_CHUNK};

pub(super) const MAGIC: &[u8; 8] = b"NSOMED2\0";
const HEADER: usize = 100;

pub(super) fn encode(
    envelope: &Envelope,
    sha: &str,
    offset: u64,
    bytes: &[u8],
) -> Result<Vec<u8>, SessionError> {
    if envelope.version != 1
        || envelope.generation != 1
        || !crate::device_sync::qr::valid_hex(&envelope.session, 32)
        || !crate::device_sync::qr::valid_hex(&envelope.operation, 32)
        || !crate::device_sync::qr::valid_hex(sha, 64)
    {
        return Err(SessionError::Protocol);
    }
    if bytes.is_empty()
        || bytes.len() > MEDIA_CHUNK
        || offset.checked_add(bytes.len() as u64).is_none()
    {
        return Err(SessionError::Bounds);
    }
    let mut output = Vec::with_capacity(HEADER + bytes.len());
    output.extend_from_slice(MAGIC);
    for value in [&envelope.session, &envelope.operation] {
        output.extend(hex::decode(value).map_err(|_| SessionError::Protocol)?);
    }
    output.extend_from_slice(&envelope.generation.to_be_bytes());
    output.extend_from_slice(&envelope.sequence.to_be_bytes());
    output.extend(hex::decode(sha).map_err(|_| SessionError::Protocol)?);
    output.extend_from_slice(&offset.to_be_bytes());
    output.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    output.extend_from_slice(bytes);
    Ok(output)
}

pub(super) fn decode(bytes: &[u8]) -> Result<Envelope, SessionError> {
    if bytes.len() < HEADER || bytes.len() > HEADER + MEDIA_CHUNK {
        return Err(SessionError::Bounds);
    }
    let length = u32::from_be_bytes(bytes[96..100].try_into().unwrap()) as usize;
    let offset = u64::from_be_bytes(bytes[88..96].try_into().unwrap());
    if length == 0
        || length > MEDIA_CHUNK
        || bytes.len() != HEADER + length
        || offset.checked_add(length as u64).is_none()
    {
        return Err(SessionError::Bounds);
    }
    let generation = u64::from_be_bytes(bytes[40..48].try_into().unwrap());
    if bytes[..8] != *MAGIC || generation != 1 {
        return Err(SessionError::Protocol);
    }
    Ok(Envelope {
        version: 1,
        session: hex::encode(&bytes[8..24]),
        operation: hex::encode(&bytes[24..40]),
        generation,
        sequence: u64::from_be_bytes(bytes[48..56].try_into().unwrap()),
        message: Message::FileChunk {
            sha256: hex::encode(&bytes[56..88]),
            offset,
            data: bytes[HEADER..].to_vec(),
        },
    })
}
