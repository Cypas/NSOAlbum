//! Synthetic-library subprocess tests. No account, network service, or user-library mode.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use super::*;
use crate::api::CoreApi;
use crate::database::Database;

const CHILD_TEST: &str = "device_sync::library_guard::process_tests::library_process_child";
const ROOT_PREFIX: &str = "nsoalbum-library-process-test-";
const TIMEOUT: Duration = Duration::from_secs(20);

fn synthetic_root() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix(ROOT_PREFIX)
        .tempdir_in(std::env::temp_dir().canonicalize().unwrap())
        .unwrap()
}

fn carrier(database: &Path) -> PathBuf {
    let mut name = std::ffi::OsString::from(".");
    name.push(database.file_name().unwrap());
    name.push(".nsoalbum.lock");
    database.with_file_name(name)
}

struct SyntheticChild {
    process: OwnedChild,
    stream: TcpStream,
}

struct OwnedChild(Child);

impl Drop for OwnedChild {
    fn drop(&mut self) {
        // This handle is exclusively the synthetic child this fixture spawned.
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

impl SyntheticChild {
    fn spawn(root: &Path, tag: &str) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let process = OwnedChild(
            Command::new(std::env::current_exe().unwrap())
                .args(["--ignored", "--exact", CHILD_TEST, "--nocapture"])
                .env("NSOALBUM_LIBRARY_TEST_ROOT", root)
                .env("NSOALBUM_LIBRARY_TEST_ADDRESS", address.to_string())
                .env("NSOALBUM_LIBRARY_TEST_TAG", tag)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap(),
        );
        let (sender, receiver) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let _ = sender.send(listener.accept());
        });
        let stream = match receiver.recv_timeout(TIMEOUT) {
            Ok(result) => result.unwrap().0,
            Err(error) => {
                // Wake and retire the accept thread even when child startup failed.
                let _ = TcpStream::connect_timeout(&address, TIMEOUT);
                panic!("synthetic child handshake failed: {error}");
            }
        };
        let mut child = Self { process, stream };
        child.stream.set_read_timeout(Some(TIMEOUT)).unwrap();
        child.stream.set_write_timeout(Some(TIMEOUT)).unwrap();
        let mut ready = [0];
        child.stream.read_exact(&mut ready).unwrap();
        assert_eq!(ready, [b'R']);
        child
    }

    fn start_open(&mut self) {
        self.stream.write_all(b"O").unwrap();
    }

    fn opened(&mut self) -> Option<uuid::Uuid> {
        let mut status = [0];
        self.stream.read_exact(&mut status).unwrap();
        match status[0] {
            b'B' => None,
            b'S' => {
                let mut uuid = [0; 16];
                self.stream.read_exact(&mut uuid).unwrap();
                Some(uuid::Uuid::from_bytes(uuid))
            }
            other => panic!("unexpected child status {other}"),
        }
    }

    fn open(&mut self) -> Option<uuid::Uuid> {
        self.start_open();
        self.opened()
    }

    fn terminate(&mut self) {
        self.process.0.kill().unwrap();
        self.process.0.wait().unwrap();
    }
}

#[test]
#[ignore = "bounded IPC subprocess entry point; exercised by library_process_* tests"]
fn library_process_child() {
    let root = PathBuf::from(std::env::var_os("NSOALBUM_LIBRARY_TEST_ROOT").unwrap());
    assert!(root.starts_with(std::env::temp_dir().canonicalize().unwrap()));
    assert!(root.components().any(|component| component
        .as_os_str()
        .to_str()
        .is_some_and(|name| name.starts_with(ROOT_PREFIX))));
    let mut stream =
        TcpStream::connect(std::env::var("NSOALBUM_LIBRARY_TEST_ADDRESS").unwrap()).unwrap();
    stream.set_read_timeout(Some(TIMEOUT)).unwrap();
    stream.set_write_timeout(Some(TIMEOUT)).unwrap();
    stream.write_all(b"R").unwrap();
    let mut command = [0];
    let mut api = None;
    while stream.read_exact(&mut command).is_ok() {
        assert_eq!(command, [b'O']);
        assert!(api.is_none());
        match CoreApi::open(&root) {
            Ok(opened) => {
                opened
                    .create_tag(std::env::var("NSOALBUM_LIBRARY_TEST_TAG").unwrap())
                    .unwrap();
                let uuid = uuid::Uuid::parse_str(
                    &opened.database().device_sync_header().unwrap().library_uuid,
                )
                .unwrap();
                api = Some(opened);
                stream.write_all(b"S").unwrap();
                stream.write_all(uuid.as_bytes()).unwrap();
            }
            Err(CoreError::LibraryBusy) => stream.write_all(b"B").unwrap(),
            Err(error) => panic!("synthetic child open unexpectedly failed: {error}"),
        }
    }
}

