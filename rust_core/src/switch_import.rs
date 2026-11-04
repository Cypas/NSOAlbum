//! Hidden-worker entry point for Nintendo Switch USB album import.
//!
//! The worker speaks newline-delimited JSON and is spawned with a hidden
//! window. It never prints device names, paths or file contents to logs.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SwitchMtpEntry {
    pub game_name: String,
    pub file_name: String,
    pub size_bytes: u64,
    #[serde(default)]
    pub captured_at: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SwitchMtpStageStatus {
    pub phase: String,
    pub completed_files: i64,
    pub total_files: i64,
    pub completed_bytes: i64,
    pub total_bytes: i64,
    pub current_file: Option<String>,
    pub error_code: Option<String>,
    pub error: Option<String>,
    pub staged_files: Vec<String>,
}

#[cfg(any(windows, target_os = "macos"))]
mod imp {
    use super::SwitchMtpEntry;
    use mtp_rs::mtp::{
        Backend, ByteRange, ListingItem, MtpDevice, ObjectHandle, ObjectInfo, Storage, UtcOffset,
    };
    use serde_json::json;
    use std::io::{BufRead, Write};
    use std::path::{Path, PathBuf};
    use tokio::io::AsyncWriteExt;

    const DEVICE_NAMES: [&str; 2] = ["Nintendo Switch", "Nintendo Switch 2"];

    #[derive(Debug)]
    enum ImportError {
        Disconnected,
        Unavailable,
        Io,
        Invalid,
    }

    impl ImportError {
        fn code(&self) -> &'static str {
            match self {
                Self::Disconnected => "disconnected",
                Self::Unavailable => "unavailable",
                Self::Io => "io",
                Self::Invalid => "invalid",
            }
        }

