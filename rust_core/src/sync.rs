use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::database::Database;
use crate::error::{CoreError, CoreResult};
use crate::models::{MediaCandidate, SyncItemError, SyncSummary};
use crate::nso::MediaProvider;
use crate::transport::HttpTransport;

#[derive(Clone, Default)]
pub struct CancellationToken(Arc<AtomicBool>);

impl CancellationToken {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn check(&self) -> CoreResult<()> {
        if self.0.load(Ordering::SeqCst) {
            Err(CoreError::Cancelled)
        } else {
            Ok(())
        }
    }
}

pub struct MediaRepository {
    root: PathBuf,
    database: Arc<Database>,
}

pub struct StagedMedia {
    pub sha256: String,
    pub size: u64,
    pub path: PathBuf,
    pub created: bool,
}

impl MediaRepository {
    pub fn new(root: impl Into<PathBuf>, database: Arc<Database>) -> Self {
        Self {
            root: root.into(),
            database,
        }
    }

    pub async fn import_bytes(
        &self,
        candidate: &MediaCandidate,
        bytes: &[u8],
        provider: Option<&str>,
    ) -> CoreResult<(i64, bool)> {
        let sha256 = hex::encode(Sha256::digest(bytes));
        let destination = self
            .root
            .join("originals")
            .join(&sha256[0..2])
            .join(&sha256[2..4])
            .join(format!("{sha256}.{}", candidate.storage_extension()));
        let created = !destination.exists();
        if created {
            let parent = destination.parent().expect("content path has parent");
            tokio::fs::create_dir_all(parent).await?;
            let temporary =
                destination.with_extension(format!("{}.part", candidate.storage_extension()));
            let mut file = tokio::fs::File::create(&temporary).await?;
            file.write_all(bytes).await?;
            file.flush().await?;
            drop(file);
            match tokio::fs::rename(&temporary, &destination).await {
                Ok(()) => {}
                Err(error) if destination.exists() => {
                    let _ = tokio::fs::remove_file(&temporary).await;
                    let _ = error;
                }
                Err(error) => {
                    let _ = tokio::fs::remove_file(&temporary).await;
                    return Err(error.into());
                }
            }
        }
        let result = self.database.register_media(
            &sha256,
            bytes.len() as u64,
            &destination,
            candidate,
            provider,
        );
        if result.is_err() && created {
            let _ = tokio::fs::remove_file(&destination).await;
        }
        result
    }

    pub async fn import_file(
        &self,
        candidate: &MediaCandidate,
        source: &Path,
        provider: Option<&str>,
    ) -> CoreResult<(i64, bool)> {
        let staged = self
            .stage_file(source, candidate.storage_extension())
            .await?;
        let result = self.database.register_media(
            &staged.sha256,
            staged.size,
            &staged.path,
            candidate,
            provider,
        );
        if result.is_err() && staged.created {
            let _ = tokio::fs::remove_file(&staged.path).await;
        }
        result
    }

    pub async fn stage_file(&self, source: &Path, extension: &str) -> CoreResult<StagedMedia> {
        const MAX_MEDIA_BYTES: u64 = 256 * 1024 * 1024;

        let metadata = tokio::fs::metadata(source).await?;
        if metadata.len() == 0 {
            return Err(CoreError::InvalidConfig(
                "processed media file is empty".into(),
            ));
        }
        if metadata.len() > MAX_MEDIA_BYTES {
            return Err(CoreError::DownloadTooLarge {
                actual: metadata.len(),
                limit: MAX_MEDIA_BYTES,
            });
        }

        let temporary_root = self.root.join("temporary");
        tokio::fs::create_dir_all(&temporary_root).await?;
        let temporary = temporary_root.join(format!("{}.part", uuid::Uuid::new_v4()));
        let mut input = tokio::fs::File::open(source).await?;
        let mut output = tokio::fs::File::create(&temporary).await?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0_u8; 1024 * 1024];
        let mut size = 0_u64;
        loop {
            let read = input.read(&mut buffer).await?;
            if read == 0 {
                break;
            }
            size += read as u64;
            if size > MAX_MEDIA_BYTES {
                drop(output);
                let _ = tokio::fs::remove_file(&temporary).await;
                return Err(CoreError::DownloadTooLarge {
                    actual: size,
                    limit: MAX_MEDIA_BYTES,
                });
            }
            hasher.update(&buffer[..read]);
            output.write_all(&buffer[..read]).await?;
        }
        output.flush().await?;
        drop(output);

        let sha256 = hex::encode(hasher.finalize());
        let extension = extension
            .trim()
            .trim_start_matches('.')
            .to_ascii_lowercase();
        if !matches!(
            extension.as_str(),
            "jpg" | "jpeg" | "png" | "webp" | "mp4" | "mov"
        ) {
            let _ = tokio::fs::remove_file(&temporary).await;
            return Err(CoreError::InvalidConfig(
                "unsupported processed media extension".into(),
            ));
        }
        let destination = self
            .root
            .join("originals")
            .join(&sha256[0..2])
            .join(&sha256[2..4])
            .join(format!("{sha256}.{extension}"));
        let created = !destination.exists();
        if destination.exists() {
            let _ = tokio::fs::remove_file(&temporary).await;
        } else {
            tokio::fs::create_dir_all(destination.parent().expect("content path has parent"))
                .await?;
            if let Err(error) = tokio::fs::rename(&temporary, &destination).await {
                if destination.exists() {
                    let _ = tokio::fs::remove_file(&temporary).await;
                } else {
                    let _ = tokio::fs::remove_file(&temporary).await;
                    return Err(error.into());
                }
            }
        }

