use super::*;
use crate::device_sync::manifest::{
    ManifestCollector, ManifestHeader, ManifestRecord, MediaRecord, VERSION,
};
use crate::device_sync::planner::{build_plan, SyncMode};
use crate::models::MediaKind;

struct Fixture {
    database: Arc<Database>,
    source: Manifest,
    target: Manifest,
    plan: SyncPlan,
    root: tempfile::TempDir,
}

impl Fixture {
    fn new(files: u64) -> Self {
        let root = tempfile::tempdir().unwrap();
        let database =
            Arc::new(Database::open(root.path().join("database/library.sqlite3")).unwrap());
        let header = database.device_sync_header().unwrap();
        let mut collector = ManifestCollector::new(header.clone()).unwrap();
        let mut cursor = None;
        loop {
            let page = database
                .device_sync_manifest_page(&header, cursor.as_ref(), 128)
                .unwrap();
            cursor = page.next.clone();
            collector.push(page).unwrap();
            if cursor.is_none() {
                break;
            }
        }
        let target = collector.finish().unwrap();
        let mut source = Manifest {
            header: ManifestHeader {
                version: VERSION,
                library_uuid: uuid::Uuid::new_v4().to_string(),
                generation: 0,
                observed_at: target.header.observed_at,
            },
            records: target.records.clone(),
        };
        for index in 0..files {
            source.records.push(ManifestRecord::Media(MediaRecord {
                sha256: sha(index),
                length: 8,
                kind: MediaKind::Image,
                extension: "jpg".into(),
                original_display_name: "synthetic.jpg".into(),
                captured_at: None,
                imported_at: None,
                game_title_id: None,
                source_game_name: "Synthetic".into(),
                game_name: "Synthetic".into(),
                tags: vec![],
                note: String::new(),
                favorite: false,
                revision: None,
            }));
        }
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        Self {
            root,
            database,
            source,
            target,
            plan,
        }
    }

    fn prepare(&self) -> StagingOperation {
        StagingOperation::prepare(
            self.database.clone(),
            &self.source,
            &self.target,
            &self.plan,
        )
        .unwrap()
    }

    fn directory(&self, operation: &StagingOperation) -> PathBuf {
        self.root
            .path()
            .join("temporary/device-sync")
            .join(operation.operation_id().to_string())
    }

    fn cached_file(&self, index: u64) -> PathBuf {
        self.root
            .path()
            .join("temporary/device-sync/verified-v1")
            .join(format!("{}-8-image.jpg", sha(index)))
    }
}

fn sha(index: u64) -> String {
    hex::encode(Sha256::digest(index.to_le_bytes()))
}

fn receive(operation: &mut StagingOperation, index: u64) {
    let id = operation.operation_id();
    let hash = sha(index);
    operation.begin_file(id, &hash).unwrap();
    finish(operation, index);
}

fn finish(operation: &mut StagingOperation, index: u64) {
    let id = operation.operation_id();
    let hash = sha(index);
    operation
        .write_chunk(id, &hash, 0, &index.to_le_bytes())
        .unwrap();
    operation
        .finish_file(id, &hash, &CancellationToken::default(), &mut |_| {})
        .unwrap();
}