        fn message(&self) -> &'static str {
            match self {
                Self::Disconnected => "Switch USB device disconnected",
                Self::Unavailable => "Switch USB device is unavailable",
                Self::Io => "Unable to write the staged Nintendo media",
                Self::Invalid => "Invalid Nintendo import request",
            }
        }
    }

    fn map_mtp(error: mtp_rs::mtp::Error) -> ImportError {
        match error {
            mtp_rs::mtp::Error::Disconnected | mtp_rs::mtp::Error::NotFound => {
                ImportError::Disconnected
            }
            _ => ImportError::Unavailable,
        }
    }

    fn builder() -> mtp_rs::mtp::MtpDeviceBuilder {
        MtpDevice::builder()
            .backend(if cfg!(windows) {
                Backend::Wpd
            } else {
                Backend::Usb
            })
            .timeout(std::time::Duration::from_secs(15))
    }

    async fn list(
        storage: &Storage,
        parent: Option<ObjectHandle>,
    ) -> Result<Vec<ObjectInfo>, ImportError> {
        let mut listing = storage.list_objects_stream(parent).await.map_err(map_mtp)?;
        let mut values = Vec::new();
        while let Some(item) = listing.next().await {
            let item = item.map_err(map_mtp)?;
            if let ListingItem::Object(info) = item {
                values.push(info);
            }
        }
        Ok(values)
    }

    async fn find_folder(
        storage: &Storage,
        parent: Option<ObjectHandle>,
        name: &str,
    ) -> Result<ObjectHandle, ImportError> {
        list(storage, parent)
            .await?
            .into_iter()
            .find(|item| item.is_folder() && item.filename == name)
            .map(|item| item.handle)
            .ok_or(ImportError::Unavailable)
    }

    async fn open_target(name: &str) -> Result<(MtpDevice, Storage, ObjectHandle), ImportError> {
        let candidates = MtpDevice::list_devices().map_err(map_mtp)?;
        for candidate in candidates {
            let Ok(device) = builder().open_by_location(candidate.location_id).await else {
                continue;
            };
            if !DEVICE_NAMES.contains(&device.device_info().model.as_str()) {
                let _ = device.close().await;
                continue;
            }
            if device.device_info().model != name {
                let _ = device.close().await;
                continue;
            }
            let storages = match device.storages().await {
                Ok(values) => values,
                Err(error) => {
                    let _ = device.close().await;
                    return Err(map_mtp(error));
                }
            };
            for storage in storages {
                let album = if storage.info().description.eq_ignore_ascii_case("Album") {
                    Ok(ObjectHandle::ROOT)
                } else {
                    find_folder(&storage, None, "Album").await
                };
                match album {
                    Ok(album) => return Ok((device, storage, album)),
                    Err(ImportError::Unavailable) => continue,
                    Err(error) => return Err(error),
                }
            }
            let _ = device.close().await;
        }
        Err(ImportError::Disconnected)
    }

    fn supported(name: &str) -> bool {
        matches!(
            Path::new(name)
                .extension()
                .and_then(|value| value.to_str())
                .map(|value| value.to_ascii_lowercase())
                .as_deref(),
            Some("jpg" | "jpeg" | "png" | "webp" | "mp4" | "mov")
        )
    }

    fn captured_at(name: &str, modified: Option<mtp_rs::mtp::DateTime>) -> Option<String> {
        if name.len() >= 14 {
            let prefix = &name[..14];
            if prefix.bytes().all(|byte| byte.is_ascii_digit()) {
                if let Ok(value) = chrono::NaiveDateTime::parse_from_str(prefix, "%Y%m%d%H%M%S") {
                    return Some(value.format("%Y-%m-%dT%H:%M:%S").to_string());
                }
            }
        }
        let seconds = modified?.to_unix_seconds_with_fallback(UtcOffset::UTC)?;
        chrono::DateTime::from_timestamp(seconds, 0).map(|value| value.to_rfc3339())
    }

    fn safe_game(name: &str) -> String {
        let mut value = String::with_capacity(name.len());
        for character in name.chars() {
            value.push(if "\\/:*?\"<>|".contains(character) {
                '＿'
            } else {
                character
            });
        }
        let value = value.trim().trim_end_matches('.').to_string();
        if value.is_empty() {
            "Unknown Game".into()
        } else {
            value
        }
    }

    fn listing_parent(handle: ObjectHandle) -> Option<ObjectHandle> {
        (handle.0 != 0).then_some(handle)
    }

    async fn devices() -> Result<Vec<String>, ImportError> {
        let mut names = Vec::new();
        for candidate in MtpDevice::list_devices().map_err(map_mtp)? {
            let Ok(device) = builder().open_by_location(candidate.location_id).await else {
                continue;
            };
            let name = device.device_info().model.clone();
            let _ = device.close().await;
            if DEVICE_NAMES.contains(&name.as_str()) && !names.contains(&name) {
                names.push(name);
            }
        }
        Ok(names)
    }

    async fn scan(name: &str) -> Result<(Vec<SwitchMtpEntry>, MtpDevice), ImportError> {
        let (device, storage, album) = open_target(name).await?;
        let result = async {
            let games = list(&storage, listing_parent(album)).await?;
            let mut entries = Vec::new();
            for game in games.into_iter().filter(ObjectInfo::is_folder) {
                for item in list(&storage, Some(game.handle)).await? {
                    if item.is_folder() || !supported(&item.filename) {
                        continue;
                    }
                    entries.push(SwitchMtpEntry {
                        game_name: game.filename.clone(),
                        file_name: item.filename.clone(),
                        size_bytes: item.size,
                        captured_at: captured_at(&item.filename, item.modified),
                    });
                }
            }
            entries.sort_by(|left, right| {
                left.game_name
                    .cmp(&right.game_name)
                    .then_with(|| left.file_name.cmp(&right.file_name))
            });
            Ok(entries)
        }
        .await;
        result.map(|entries| (entries, device))
    }

    async fn stage(
        name: &str,
        entries: Vec<SwitchMtpEntry>,
        target: PathBuf,
        output: &mut impl Write,
    ) -> Result<(Vec<String>, MtpDevice), ImportError> {
        if entries.is_empty() || !target.is_absolute() {
            return Err(ImportError::Invalid);
        }
        let (device, storage, album) = open_target(name).await?;
        let result = async {
            let album_target = target.join("Album");
            std::fs::create_dir_all(&album_target).map_err(|_| ImportError::Io)?;
            let games = list(&storage, listing_parent(album)).await?;
            let index = games
                .into_iter()
                .filter(ObjectInfo::is_folder)
                .map(|game| (game.filename.clone(), game.handle))
                .collect::<std::collections::HashMap<_, _>>();
            let total_files = entries.len() as u64;
            let total_bytes = entries.iter().map(|entry| entry.size_bytes).sum::<u64>();
            let mut completed_files = 0_u64;
            let mut completed_bytes = 0_u64;
            let mut staged = Vec::new();
            for entry in entries {
                let game = index
                    .get(&entry.game_name)
                    .ok_or(ImportError::Disconnected)?;
                let item = list(&storage, Some(*game))
                    .await?
                    .into_iter()
                    .find(|item| !item.is_folder() && item.filename == entry.file_name)
                    .ok_or(ImportError::Disconnected)?;
                let game_dir = album_target.join(safe_game(&entry.game_name));
                std::fs::create_dir_all(&game_dir).map_err(|_| ImportError::Io)?;
                let final_path = game_dir.join(&entry.file_name);
                let part_path = game_dir.join(format!("{}.part", entry.file_name));
                let mut file = tokio::fs::File::create(&part_path)
                    .await
                    .map_err(|_| ImportError::Io)?;
                let mut download = storage
                    .download(item.handle, ByteRange::Full)
                    .await
                    .map_err(map_mtp)?;
                while let Some(chunk) = download.next_chunk().await {
                    let chunk = chunk.map_err(map_mtp)?;
                    file.write_all(&chunk).await.map_err(|_| ImportError::Io)?;
                    completed_bytes = completed_bytes.saturating_add(chunk.len() as u64);
                    let _ = writeln!(
                        output,
                        "{}",
                        json!({
                            "event": "progress",
                            "phase": "copying",
                            "completedFiles": completed_files,
                            "totalFiles": total_files,
                            "completedBytes": completed_bytes,
                            "totalBytes": total_bytes,
                            "currentFile": format!("{}/{}", entry.game_name, entry.file_name),
                        })
                    );
                    let _ = output.flush();
                }
                file.flush().await.map_err(|_| ImportError::Io)?;
                drop(file);
                tokio::fs::rename(&part_path, &final_path)
                    .await
                    .map_err(|_| ImportError::Io)?;
                completed_files += 1;
                staged.push(final_path.to_string_lossy().into_owned());
                let _ = writeln!(
                    output,
                    "{}",
                    json!({
                        "event": "progress",
                        "phase": "copying",
                        "completedFiles": completed_files,
                        "totalFiles": total_files,
                        "completedBytes": completed_bytes,
                        "totalBytes": total_bytes,
                        "currentFile": format!("{}/{}", entry.game_name, entry.file_name),
                    })
                );
                let _ = output.flush();
            }
            Ok(staged)
        }
        .await;
        result.map(|files| (files, device))
    }

    fn emit(output: &mut impl Write, value: serde_json::Value) {
        let _ = writeln!(output, "{value}");
        let _ = output.flush();
    }

    pub fn worker_main() -> ! {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("switch import runtime");
        let stdin = std::io::stdin();
        let mut stdout = std::io::stdout().lock();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            let Ok(request) = serde_json::from_str::<serde_json::Value>(&line) else {
                emit(
                    &mut stdout,
                    json!({"event":"error","code":"invalid","message":"Invalid request"}),
                );
                break;
            };
            match request.get("cmd").and_then(|value| value.as_str()) {
                Some("devices") => match runtime.block_on(devices()) {
                    Ok(devices) => emit(&mut stdout, json!({"event":"devices","devices":devices})),
                    Err(error) => emit(
                        &mut stdout,
                        json!({"event":"error","code":error.code(),"message":error.message()}),
                    ),
                },
                Some("scan") => {
                    let name = request
                        .get("device")
                        .and_then(|value| value.as_str())
                        .unwrap_or_default();
                    match runtime.block_on(scan(name)) {
                        Ok((entries, device)) => {
                            emit(&mut stdout, json!({"event":"scan","entries":entries}));
                            std::mem::forget(device);
                            break;
                        }
                        Err(error) => emit(
                            &mut stdout,
                            json!({"event":"error","code":error.code(),"message":error.message()}),
                        ),
                    }
                }
                Some("stage") => {
                    let name = request
                        .get("device")
                        .and_then(|value| value.as_str())
                        .unwrap_or_default();
                    let entries = request
                        .get("entries")
                        .cloned()
                        .and_then(|value| serde_json::from_value(value).ok())
                        .unwrap_or_default();
                    let target = request
                        .get("target")
                        .and_then(|value| value.as_str())
                        .map(PathBuf::from)
                        .unwrap_or_default();
                    match runtime.block_on(stage(name, entries, target, &mut stdout)) {
                        Ok((files, device)) => {
                            emit(&mut stdout, json!({"event":"done","files":files}));
                            std::mem::forget(device);
                        }
                        Err(error) => emit(
                            &mut stdout,
                            json!({"event":"error","code":error.code(),"message":error.message()}),
                        ),
                    }
                    break;
                }
                _ => {
                    emit(
                        &mut stdout,
                        json!({"event":"error","code":"invalid","message":"Unknown command"}),
                    );
                    break;
                }
            }
        }
        std::process::exit(0);
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn switch_import_filters_extensions_and_sanitizes_game_names() {
            assert!(supported("2026010112000001.JPG"));
            assert!(supported("clip.mp4"));
            assert!(!supported("notes.txt"));
            assert_eq!(safe_game("ゼルダ: 王国/泪."), "ゼルダ＿ 王国＿泪");
            assert_eq!(safe_game("   "), "Unknown Game");
        }

        #[test]
        fn switch_import_prefers_filename_timestamp() {
            let value = captured_at(
                "2026103111223301.jpg",
                mtp_rs::mtp::DateTime::new(2020, 1, 1, 0, 0, 0),
            );
            assert_eq!(value.as_deref(), Some("2026-10-31T11:22:33"));
        }
    }
}

