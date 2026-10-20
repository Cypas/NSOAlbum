// Synthetic native worker: completes one well-formed response after the deadline.
use std::io::{Read, Write};

fn main() {
    let mut header = [0; 4];
    if std::io::stdin().read_exact(&mut header).is_err() {
        return;
    }
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > 524_288 {
        return;
    }
    let mut request = vec![0; length];
    if std::io::stdin().read_exact(&mut request).is_err() {
        return;
    }
    std::thread::sleep(std::time::Duration::from_millis(250));
    let response = b"{\"value\":{\"Ok\":123}}";
    let mut output = std::io::stdout().lock();
    let _ = output.write_all(&(response.len() as u32).to_be_bytes());
    let _ = output.write_all(response);
    let _ = output.flush();
    // Keep the pipe open until the parent owns teardown.
    let _ = std::io::stdin().read(&mut [0; 1]);
}
