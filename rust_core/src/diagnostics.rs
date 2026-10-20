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
        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        status
            .map(|code| format!(" http={code}"))
            .unwrap_or_default(),
    );
    write_record(&record);
}

pub(crate) fn device(record: &str) {
    // The caller supplies only records constructed from data-free enums and
    // static allowlists; never pass an arbitrary formatted application error.
    write_record(&format!(
        "{} [ERROR] [device_sync] {record}\n",
        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
    ));
}

pub(crate) fn device_measurement(record: &str) {
    // Measurements are built only from fixed enums and numeric counters.
    write_record(&format!(
        "{} [INFO] [device_sync] {record}\n",
        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
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