#[test]
fn staging_fix1_receiving_window_is_recoverable_and_has_no_side_effects() {
    let fixture = Fixture::new(6);
    let mut operation = fixture.prepare();
    let id = operation.operation_id();
    for index in 0..4 {
        operation.begin_file(id, &sha(index)).unwrap();
    }
    let directory = fixture.directory(&operation);
    let before = std::fs::read_dir(&directory).unwrap().count();
    let status = operation.progress().clone();
    let result = operation.begin_file(id, &sha(4));
    let after = std::fs::read_dir(&directory).unwrap().count();
    eprintln!("receiving window: before={before}, after_fifth={after}, result={result:?}");
    assert_eq!(result, Err(StagingError::ReceivingWindowFull));
    assert_eq!(before, 4);
    assert_eq!(after, 4);
    assert_eq!(operation.progress(), &status);
    assert_eq!(
        fixture.database.device_sync_header().unwrap().generation,
        fixture.target.header.generation
    );
    assert_eq!(
        operation.begin_file(id, &sha(0)),
        Err(StagingError::InvalidState)
    );
    assert_eq!(
        operation.begin_file(id, &"f".repeat(64)),
        Err(StagingError::UnknownMedia)
    );
    finish(&mut operation, 0);
    operation.begin_file(id, &sha(4)).unwrap();
    assert_eq!(
        operation.finish_file(id, &sha(0), &CancellationToken::default(), &mut |_| {}),
        Err(StagingError::InvalidState)
    );
    assert_eq!(
        operation.begin_file(id, &sha(5)),
        Err(StagingError::ReceivingWindowFull)
    );
    finish(&mut operation, 1);
    operation.begin_file(id, &sha(5)).unwrap();
    for index in 2..6 {
        finish(&mut operation, index);
    }
    assert_eq!(std::fs::read_dir(&directory).unwrap().count(), 0);
    for index in 0_u64..6 {
        assert_eq!(
            std::fs::read(fixture.cached_file(index)).unwrap(),
            index.to_le_bytes()
        );
    }
    operation.cancel().unwrap();
    assert!(!directory.exists());
    assert!(!fixture.root.path().join("originals").exists());
}

#[test]
fn staging_fix1_full_window_failure_and_cancel_are_terminal_and_clean_only_their_files() {
    for cancel in [false, true] {
        let fixture = Fixture::new(6);
        let mut operation = fixture.prepare();
        let mut other = fixture.prepare();
        receive(&mut other, 5);
        let other_directory = fixture.directory(&other);
        let id = operation.operation_id();
        let directory = fixture.directory(&operation);
        for index in 0..4 {
            operation.begin_file(id, &sha(index)).unwrap();
        }
        let terminal = if cancel {
            operation.cancel().unwrap();
            StagingError::Cancelled
        } else {
            operation.write_chunk(id, &sha(0), 0, b"damaged!").unwrap();
            assert_eq!(
                operation.finish_file(id, &sha(0), &CancellationToken::default(), &mut |_| {}),
                Err(StagingError::ChecksumMismatch)
            );
            StagingError::InvalidState
        };
        assert_eq!(operation.begin_file(id, &sha(4)), Err(terminal));
        assert_eq!(
            operation.write_chunk(id, &sha(1), 0, &1_u64.to_le_bytes()),
            Err(terminal)
        );
        assert_eq!(
            operation.finish_file(id, &sha(1), &CancellationToken::default(), &mut |_| {}),
            Err(terminal)
        );
        assert_eq!(operation.cancel(), Err(terminal));
        assert!(!directory.exists());
        assert_eq!(other.progress().phase, Phase::Verified);
        assert_eq!(std::fs::read_dir(&other_directory).unwrap().count(), 0);
        assert_eq!(
            std::fs::read(fixture.cached_file(5)).unwrap(),
            5_u64.to_le_bytes()
        );
        other.cancel().unwrap();
        assert!(!other_directory.exists());
    }
}

#[test]
fn staging_fix1_closed_verified_path_is_rechecked_before_publication() {
    let fixture = Fixture::new(1);
    let mut operation = fixture.prepare();
    receive(&mut operation, 0);
    let directory = fixture.directory(&operation);
    let path = fixture.cached_file(0);
    std::fs::write(&path, b"damaged!").unwrap();
    let lease = fixture.database.device_sync_exclusive().unwrap();
    assert!(matches!(
        operation.publish(
            &lease,
            operation.operation_id(),
            &sha(0),
            &CancellationToken::default(),
            &mut |_| {}
        ),
        Err(StagingError::ChecksumMismatch)
    ));
    assert!(!directory.exists());
    assert_eq!(operation.progress().phase, Phase::Failed);
    assert_eq!(
        walkdir::WalkDir::new(fixture.root.path().join("originals"))
            .into_iter()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().is_file())
            .count(),
        0
    );
}

