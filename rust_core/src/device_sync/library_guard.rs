//! Local, owned write leases and original-file retention. No pairing trust is stored here.

use std::collections::HashMap;
use std::fs::{File, Metadata, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use crate::error::{CoreError, CoreResult};

#[derive(Default)]
pub(crate) struct LibraryGate {
    // Only registered gates have a carrier; bare Default gates are test-local.
    _process_lock: Option<File>,
    database_path: PathBuf,
    state: Mutex<GateState>,
    pub(crate) originals: Mutex<OriginalProtection>,
    pub(crate) root_ownership: Mutex<()>,
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct OriginalRootOwner {
    pub(crate) version: u32,
    pub(crate) database_path: PathBuf,
    pub(crate) library_uuid: String,
}

pub(crate) const ORIGINAL_ROOT_OWNER_FILE: &str = ".nsoalbum-originals-owner.json";

#[derive(Default)]
struct GateState {
    writers: usize,
    exclusive: bool,
    recovery_pending: bool,
}

#[derive(Default)]
pub(crate) struct OriginalProtection {
    pub(crate) snapshots: HashMap<uuid::Uuid, Vec<OriginalIdentity>>,
    pins: HashMap<OriginalIdentity, usize>,
}

pub struct WriteLease {
    gate: Arc<LibraryGate>,
    active: bool,
}

pub struct ExclusiveLease {
    gate: Arc<LibraryGate>,
}

/// Recovery-only capability. It cannot be converted to an ordinary exclusive.
pub struct RecoveryLease {
    gate: Arc<LibraryGate>,
    operation: uuid::Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct OriginalIdentity {
    pub(crate) root: PathBuf,
    pub(crate) relative: PathBuf,
    pub(crate) sha256: String,
    pub(crate) length: u64,
}

pub struct SourceSnapshotLease {
    gate: Arc<LibraryGate>,
    owner: uuid::Uuid,
    originals: Vec<OriginalIdentity>,
}

pub(crate) struct PublicationPin {
    gate: Arc<LibraryGate>,
    identity: OriginalIdentity,
}

impl LibraryGate {
    pub(crate) fn for_database(path: &Path) -> CoreResult<Arc<Self>> {
        type Registry = Mutex<HashMap<PathBuf, Weak<LibraryGate>>>;
        static REGISTRY: OnceLock<Registry> = OnceLock::new();
        let path = controlled_database_path(path)?;
        let key = path_key(&path);
        let mut registry = REGISTRY
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| CoreError::LibraryBusy)?;
        registry.retain(|_, value| value.strong_count() > 0);
        if let Some(gate) = registry.get(&key).and_then(Weak::upgrade) {
            return Ok(gate);
        }
        let process_lock = lock_carrier(&path)?;
        let gate = Arc::new(Self {
            _process_lock: Some(process_lock),
            database_path: path,
            ..Self::default()
        });
        registry.insert(key, Arc::downgrade(&gate));
        Ok(gate)
    }

    pub(crate) fn database_path(&self) -> &Path {
        &self.database_path
    }

    pub(crate) fn write(self: &Arc<Self>) -> CoreResult<WriteLease> {
        self.write_inner(false)
    }

    pub(crate) fn opening(self: &Arc<Self>) -> CoreResult<WriteLease> {
        self.write_inner(true)
    }

    fn write_inner(self: &Arc<Self>, opening: bool) -> CoreResult<WriteLease> {
        let mut state = self.state.lock().map_err(|_| CoreError::LibraryBusy)?;
        if state.exclusive || (state.recovery_pending && !opening) {
            return Err(CoreError::LibraryBusy);
        }
        state.writers = state.writers.checked_add(1).ok_or(CoreError::LibraryBusy)?;
        Ok(WriteLease {
            gate: self.clone(),
            active: true,
        })
    }

    pub(crate) fn exclusive(self: &Arc<Self>) -> CoreResult<ExclusiveLease> {
        let mut state = self.state.lock().map_err(|_| CoreError::LibraryBusy)?;
        if state.exclusive || state.writers != 0 || state.recovery_pending {
            return Err(CoreError::LibraryBusy);
        }
        state.exclusive = true;
        Ok(ExclusiveLease { gate: self.clone() })
    }

    pub(crate) fn pending(&self) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .recovery_pending
    }

    pub(crate) fn publish_pending(&self, pending: bool) {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .recovery_pending = pending;
    }

    pub(crate) fn recover(self: &Arc<Self>, operation: uuid::Uuid) -> CoreResult<RecoveryLease> {
        let mut state = self.state.lock().map_err(|_| CoreError::LibraryBusy)?;
        if !state.recovery_pending || state.exclusive || state.writers != 0 {
            return Err(CoreError::LibraryBusy);
        }
        state.exclusive = true;
        Ok(RecoveryLease {
            gate: self.clone(),
            operation,
        })
    }

    pub(crate) fn snapshot(
        self: &Arc<Self>,
        originals: Vec<OriginalIdentity>,
    ) -> SourceSnapshotLease {
        let owner = uuid::Uuid::new_v4();
        self.originals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .snapshots
            .insert(owner, originals.clone());
        SourceSnapshotLease {
            gate: self.clone(),
            owner,
            originals,
        }
    }

    pub(crate) fn pin(self: &Arc<Self>, identity: OriginalIdentity) -> PublicationPin {
        let mut protection = self.originals.lock().unwrap_or_else(|e| e.into_inner());
        *protection.pins.entry(identity.clone()).or_default() += 1;
        PublicationPin {
            gate: self.clone(),
            identity,
        }
    }
}

fn controlled_database_path(path: &Path) -> CoreResult<PathBuf> {
    let invalid = || CoreError::LibraryLockUnavailable;
    if path
        .components()
        .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(invalid());
    }
    let filename = path.file_name().ok_or_else(invalid)?;
    #[cfg(windows)]
    {
        let name = filename.to_str().ok_or_else(invalid)?;
        let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
        if name.contains([':', '/', '\\'])
            || name.ends_with(['.', ' '])
            || matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
            || ["COM", "LPT"].iter().any(|prefix| {
                stem.strip_prefix(prefix).is_some_and(|suffix| {
                    matches!(suffix, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9")
                })
            })
        {
            return Err(invalid());
        }
    }
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    // Local ancestor aliases (including macOS /var) resolve to one real base.
    // No remote manifest or comparison key is ever used as an I/O path.
    std::fs::create_dir_all(parent).map_err(|_| invalid())?;
    let parent = parent.canonicalize().map_err(|_| invalid())?;
    let mut checked = PathBuf::new();
    for component in parent.components() {
        checked.push(component);
        if matches!(component, std::path::Component::Prefix(_)) {
            continue;
        }
        let metadata = std::fs::symlink_metadata(&checked).map_err(|_| invalid())?;
        if !metadata.is_dir() || is_link_or_reparse(&metadata) {
            return Err(invalid());
        }
    }
    let path = parent.join(filename);
    match std::fs::symlink_metadata(&path) {
        Ok(metadata) => {
            validate_regular_file(&metadata)?;
            let file = File::open(&path).map_err(|_| invalid())?;
            validate_single_link(&file)?;
            path.canonicalize().map_err(|_| invalid())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(path),
        Err(_) => Err(invalid()),
    }
}

fn is_link_or_reparse(metadata: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

fn validate_regular_file(metadata: &Metadata) -> CoreResult<()> {
    if metadata.is_file() && !is_link_or_reparse(metadata) {
        Ok(())
    } else {
        Err(CoreError::LibraryLockUnavailable)
    }
}

fn validate_single_link(file: &File) -> CoreResult<()> {
    #[cfg(windows)]
    let count = winapi_util::file::information(file)
        .map_err(|_| CoreError::LibraryLockUnavailable)?
        .number_of_links();
    #[cfg(unix)]
    let count = {
        use std::os::unix::fs::MetadataExt;
        file.metadata()
            .map_err(|_| CoreError::LibraryLockUnavailable)?
            .nlink()
    };
    #[cfg(not(any(windows, unix)))]
    let count = 0;
    if count == 1 {
        Ok(())
    } else {
        Err(CoreError::LibraryLockUnavailable)
    }
}

fn lock_carrier(database: &Path) -> CoreResult<File> {
    let mut name = std::ffi::OsString::from(".");
    name.push(
        database
            .file_name()
            .ok_or(CoreError::LibraryLockUnavailable)?,
    );
    name.push(".nsoalbum.lock");
    let path = database.with_file_name(name);
    let file = match OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            validate_regular_file(
                &std::fs::symlink_metadata(&path).map_err(|_| CoreError::LibraryLockUnavailable)?,
            )?;
            OpenOptions::new()
                .read(true)
                .write(true)
                .open(&path)
                .map_err(|_| CoreError::LibraryLockUnavailable)?
        }
        Err(_) => return Err(CoreError::LibraryLockUnavailable),
    };
    validate_regular_file(
        &file
            .metadata()
            .map_err(|_| CoreError::LibraryLockUnavailable)?,
    )?;
    validate_single_link(&file)?;
    file.try_lock().map_err(|error| match error {
        TryLockError::WouldBlock => CoreError::LibraryBusy,
        TryLockError::Error(_) => CoreError::LibraryLockUnavailable,
    })?;
    Ok(file)
}

impl Drop for WriteLease {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        let mut state = self.gate.state.lock().unwrap_or_else(|e| e.into_inner());
        state.writers -= 1;
    }
}

