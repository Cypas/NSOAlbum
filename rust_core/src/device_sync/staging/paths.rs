use std::path::{Component, Path};

use super::{StagingError, StagingResult};
use crate::device_sync::diagnostics::{self, Boundary};

fn unsafe_path(boundary: Boundary) -> StagingError {
    diagnostics::receiver(
        boundary,
        &crate::device_sync::receiver::ReceiverError::Staging(StagingError::UnsafePath),
    );
    StagingError::UnsafePath
}

fn unsafe_io(boundary: Boundary, error: std::io::Error) -> StagingError {
    diagnostics::core(boundary, &crate::error::CoreError::Io(error));
    StagingError::UnsafePath
}

#[derive(Clone, PartialEq, Eq)]
pub(super) struct FileIdentity(u64, u64);

impl FileIdentity {
    pub(super) fn of(file: &std::fs::File) -> StagingResult<Self> {
        #[cfg(windows)]
        {
            let info =
                winapi_util::file::information(file).map_err(|_| StagingError::UnsafePath)?;
            Ok(Self(info.volume_serial_number(), info.file_index()))
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let metadata = file.metadata().map_err(|_| StagingError::UnsafePath)?;
            Ok(Self(metadata.dev(), metadata.ino()))
        }
        #[cfg(not(any(windows, unix)))]
        {
            let _ = file;
            Err(StagingError::UnsafePath)
        }
    }
}

pub(crate) struct HeldDirectory {
    path: std::path::PathBuf,
    // One directory handle, not one handle per cached object.
    _file: std::fs::File,
    ancestors: Vec<(std::path::PathBuf, FileIdentity)>,
}

