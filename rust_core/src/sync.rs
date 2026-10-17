use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::task::JoinSet;
use tokio::time::Instant;

use crate::database::Database;
use crate::device_sync::library_guard::{PublicationPin, WriteLease};
use crate::error::{CoreError, CoreResult};
use crate::models::{MediaCandidate, SyncItemError, SyncSummary};
use crate::nso::MediaProvider;
use crate::transport::{DownloadedMedia, HttpTransport};

#[derive(Default)]
struct CancellationState {
    cancelled: AtomicBool,
    notify: tokio::sync::Notify,
}

#[derive(Clone, Default)]
pub struct CancellationToken(Arc<CancellationState>);

impl CancellationToken {
    pub fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::SeqCst);
        self.0.notify.notify_waiters();
    }

    pub fn check(&self) -> CoreResult<()> {
        if self.0.cancelled.load(Ordering::SeqCst) {
            Err(CoreError::Cancelled)
        } else {
            Ok(())
        }
    }

    pub async fn cancelled(&self) {
        loop {
            let notified = self.0.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.0.cancelled.load(Ordering::SeqCst) {
                return;
            }
            notified.await;
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
    pub(crate) pin: PublicationPin,
    _writing: WriteLease,
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
        let _writing = self.database.write_lease()?;
        self.database.ensure_original_root(&self.root)?;
        let sha256 = hex::encode(Sha256::digest(bytes));
        let destination = self
            .root
            .join("originals")
            .join(&sha256[0..2])
            .join(&sha256[2..4])
            .join(format!("{sha256}.{}", candidate.storage_extension()));
        let parent = destination.parent().expect("content path has parent");
        tokio::fs::create_dir_all(parent).await?;
        let pin =
            self.database
                .pin_original(&self.root, &destination, &sha256, bytes.len() as u64)?;
        let created = !destination.exists();
        if created {
            let temporary = parent.join(format!("{}.part", uuid::Uuid::new_v4()));
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
        if created && !matches!(result, Ok((_, true))) {
            let _ = self
                .database
                .cleanup_original(&self.root, &destination, &sha256, Some(&pin));
        }
        result
    }

    pub async fn import_file(
        &self,
        candidate: &MediaCandidate,
        source: &Path,
        provider: Option<&str>,
    ) -> CoreResult<(i64, bool)> {
        let _writing = self.database.write_lease()?;
        self.database.ensure_original_root(&self.root)?;
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
        if staged.created && !matches!(result, Ok((_, true))) {
            let _ = self.database.cleanup_original(
                &self.root,
                &staged.path,
                &staged.sha256,
                Some(&staged.pin),
            );
        }
        result
    }

    pub async fn import_downloaded(
        &self,
        candidate: &MediaCandidate,
        mut downloaded: DownloadedMedia,
        provider: Option<&str>,
    ) -> CoreResult<(i64, bool)> {
        let _writing = self.database.write_lease()?;
        self.database.ensure_original_root(&self.root)?;
        let sha256 = downloaded.sha256().to_owned();
        let size = downloaded.size();
        let destination = self
            .root
            .join("originals")
            .join(&sha256[0..2])
            .join(&sha256[2..4])
            .join(format!("{}.{}", sha256, candidate.storage_extension()));
        tokio::fs::create_dir_all(destination.parent().expect("content path has parent")).await?;
        let pin = self
            .database
            .pin_original(&self.root, &destination, &sha256, size)?;
        let created = !destination.exists();
        if created {
            tokio::fs::create_dir_all(destination.parent().expect("content path has parent"))
                .await?;
            if let Err(error) = downloaded.publish_to(&destination).await {
                if !destination.exists() {
                    return Err(error);
                }
            }
        }
        let result = self
            .database
            .register_media(&sha256, size, &destination, candidate, provider);
        if created && !matches!(result, Ok((_, true))) {
            let _ = self
                .database
                .cleanup_original(&self.root, &destination, &sha256, Some(&pin));
        }
        result
    }

    pub async fn stage_file(&self, source: &Path, extension: &str) -> CoreResult<StagedMedia> {
        let writing = self.database.write_lease()?;
        self.database.ensure_original_root(&self.root)?;
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
        tokio::fs::create_dir_all(destination.parent().expect("content path has parent")).await?;
        let pin = self
            .database
            .pin_original(&self.root, &destination, &sha256, size)?;
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
            pin,
            _writing: writing,
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
}

#[async_trait]
pub trait MediaDownloader: Clone + Send + Sync + 'static {
    async fn download_to_file(
        &self,
        url: &str,
        expected_size: Option<u64>,
        temporary_root: &Path,
        cancellation: &CancellationToken,
    ) -> CoreResult<DownloadedMedia>;
}

#[async_trait]
impl MediaDownloader for HttpTransport {
    async fn download_to_file(
        &self,
        url: &str,
        expected_size: Option<u64>,
        temporary_root: &Path,
        cancellation: &CancellationToken,
    ) -> CoreResult<DownloadedMedia> {
        self.download_media_to_file(url, expected_size, temporary_root, cancellation)
            .await
    }
}

pub struct SyncEngine<P, D = HttpTransport> {
    provider: P,
    downloader: D,
    repository: MediaRepository,
}

struct DownloadWork {
    candidate: MediaCandidate,
    attempt: u32,
    ready_at: Instant,
}

struct AdaptiveDownloadController {
    concurrency: usize,
    successes_since_growth: usize,
    last_growth_at: Instant,
    pause_until: Option<Instant>,
}

impl AdaptiveDownloadController {
    const MIN_CONCURRENCY: usize = 2;
    const MAX_CONCURRENCY: usize = 4;
    const SUCCESSES_PER_GROWTH: usize = 4;
    const GROWTH_COOLDOWN: Duration = Duration::from_secs(30);
    const RATE_LIMIT_PAUSE: Duration = Duration::from_secs(60);

    fn new(now: Instant) -> Self {
        Self {
            concurrency: Self::MIN_CONCURRENCY,
            successes_since_growth: 0,
            last_growth_at: now,
            pause_until: None,
        }
    }

    fn limit(&mut self, now: Instant) -> usize {
        if self.concurrency < Self::MAX_CONCURRENCY
            && self.successes_since_growth >= Self::SUCCESSES_PER_GROWTH
            && now.duration_since(self.last_growth_at) >= Self::GROWTH_COOLDOWN
        {
            self.concurrency += 1;
            self.successes_since_growth = 0;
            self.last_growth_at = now;
        }
        self.concurrency
    }

    fn record_success(&mut self, now: Instant) {
        self.successes_since_growth = self.successes_since_growth.saturating_add(1);
        self.limit(now);
    }

    fn record_temporary_error(&mut self, now: Instant) {
        self.concurrency = self
            .concurrency
            .saturating_sub(1)
            .max(Self::MIN_CONCURRENCY);
        self.successes_since_growth = 0;
        self.last_growth_at = now;
    }

    fn record_permanent_error(&mut self) {
        self.successes_since_growth = 0;
    }

    fn record_rate_limit(&mut self, now: Instant) {
        self.record_temporary_error(now);
        self.pause_until = Some(now + Self::RATE_LIMIT_PAUSE);
    }

    fn pause_remaining(&self, now: Instant) -> Option<Duration> {
        self.pause_until
            .and_then(|until| until.checked_duration_since(now))
            .filter(|remaining| !remaining.is_zero())
    }
}

impl<P: MediaProvider, D: MediaDownloader> SyncEngine<P, D> {
    pub fn new(provider: P, downloader: D, repository: MediaRepository) -> Self {
        Self {
            provider,
            downloader,
            repository,
        }
    }

    pub async fn sync(
        &self,
        cursor: Option<&str>,
        cancellation: &CancellationToken,
    ) -> CoreResult<SyncSummary> {
        let _writing = self.repository.database.write_lease()?;
        self.repository
            .database
            .ensure_original_root(self.repository.root())?;
        cancellation.check()?;
        let job_id = uuid::Uuid::new_v4().to_string();
        let provider_name = self.provider.provider_name();
        self.repository
            .database
            .begin_sync_job(&job_id, provider_name, cursor)?;
        let page = match tokio::select! {
            _ = cancellation.cancelled() => Err(CoreError::Cancelled),
            result = self.provider.list_recent(cursor) => result,
        } {
            Ok(page) => page,
            Err(error) => {
                self.repository.database.update_sync_job(
                    &job_id,
                    if matches!(error, CoreError::Cancelled) {
                        "cancelled"
                    } else {
                        "failed"
                    },
                    0,
                    0,
                    usize::from(!matches!(error, CoreError::Cancelled)),
                    cursor,
                    Some(&error.to_string()),
                )?;
                return Err(error);
            }
        };
        let next_cursor = page.next_cursor;
        let mut summary = SyncSummary {
            job_id: job_id.clone(),
            total_found: page.items.len(),
            downloaded: 0,
            duplicates: 0,
            skipped_remote: 0,
            failed: 0,
            new_media_at: None,
            cursor: cursor.map(str::to_owned),
            errors: Vec::new(),
        };
        self.repository.database.update_sync_job(
            &job_id,
            "running",
            summary.total_found,
            0,
            0,
            cursor,
            None,
        )?;

        let mut pending = VecDeque::new();
        let now = Instant::now();
        for candidate in page.items {
            if cancellation.check().is_err() {
                self.mark_cancelled(&job_id, cursor, &summary)?;
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
                        cursor,
                        None,
                    )?;
                    continue;
                }
            }
            if candidate.content_url.is_none() {
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
                    cursor,
                    None,
                )?;
                continue;
            }
            pending.push_back(DownloadWork {
                candidate,
                attempt: 0,
                ready_at: now,
            });
        }

        let temporary_root = self.repository.root().join("temporary");
        let mut downloads = JoinSet::new();
        let mut controller = AdaptiveDownloadController::new(Instant::now());
        while !pending.is_empty() || !downloads.is_empty() {
            if cancellation.check().is_err() {
                downloads.abort_all();
                while downloads.join_next().await.is_some() {}
                self.mark_cancelled(&job_id, cursor, &summary)?;
                return Err(CoreError::Cancelled);
            }

            let schedule_now = Instant::now();
            let paused = controller.pause_remaining(schedule_now).is_some();
            if !paused {
                let limit = controller.limit(schedule_now);
                while downloads.len() < limit {
                    let Some(work) = pending.front() else {
                        break;
                    };
                    if work.ready_at > Instant::now() {
                        break;
                    }
                    let work = pending.pop_front().expect("pending work exists");
                    let downloader = self.downloader.clone();
                    let cancellation = cancellation.clone();
                    let temporary_root = temporary_root.clone();
                    downloads.spawn(async move {
                        let url = work
                            .candidate
                            .content_url
                            .as_deref()
                            .expect("queued downloads have URLs");
                        let result = downloader
                            .download_to_file(
                                url,
                                work.candidate.expected_size,
                                &temporary_root,
                                &cancellation,
                            )
                            .await;
                        (work, result)
                    });
                }
            }

            if downloads.is_empty() {
                let now = Instant::now();
                let retry_wait = pending
                    .front()
                    .and_then(|work| work.ready_at.checked_duration_since(now))
                    .unwrap_or_default();
                let pause_wait = controller.pause_remaining(now).unwrap_or_default();
                let wait = retry_wait.max(pause_wait);
                if !wait.is_zero() {
                    tokio::select! {
                        _ = cancellation.cancelled() => {
                            self.mark_cancelled(&job_id, cursor, &summary)?;
                            return Err(CoreError::Cancelled);
                        }
                        _ = tokio::time::sleep(wait) => {}
                    }
                }
                continue;
            }

            let joined = tokio::select! {
                _ = cancellation.cancelled() => {
                    downloads.abort_all();
                    while downloads.join_next().await.is_some() {}
                    self.mark_cancelled(&job_id, cursor, &summary)?;
                    return Err(CoreError::Cancelled);
                }
                joined = downloads.join_next() => joined,
            };
            let Some(joined) = joined else {
                continue;
            };
            let (mut work, result) = joined
                .map_err(|error| CoreError::Provider(format!("download task failed: {error}")))?;
            match result {
                Ok(downloaded) => {
                    controller.record_success(Instant::now());
                    match self
                        .repository
                        .import_downloaded(&work.candidate, downloaded, Some(provider_name))
                        .await
                    {
                        Ok((_, true)) => {
                            summary.downloaded += 1;
                            let timestamp = work.candidate.effective_timestamp();
                            summary.new_media_at = Some(
                                summary
                                    .new_media_at
                                    .map(|current| current.max(timestamp))
                                    .unwrap_or(timestamp),
                            );
                        }
                        Ok((_, false)) => summary.duplicates += 1,
                        Err(error) => record_item_error(&mut summary, &work.candidate, error),
                    }
                }
                Err(CoreError::Cancelled) => {
                    downloads.abort_all();
                    while downloads.join_next().await.is_some() {}
                    self.mark_cancelled(&job_id, cursor, &summary)?;
                    return Err(CoreError::Cancelled);
                }
                Err(error) => {
                    let now = Instant::now();
                    let temporary = is_temporary_download_error(&error);
                    let rate_limited = matches!(error, CoreError::RateLimited { .. });
                    if rate_limited {
                        controller.record_rate_limit(now);
                    } else if temporary {
                        controller.record_temporary_error(now);
                    } else {
                        controller.record_permanent_error();
                    }
                    if temporary && work.attempt < 2 {
                        work.attempt += 1;
                        work.ready_at = if rate_limited {
                            now
                        } else {
                            now + Duration::from_secs(1_u64 << (work.attempt - 1))
                        };
                        pending.push_back(work);
                        continue;
                    }
                    record_item_error(&mut summary, &work.candidate, error);
                }
            }
            self.repository.database.update_sync_job(
                &job_id,
                "running",
                summary.total_found,
                summary.downloaded + summary.duplicates + summary.skipped_remote,
                summary.failed,
                cursor,
                None,
            )?;
        }

        if cancellation.check().is_err() {
            self.mark_cancelled(&job_id, cursor, &summary)?;
            return Err(CoreError::Cancelled);
        }

        if summary.failed == 0 {
            summary.cursor = next_cursor;
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

    fn mark_cancelled(
        &self,
        job_id: &str,
        cursor: Option<&str>,
        summary: &SyncSummary,
    ) -> CoreResult<()> {
        self.repository.database.update_sync_job(
            job_id,
            "cancelled",
            summary.total_found,
            summary.downloaded + summary.duplicates + summary.skipped_remote,
            summary.failed,
            cursor,
            Some("cancelled"),
        )
    }
}

