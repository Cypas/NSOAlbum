// Synthetic native worker: completes one well-formed response after the deadline.
mod ipc {
    include!("device_sync_ipc.rs");
}

use std::io::Read;

fn main() {
    let stdin = std::io::stdin();
    let mut input = stdin.lock();
    if ipc::read(&mut input).is_none() {
        return;
    }
    std::thread::sleep(std::time::Duration::from_millis(250));
    let stdout = std::io::stdout();
    let mut output = stdout.lock();
    let _ = ipc::write(&mut output, r#"{"Ok":123}"#, &[]);
    let _ = input.read(&mut [0; 1]);
}