#[cfg(any(windows, unix))]
#[test]
fn staging_fix1_reopening_a_replaced_symlink_does_not_touch_the_external_file() {
    let fixture = Fixture::new(1);
    let outside = tempfile::tempdir().unwrap();
    let external = outside.path().join("outside");
    std::fs::write(&external, b"outside!").unwrap();
    let mut operation = fixture.prepare();
    receive(&mut operation, 0);
    let path = fixture.cached_file(0);
    std::fs::remove_file(&path).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&external, &path).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&external, &path).unwrap();
    let lease = fixture.database.device_sync_exclusive().unwrap();
    assert!(matches!(
        operation.publish(
            &lease,
            operation.operation_id(),
            &sha(0),
            &CancellationToken::default(),
            &mut |_| {}
        ),
        Err(StagingError::UnsafePath)
    ));
    drop(operation);
    assert_eq!(std::fs::read(&external).unwrap(), b"outside!");
    assert!(std::fs::symlink_metadata(path)
        .unwrap()
        .file_type()
        .is_symlink());
}

#[cfg(any(windows, unix))]
fn handle_count() -> u64 {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let output = std::process::Command::new("powershell.exe")
            .creation_flags(0x0800_0000)
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                &format!("(Get-Process -Id {}).HandleCount", std::process::id()),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
        String::from_utf8(output.stdout)
            .unwrap()
            .trim()
            .parse()
            .unwrap()
    }
    #[cfg(all(unix, any(target_os = "linux", target_os = "android")))]
    {
        std::fs::read_dir("/proc/self/fd").unwrap().count() as u64
    }
    #[cfg(all(unix, not(any(target_os = "linux", target_os = "android"))))]
    {
        std::fs::read_dir("/dev/fd").unwrap().count() as u64
    }
}

#[cfg(any(windows, unix))]
#[test]
fn staging_fix1_sequential_513_verified_files_do_not_retain_os_handles() {
    const CHILD_ENV: &str = "NSOALBUM_STAGING_FIX1_RESOURCE_CHILD";
    if std::env::var_os(CHILD_ENV).as_deref() != Some(std::ffi::OsStr::new("1")) {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "device_sync::staging::fix1_tests::staging_fix1_sequential_513_verified_files_do_not_retain_os_handles",
                "--nocapture",
            ])
            .env(CHILD_ENV, "1")
            .output()
            .unwrap();
        eprintln!("{}", String::from_utf8_lossy(&output.stdout));
        eprintln!("{}", String::from_utf8_lossy(&output.stderr));
        assert!(
            output.status.success(),
            "isolated resource regression failed"
        );
        return;
    }
    let fixture = Fixture::new(513);
    let mut operation = fixture.prepare();
    let before = handle_count();
    for index in 0..513 {
        receive(&mut operation, index);
    }
    let verified = handle_count();
    eprintln!(
        "sequential_verified_files=513; before={before}; verified={verified}; growth={}",
        verified.saturating_sub(before)
    );
    assert!(
        verified <= before + 8,
        "verified files must not each retain an OS handle"
    );
    let lease = fixture.database.device_sync_exclusive().unwrap();
    for index in 0..513 {
        let published = operation
            .publish(
                &lease,
                operation.operation_id(),
                &sha(index),
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        assert_eq!(
            std::fs::read(published.identity().path()).unwrap(),
            index.to_le_bytes()
        );
        assert!(published.rollback().unwrap());
    }
    let reclaimed = handle_count();
    assert!(reclaimed <= before + 8);
    let directory = fixture.directory(&operation);
    operation.cancel().unwrap();
    assert!(!directory.exists());
    eprintln!("all_513_published_and_reclaimed; handles={reclaimed}");
}