fn is_temporary_download_error(error: &CoreError) -> bool {
    matches!(
        error,
        CoreError::RateLimited { .. } | CoreError::Network(_) | CoreError::Io(_)
    )
}

fn record_item_error(summary: &mut SyncSummary, candidate: &MediaCandidate, error: CoreError) {
    summary.failed += 1;
    summary.errors.push(SyncItemError {
        remote_id: candidate.remote_id.clone(),
        message: error.to_string(),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{GalleryQuery, MediaKind, ProviderPage, SourceType};
    use crate::transport::DownloadedMedia;
    use async_trait::async_trait;
    use std::collections::HashMap;
    use std::sync::atomic::AtomicUsize;
    use std::sync::Mutex;

    struct StaticProvider {
        items: Vec<MediaCandidate>,
        next_cursor: Option<String>,
    }

    #[async_trait]
    impl MediaProvider for StaticProvider {
        fn provider_name(&self) -> &str {
            "test-provider"
        }

        async fn list_recent(&self, _cursor: Option<&str>) -> CoreResult<ProviderPage> {
            Ok(ProviderPage {
                items: self.items.clone(),
                next_cursor: self.next_cursor.clone(),
            })
        }
    }

    #[derive(Clone)]
    struct FakeDownloader {
        active: Arc<AtomicUsize>,
        max_active: Arc<AtomicUsize>,
        fail_url: Option<String>,
    }

    #[derive(Clone)]
    struct FinalRateLimitDownloader {
        calls: Arc<Mutex<HashMap<String, usize>>>,
        events: Arc<Mutex<Vec<(String, usize, tokio::time::Instant)>>>,
    }

    impl FinalRateLimitDownloader {
        fn new() -> Self {
            Self {
                calls: Arc::new(Mutex::new(HashMap::new())),
                events: Arc::new(Mutex::new(Vec::new())),
            }
        }

        fn event_time(&self, suffix: &str, attempt: usize) -> tokio::time::Instant {
            self.events
                .lock()
                .unwrap()
                .iter()
                .find(|(url, recorded_attempt, _)| {
                    url.ends_with(suffix) && *recorded_attempt == attempt
                })
                .map(|(_, _, time)| *time)
                .expect("expected scripted download event")
        }
    }

    #[async_trait]
    impl MediaDownloader for FinalRateLimitDownloader {
        async fn download_to_file(
            &self,
            url: &str,
            _expected_size: Option<u64>,
            temporary_root: &Path,
            cancellation: &CancellationToken,
        ) -> CoreResult<DownloadedMedia> {
            cancellation.check()?;
            let attempt = {
                let mut calls = self.calls.lock().unwrap();
                let count = calls.entry(url.to_owned()).or_default();
                *count += 1;
                *count
            };
            self.events.lock().unwrap().push((
                url.to_owned(),
                attempt,
                tokio::time::Instant::now(),
            ));

            if url.ends_with("/0.jpg") {
                return match attempt {
                    1 | 2 => Err(CoreError::Io(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "synthetic temporary failure",
                    ))),
                    3 => Err(CoreError::RateLimited {
                        retry_after_seconds: 60,
                    }),
                    _ => panic!("rate-limited item retried too many times"),
                };
            }
            if url.ends_with("/1.jpg") {
                match attempt {
                    1 => {
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        return Err(CoreError::Io(std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "synthetic temporary failure",
                        )));
                    }
                    2 => {
                        return Err(CoreError::Io(std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "synthetic temporary failure",
                        )));
                    }
                    3 => {}
                    _ => panic!("pending item retried too many times"),
                }
            } else if url.ends_with("/2.jpg") {
                tokio::time::sleep(Duration::from_millis(500)).await;
            }

            let bytes = url.as_bytes();
            Ok(crate::transport::test_support::download_bytes(temporary_root, bytes).await)
        }
    }

    #[async_trait]
    impl MediaDownloader for FakeDownloader {
        async fn download_to_file(
            &self,
            url: &str,
            _expected_size: Option<u64>,
            temporary_root: &Path,
            cancellation: &CancellationToken,
        ) -> CoreResult<DownloadedMedia> {
            cancellation.check()?;
            if self.fail_url.as_deref() == Some(url) {
                return Err(CoreError::Provider("synthetic download failure".into()));
            }
            let active = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.max_active.fetch_max(active, Ordering::SeqCst);
            tokio::select! {
                _ = cancellation.cancelled() => {
                    self.active.fetch_sub(1, Ordering::SeqCst);
                    return Err(CoreError::Cancelled);
                }
                _ = tokio::time::sleep(Duration::from_millis(20)) => {}
            }
            self.active.fetch_sub(1, Ordering::SeqCst);
            let bytes = url.as_bytes();
            Ok(crate::transport::test_support::download_bytes(temporary_root, bytes).await)
        }
    }

    fn remote_candidate(index: usize) -> MediaCandidate {
        MediaCandidate {
            remote_id: Some(format!("remote-{index}")),
            title_id: None,
            game_name: "Game".into(),
            kind: MediaKind::Image,
            content_url: Some(format!("https://example.com/{index}.jpg")),
            thumbnail_url: None,
            expected_size: None,
            captured_at: None,
            uploaded_at: None,
            expires_at: None,
            original_name: Some(format!("{index}.jpg")),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Nso,
            source_path: None,
        }
    }
    #[tokio::test]
    async fn cancellation_future_wakes_without_polling() {
        let token = CancellationToken::default();
        let waiter = token.clone();
        let task = tokio::spawn(async move { waiter.cancelled().await });

        tokio::task::yield_now().await;
        token.cancel();

        tokio::time::timeout(Duration::from_millis(100), task)
            .await
            .expect("cancellation waiter should be notified")
            .expect("cancellation waiter should not panic");
    }

    #[test]
    fn adaptive_downloads_grow_after_four_successes_and_cooldown() {
        let started = Instant::now();
        let mut controller = AdaptiveDownloadController::new(started);
        assert_eq!(controller.limit(started), 2);

        for offset in 0..4 {
            controller.record_success(started + Duration::from_secs(offset));
        }
        assert_eq!(
            controller.limit(started + Duration::from_secs(29)),
            2,
            "growth must wait for cooldown"
        );

        assert_eq!(controller.limit(started + Duration::from_secs(30)), 3);
        for offset in 31..35 {
            controller.record_success(started + Duration::from_secs(offset));
        }
        assert_eq!(
            controller.limit(started + Duration::from_secs(59)),
            3,
            "each growth has its own cooldown"
        );
        assert_eq!(controller.limit(started + Duration::from_secs(60)), 4);
        for offset in 61..100 {
            controller.record_success(started + Duration::from_secs(offset));
        }
        assert_eq!(
            controller.limit(started + Duration::from_secs(100)),
            4,
            "concurrency is capped at four"
        );
    }

    #[test]
    fn temporary_error_reduces_downloads_to_minimum_two() {
        let started = Instant::now();
        let mut controller = AdaptiveDownloadController::new(started);
        for _ in 0..4 {
            controller.record_success(started + Duration::from_secs(30));
        }
        assert_eq!(controller.limit(started + Duration::from_secs(30)), 3);
        for _ in 0..4 {
            controller.record_success(started + Duration::from_secs(60));
        }
        assert_eq!(controller.limit(started + Duration::from_secs(60)), 4);

        controller.record_temporary_error(started + Duration::from_secs(61));
        assert_eq!(controller.limit(started + Duration::from_secs(61)), 3);
        controller.record_temporary_error(started + Duration::from_secs(62));
        controller.record_temporary_error(started + Duration::from_secs(63));
        assert_eq!(controller.limit(started + Duration::from_secs(63)), 2);
    }

    #[test]
    fn permanent_error_resets_consecutive_successes_without_reducing_limit() {
        let started = Instant::now();
        let mut controller = AdaptiveDownloadController::new(started);
        for offset in 0..3 {
            controller.record_success(started + Duration::from_secs(offset));
        }

        controller.record_permanent_error();
        controller.record_success(started + Duration::from_secs(30));

        assert_eq!(controller.limit(started + Duration::from_secs(30)), 2);
    }

    #[test]
    fn rate_limit_pauses_new_downloads_for_sixty_seconds() {
        let started = Instant::now();
        let mut controller = AdaptiveDownloadController::new(started);

        controller.record_rate_limit(started);

        assert_eq!(
            controller.pause_remaining(started + Duration::from_secs(1)),
            Some(Duration::from_secs(59))
        );
        assert_eq!(
            controller.pause_remaining(started + Duration::from_secs(60)),
            None
        );
    }

    #[tokio::test]
    async fn streamed_downloads_use_sha_deduplication_and_remove_parts() {
        let directory = tempfile::tempdir().unwrap();
        let database = Arc::new(
            Database::open(directory.path().join("database").join("library.sqlite3")).unwrap(),
        );
        let repository = MediaRepository::new(directory.path(), database);
        let candidate = MediaCandidate {
            remote_id: Some("remote-one".into()),
            title_id: None,
            game_name: "Game".into(),
            kind: MediaKind::Image,
            content_url: Some("https://example.com/image.jpg".into()),
            thumbnail_url: None,
            expected_size: Some(4),
            captured_at: None,
            uploaded_at: None,
            expires_at: None,
            original_name: Some("image.jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Nso,
            source_path: None,
        };
        let bytes = b"same";
        let download = crate::transport::test_support::download_bytes(
            &directory.path().join("temporary"),
            bytes,
        )
        .await;
        let first_part = download.path().to_path_buf();
        let (_, created) = repository
            .import_downloaded(&candidate, download, Some("test"))
            .await
            .unwrap();
        assert!(created);
        assert!(!first_part.exists());

        let download = crate::transport::test_support::download_bytes(
            &directory.path().join("temporary"),
            bytes,
        )
        .await;
        let second_part = download.path().to_path_buf();
        let (_, created) = repository
            .import_downloaded(
                &MediaCandidate {
                    remote_id: Some("remote-two".into()),
                    ..candidate
                },
                download,
                Some("test"),
            )
            .await
            .unwrap();
        assert!(!created);
        assert!(!second_part.exists());
    }

    #[tokio::test]
    async fn sync_downloads_with_bounded_tokio_concurrency_and_serial_ingest() {
        let directory = tempfile::tempdir().unwrap();
        let database = Arc::new(
            Database::open(directory.path().join("database").join("library.sqlite3")).unwrap(),
        );
        let active = Arc::new(AtomicUsize::new(0));
        let max_active = Arc::new(AtomicUsize::new(0));
        let engine = SyncEngine::new(
            StaticProvider {
                items: (0..6).map(remote_candidate).collect(),
                next_cursor: Some("next".into()),
            },
            FakeDownloader {
                active,
                max_active: Arc::clone(&max_active),
                fail_url: None,
            },
            MediaRepository::new(directory.path(), Arc::clone(&database)),
        );

        let summary = engine
            .sync(None, &CancellationToken::default())
            .await
            .unwrap();

        assert_eq!(summary.downloaded, 6);
        assert_eq!(summary.failed, 0);
        assert!((2..=4).contains(&max_active.load(Ordering::SeqCst)));
        assert_eq!(
            database.list_media(&GalleryQuery::default()).unwrap().len(),
            6
        );
    }

    #[tokio::test]
    async fn failed_item_does_not_advance_persisted_cursor() {
        let directory = tempfile::tempdir().unwrap();
        let database = Arc::new(
            Database::open(directory.path().join("database").join("library.sqlite3")).unwrap(),
        );
        database
            .begin_sync_job("previous", "test-provider", None)
            .unwrap();
        database
            .update_sync_job("previous", "completed", 0, 0, 0, Some("old"), None)
            .unwrap();
        let failed_url = "https://example.com/1.jpg".to_owned();
        let engine = SyncEngine::new(
            StaticProvider {
                items: (0..2).map(remote_candidate).collect(),
                next_cursor: Some("next".into()),
            },
            FakeDownloader {
                active: Arc::new(AtomicUsize::new(0)),
                max_active: Arc::new(AtomicUsize::new(0)),
                fail_url: Some(failed_url),
            },
            MediaRepository::new(directory.path(), Arc::clone(&database)),
        );

        let summary = engine
            .sync(Some("old"), &CancellationToken::default())
            .await
            .unwrap();

        assert_eq!(summary.failed, 1);
        assert_eq!(
            database.latest_sync_cursor("test-provider").unwrap(),
            Some("old".into())
        );
    }

    #[tokio::test(start_paused = true)]
    async fn final_attempt_rate_limit_pauses_pending_downloads_for_sixty_seconds() {
        let directory = tempfile::tempdir().unwrap();
        let database = Arc::new(
            Database::open(directory.path().join("database").join("library.sqlite3")).unwrap(),
        );
        let downloader = FinalRateLimitDownloader::new();
        let engine = SyncEngine::new(
            StaticProvider {
                items: (0..3).map(remote_candidate).collect(),
                next_cursor: Some("next".into()),
            },
            downloader.clone(),
            MediaRepository::new(directory.path(), database),
        );

        let summary = tokio::time::timeout(
            Duration::from_secs(70),
            engine.sync(None, &CancellationToken::default()),
        )
        .await
        .expect("scheduler should finish under paused Tokio time")
        .unwrap();
        let final_rate_limit = downloader.event_time("/0.jpg", 3);
        let pending_start = downloader.event_time("/1.jpg", 3);

        assert_eq!(summary.failed, 1);
        assert_eq!(summary.downloaded, 2);
        assert!(
            pending_start.duration_since(final_rate_limit) >= Duration::from_secs(60),
            "pending work started before the final-attempt 429 pause elapsed"
        );
    }
}
