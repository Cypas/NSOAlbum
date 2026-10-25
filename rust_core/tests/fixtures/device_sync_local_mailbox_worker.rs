//! Synthetic native child only. Fresh executable parent owns this test exchange.
mod ipc {
    include!("device_sync_ipc.rs");
}

use std::path::Path;

fn answer(root: &Path, request: &str, payload: Vec<u8>) -> (String, Vec<u8>) {
    if root.join("fail-native").exists() {
        return (r#"{"Err":"Io"}"#.into(), vec![]);
    }
    let method = ipc::method(request);
    let session = if method == "enumerate" || method == "close" {
        ""
    } else {
        ipc::field(request, "session")
    };
    if method != "enumerate"
        && method != "close"
        && (session.len() != 32
            || !session.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)))
    {
        return (r#"{"Err":"InvalidScope"}"#.into(), vec![]);
    }
    if method != "write" && !payload.is_empty() {
        return (r#"{"Err":"InvalidBlock"}"#.into(), vec![]);
    }

    match method {
        "discover" => (r#"{"Ok":false}"#.into(), vec![]),
        "enumerate" => (
            r#"{"Ok":[{"id":"synthetic","name":"Synthetic","storages":[{"id":"storage","name":"Synthetic","free_bytes":1099511627776}]}]}"#.into(),
            vec![],
        ),
        "open" => {
            let base = root.join("exchange").join(format!("s-{session}"));
            for direction in ["desktop", "mobile"] {
                if std::fs::create_dir_all(base.join(direction)).is_err() {
                    return (r#"{"Err":"Io"}"#.into(), vec![]);
                }
            }
            (r#"{"Ok":null}"#.into(), vec![])
        }
        "close" => (r#"{"Ok":null}"#.into(), vec![]),
        "list" | "read" | "write" | "acknowledge" => {
            let direction = if method == "write" {
                "desktop"
            } else {
                ipc::field(request, "direction")
            };
            if !["desktop", "mobile"].contains(&direction) {
                return (r#"{"Err":"InvalidScope"}"#.into(), vec![]);
            }
            let directory = root
                .join("exchange")
                .join(format!("s-{session}"))
                .join(direction);
            match method {
                "list" => {
                    let mut names = match std::fs::read_dir(directory) {
                        Ok(entries) => entries
                            .filter_map(Result::ok)
                            .filter_map(|entry| entry.file_name().into_string().ok())
                            .filter(|name| name.ends_with(".block"))
                            .collect::<Vec<_>>(),
                        Err(_) => return (r#"{"Err":"Io"}"#.into(), vec![]),
                    };
                    names.sort();
                    if names.len() > 128 {
                        return (r#"{"Err":"Bounds"}"#.into(), vec![]);
                    }
                    let names = names
                        .iter()
                        .map(|name| format!("\"{name}\""))
                        .collect::<Vec<_>>()
                        .join(",");
                    (format!(r#"{{"Ok":[{names}]}}"#), vec![])
                }
                "read" | "write" | "acknowledge" => {
                    let name = ipc::field(request, "name");
                    if name.len() != 22
                        || !name.ends_with(".block")
                        || !name[..16].bytes().all(|byte| byte.is_ascii_hexdigit())
                    {
                        return (r#"{"Err":"InvalidBlock"}"#.into(), vec![]);
                    }
                    let path = directory.join(name);
                    match method {
                        "read" => match std::fs::read(path) {
                            Ok(bytes) if !bytes.is_empty() && bytes.len() <= 8 * 1024 * 1024 => {
                                (r#"{"Ok":null}"#.into(), bytes)
                            }
                            Ok(_) => (r#"{"Err":"Bounds"}"#.into(), vec![]),
                            Err(_) => (r#"{"Err":"InvalidBlock"}"#.into(), vec![]),
                        },
                        "write" => {
                            if ipc::number(request, "payload_length") != Some(payload.len())
                                || payload.is_empty()
                                || payload.len() > 8 * 1024 * 1024
                            {
                                return (r#"{"Err":"Bounds"}"#.into(), vec![]);
                            }
                            if path.exists() {
                                return (r#"{"Err":"Duplicate"}"#.into(), vec![]);
                            }
                            let part = path.with_extension("part");
                            if std::fs::write(&part, payload).is_err()
                                || std::fs::rename(part, path).is_err()
                            {
                                return (r#"{"Err":"Io"}"#.into(), vec![]);
                            }
                            (r#"{"Ok":null}"#.into(), vec![])
                        }
                        _ => {
                            let mut names = match std::fs::read_dir(&directory) {
                                Ok(entries) => entries
                                    .filter_map(Result::ok)
                                    .filter_map(|entry| entry.file_name().into_string().ok())
                                    .filter(|entry| {
                                        entry.ends_with(".block") && entry.as_str() <= name
                                    })
                                    .collect::<Vec<_>>(),
                                Err(_) => return (r#"{"Err":"Io"}"#.into(), vec![]),
                            };
                            names.sort();
                            if names.len() > 8 {
                                return (r#"{"Err":"Bounds"}"#.into(), vec![]);
                            }
                            for entry in names {
                                if std::fs::remove_file(directory.join(entry)).is_err() {
                                    return (r#"{"Err":"Io"}"#.into(), vec![]);
                                }
                            }
                            (r#"{"Ok":null}"#.into(), vec![])
                        }
                    }
                }
                _ => unreachable!(),
            }
        }
        _ => (r#"{"Err":"Io"}"#.into(), vec![]),
    }
}

fn main() {
    let root = std::env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    while let Some((header, payload)) = ipc::read(&mut input) {
        let request = match std::str::from_utf8(&header) {
            Ok(request) => request,
            Err(_) => break,
        };
        let (value, response_payload) = answer(&root, request, payload);
        if ipc::write(&mut output, &value, &response_payload).is_err() {
            break;
        }
    }
}