impl HeldDirectory {
    pub(crate) fn open(path: &Path) -> StagingResult<Self> {
        inspect(path)?;
        let file = open_checked(path, true)?;
        let mut ancestors = Vec::new();
        for ancestor in path.ancestors() {
            let directory = open_checked(ancestor, true)?;
            ancestors.push((ancestor.to_path_buf(), FileIdentity::of(&directory)?));
        }
        let held = Self {
            path: path.to_path_buf(),
            _file: file,
            ancestors,
        };
        held.inspect()?;
        Ok(held)
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn inspect(&self) -> StagingResult<()> {
        inspect(&self.path)?;
        for (path, expected) in &self.ancestors {
            if FileIdentity::of(&open_checked(path, true)?)? != *expected {
                return Err(unsafe_path(Boundary::PathHeldAncestorIdentity));
            }
        }
        Ok(())
    }

    pub(crate) fn volume_id(&self) -> StagingResult<u64> {
        self.inspect()?;
        Ok(FileIdentity::of(&self._file)?.0)
    }
}

fn is_link(metadata: &std::fs::Metadata) -> bool {
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

fn open_checked(path: &Path, directory: bool) -> StagingResult<std::fs::File> {
    inspect(path)?;
    let before = std::fs::symlink_metadata(path)
        .map_err(|error| unsafe_io(Boundary::PathOpenBeforeStat, error))?;
    if before.is_dir() != directory || (!directory && !before.is_file()) {
        return Err(unsafe_path(Boundary::PathOpenKind));
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(any(target_os = "linux", target_os = "android"))]
    if directory {
        use std::os::unix::fs::OpenOptionsExt;
        // Identity-only handles need traversal, not directory read permission
        // (Android /data is intentionally not readable to application UIDs).
        // Do not apply O_PATH to regular files: those must remain readable.
        options.custom_flags(libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x0020_0000 | if directory { 0x0200_0000 } else { 0 });
    }
    let file = options
        .open(path)
        .map_err(|error| unsafe_io(Boundary::PathOpenHandle, error))?;
    let opened = file
        .metadata()
        .map_err(|error| unsafe_io(Boundary::PathOpenAfterStat, error))?;
    if is_link(&opened) || opened.is_dir() != directory || (!directory && !opened.is_file()) {
        return Err(unsafe_path(Boundary::PathOpenKind));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.dev() != opened.dev() || before.ino() != opened.ino() {
            return Err(unsafe_path(Boundary::PathOpenIdentity));
        }
    }
    inspect(path)?;
    Ok(file)
}

pub(super) fn open_regular(path: &Path) -> StagingResult<std::fs::File> {
    open_checked(path, false)
}

pub(super) fn require_single_link(file: &std::fs::File) -> StagingResult<()> {
    #[cfg(windows)]
    let links = winapi_util::file::information(file)
        .map_err(|_| StagingError::UnsafePath)?
        .number_of_links() as u64;
    #[cfg(unix)]
    let links = {
        use std::os::unix::fs::MetadataExt;
        file.metadata()
            .map_err(|_| StagingError::UnsafePath)?
            .nlink()
    };
    #[cfg(not(any(windows, unix)))]
    let links = 0;
    if links == 1 {
        Ok(())
    } else {
        Err(StagingError::UnsafePath)
    }
}

pub(super) struct OwnedPart {
    file: Option<tempfile::NamedTempFile>,
    path: std::path::PathBuf,
    identity: FileIdentity,
    directory: HeldDirectory,
}

impl OwnedPart {
    pub(super) fn create(parent: &Path) -> StagingResult<Self> {
        inspect(parent)?;
        let directory = HeldDirectory::open(parent)?;
        let mut file = tempfile::Builder::new()
            .prefix(&format!("{}-", uuid::Uuid::new_v4()))
            .suffix(".part")
            .tempfile_in(parent)
            .map_err(|error| super::io_error(&error, StagingError::Write))?;
        // Cleanup remains owned by this wrapper, including the old temporary
        // link if a platform no-clobber fallback could not unlink it.
        file.disable_cleanup(true);
        let path = file.path().to_path_buf();
        let identity = FileIdentity::of(file.as_file())?;
        Ok(Self {
            file: Some(file),
            path,
            identity,
            directory,
        })
    }

    pub(super) fn path(&self) -> &Path {
        &self.path
    }

    pub(super) fn inspect(&self) -> StagingResult<()> {
        self.directory.inspect()?;
        inspect(&self.path)?;
        if !std::fs::symlink_metadata(&self.path)
            .map_err(|_| StagingError::UnsafePath)?
            .is_file()
        {
            return Err(StagingError::UnsafePath);
        }
        if let Some(file) = &self.file {
            if FileIdentity::of(file.as_file())? != FileIdentity::of(&open_regular(&self.path)?)? {
                return Err(StagingError::UnsafePath);
            }
        }
        Ok(())
    }

    pub(super) fn file_mut(&mut self) -> &mut std::fs::File {
        self.file
            .as_mut()
            .expect("owned part is not yet published")
            .as_file_mut()
    }

    pub(super) fn publish_to(&mut self, destination: &Path) -> std::io::Result<()> {
        #[cfg(test)]
        super::tests::io_fault(super::tests::IoPoint::Publish)?;
        let file = self.file.take().expect("owned part is not yet published");
        match file.persist_noclobber(destination) {
            Ok(file) => {
                drop(file);
                Ok(())
            }
            Err(error) => {
                self.file = Some(error.file);
                Err(error.error)
            }
        }
    }
}

impl Drop for OwnedPart {
    fn drop(&mut self) {
        let owned = self.file.take();
        if self.directory.inspect().is_ok() {
            if let Ok(file) = open_regular(&self.path) {
                if FileIdentity::of(&file).is_ok_and(|identity| identity == self.identity) {
                    let _ = std::fs::remove_file(&self.path);
                }
            }
        }
        drop(owned);
    }
}

pub(super) fn inspect(path: &Path) -> StagingResult<()> {
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
    {
        return Err(unsafe_path(Boundary::PathSyntax));
    }
    let mut current = std::path::PathBuf::new();
    for component in path.components() {
        current.push(component);
        if matches!(component, Component::Prefix(_)) {
            continue;
        }
        let metadata = std::fs::symlink_metadata(&current)
            .map_err(|error| unsafe_io(Boundary::PathInspectStat, error))?;
        if is_link(&metadata) {
            return Err(unsafe_path(Boundary::PathInspectLink));
        }
        if (!metadata.is_dir() && current != path) || (!metadata.is_dir() && !metadata.is_file()) {
            return Err(unsafe_path(Boundary::PathInspectKind));
        }
    }
    Ok(())
}

pub(super) fn ensure_directory(path: &Path) -> StagingResult<()> {
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
    {
        return Err(unsafe_path(Boundary::PathSyntax));
    }
    let mut current = std::path::PathBuf::new();
    for component in path.components() {
        current.push(component);
        if matches!(component, Component::Prefix(_)) {
            continue;
        }
        match std::fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.is_dir() && !is_link(&metadata) => {}
            Ok(metadata) => {
                return Err(unsafe_path(if is_link(&metadata) {
                    Boundary::PathEnsureLink
                } else {
                    Boundary::PathEnsureKind
                }))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let builder = std::fs::DirBuilder::new();
                #[cfg(unix)]
                let mut builder = builder;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::DirBuilderExt;
                    builder.mode(0o700);
                }
                builder.create(&current).map_err(|error| {
                    let mapped = super::io_error(&error, StagingError::UnsafePath);
                    diagnostics::core(
                        Boundary::PathEnsureCreate,
                        &crate::error::CoreError::Io(error),
                    );
                    mapped
                })?;
            }
            Err(error) => return Err(unsafe_io(Boundary::PathEnsureStat, error)),
        }
    }
    inspect(path)
}