#[test]
fn library_process_open_is_busy_before_any_write_even_without_exclusive() {
    let root = synthetic_root();
    let api = CoreApi::open(root.path()).unwrap();
    let database = api.database();
    let header = database.device_sync_header().unwrap();
    let database_bytes = std::fs::read(root.path().join("database/library.sqlite3")).unwrap();
    let wal_bytes = std::fs::read(root.path().join("database/library.sqlite3-wal")).unwrap();
    let owner = std::fs::read(root.path().join(ORIGINAL_ROOT_OWNER_FILE)).unwrap();
    let mut child = SyntheticChild::spawn(root.path(), "must-not-be-written");
    assert!(
        child.open().is_none(),
        "second CoreApi process must be busy"
    );
    let ordinary = database.write_lease().unwrap();
    assert!(child.open().is_none());
    drop(ordinary);
    let exclusive = database.device_sync_exclusive().unwrap();
    assert!(child.open().is_none());
    drop(exclusive);
    assert!(api.list_tags().unwrap().is_empty());
    let unchanged = database.device_sync_header().unwrap();
    assert_eq!(unchanged.library_uuid, header.library_uuid);
    assert_eq!(unchanged.generation, header.generation);
    assert_eq!(
        std::fs::read(root.path().join("database/library.sqlite3")).unwrap(),
        database_bytes
    );
    assert_eq!(
        std::fs::read(root.path().join("database/library.sqlite3-wal")).unwrap(),
        wal_bytes
    );
    assert_eq!(
        std::fs::read(root.path().join(ORIGINAL_ROOT_OWNER_FILE)).unwrap(),
        owner
    );
    drop(database);
    drop(api);
    assert_eq!(child.open().unwrap().to_string(), header.library_uuid);
    child.terminate();
    let reopened = CoreApi::open(root.path()).unwrap();
    assert_eq!(reopened.list_tags().unwrap(), ["must-not-be-written"]);
}

#[test]
fn library_process_last_ordinary_lease_keeps_os_lock() {
    let root = synthetic_root();
    let api = CoreApi::open(root.path()).unwrap();
    let ordinary = api.database().write_lease().unwrap();
    let mut child = SyntheticChild::spawn(root.path(), "after-ordinary");
    drop(api);
    assert!(child.open().is_none());
    drop(ordinary);
    assert!(child.open().is_some());
}

#[test]
fn library_process_last_snapshot_keeps_os_lock() {
    let root = synthetic_root();
    let api = CoreApi::open(root.path()).unwrap();
    let database = api.database();
    let exclusive = database.device_sync_exclusive().unwrap();
    let snapshot = database
        .device_sync_retain_source(&exclusive, root.path())
        .unwrap();
    let mut child = SyntheticChild::spawn(root.path(), "after-snapshot");
    drop(exclusive);
    drop(database);
    drop(api);
    assert!(child.open().is_none());
    drop(snapshot);
    assert!(child.open().is_some());
}