        Ok(StagedMedia {
            sha256,
            size,
            path: destination,
            created,
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
}

pub struct SyncEngine<P> {
    provider: P,
    transport: HttpTransport,
    repository: MediaRepository,
}

impl<P: MediaProvider> SyncEngine<P> {
    pub fn new(provider: P, transport: HttpTransport, repository: MediaRepository) -> Self {
        Self {
            provider,
            transport,
            repository,
        }
    }

    pub async fn sync(
        &self,
        cursor: Option<&str>,
        cancellation: &CancellationToken,
    ) -> CoreResult<SyncSummary> {
        cancellation.check()?;
        let job_id = uuid::Uuid::new_v4().to_string();
        let provider_name = self.provider.provider_name();
        self.repository
            .database
            .begin_sync_job(&job_id, provider_name, cursor)?;
        let page = match self.provider.list_recent(cursor).await {
            Ok(page) => page,
            Err(error) => {
                self.repository.database.update_sync_job(
                    &job_id,
                    "failed",
                    0,
                    0,
                    1,
                    cursor,
                    Some(&error.to_string()),
                )?;
                return Err(error);
            }
        };
        let mut summary = SyncSummary {
            job_id: job_id.clone(),
            total_found: page.items.len(),
            downloaded: 0,
            duplicates: 0,
            skipped_remote: 0,
            failed: 0,
            new_media_at: None,
            cursor: page.next_cursor.clone(),
            errors: Vec::new(),
        };
        self.repository.database.update_sync_job(
            &job_id,
            "running",
            summary.total_found,
            0,
            0,
            summary.cursor.as_deref(),
            None,
        )?;
        for candidate in page.items {
            if cancellation.check().is_err() {
                self.repository.database.update_sync_job(
                    &job_id,
                    "cancelled",
                    summary.total_found,
                    summary.downloaded + summary.duplicates + summary.skipped_remote,
                    summary.failed,
                    summary.cursor.as_deref(),
                    Some("cancelled"),
                )?;
                return Err(CoreError::Cancelled);
            }
            if let Some(remote_id) = candidate.remote_id.as_deref() {
                if self
                    .repository
                    .database
                    .has_remote_media(provider_name, remote_id)?
                {
                    summary.skipped_remote += 1;
                    self.repository.database.update_sync_job(
                        &job_id,
                        "running",
                        summary.total_found,
                        summary.downloaded + summary.duplicates + summary.skipped_remote,
                        summary.failed,
                        summary.cursor.as_deref(),
                        None,
                    )?;
                    continue;
                }
            }
            let Some(url) = candidate.content_url.as_deref() else {
                summary.failed += 1;
                summary.errors.push(SyncItemError {
                    remote_id: candidate.remote_id.clone(),
                    message: "media has no content URL".into(),
                });
                self.repository.database.update_sync_job(
                    &job_id,
                    "running",
                    summary.total_found,
                    summary.downloaded + summary.duplicates + summary.skipped_remote,
                    summary.failed,
                    summary.cursor.as_deref(),
                    None,
                )?;
                continue;
            };
            match self
                .download_with_retry(url, candidate.expected_size, cancellation)
                .await
            {
                Ok(bytes) => match self
                    .repository
                    .import_bytes(&candidate, &bytes, Some(provider_name))
                    .await
                {
                    Ok((_, true)) => {
                        summary.downloaded += 1;
                        let timestamp = candidate.effective_timestamp();
                        summary.new_media_at = Some(
                            summary
                                .new_media_at
                                .map(|current| current.max(timestamp))
                                .unwrap_or(timestamp),
                        );
                    }
                    Ok((_, false)) => summary.duplicates += 1,
                    Err(error) => {
                        summary.failed += 1;
                        summary.errors.push(SyncItemError {
                            remote_id: candidate.remote_id.clone(),
                            message: error.to_string(),
                        });
                    }
                },
                Err(error) => {
                    summary.failed += 1;
                    summary.errors.push(SyncItemError {
                        remote_id: candidate.remote_id.clone(),
                        message: error.to_string(),
                    });
                }
            }
            self.repository.database.update_sync_job(
                &job_id,
                "running",
                summary.total_found,
                summary.downloaded + summary.duplicates + summary.skipped_remote,
                summary.failed,
                summary.cursor.as_deref(),
                None,
            )?;
        }
        self.repository.database.update_sync_job(
            &job_id,
            if summary.failed == 0 {
                "completed"
            } else {
                "completed_with_errors"
            },
            summary.total_found,
            summary.downloaded + summary.duplicates + summary.skipped_remote,
            summary.failed,
            summary.cursor.as_deref(),
            summary.errors.first().map(|error| error.message.as_str()),
        )?;
        Ok(summary)
    }

    async fn download_with_retry(
        &self,
        url: &str,
        expected_size: Option<u64>,
        cancellation: &CancellationToken,
    ) -> CoreResult<Vec<u8>> {
        let mut last_error = None;
        for attempt in 0..3_u32 {
            cancellation.check()?;
            match self.transport.download_media(url, expected_size).await {
                Ok(bytes) => return Ok(bytes),
                Err(error) => last_error = Some(error),
            }
            if attempt < 2 {
                tokio::time::sleep(Duration::from_secs(1_u64 << attempt)).await;
            }
        }
        Err(last_error.expect("download retry loop always records an error"))
    }
}
