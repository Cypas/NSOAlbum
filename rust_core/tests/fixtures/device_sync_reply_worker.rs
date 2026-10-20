use std::io::{Read, Write};
fn main() {
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    let mut discoveries = 0;
    loop {
        let mut header = [0; 4];
        if input.read_exact(&mut header).is_err() {
            break;
        }
        let length = u32::from_be_bytes(header) as usize;
        if length == 0 || length > 524288 {
            break;
        }
        let mut bytes = vec![0; length];
        if input.read_exact(&mut bytes).is_err() {
            break;
        }
        let reply = if bytes.windows(8).any(|w| w == b"discover") {
            discoveries += 1;
            if discoveries == 1 {
                b"{\"value\":{\"Err\":\"Unavailable\"}}".as_slice()
            } else {
                b"{\"value\":{\"Ok\":false}}".as_slice()
            }
        } else if bytes
            .windows(b"\"method\":\"open\"".len())
            .any(|w| w == b"\"method\":\"open\"")
        {
            b"{\"value\":{\"Err\":\"Unavailable\"}}".as_slice()
        } else if bytes.windows(9).any(|w| w == b"enumerate") {
            b"{\"value\":{\"Ok\":123}}".as_slice()
        } else if bytes.windows(4).any(|w| w == b"AQID") {
            b"{\"value\":{\"Err\":\"WindowFull\"}}".as_slice()
        } else if bytes
            .windows(b"\"method\":\"read\"".len())
            .any(|w| w == b"\"method\":\"read\"")
        {
            b"{\"value\":{\"Ok\":\"AQID\"}}".as_slice()
        } else if bytes
            .windows(b"\"method\":\"acknowledge\"".len())
            .any(|w| w == b"\"method\":\"acknowledge\"")
        {
            b"{\"value\":{\"Ok\":null}}".as_slice()
        } else if bytes.windows(5).any(|w| w == b"close") {
            b"{\"value\":{\"Ok\":null}}".as_slice()
        } else {
            b"{\"value\":{\"Err\":\"InvalidBlock\"}}".as_slice()
        };
        if output
            .write_all(&(reply.len() as u32).to_be_bytes())
            .is_err()
            || output.write_all(reply).is_err()
            || output.flush().is_err()
        {
            break;
        }
    }
}