#[tokio::test]
async fn library_process_last_owned_lease_snapshot_and_pin_keep_os_lock() {
    let root = synthetic_root();
    let api = CoreApi::open(root.path()).unwrap();
    let input = root.path().join("synthetic.jpg");
    std::fs::write(&input, b"synthetic original").unwrap();
    api.import_local_files(vec![input.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let database = api.database();
    let media = api
        .list_media(crate::models::GalleryQuery::default())
        .unwrap()
        .remove(0);
    let exclusive = database.device_sync_exclusive().unwrap();
    let snapshot = database
        .device_sync_retain_source(&exclusive, root.path())
        .unwrap();
    drop(exclusive);
    let mut child = SyntheticChild::spawn(root.path(), "after-last-reference");
    let ordinary = database.write_lease().unwrap();
    let pin = database
        .pin_original(
            root.path(),
            Path::new(&media.storage_path),
            &media.sha256,
            std::fs::metadata(&media.storage_path).unwrap().len(),
        )
        .unwrap();
    drop(database);
    drop(api);
    assert!(child.open().is_none());
    drop(ordinary);
    assert!(child.open().is_none());
    drop(snapshot);
    assert!(child.open().is_none());
    drop(pin);
    assert!(child.open().is_some());
}

#[test]
fn library_process_last_exclusive_keeps_os_lock() {
    let root = synthetic_root();
    let api = CoreApi::open(root.path()).unwrap();
    let exclusive = api.database().device_sync_exclusive().unwrap();
    let mut child = SyntheticChild::spawn(root.path(), "after-exclusive");
    drop(api);
    assert!(child.open().is_none());
    drop(exclusive);
    assert!(child.open().is_some());
}

#[test]
fn library_process_simultaneous_first_creation_has_one_identity_and_owner() {
    let parent = synthetic_root();
    let root = parent.path().join("new-library");
    let mut first = SyntheticChild::spawn(&root, "first");
    let mut second = SyntheticChild::spawn(&root, "second");
    assert!(!root.exists());
    first.start_open();
    second.start_open();
    let results = [first.opened(), second.opened()];
    assert_eq!(results.iter().filter(|value| value.is_some()).count(), 1);
    let expected = results.into_iter().flatten().next().unwrap();
    first.terminate();
    second.terminate();
    let api = CoreApi::open(&root).unwrap();
    assert_eq!(
        api.database().device_sync_header().unwrap().library_uuid,
        expected.to_string()
    );
    assert_eq!(api.list_tags().unwrap().len(), 1);
    let marker: OriginalRootOwner =
        serde_json::from_slice(&std::fs::read(root.join(ORIGINAL_ROOT_OWNER_FILE)).unwrap())
            .unwrap();
    assert_eq!(marker.library_uuid, expected.to_string());
}

#[test]
fn library_process_terminated_child_releases_lock_but_keeps_carrier() {
    let root = synthetic_root();
    let mut child = SyntheticChild::spawn(root.path(), "child-created");
    let uuid = child.open().unwrap();
    assert!(matches!(
        CoreApi::open(root.path()),
        Err(CoreError::LibraryBusy)
    ));
    let lock = carrier(&root.path().join("database/library.sqlite3"));
    assert_eq!(std::fs::metadata(&lock).unwrap().len(), 0);
    child.terminate();
    let api = CoreApi::open(root.path()).unwrap();
    assert_eq!(
        api.database().device_sync_header().unwrap().library_uuid,
        uuid.to_string()
    );
    assert_eq!(api.list_tags().unwrap(), ["child-created"]);
    assert_eq!(std::fs::metadata(&lock).unwrap().len(), 0);
}

#[test]
fn library_process_same_process_shared_and_same_directory_databases_are_independent() {
    let root = synthetic_root();
    let database_path = root.path().join("one.sqlite3");
    let first = Database::open(&database_path).unwrap();
    let second = Database::open(root.path().join("./one.sqlite3")).unwrap();
    let ordinary = first.write_lease().unwrap();
    second.create_tag("nested-writer").unwrap();
    drop(ordinary);
    let exclusive = first.device_sync_exclusive().unwrap();
    assert!(matches!(
        second.create_tag("blocked"),
        Err(CoreError::LibraryBusy)
    ));
    let independent = Database::open(root.path().join("two.sqlite3")).unwrap();
    independent.create_tag("independent").unwrap();
    assert!(carrier(&database_path).is_file());
    assert!(carrier(&root.path().join("two.sqlite3")).is_file());
    drop(exclusive);
    assert_eq!(second.list_tags().unwrap(), ["nested-writer"]);
    let unicode = root.path().join("\u{0130}");
    let first = CoreApi::open(&unicode).unwrap();
    let second = CoreApi::open(unicode.join(".")).unwrap();
    second.create_tag("unicode".into()).unwrap();
    assert_eq!(first.list_tags().unwrap(), ["unicode"]);
}

#[test]
fn library_process_carrier_directory_and_symlink_are_rejected_without_changes() {
    let root = synthetic_root();
    let path = root.path().join("library.sqlite3");
    let lock = carrier(&path);
    std::fs::create_dir(&lock).unwrap();
    assert!(Database::open(&path).is_err());
    assert!(lock.is_dir());
    assert!(!path.exists());
    std::fs::remove_dir(&lock).unwrap();
    let outside = root.path().join("outside");
    std::fs::write(&outside, b"unmodified outside bytes").unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&outside, &lock).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&outside, &lock).unwrap();
    assert!(Database::open(&path).is_err());
    assert!(std::fs::symlink_metadata(&lock)
        .unwrap()
        .file_type()
        .is_symlink());
    assert_eq!(std::fs::read(outside).unwrap(), b"unmodified outside bytes");
    assert!(!path.exists());
}

