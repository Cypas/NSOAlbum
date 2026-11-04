use std::io::{Read, Write};

const MAGIC: &[u8; 8] = b"NSOMTP2\0";
const ENVELOPE_BYTES: usize = 16;
const MAX_HEADER: usize = 64 * 1024;
const MAX_PAYLOAD: usize = 8 * 1024 * 1024;
const MAX_PACKET: usize = 8 * 1024 * 1024 + 64 * 1024 + ENVELOPE_BYTES;

fn u32_at(bytes: &[u8], offset: usize) -> usize {
    ((bytes[offset] as usize) << 24)
        | ((bytes[offset + 1] as usize) << 16)
        | ((bytes[offset + 2] as usize) << 8)
        | bytes[offset + 3] as usize
}

pub fn read(input: &mut impl Read) -> Option<(Vec<u8>, Vec<u8>)> {
    let mut size = [0; 4];
    input.read_exact(&mut size).ok()?;
    let size = u32::from_be_bytes(size) as usize;
    if !(ENVELOPE_BYTES..=MAX_PACKET).contains(&size) {
        return None;
    }
    let mut envelope = [0; ENVELOPE_BYTES];
    input.read_exact(&mut envelope).ok()?;
    if &envelope[..8] != MAGIC {
        return None;
    }
    let header_len = u32_at(&envelope, 8);
    let payload_len = u32_at(&envelope, 12);
    if header_len == 0
        || header_len > MAX_HEADER
        || payload_len > MAX_PAYLOAD
        || ENVELOPE_BYTES
            .checked_add(header_len)
            .and_then(|length| length.checked_add(payload_len))
            != Some(size)
    {
        return None;
    }
    let mut header = vec![0; header_len];
    let mut payload = vec![0; payload_len];
    input.read_exact(&mut header).ok()?;
    input.read_exact(&mut payload).ok()?;
    Some((header, payload))
}

pub fn write(
    output: &mut impl Write,
    value: &str,
    payload: &[u8],
) -> std::io::Result<()> {
    let header = format!(r#"{{"value":{value},"payload_length":{}}}"#, payload.len());
    if header.is_empty() || header.len() > MAX_HEADER || payload.len() > MAX_PAYLOAD {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "IPC packet exceeds fixture bounds",
        ));
    }
    let length = ENVELOPE_BYTES + header.len() + payload.len();
    output.write_all(&(length as u32).to_be_bytes())?;
    output.write_all(MAGIC)?;
    output.write_all(&(header.len() as u32).to_be_bytes())?;
    output.write_all(&(payload.len() as u32).to_be_bytes())?;
    output.write_all(header.as_bytes())?;
    output.write_all(payload)?;
    output.flush()
}

#[allow(dead_code)]
pub fn field<'a>(request: &'a str, key: &str) -> &'a str {
    let marker = format!("\"{key}\":\"");
    request
        .split_once(&marker)
        .and_then(|(_, value)| value.split_once('"'))
        .map(|(value, _)| value)
        .expect("synthetic request contains the named string field")
}

#[allow(dead_code)]
pub fn method(request: &str) -> &str {
    field(request, "method")
}

#[allow(dead_code)]
pub fn number(request: &str, key: &str) -> Option<usize> {
    let marker = format!("\"{key}\":");
    let value = request.split_once(&marker)?.1;
    let digits = value
        .bytes()
        .take_while(|byte| byte.is_ascii_digit())
        .collect::<Vec<_>>();
    std::str::from_utf8(&digits).ok()?.parse().ok()
}