impl WriteLease {
    pub(crate) fn try_exclusive(mut self) -> CoreResult<ExclusiveLease> {
        let gate = self.gate.clone();
        {
            let mut state = gate.state.lock().map_err(|_| CoreError::LibraryBusy)?;
            if state.writers != 1 || state.exclusive {
                return Err(CoreError::LibraryBusy);
            }
            state.writers = 0;
            state.exclusive = true;
            self.active = false;
        }
        Ok(ExclusiveLease { gate })
    }
}

impl Drop for ExclusiveLease {
    fn drop(&mut self) {
        self.gate
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .exclusive = false;
    }
}

impl ExclusiveLease {
    pub(crate) fn validate(&self, gate: &Arc<LibraryGate>) -> CoreResult<()> {
        if Arc::ptr_eq(&self.gate, gate) {
            Ok(())
        } else {
            Err(CoreError::InvalidConfig(
                "exclusive lease belongs to another library".into(),
            ))
        }
    }
}

impl RecoveryLease {
    pub(crate) fn validate(
        &self,
        gate: &Arc<LibraryGate>,
        operation: uuid::Uuid,
    ) -> CoreResult<()> {
        if Arc::ptr_eq(&self.gate, gate) && self.operation == operation && gate.pending() {
            Ok(())
        } else {
            Err(CoreError::LibraryBusy)
        }
    }
}

impl Drop for RecoveryLease {
    fn drop(&mut self) {
        self.gate
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .exclusive = false;
    }
}

impl SourceSnapshotLease {
    pub fn originals(&self) -> &[OriginalIdentity] {
        &self.originals
    }
}

impl Drop for SourceSnapshotLease {
    fn drop(&mut self) {
        self.gate
            .originals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .snapshots
            .remove(&self.owner);
    }
}

