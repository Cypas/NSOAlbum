mod ipc {
    include!("device_sync_ipc.rs");
}

fn main() {
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    while let Some((header, payload)) = ipc::read(&mut input) {
        if !payload.is_empty() {
            break;
        }
        let request = std::str::from_utf8(&header).unwrap();
        let response = if ipc::method(request) == "enumerate" {
            r#"{"Ok":[{"id":"same","name":"Synthetic A","storages":[{"id":"storage","name":"Documents","free_bytes":1024}]},{"id":"same","name":"Synthetic B","storages":[]}]}"#
        } else {
            r#"{"Ok":null}"#
        };
        if ipc::write(&mut output, response, &[]).is_err() {
            break;
        }
    }
}