#[test]
fn library_process_database_and_carrier_hardlinks_are_rejected() {
    let root = synthetic_root();
    let path = root.path().join("library.sqlite3");
    let alias = root.path().join("alias.sqlite3");
    let database = Database::open(&path).unwrap();
    drop(database);
    std::fs::hard_link(&path, &alias).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    assert!(Database::open(&alias).is_err());
    assert!(Database::open(&path).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    let fresh = root.path().join("fresh.sqlite3");
    let outside = root.path().join("outside-lock");
    std::fs::write(&outside, b"outside lock bytes").unwrap();
    std::fs::hard_link(&outside, carrier(&fresh)).unwrap();
    assert!(Database::open(&fresh).is_err());
    assert_eq!(std::fs::read(outside).unwrap(), b"outside lock bytes");
    assert!(!fresh.exists());
}

#[test]
fn library_process_local_ancestor_alias_shares_actual_database_and_os_lock() {
    let parent = synthetic_root();
    let actual = parent.path().join("actual");
    let alias = parent.path().join("alias");
    std::fs::create_dir(&actual).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_dir(&actual, &alias).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&actual, &alias).unwrap();
    let first = CoreApi::open(&actual).unwrap();
    let second = CoreApi::open(&alias).unwrap();
    second.create_tag("alias".into()).unwrap();
    assert_eq!(first.list_tags().unwrap(), ["alias"]);
    let exclusive = first.database().device_sync_exclusive().unwrap();
    assert!(matches!(
        second.create_tag("blocked".into()),
        Err(CoreError::LibraryBusy)
    ));
    let mut child = SyntheticChild::spawn(&alias, "after-alias-close");
    assert!(child.open().is_none());
    drop(exclusive);
    drop(first);
    assert!(
        child.open().is_none(),
        "the second Database still owns its gate"
    );
    drop(second);
    assert!(child.open().is_some());
}

#[test]
fn library_process_database_leaf_links_directories_and_parent_escape_are_rejected() {
    let root = synthetic_root();
    let actual = root.path().join("actual.sqlite3");
    let alias = root.path().join("alias.sqlite3");
    drop(Database::open(&actual).unwrap());
    let bytes = std::fs::read(&actual).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&actual, &alias).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&actual, &alias).unwrap();
    let error = Database::open(&alias).err().unwrap();
    assert!(matches!(error, CoreError::LibraryLockUnavailable));
    assert!(!error
        .to_string()
        .contains(&root.path().to_string_lossy().to_string()));
    assert_eq!(std::fs::read(&actual).unwrap(), bytes);
    assert!(std::fs::symlink_metadata(&alias)
        .unwrap()
        .file_type()
        .is_symlink());
    let directory = root.path().join("directory.sqlite3");
    std::fs::create_dir(&directory).unwrap();
    assert!(matches!(
        Database::open(&directory),
        Err(CoreError::LibraryLockUnavailable)
    ));
    assert!(directory.is_dir());
    // PathBuf::join normalizes ".." on Windows verbatim paths; retain raw input.
    let mut escaped = root.path().as_os_str().to_os_string();
    escaped.push("/missing/../escaped.sqlite3");
    let escaped = PathBuf::from(escaped);
    let error = Database::open(&escaped).err();
    assert!(
        matches!(error, Some(CoreError::LibraryLockUnavailable)),
        "unexpected result {error:?}; components: {:?}",
        escaped.components().collect::<Vec<_>>()
    );
    assert!(!root.path().join("escaped.sqlite3").exists());
}

#[test]
fn library_process_existing_plain_carrier_is_not_truncated_or_deleted() {
    let root = synthetic_root();
    let path = root.path().join("plain.sqlite3");
    let lock = carrier(&path);
    std::fs::write(&lock, b"pre-existing ordinary carrier bytes").unwrap();
    drop(Database::open(&path).unwrap());
    drop(Database::open(&path).unwrap());
    assert_eq!(
        std::fs::read(&lock).unwrap(),
        b"pre-existing ordinary carrier bytes"
    );
}

#[cfg(unix)]
#[test]
fn library_process_unix_nonregular_socket_carrier_is_rejected() {
    // macOS sockaddr_un has a small path budget; this test needs no child prefix.
    let root = tempfile::Builder::new()
        .prefix("nso")
        .tempdir_in(std::env::temp_dir().canonicalize().unwrap())
        .unwrap();
    let path = root.path().join("s");
    let lock = carrier(&path);
    let _socket = std::os::unix::net::UnixListener::bind(&lock).unwrap();
    assert!(matches!(
        Database::open(&path),
        Err(CoreError::LibraryLockUnavailable)
    ));
    assert!(!path.exists());
    assert!(std::fs::symlink_metadata(lock).is_ok());
}