impl Drop for PublicationPin {
    fn drop(&mut self) {
        let mut protection = self
            .gate
            .originals
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some(count) = protection.pins.get_mut(&self.identity) {
            *count -= 1;
            if *count == 0 {
                protection.pins.remove(&self.identity);
            }
        }
    }
}

impl PublicationPin {
    pub(crate) fn validate(&self, gate: &Arc<LibraryGate>) -> CoreResult<()> {
        if Arc::ptr_eq(&self.gate, gate) {
            Ok(())
        } else {
            Err(CoreError::InvalidConfig(
                "publication pin belongs to another library".into(),
            ))
        }
    }
}

impl OriginalProtection {
    pub(crate) fn retains(
        &self,
        identity: &OriginalIdentity,
        own_pin: Option<&PublicationPin>,
    ) -> bool {
        if self
            .snapshots
            .values()
            .flatten()
            .any(|entry| entry.same_file(identity))
        {
            return true;
        }
        let own = usize::from(own_pin.is_some_and(|pin| pin.identity.same_file(identity)));
        self.pins
            .iter()
            .filter(|(entry, _)| entry.same_file(identity))
            .map(|(_, count)| *count)
            .sum::<usize>()
            > own
    }

    pub(crate) fn prevents_relocation(&self) -> bool {
        !self.snapshots.is_empty() || !self.pins.is_empty()
    }
}

impl OriginalIdentity {
    pub fn path(&self) -> PathBuf {
        self.root.join(&self.relative)
    }

    pub fn sha256(&self) -> &str {
        &self.sha256
    }

    pub fn length(&self) -> u64 {
        self.length
    }

    pub(crate) fn controlled(
        root: &Path,
        path: &Path,
        sha256: &str,
        length: u64,
    ) -> CoreResult<Self> {
        let invalid = || CoreError::InvalidConfig("invalid managed original identity".into());
        if sha256.len() != 64
            || !sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || length == 0
            || length > i64::MAX as u64
            || path
                .components()
                .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return Err(invalid());
        }
        let root = root.canonicalize()?;
        let parent = path.parent().ok_or_else(invalid)?.canonicalize()?;
        let filename = path.file_name().ok_or_else(invalid)?;
        let full = parent.join(filename);
        let relative = full.strip_prefix(&root).map_err(|_| invalid())?;
        let extension = full
            .extension()
            .and_then(|value| value.to_str())
            .ok_or_else(invalid)?;
        if !matches!(extension, "jpg" | "jpeg" | "png" | "webp" | "mp4" | "mov") {
            return Err(invalid());
        }
        let expected = PathBuf::from("originals")
            .join(&sha256[..2])
            .join(&sha256[2..4])
            .join(format!("{sha256}.{extension}"));
        if path_key(relative) != path_key(&expected) {
            return Err(invalid());
        }
        let mut checked = root.clone();
        for component in &expected {
            checked.push(component);
            match std::fs::symlink_metadata(&checked) {
                Ok(metadata) if metadata.file_type().is_symlink() => return Err(invalid()),
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound && checked == full => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(Self {
            root,
            relative: expected,
            sha256: sha256.into(),
            length,
        })
    }

    fn same_file(&self, other: &Self) -> bool {
        path_key(&self.root) == path_key(&other.root)
            && path_key(&self.relative) == path_key(&other.relative)
            && self.sha256 == other.sha256
    }
}

pub(crate) fn path_key(path: &Path) -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(path.to_string_lossy().to_ascii_lowercase())
    } else {
        path.to_path_buf()
    }
}