pub(super) fn create_operation(path: &Path) -> StagingResult<()> {
    inspect(path.parent().ok_or(StagingError::UnsafePath)?)?;
    let builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    let mut builder = builder;
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::AlreadyExists {
            StagingError::Conflict
        } else {
            super::io_error(&error, StagingError::Write)
        }
    })?;
    inspect(path)
}

pub(super) fn same_volume(first: &Path, second: &Path) -> StagingResult<bool> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(std::fs::metadata(first)
            .map_err(|_| StagingError::Read)?
            .dev()
            == std::fs::metadata(second)
                .map_err(|_| StagingError::Read)?
                .dev())
    }
    #[cfg(windows)]
    {
        // Canonical paths resolve drive aliases and junctions. Equal prefixes are
        // conservatively charged as shared even for volume mount directories.
        let first = first.canonicalize().map_err(|_| StagingError::UnsafePath)?;
        let second = second
            .canonicalize()
            .map_err(|_| StagingError::UnsafePath)?;
        Ok(crate::device_sync::library_guard::path_key(&first)
            .components()
            .next()
            == crate::device_sync::library_guard::path_key(&second)
                .components()
                .next())
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (first, second);
        Ok(true)
    }
}

#[cfg(all(test, any(target_os = "linux", target_os = "android")))]
mod directory_permission_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn directory_identity_works_below_execute_only_ancestor() {
        let root = tempfile::tempdir().unwrap();
        let ancestor = root.path().canonicalize().unwrap().join("traversable");
        let child = ancestor.join("owned");
        std::fs::create_dir_all(&child).unwrap();
        std::fs::set_permissions(&ancestor, std::fs::Permissions::from_mode(0o111)).unwrap();
        let opened = HeldDirectory::open(&child);
        let inspected = opened.as_ref().map(|held| held.inspect());
        // Restore before asserting so a failed regression can clean its fixture.
        std::fs::set_permissions(&ancestor, std::fs::Permissions::from_mode(0o700)).unwrap();
        inspected
            .expect("identity handles must open below execute-only ancestors")
            .expect("inspection must not require ancestor read permission");
        let held = opened.expect("identity handles must not require ancestor read permission");
        held.inspect().unwrap();
        assert!(held.volume_id().is_ok());
    }

    #[test]
    fn directory_identity_still_rejects_a_replaced_ancestor() {
        let root = tempfile::tempdir().unwrap();
        let ancestor = root.path().canonicalize().unwrap().join("original");
        let child = ancestor.join("owned");
        std::fs::create_dir_all(&child).unwrap();
        let held = HeldDirectory::open(&child).unwrap();
        std::fs::rename(&ancestor, ancestor.with_extension("retained")).unwrap();
        std::fs::create_dir_all(&child).unwrap();
        assert!(matches!(held.inspect(), Err(StagingError::UnsafePath)));
    }
}
