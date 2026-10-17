use std::io::{Read, Write};

fn main() {
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    loop {
        let mut length = [0; 4];
        if input.read_exact(&mut length).is_err() { break; }
        let length = u32::from_be_bytes(length) as usize;
        if length == 0 || length > 196608 { break; }
        let mut command = vec![0; length];
        if input.read_exact(&mut command).is_err() { break; }
        let response = if command.windows(9).any(|v| v == b"enumerate") {
            br#"{"value":{"Ok":[{"id":"same","name":"Synthetic A","storages":[{"id":"storage","name":"Documents","free_bytes":1024}]},{"id":"same","name":"Synthetic B","storages":[]}]}}"#.as_slice()
        } else {
            br#"{"value":{"Ok":null}}"#.as_slice()
        };
        if output.write_all(&(response.len() as u32).to_be_bytes()).is_err()
            || output.write_all(response).is_err() || output.flush().is_err() { break; }
    }
}
