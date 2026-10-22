//! Bounded, fixed-field runtime diagnostics. No remote strings or credentials.
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

static OUTPUT: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

pub(crate) fn configure(root: &Path) {
    if let Ok(mut sink) = OUTPUT.get_or_init(|| Mutex::new(None)).lock() {
        *sink = Some(root.join("logs").join("rust_core.log"));
    }
}

pub(crate) fn event(module: &'static str, stage: &'static str, status: Option<u16>) {
    let record = format!(
        "{} [ERROR] [{module}] stage={stage}{}\n",
        chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false),
        status
            .map(|code| format!(" http={code}"))
            .unwrap_or_default(),
    );
    write_record(&record);
}

pub(crate) fn network_failure(error: &crate::error::CoreError) {
    let crate::error::CoreError::NetworkRequest { .. } = error else {
        return;
    };
    write_record(&format!(
        "{} [ERROR] [network] {error}\n",
        chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
    ));
}

pub(crate) fn device(record: &str) {
    // The caller supplies only records constructed from data-free enums and
    // static allowlists; never pass an arbitrary formatted application error.
    write_record(&format!(
        "{} [ERROR] [device_sync] {record}\n",
        chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
    ));
}

pub(crate) fn device_measurement(record: &str) {
    // Measurements are built only from fixed enums and numeric counters.
    write_record(&format!(
        "{} [INFO] [device_sync] {record}\n",
        chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
    ));
}

fn write_record(record: &str) {
    let Ok(sink) = OUTPUT.get_or_init(|| Mutex::new(None)).lock() else {
        return;
    };
    let Some(path) = sink.as_ref() else { return };
    let _ = (|| -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        if std::fs::metadata(path).is_ok_and(|meta| meta.len() >= 2 * 1024 * 1024) {
            let rotated = path.with_extension("log.1");
            // Only this logger's exact rotated file is replaced.
            if rotated.exists() {
                std::fs::remove_file(&rotated)?;
            }
            std::fs::rename(path, rotated)?;
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        file.write_all(record.as_bytes())
    })();
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Timelike;

    #[test]
    fn all_runtime_log_headers_use_system_local_seconds_with_an_explicit_offset() {
        let root = tempfile::tempdir().unwrap();
        configure(root.path());
        let before = chrono::Local::now();
        event("timestamp_probe", "runtime", None);
        device("timestamp_probe");
        device_measurement("timestamp_probe");
        network_failure(&crate::error::CoreError::NetworkRequest {
            stage: "timestamp_probe",
            reason: "timeout",
            proxy: "default",
            elapsed_ms: 30000,
            url: "https://example.invalid/<redacted-path>".into(),
            code_kind: "none",
            code: "none".into(),
        });
        let after = chrono::Local::now();
        let contents = std::fs::read_to_string(root.path().join("logs/rust_core.log")).unwrap();
        *OUTPUT.get().unwrap().lock().unwrap() = None;
        let records = contents
            .lines()
            .filter(|line| line.contains("timestamp_probe"))
            .collect::<Vec<_>>();
        assert_eq!(records.len(), 4);
        for record in records {
            let header = record.split_whitespace().next().unwrap();
            assert!(
                !header.ends_with('Z') && !header.contains('.'),
                "runtime timestamp must be local and precise to seconds: {header}"
            );
            let parsed = chrono::DateTime::parse_from_rfc3339(header).unwrap();
            assert_eq!(parsed.offset(), before.offset());
            assert_eq!(parsed.nanosecond(), 0);
            assert!(parsed.timestamp() >= before.timestamp());
            assert!(parsed.timestamp() <= after.timestamp());
        }
    }
}
