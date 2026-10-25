mod ipc {
    include!("device_sync_ipc.rs");
}

use std::io;

fn main() {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut discoveries = 0;
    while let Some((header, payload)) = ipc::read(&mut input) {
        let request = std::str::from_utf8(&header).unwrap();
        let method = ipc::method(request);
        let (value, response_payload) = match method {
            "discover" => {
                discoveries += 1;
                if discoveries == 1 {
                    (r#"{"Err":"Unavailable"}"#, vec![])
                } else {
                    (r#"{"Ok":false}"#, vec![])
                }
            }
            "open" => (r#"{"Err":"Unavailable"}"#, vec![]),
            "enumerate" => (r#"{"Ok":123}"#, vec![]),
            "write" if ipc::field(request, "name") == "0000000000000080.block" => {
                (r#"{"Err":"WindowFull"}"#, vec![])
            }
            "write" => (r#"{"Err":"InvalidBlock"}"#, vec![]),
            "read" => (r#"{"Ok":null}"#, vec![1, 2, 3]),
            "acknowledge" | "close" => (r#"{"Ok":null}"#, vec![]),
            _ => (r#"{"Err":"InvalidBlock"}"#, vec![]),
        };
        if method == "write" && payload.is_empty() {
            break;
        }
        if ipc::write(&mut output, value, &response_payload).is_err() {
            break;
        }
    }
}