#[cfg(test)]
#[path = "../../tests/fixtures/library_process.rs"]
mod process_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::CoreApi;
    use crate::database::Database;
    use crate::models::{GalleryQuery, MediaCandidate, MediaKind, SourceType};
    use crate::sync::MediaRepository;

    fn candidate() -> MediaCandidate {
        MediaCandidate {
            remote_id: None,
            title_id: None,
            game_name: "Synthetic".into(),
            kind: MediaKind::Image,
            captured_at: None,
            uploaded_at: None,
            source_type: SourceType::Folder,
            source_path: None,
            content_url: None,
            thumbnail_url: None,
            expires_at: None,
            expected_size: None,
            original_name: Some("capture.jpg".into()),
            file_extension: Some("jpg".into()),
        }
    }

    #[test]
    fn device_sync_guard_exclusive_rejects_nested_new_writes_without_blocking() {
        let gate = Arc::new(LibraryGate::default());
        let _exclusive = gate.exclusive().unwrap();
        assert!(matches!(gate.write(), Err(CoreError::LibraryBusy)));
        assert!(matches!(gate.exclusive(), Err(CoreError::LibraryBusy)));
    }

    #[tokio::test]
    async fn device_sync_guard_owned_nested_writes_release_after_await_and_error() {
        let gate = Arc::new(LibraryGate::default());
        let result: CoreResult<()> = async {
            let _first = gate.write()?;
            let _nested = gate.write()?;
            tokio::task::yield_now().await;
            assert!(matches!(gate.exclusive(), Err(CoreError::LibraryBusy)));
            Err(CoreError::Cancelled)
        }
        .await;
        assert!(matches!(result, Err(CoreError::Cancelled)));
        let exclusive = gate.exclusive().unwrap();
        fn assert_send<T: Send>(_: &T) {}
        assert_send(&exclusive);
        drop(exclusive);
        assert!(gate.write().is_ok());
    }

    #[tokio::test]
    async fn device_sync_guard_blocks_all_local_entry_layers_but_not_reads_or_other_libraries() {
        let directory = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let database = api.database();
        let repository = MediaRepository::new(directory.path(), database.clone());
        repository
            .import_bytes(&candidate(), b"retained", None)
            .await
            .unwrap();
        let another = Database::open(
            directory
                .path()
                .join("database")
                .join(".")
                .join("library.sqlite3"),
        )
        .unwrap();
        let exclusive = database.device_sync_exclusive().unwrap();
        assert!(matches!(
            api.create_tag("blocked".into()),
            Err(CoreError::LibraryBusy)
        ));
        assert!(matches!(
            database.set_note(1, "blocked"),
            Err(CoreError::LibraryBusy)
        ));
        assert!(matches!(
            another.create_album("blocked", "", false),
            Err(CoreError::LibraryBusy)
        ));
        assert!(matches!(
            repository
                .import_bytes(&candidate(), b"new data", None)
                .await,
            Err(CoreError::LibraryBusy)
        ));
        assert!(matches!(
            CoreApi::open(directory.path()),
            Err(CoreError::LibraryBusy)
        ));
        assert_eq!(api.list_media(GalleryQuery::default()).unwrap().len(), 1);
        assert!(database.list_tags().unwrap().is_empty());
        let other_directory = tempfile::tempdir().unwrap();
        CoreApi::open(other_directory.path())
            .unwrap()
            .create_tag("independent".into())
            .unwrap();
        drop(exclusive);
        api.create_tag("after".into()).unwrap();
    }

    #[tokio::test]
    async fn device_sync_guard_snapshot_owners_and_durable_backups_retain_deleted_originals() {
        let directory = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let database = api.database();
        let repository = MediaRepository::new(directory.path(), database.clone());
        let (id, _) = repository
            .import_bytes(&candidate(), b"snapshot original", None)
            .await
            .unwrap();
        let exclusive = database.device_sync_exclusive().unwrap();
        let first = database
            .device_sync_retain_source(&exclusive, directory.path())
            .unwrap();
        let second = database
            .device_sync_retain_source(&exclusive, directory.path())
            .unwrap();
        let backup = database
            .device_sync_retain_backup(&exclusive, directory.path())
            .unwrap();
        let original = first.originals()[0].clone();
        drop(exclusive);
        api.delete_media(id).unwrap();
        assert_eq!(
            std::fs::read(original.path()).unwrap(),
            b"snapshot original"
        );
        drop(first);
        assert!(!database
            .cleanup_original(directory.path(), &original.path(), original.sha256(), None)
            .unwrap());
        drop(second);
        drop(repository);
        drop(database);
        drop(api);
        let reopened = CoreApi::open(directory.path()).unwrap();
        let database = reopened.database();
        assert_eq!(
            database.device_sync_backup_reference_owners().unwrap(),
            vec![backup]
        );
        assert!(!database
            .cleanup_original(directory.path(), &original.path(), original.sha256(), None)
            .unwrap());
        let exclusive = database.device_sync_exclusive().unwrap();
        database
            .device_sync_release_backup(&exclusive, backup)
            .unwrap();
        drop(exclusive);
        assert!(database
            .cleanup_original(directory.path(), &original.path(), original.sha256(), None)
            .unwrap());
        assert!(!original.path().exists());
    }

    #[tokio::test]
    async fn device_sync_guard_publication_pin_blocks_cleanup_until_drop() {
        let directory = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let database = api.database();
        let repository = MediaRepository::new(directory.path(), database.clone());
        let (id, _) = repository
            .import_bytes(&candidate(), b"pinned original", None)
            .await
            .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        let pin = database
            .pin_original(
                directory.path(),
                Path::new(&media.storage_path),
                &media.sha256,
                std::fs::metadata(&media.storage_path).unwrap().len(),
            )
            .unwrap();
        api.delete_media(id).unwrap();
        assert!(!database
            .cleanup_original(
                directory.path(),
                Path::new(&media.storage_path),
                &media.sha256,
                None
            )
            .unwrap());
        drop(pin);
        assert!(database
            .cleanup_original(
                directory.path(),
                Path::new(&media.storage_path),
                &media.sha256,
                None
            )
            .unwrap());
    }

    #[test]
    fn device_sync_guard_rejects_symlink_and_path_escape_references() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("library");
        std::fs::create_dir_all(root.join("originals/aa/bb")).unwrap();
        let path = root.join(
            "originals/aa/aa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg",
        );
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"x").unwrap();
        assert!(OriginalIdentity::controlled(
            &root,
            &root.join("../outside.jpg"),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            1
        )
        .is_err());
        assert!(OriginalIdentity::controlled(
            &root,
            &path,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            1
        )
        .is_ok());
        let link = path.with_extension("jpeg");
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(&path, &link).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(OriginalIdentity::controlled(
            &root,
            &link,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            1
        )
        .is_err());
    }

    #[tokio::test]
    async fn device_sync_guard_first_settings_save_cannot_retarget_a_retained_library() {
        let directory = tempfile::tempdir().unwrap();
        let destination = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let database = api.database();
        let repository = MediaRepository::new(directory.path(), database.clone());
        repository
            .import_bytes(&candidate(), b"retained root", None)
            .await
            .unwrap();
        let exclusive = database.device_sync_exclusive().unwrap();
        let snapshot = database
            .device_sync_retain_source(&exclusive, directory.path())
            .unwrap();
        drop(exclusive);
        let settings = crate::settings::AppSettings {
            proxy_url: None,
            library_path: destination.path().to_string_lossy().into_owned(),
            theme: "ocean".into(),
            language: "en".into(),
            gallery_columns: 4,
            gallery_rows: 3,
            show_note_preview: true,
            show_game_tag: true,
            compact_tag_display: true,
            auto_play_video: false,
            auto_sync_on_launch: false,
            notify_on_auto_sync: true,
            show_splatoon_schedule: true,
            show_splatoon_friend_activity: false,
            close_behavior: "ask".into(),
            custom_font_paths: Vec::new(),
            sync_policy: Default::default(),
        };
        assert!(matches!(
            api.save_settings(&settings),
            Err(CoreError::LibraryReferenced)
        ));
        assert!(matches!(
            api.relocate_media_library(settings.clone()).await,
            Err(CoreError::LibraryReferenced)
        ));
        assert!(api.load_settings().unwrap().is_none());
        drop(snapshot);
        api.relocate_media_library(settings).await.unwrap();
        assert!(
            Path::new(&api.list_media(GalleryQuery::default()).unwrap()[0].storage_path)
                .starts_with(destination.path())
        );
    }

    #[tokio::test]
    async fn device_sync_guard_nso_rejects_before_auth_and_cancelled_sync_releases_lease() {
        struct WaitingProvider(Arc<tokio::sync::Notify>);
        #[async_trait::async_trait]
        impl crate::nso::MediaProvider for WaitingProvider {
            fn provider_name(&self) -> &str {
                "synthetic-waiting"
            }
            async fn list_recent(
                &self,
                _: Option<&str>,
            ) -> CoreResult<crate::models::ProviderPage> {
                self.0.notify_one();
                std::future::pending().await
            }
        }
        let directory = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let database = api.database();
        let exclusive = database.device_sync_exclusive().unwrap();
        assert!(matches!(
            api.sync_nso_from_session_token(
                "not-a-real-token".into(),
                None,
                &crate::sync::CancellationToken::default()
            )
            .await,
            Err(CoreError::LibraryBusy)
        ));
        drop(exclusive);
        let entered = Arc::new(tokio::sync::Notify::new());
        let engine = crate::sync::SyncEngine::new(
            WaitingProvider(entered.clone()),
            crate::transport::HttpTransport::new(Default::default()).unwrap(),
            MediaRepository::new(directory.path(), database.clone()),
        );
        let cancellation = crate::sync::CancellationToken::default();
        let work = engine.sync(None, &cancellation);
        tokio::pin!(work);
        tokio::select! {
            _ = entered.notified() => {}
            result = &mut work => panic!("sync ended early: {:?}", result.err()),
        }
        assert!(matches!(
            database.device_sync_exclusive(),
            Err(CoreError::LibraryBusy)
        ));
        cancellation.cancel();
        assert!(matches!(work.await, Err(CoreError::Cancelled)));
        assert!(database.device_sync_exclusive().is_ok());
    }

    #[tokio::test]
    async fn device_sync_guard_snapshot_survives_another_open_and_releases_on_cancel() {
        let directory = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let database = api.database();
        let repository = MediaRepository::new(directory.path(), database.clone());
        let (id, _) = repository
            .import_bytes(&candidate(), b"ephemeral snapshot", None)
            .await
            .unwrap();
        let exclusive = database.device_sync_exclusive().unwrap();
        let snapshot = database
            .device_sync_retain_source(&exclusive, directory.path())
            .unwrap();
        let original = snapshot.originals()[0].clone();
        drop(exclusive);
        let reopened = CoreApi::open(directory.path()).unwrap();
        api.delete_media(id).unwrap();
        assert_eq!(
            std::fs::read(original.path()).unwrap(),
            b"ephemeral snapshot"
        );
        let task = tokio::spawn(async move {
            let _snapshot = snapshot;
            std::future::pending::<()>().await;
        });
        tokio::task::yield_now().await;
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert!(reopened
            .database()
            .cleanup_original(directory.path(), &original.path(), original.sha256(), None)
            .unwrap());
    }

    #[tokio::test]
    async fn device_sync_guard_wrong_library_and_windows_case_cannot_forge_authority() {
        let first_root = tempfile::tempdir().unwrap();
        let second_root = tempfile::tempdir().unwrap();
        let first = CoreApi::open(first_root.path()).unwrap();
        let second = CoreApi::open(second_root.path()).unwrap();
        let exclusive = first.database().device_sync_exclusive().unwrap();
        assert!(second
            .database()
            .device_sync_retain_source(&exclusive, second_root.path())
            .is_err());
        assert!(first
            .database()
            .device_sync_retain_backup(&exclusive, second_root.path())
            .is_err());
        #[cfg(windows)]
        {
            let upper = PathBuf::from(first_root.path().to_string_lossy().to_uppercase());
            assert!(matches!(CoreApi::open(upper), Err(CoreError::LibraryBusy)));
        }
    }

    #[tokio::test]
    async fn device_sync_guard_publisher_cleanup_race_preserves_other_pins_and_active_rows() {
        let directory = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let database = api.database();
        let repository = MediaRepository::new(directory.path(), database.clone());
        let (id, _) = repository
            .import_bytes(&candidate(), b"concurrent publish", None)
            .await
            .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        database.delete_media_record(id).unwrap();
        let ready = Arc::new(std::sync::Barrier::new(2));
        let finish = Arc::new(std::sync::Barrier::new(2));
        std::thread::scope(|scope| {
            let publisher_database = database.clone();
            let path = PathBuf::from(&media.storage_path);
            let sha = media.sha256.clone();
            let root = directory.path();
            let ready_worker = ready.clone();
            let finish_worker = finish.clone();
            scope.spawn(move || {
                let _writing = publisher_database.write_lease().unwrap();
                let pin = publisher_database
                    .pin_original(root, &path, &sha, 18)
                    .unwrap();
                ready_worker.wait();
                finish_worker.wait();
                publisher_database
                    .register_media(&sha, 18, &path, &candidate(), None)
                    .unwrap();
                assert!(!publisher_database
                    .cleanup_original(root, &path, &sha, Some(&pin))
                    .unwrap());
            });
            ready.wait();
            assert!(!database
                .cleanup_original(
                    directory.path(),
                    Path::new(&media.storage_path),
                    &media.sha256,
                    None
                )
                .unwrap());
            finish.wait();
        });
        assert_eq!(
            std::fs::read(&media.storage_path).unwrap(),
            b"concurrent publish"
        );
        assert_eq!(api.list_media(GalleryQuery::default()).unwrap().len(), 1);
    }

    #[tokio::test]
    async fn device_sync_guard_snapshot_protects_video_overwrite_and_album_cleanup() {
        let directory = tempfile::tempdir().unwrap();
        let input = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let original_path = input.path().join("clip.mp4");
        let edited_path = input.path().join("edited.mp4");
        std::fs::write(&original_path, b"old synthetic video").unwrap();
        std::fs::write(&edited_path, b"new synthetic video").unwrap();
        api.import_local_files(vec![original_path.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        let database = api.database();
        let exclusive = database.device_sync_exclusive().unwrap();
        let snapshot = database
            .device_sync_retain_source(&exclusive, directory.path())
            .unwrap();
        drop(exclusive);
        let edited = api
            .commit_video_edit(media.id, edited_path.to_string_lossy().into_owned(), true)
            .await
            .unwrap();
        assert_ne!(media.sha256, edited.sha256);
        assert_eq!(
            std::fs::read(&media.storage_path).unwrap(),
            b"old synthetic video"
        );
        let album = api
            .create_album("temporary".into(), String::new(), false)
            .unwrap();
        api.add_media_to_album(album, edited.id).unwrap();
        let exclusive = database.device_sync_exclusive().unwrap();
        let edited_snapshot = database
            .device_sync_retain_source(&exclusive, directory.path())
            .unwrap();
        drop(exclusive);
        api.remove_media_from_album_and_cleanup(album, edited.id)
            .unwrap();
        assert_eq!(
            std::fs::read(&edited.storage_path).unwrap(),
            b"new synthetic video"
        );
        drop(snapshot);
        drop(edited_snapshot);
        assert!(database
            .cleanup_original(
                directory.path(),
                Path::new(&media.storage_path),
                &media.sha256,
                None
            )
            .unwrap());
        assert!(database
            .cleanup_original(
                directory.path(),
                Path::new(&edited.storage_path),
                &edited.sha256,
                None
            )
            .unwrap());
    }

    #[tokio::test]
    async fn device_sync_guard_duplicate_extension_keeps_actual_original_without_orphan_copy() {
        let directory = tempfile::tempdir().unwrap();
        let api = CoreApi::open(directory.path()).unwrap();
        let repository = MediaRepository::new(directory.path(), api.database());
        let (first, _) = repository
            .import_bytes(&candidate(), b"same JPEG", None)
            .await
            .unwrap();
        let mut jpeg = candidate();
        jpeg.file_extension = Some("jpeg".into());
        let (second, created) = repository
            .import_bytes(&jpeg, b"same JPEG", None)
            .await
            .unwrap();
        assert_eq!(first, second);
        assert!(!created);
        let media = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        assert!(media.storage_path.ends_with(".jpg"));
        assert_eq!(std::fs::read(&media.storage_path).unwrap(), b"same JPEG");
        let files = walkdir::WalkDir::new(directory.path().join("originals"))
            .into_iter()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().is_file())
            .count();
        assert_eq!(files, 1);
    }

    #[tokio::test]
    async fn review_fix1_r1_another_database_cannot_claim_a_protected_original_root() {
        let first_root = tempfile::tempdir().unwrap();
        let second_root = tempfile::tempdir().unwrap();
        let first = CoreApi::open(first_root.path()).unwrap();
        let second = CoreApi::open(second_root.path()).unwrap();
        let repository = MediaRepository::new(first_root.path(), first.database());
        repository
            .import_bytes(&candidate(), b"protected shared root", None)
            .await
            .unwrap();
        let original = first.list_media(GalleryQuery::default()).unwrap().remove(0);
        let database = first.database();
        let exclusive = database.device_sync_exclusive().unwrap();
        let snapshot = database
            .device_sync_retain_source(&exclusive, first_root.path())
            .unwrap();
        let backup = database
            .device_sync_retain_backup(&exclusive, first_root.path())
            .unwrap();
        let settings = crate::settings::AppSettings {
            proxy_url: None,
            library_path: first_root.path().to_string_lossy().into_owned(),
            theme: "ocean".into(),
            language: "en".into(),
            gallery_columns: 4,
            gallery_rows: 3,
            show_note_preview: true,
            show_game_tag: true,
            compact_tag_display: true,
            auto_play_video: false,
            auto_sync_on_launch: false,
            notify_on_auto_sync: true,
            show_splatoon_schedule: true,
            show_splatoon_friend_activity: false,
            close_behavior: "ask".into(),
            custom_font_paths: Vec::new(),
            sync_policy: Default::default(),
        };
        assert!(
            second.save_settings(&settings).is_err(),
            "foreign root must be rejected before settings change"
        );
        assert!(second.load_settings().unwrap().is_none());
        let foreign = MediaRepository::new(first_root.path(), second.database());
        assert!(foreign
            .import_bytes(&candidate(), b"protected shared root", None)
            .await
            .is_err());
        assert!(matches!(
            second.database().register_media(
                &original.sha256,
                21,
                Path::new(&original.storage_path),
                &candidate(),
                None,
            ),
            Err(CoreError::LibraryRootOwnership)
        ));
        assert_eq!(
            std::fs::read(&original.storage_path).unwrap(),
            b"protected shared root"
        );
        assert_eq!(first.list_media(GalleryQuery::default()).unwrap().len(), 1);
        assert!(second
            .list_media(GalleryQuery::default())
            .unwrap()
            .is_empty());
        assert_eq!(snapshot.originals().len(), 1);
        assert_eq!(
            database.device_sync_backup_reference_owners().unwrap(),
            vec![backup]
        );
    }

    #[tokio::test]
    async fn review_fix1_r2_busy_download_cannot_remove_a_protected_original() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let database = api.database();
        let repository = MediaRepository::new(root.path(), database.clone());
        repository
            .import_bytes(&candidate(), b"protected download original", None)
            .await
            .unwrap();
        let original = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        let downloaded = crate::transport::test_support::download_bytes(
            &root.path().join("temporary"),
            b"downloaded temporary",
        )
        .await;
        let temporary_path = downloaded.path().to_path_buf();
        let exclusive = database.device_sync_exclusive().unwrap();
        let _snapshot = database
            .device_sync_retain_source(&exclusive, root.path())
            .unwrap();
        let _backup = database
            .device_sync_retain_backup(&exclusive, root.path())
            .unwrap();
        let result = repository
            .import_downloaded(&candidate(), downloaded, None)
            .await;
        assert!(matches!(result, Err(CoreError::LibraryBusy)));
        assert!(!temporary_path.exists());
        assert_eq!(
            std::fs::read(&original.storage_path).unwrap(),
            b"protected download original"
        );
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn review_fix1_r3_unicode_root_preserves_real_io_path_and_backup_lookup() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("\u{0130}");
        let api = CoreApi::open(&root).unwrap();
        let database = api.database();
        let repository = MediaRepository::new(&root, database.clone());
        let (id, _) = repository
            .import_bytes(&candidate(), b"Unicode folder original", None)
            .await
            .unwrap();
        let actual = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        let exclusive = database.device_sync_exclusive().unwrap();
        let snapshot = database
            .device_sync_retain_source(&exclusive, &root)
            .unwrap();
        let backup = database
            .device_sync_retain_backup(&exclusive, &root)
            .unwrap();
        assert_eq!(
            std::fs::read(snapshot.originals()[0].path()).unwrap(),
            b"Unicode folder original"
        );
        drop(exclusive);
        api.delete_media(id).unwrap();
        drop(snapshot);
        assert!(!database
            .cleanup_original(&root, Path::new(&actual.storage_path), &actual.sha256, None)
            .unwrap());
        assert_eq!(
            std::fs::read(&actual.storage_path).unwrap(),
            b"Unicode folder original"
        );
        let exclusive = database.device_sync_exclusive().unwrap();
        database
            .device_sync_release_backup(&exclusive, backup)
            .unwrap();
        drop(exclusive);
        assert!(database
            .cleanup_original(&root, Path::new(&actual.storage_path), &actual.sha256, None)
            .unwrap());
        assert!(!Path::new(&actual.storage_path).exists());
    }

    fn settings_for(root: &Path) -> crate::settings::AppSettings {
        crate::settings::AppSettings {
            proxy_url: None,
            library_path: root.to_string_lossy().into_owned(),
            theme: "ocean".into(),
            language: "en".into(),
            gallery_columns: 4,
            gallery_rows: 3,
            show_note_preview: true,
            show_game_tag: true,
            compact_tag_display: true,
            auto_play_video: false,
            auto_sync_on_launch: false,
            notify_on_auto_sync: true,
            show_splatoon_schedule: true,
            show_splatoon_friend_activity: false,
            close_behavior: "ask".into(),
            custom_font_paths: Vec::new(),
            sync_policy: Default::default(),
        }
    }

    #[test]
    fn review_fix1_r1_atomic_claim_has_one_database_winner_and_persists_after_close() {
        let first_root = tempfile::tempdir().unwrap();
        let second_root = tempfile::tempdir().unwrap();
        let shared = tempfile::tempdir().unwrap();
        let first = CoreApi::open(first_root.path()).unwrap();
        let second = CoreApi::open(second_root.path()).unwrap();
        let start = Arc::new(std::sync::Barrier::new(2));
        let shared_root = shared.path();
        let results = std::thread::scope(|scope| {
            let run = |database: Arc<Database>, barrier: Arc<std::sync::Barrier>| {
                scope.spawn(move || {
                    let runtime = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .unwrap();
                    barrier.wait();
                    runtime
                        .block_on(MediaRepository::new(shared_root, database).import_bytes(
                            &candidate(),
                            b"one root owner",
                            None,
                        ))
                        .is_ok()
                })
            };
            let first_result = run(first.database(), start.clone());
            let second_result = run(second.database(), start.clone());
            (first_result.join().unwrap(), second_result.join().unwrap())
        });
        assert_eq!(usize::from(results.0) + usize::from(results.1), 1);
        assert_eq!(
            first.list_media(GalleryQuery::default()).unwrap().len()
                + second.list_media(GalleryQuery::default()).unwrap().len(),
            1
        );
        let (winner, loser) = if results.0 {
            (first, second)
        } else {
            (second, first)
        };
        let original = winner
            .list_media(GalleryQuery::default())
            .unwrap()
            .remove(0);
        let winner_database = winner.database();
        let exclusive = winner_database.device_sync_exclusive().unwrap();
        // The snapshot/backup roots must also be the configured root.
        drop(exclusive);
        winner.save_settings(&settings_for(shared.path())).unwrap();
        let exclusive = winner_database.device_sync_exclusive().unwrap();
        let backup = winner_database
            .device_sync_retain_backup(&exclusive, shared.path())
            .unwrap();
        drop(exclusive);
        drop(winner_database);
        drop(winner);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        assert!(runtime
            .block_on(
                MediaRepository::new(shared.path(), loser.database()).import_bytes(
                    &candidate(),
                    b"one root owner",
                    None
                )
            )
            .is_err());
        assert_eq!(
            std::fs::read(&original.storage_path).unwrap(),
            b"one root owner"
        );
        assert_ne!(backup, uuid::Uuid::nil());
    }

    #[tokio::test]
    async fn review_fix1_r1_relocation_releases_only_unused_external_roots() {
        let first_root = tempfile::tempdir().unwrap();
        let second_root = tempfile::tempdir().unwrap();
        let external = tempfile::tempdir().unwrap();
        let destination = tempfile::tempdir().unwrap();
        let first = CoreApi::open(first_root.path()).unwrap();
        let second = CoreApi::open(second_root.path()).unwrap();
        first.save_settings(&settings_for(external.path())).unwrap();
        let source = tempfile::tempdir().unwrap();
        let input = source.path().join("capture.jpg");
        std::fs::write(&input, b"relocated owner").unwrap();
        first
            .import_local_files(vec![input.to_string_lossy().into_owned()])
            .await
            .unwrap();
        assert!(matches!(
            second
                .relocate_media_library(settings_for(external.path()))
                .await,
            Err(CoreError::LibraryRootOwnership)
        ));
        assert!(second.load_settings().unwrap().is_none());
        first
            .relocate_media_library(settings_for(destination.path()))
            .await
            .unwrap();
        assert!(!external.path().join(ORIGINAL_ROOT_OWNER_FILE).exists());
        second
            .save_settings(&settings_for(external.path()))
            .unwrap();
        second
            .import_local_files(vec![input.to_string_lossy().into_owned()])
            .await
            .unwrap();
        assert_eq!(second.list_media(GalleryQuery::default()).unwrap().len(), 1);
        assert_eq!(
            std::fs::read(&first.list_media(GalleryQuery::default()).unwrap()[0].storage_path)
                .unwrap(),
            b"relocated owner"
        );
    }

    #[tokio::test]
    async fn review_fix1_r1_known_legacy_originals_upgrade_but_unknown_ones_are_not_claimed() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let database = api.database();
        let repository = MediaRepository::new(root.path(), database.clone());
        repository
            .import_bytes(&candidate(), b"known legacy", None)
            .await
            .unwrap();
        let original = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        drop(repository);
        drop(database);
        drop(api);
        // Only removes a marker created by this test, to model a pre-ownership library.
        std::fs::remove_file(root.path().join(ORIGINAL_ROOT_OWNER_FILE)).unwrap();
        let reopened = CoreApi::open(root.path()).unwrap();
        assert_eq!(
            std::fs::read(&original.storage_path).unwrap(),
            b"known legacy"
        );
        reopened.delete_media(original.id).unwrap();
        assert!(!Path::new(&original.storage_path).exists());
        let unknown = tempfile::tempdir().unwrap();
        let unowned = unknown.path().join("originals/aa/aa");
        std::fs::create_dir_all(&unowned).unwrap();
        let file = unowned.join(format!("{}.jpg", "a".repeat(64)));
        std::fs::write(&file, b"unknown original").unwrap();
        assert!(matches!(
            MediaRepository::new(unknown.path(), reopened.database())
                .import_bytes(&candidate(), b"new original", None)
                .await,
            Err(CoreError::LibraryRootOwnership)
        ));
        assert_eq!(std::fs::read(&file).unwrap(), b"unknown original");
        assert!(!unknown.path().join(ORIGINAL_ROOT_OWNER_FILE).exists());
    }

    #[tokio::test]
    async fn review_fix1_r1_copied_uuid_and_moved_database_do_not_inherit_root_authority() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("original");
        let api = CoreApi::open(&root).unwrap();
        let repository = MediaRepository::new(&root, api.database());
        repository
            .import_bytes(&candidate(), b"identity is not just UUID", None)
            .await
            .unwrap();
        let original = api.list_media(GalleryQuery::default()).unwrap().remove(0);
        api.save_settings(&settings_for(&root)).unwrap();
        let identity = api.database().device_sync_header().unwrap().library_uuid;
        drop(repository);
        drop(api);
        let clone_path = parent.path().join("clone.sqlite3");
        std::fs::copy(root.join("database/library.sqlite3"), &clone_path).unwrap();
        let clone = Arc::new(Database::open(clone_path).unwrap());
        assert_eq!(clone.device_sync_header().unwrap().library_uuid, identity);
        assert!(matches!(
            MediaRepository::new(&root, clone)
                .import_bytes(&candidate(), b"identity is not just UUID", None)
                .await,
            Err(CoreError::LibraryRootOwnership)
        ));
        assert_eq!(
            std::fs::read(&original.storage_path).unwrap(),
            b"identity is not just UUID"
        );
        let moved = parent.path().join("moved");
        std::fs::rename(&root, &moved).unwrap();
        assert!(matches!(
            CoreApi::open(&moved),
            Err(CoreError::LibraryRootOwnership)
        ));
        assert!(
            !root.exists(),
            "an old marker path must not be reopened or recreated"
        );
        assert!(moved.join("originals").exists());
    }
}