#[cfg(any(windows, target_os = "macos"))]
pub use imp::worker_main;

#[cfg(windows)]
mod manager {
    use super::{SwitchMtpEntry, SwitchMtpStageStatus};
    use serde_json::{json, Value};
    use std::collections::HashMap;
    use std::io::{BufRead, BufReader, Write};
    use std::path::PathBuf;
    use std::process::{Child, Command, Stdio};
    use std::sync::{Arc, Mutex, OnceLock};

    struct SwitchImportActiveStage {
        operation_id: String,
        child: Arc<Mutex<Child>>,
        staging: PathBuf,
    }

    #[derive(Default)]
    struct SwitchImportRuntimeState {
        active: Option<SwitchImportActiveStage>,
        status: HashMap<String, SwitchMtpStageStatus>,
    }

    static STATE: OnceLock<Mutex<SwitchImportRuntimeState>> = OnceLock::new();

    fn state() -> &'static Mutex<SwitchImportRuntimeState> {
        STATE.get_or_init(Default::default)
    }

    fn worker_path() -> Result<PathBuf, String> {
        let current = std::env::current_exe().map_err(|_| "Current executable unavailable")?;
        let directory = current
            .parent()
            .ok_or_else(|| "Current executable directory unavailable".to_string())?;
        Ok(directory.join(if cfg!(windows) {
            "nsoalbum_mtp_worker.exe"
        } else {
            "nsoalbum_mtp_worker"
        }))
    }

    fn spawn() -> Result<Child, String> {
        let mut command = Command::new(worker_path()?);
        command
            .arg("--switch-import")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
        }
        command
            .spawn()
            .map_err(|_| "Switch USB worker is unavailable".to_string())
    }

    fn run_once(request: Value) -> Result<Value, String> {
        let mut child = spawn()?;
        let mut input = child
            .stdin
            .take()
            .ok_or_else(|| "Switch USB worker input unavailable".to_string())?;
        writeln!(input, "{request}").map_err(|_| "Switch USB worker request failed")?;
        drop(input);
        let output = child
            .stdout
            .take()
            .ok_or_else(|| "Switch USB worker output unavailable".to_string())?;
        let mut line = String::new();
        BufReader::new(output)
            .read_line(&mut line)
            .map_err(|_| "Switch USB worker response failed")?;
        let _ = child.kill();
        let _ = child.wait();
        let value: Value =
            serde_json::from_str(&line).map_err(|_| "Switch USB worker response invalid")?;
        if value.get("event").and_then(Value::as_str) == Some("error") {
            return Err(value
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("Switch USB import failed")
                .to_string());
        }
        Ok(value)
    }

    fn update<F: FnOnce(&mut SwitchMtpStageStatus)>(operation_id: &str, change: F) {
        if let Ok(mut state) = state().lock() {
            if let Some(status) = state.status.get_mut(operation_id) {
                change(status);
            }
        }
    }

    fn terminal(phase: &str) -> bool {
        matches!(phase, "completed" | "failed" | "cancelled")
    }

    pub fn list_devices() -> Result<Vec<String>, String> {
        let value = run_once(json!({"cmd":"devices"}))?;
        serde_json::from_value(value.get("devices").cloned().unwrap_or_else(|| json!([])))
            .map_err(|_| "Switch USB device response invalid".to_string())
    }

    pub fn scan(device: &str) -> Result<Vec<SwitchMtpEntry>, String> {
        let value = run_once(json!({"cmd":"scan","device":device}))?;
        serde_json::from_value(value.get("entries").cloned().unwrap_or_else(|| json!([])))
            .map_err(|_| "Switch USB scan response invalid".to_string())
    }

    pub fn start_stage(
        operation_id: String,
        device: String,
        entries: Vec<SwitchMtpEntry>,
    ) -> Result<(), String> {
        if operation_id.trim().is_empty() || entries.is_empty() {
            return Err("Invalid Switch USB import request".into());
        }
        if state()
            .lock()
            .map_err(|_| "Import state unavailable")?
            .active
            .is_some()
        {
            return Err("Another Switch USB import is running".into());
        }
        let staging = std::env::temp_dir().join(format!("nsoalbum-switch-{operation_id}"));
        if staging.exists() {
            std::fs::remove_dir_all(&staging).map_err(|_| "Unable to reset staging")?;
        }
        std::fs::create_dir_all(&staging).map_err(|_| "Unable to create staging")?;
        let mut child = spawn()?;
        let mut input = child
            .stdin
            .take()
            .ok_or_else(|| "Switch USB worker input unavailable".to_string())?;
        writeln!(
            input,
            "{}",
            json!({
                "cmd":"stage",
                "device":device,
                "entries":entries,
                "target":staging.to_string_lossy(),
            })
        )
        .map_err(|_| "Switch USB worker request failed")?;
        drop(input);
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Switch USB worker output unavailable".to_string())?;
        {
            let mut state = state().lock().map_err(|_| "Import state unavailable")?;
            state.status.insert(
                operation_id.clone(),
                SwitchMtpStageStatus {
                    phase: "copying".into(),
                    total_files: entries.len() as i64,
                    total_bytes: entries.iter().map(|entry| entry.size_bytes as i64).sum(),
                    ..Default::default()
                },
            );
            state.active = Some(SwitchImportActiveStage {
                operation_id: operation_id.clone(),
                child: Arc::new(Mutex::new(child)),
                staging,
            });
        }
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                match value.get("event").and_then(Value::as_str) {
                    Some("progress") => update(&operation_id, |status| {
                        status.phase = "copying".into();
                        status.completed_files = value
                            .get("completedFiles")
                            .and_then(Value::as_i64)
                            .unwrap_or(0);
                        status.total_files =
                            value.get("totalFiles").and_then(Value::as_i64).unwrap_or(0);
                        status.completed_bytes = value
                            .get("completedBytes")
                            .and_then(Value::as_i64)
                            .unwrap_or(0);
                        status.total_bytes =
                            value.get("totalBytes").and_then(Value::as_i64).unwrap_or(0);
                        status.current_file = value
                            .get("currentFile")
                            .and_then(Value::as_str)
                            .map(ToOwned::to_owned);
                    }),
                    Some("done") => {
                        update(&operation_id, |status| {
                            status.phase = "completed".into();
                            status.current_file = None;
                            status.staged_files = serde_json::from_value(
                                value.get("files").cloned().unwrap_or_else(|| json!([])),
                            )
                            .unwrap_or_default();
                        });
                    }
                    Some("error") => {
                        update(&operation_id, |status| {
                            status.phase = "failed".into();
                            status.error_code = value
                                .get("code")
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned);
                            status.error = value
                                .get("message")
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned);
                        });
                    }
                    _ => {}
                }
            }
            let finished = state()
                .lock()
                .ok()
                .and_then(|state| {
                    state
                        .status
                        .get(&operation_id)
                        .map(|status| status.phase.clone())
                })
                .is_some_and(|phase| terminal(&phase));
            if !finished {
                update(&operation_id, |status| {
                    status.phase = "failed".into();
                    status.error_code = Some("disconnected".into());
                    status.error = Some("Switch USB device disconnected".into());
                });
            }
        });
        Ok(())
    }

    pub fn stage_status(operation_id: &str) -> Option<SwitchMtpStageStatus> {
        state()
            .lock()
            .ok()
            .and_then(|state| state.status.get(operation_id).cloned())
    }

    pub fn cancel_stage(operation_id: &str) -> bool {
        let active = {
            let Ok(mut state) = state().lock() else {
                return false;
            };
            if state
                .active
                .as_ref()
                .is_some_and(|active| active.operation_id == operation_id)
            {
                let active = state.active.take().unwrap();
                if let Some(status) = state.status.get_mut(operation_id) {
                    status.phase = "cancelled".into();
                    status.current_file = None;
                }
                Some(active)
            } else {
                None
            }
        };
        let Some(active) = active else {
            return false;
        };
        if let Ok(mut child) = active.child.lock() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&active.staging);
        true
    }

    pub fn cleanup_stage(operation_id: &str) {
        let staging = state().lock().ok().and_then(|mut state| {
            state
                .active
                .take()
                .filter(|active| active.operation_id == operation_id)
                .map(|active| active.staging)
        });
        if let Some(staging) = staging {
            let _ = std::fs::remove_dir_all(staging);
        }
    }
}

