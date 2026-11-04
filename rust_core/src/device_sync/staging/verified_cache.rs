use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::{
    file_stamp, paths, verify_open_file, MediaRecord, OwnedPart, StagingError, StagingResult,
};
use crate::device_sync::work::WorkControl;

pub(super) struct CacheRoot {
    directory: paths::HeldDirectory,
    validation: crate::device_sync::validation::ValidationMetrics,
}

pub(super) struct VerifiedObject {
    root: Arc<CacheRoot>,
    path: PathBuf,
    identity: paths::FileIdentity,
    stamp: (u64, std::time::SystemTime),
}

impl CacheRoot {
    pub(super) fn open(
        runtime: &Path,
        validation: crate::device_sync::validation::ValidationMetrics,
    ) -> StagingResult<Arc<Self>> {
        let path = runtime.join("verified-v1");
        paths::ensure_directory(&path)?;
        Ok(Arc::new(Self {
            directory: paths::HeldDirectory::open(&path)?,
            validation,
        }))
    }

    fn path(&self, record: &MediaRecord) -> PathBuf {
        let kind = match record.kind {
            crate::models::MediaKind::Image => "image",
            crate::models::MediaKind::Video => "video",
        };
        self.directory.path().join(format!(
            "{}-{}-{kind}.{}",
            record.sha256, record.length, record.extension
        ))
    }

    pub(super) fn lookup(
        self: &Arc<Self>,
        record: &MediaRecord,
        work: &WorkControl,
    ) -> StagingResult<Option<VerifiedObject>> {
        work.check().map_err(super::core_error)?;
        self.directory.inspect()?;
        let path = self.path(record);
        match std::fs::symlink_metadata(&path) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(super::io_error(&error, StagingError::Read)),
        }
        // Only the successful first receive check publishes into verified-v1.
        // A retry trusts that private cache instead of reading every byte again.
        let file = paths::open_regular(&path)?;
        paths::require_single_link(&file)?;
        let stamp = file_stamp(&file)?;
        if stamp.0 != record.length {
            return Err(StagingError::LengthMismatch);
        }
        work.check().map_err(super::core_error)?;
        self.directory.inspect()?;
        let identity = paths::FileIdentity::of(&file)?;
        if paths::FileIdentity::of(&paths::open_regular(&path)?)? != identity {
            return Err(StagingError::UnsafePath);
        }
        Ok(Some(VerifiedObject {
            root: self.clone(),
            path,
            identity,
            stamp,
        }))
    }

    pub(super) fn retain(
        self: &Arc<Self>,
        mut part: OwnedPart,
        record: &MediaRecord,
        cancel: &crate::sync::CancellationToken,
    ) -> StagingResult<VerifiedObject> {
        super::check_cancel(cancel)?;
        self.directory.inspect()?;
        part.inspect()?;
        let path = self.path(record);
        let expected = paths::FileIdentity::of(part.file_mut())?;
        let created = match part.publish_to(&path) {
            Ok(()) => {
                #[cfg(unix)]
                File::open(self.directory.path())
                    .and_then(|directory| directory.sync_all())
                    .map_err(|error| super::io_error(&error, StagingError::Sync))?;
                true
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => false,
            Err(error) => return Err(super::io_error(&error, StagingError::Publish)),
        };
        // Also removes an old temporary hardlink left by a no-clobber fallback.
        drop(part);
        self.directory.inspect()?;
        // A racing incumbent is accepted only after checking its actual bytes.
        let mut file = paths::open_regular(&path)?;
        paths::require_single_link(&file)?;
        if created {
            if paths::FileIdentity::of(&file)? != expected {
                return Err(StagingError::UnsafePath);
            }
        } else {
            verify_open_file(&mut file, record, cancel, &mut |_| {}, &self.validation)?;
        }
        self.directory.inspect()?;
        Ok(VerifiedObject {
            root: self.clone(),
            path,
            identity: paths::FileIdentity::of(&file)?,
            stamp: file_stamp(&file)?,
        })
    }
}

impl VerifiedObject {
    pub(super) fn open(&self) -> StagingResult<File> {
        self.root.directory.inspect()?;
        let file = paths::open_regular(&self.path)?;
        paths::require_single_link(&file)?;
        if paths::FileIdentity::of(&file)? != self.identity || file_stamp(&file)? != self.stamp {
            return Err(StagingError::UnsafePath);
        }
        self.root.directory.inspect()?;
        Ok(file)
    }
}
