//! Synthetic native child only. Fresh executable parent owns this test exchange.
use std::io::{Read, Write};
use std::path::Path;

const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
fn encode(bytes: &[u8]) -> String {
    let mut value = String::new();
    for chunk in bytes.chunks(3) {
        let packed = ((chunk[0] as u32) << 16)
            | ((chunk.get(1).copied().unwrap_or(0) as u32) << 8)
            | chunk.get(2).copied().unwrap_or(0) as u32;
        value.push(ALPHABET[((packed >> 18) & 63) as usize] as char);
        value.push(ALPHABET[((packed >> 12) & 63) as usize] as char);
        value.push(if chunk.len() > 1 {
            ALPHABET[((packed >> 6) & 63) as usize] as char
        } else {
            '='
        });
        value.push(if chunk.len() > 2 {
            ALPHABET[(packed & 63) as usize] as char
        } else {
            '='
        });
    }
    value
}
fn decode(value: &str) -> Vec<u8> {
    let mut output = Vec::new();
    for chunk in value.as_bytes().chunks_exact(4) {
        let mut packed = 0_u32;
        for byte in chunk {
            packed = (packed << 6)
                | if *byte == b'=' {
                    0
                } else {
                    ALPHABET
                        .iter()
                        .position(|candidate| candidate == byte)
                        .unwrap() as u32
                };
        }
        output.push((packed >> 16) as u8);
        if chunk[2] != b'=' {
            output.push((packed >> 8) as u8);
        }
        if chunk[3] != b'=' {
            output.push(packed as u8);
        }
    }
    output
}
fn field<'a>(request: &'a str, key: &str) -> &'a str {
    let marker = format!("\"{key}\":\"");
    let value = request.split_once(&marker).unwrap().1;
    value.split_once('"').unwrap().0
}
fn answer(root: &Path, request: &str) -> String {
    if root.join("fail-native").exists() {
        return r#"{"value":{"Err":"Io"}}"#.into();
    }
    let method = field(request, "method");
    let value = match method {
        "enumerate" => r#"[{"id":"synthetic","name":"Synthetic","storages":[{"id":"storage","name":"Synthetic","free_bytes":1099511627776}]}]"#.into(),
        "open" => {
            let session = field(request, "session");
            for direction in ["desktop", "mobile"] {
                std::fs::create_dir_all(root.join("exchange").join(format!("s-{session}")).join(direction)).unwrap();
            }
            "null".into()
        }
        "close" => "null".into(),
        _ => {
            let session = field(request, "session");
            assert_eq!(session.len(), 32);
            let direction = if method == "write" { "desktop" } else { field(request, "direction") };
            assert!(["desktop", "mobile"].contains(&direction));
            let directory = root.join("exchange").join(format!("s-{session}")).join(direction);
            match method {
                "list" => {
                    let mut names: Vec<_> = std::fs::read_dir(directory).unwrap().map(|entry| entry.unwrap().file_name().into_string().unwrap()).filter(|name| name.ends_with(".block")).collect();
                    names.sort();
                    assert!(names.len() <= 128);
                    format!("[{}]", names.iter().map(|name| format!("\"{name}\"")).collect::<Vec<_>>().join(","))
                }
                "read" | "write" | "acknowledge" => {
                    let name = field(request, "name");
                    assert!(name.len() == 22 && name.ends_with(".block") && name[..16].bytes().all(|byte| byte.is_ascii_hexdigit()));
                    let path = directory.join(name);
                    match method {
                        "read" => {
                            let bytes = std::fs::read(path).unwrap();
                            if bytes.is_empty() || bytes.len() > 8 * 1024 * 1024 {
                                return r#"{"value":{"Err":"Bounds"}}"#.into();
                            }
                            format!("\"{}\"", encode(&bytes))
                        }
                        "write" => {
                            let bytes = decode(field(request, "bytes"));
                            if bytes.is_empty() || bytes.len() > 8 * 1024 * 1024 {
                                return r#"{"value":{"Err":"Bounds"}}"#.into();
                            }
                            assert!(!path.exists());
                            let part = path.with_extension("part");
                            std::fs::write(&part, bytes).unwrap();
                            std::fs::rename(part, path).unwrap();
                            "null".into()
                        }
                        _ => {
                            let mut names: Vec<_> = std::fs::read_dir(&directory).unwrap()
                                .map(|entry| entry.unwrap().file_name().into_string().unwrap())
                                .filter(|entry| entry.ends_with(".block") && entry.as_str() <= name)
                                .collect();
                            names.sort();
                            assert!(names.len() <= 8);
                            for entry in names { std::fs::remove_file(directory.join(entry)).unwrap(); }
                            "null".into()
                        }
                    }
                }
                _ => panic!("unsupported synthetic request"),
            }
        }
    };
    format!("{{\"value\":{{\"Ok\":{value}}}}}")
}
fn main() {
    let executable = std::env::current_exe().unwrap();
    let root = executable.parent().unwrap();
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    loop {
        let mut header = [0; 4];
        if input.read_exact(&mut header).is_err() {
            break;
        }
        let length = u32::from_be_bytes(header) as usize;
        assert!((1..=12 * 1024 * 1024).contains(&length));
        let mut bytes = vec![0; length];
        input.read_exact(&mut bytes).unwrap();
        let response = answer(root, std::str::from_utf8(&bytes).unwrap());
        if output
            .write_all(&(response.len() as u32).to_be_bytes())
            .is_err()
            || output.write_all(response.as_bytes()).is_err()
            || output.flush().is_err()
        {
            break;
        }
    }
}