#[cfg(windows)]
pub fn switch_mtp_list_devices() -> Result<Vec<String>, String> {
    manager::list_devices()
}

#[cfg(windows)]
pub fn switch_mtp_scan(device: String) -> Result<Vec<SwitchMtpEntry>, String> {
    manager::scan(&device)
}

#[cfg(windows)]
pub fn switch_mtp_start_stage(
    operation_id: String,
    device: String,
    entries: Vec<SwitchMtpEntry>,
) -> Result<(), String> {
    manager::start_stage(operation_id, device, entries)
}

#[cfg(windows)]
pub fn switch_mtp_stage_status(operation_id: String) -> Option<SwitchMtpStageStatus> {
    manager::stage_status(&operation_id)
}

#[cfg(windows)]
pub fn switch_mtp_cancel_stage(operation_id: String) -> bool {
    manager::cancel_stage(&operation_id)
}

#[cfg(windows)]
pub fn switch_mtp_cleanup_stage(operation_id: String) {
    manager::cleanup_stage(&operation_id);
}

#[cfg(not(windows))]
pub fn switch_mtp_list_devices() -> Result<Vec<String>, String> {
    Err("Switch USB import is only available on Windows".into())
}

#[cfg(not(windows))]
pub fn switch_mtp_scan(_device: String) -> Result<Vec<SwitchMtpEntry>, String> {
    Err("Switch USB import is only available on Windows".into())
}

#[cfg(not(windows))]
pub fn switch_mtp_start_stage(
    _operation_id: String,
    _device: String,
    _entries: Vec<SwitchMtpEntry>,
) -> Result<(), String> {
    Err("Switch USB import is only available on Windows".into())
}

#[cfg(not(windows))]
pub fn switch_mtp_stage_status(_operation_id: String) -> Option<SwitchMtpStageStatus> {
    None
}

#[cfg(not(windows))]
pub fn switch_mtp_cancel_stage(_operation_id: String) -> bool {
    false
}

#[cfg(not(windows))]
pub fn switch_mtp_cleanup_stage(_operation_id: String) {}
