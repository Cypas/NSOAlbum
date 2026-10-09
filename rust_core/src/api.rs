use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{Local, NaiveDateTime, TimeZone, Utc};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::album::{readable_import_media_name, readable_media_name, sanitize_game_folder};
use crate::database::Database;
use crate::error::{CoreError, CoreResult};
use crate::models::{
    AlbumRule, AlbumSummary, GalleryQuery, GameTagAliasSummary, GameTagSummary, ImportItemError,
    ImportSummary, LibraryRelocationResult, LoginChallenge, MediaAsset, MediaCandidate,
    MediaDeletionResult, MediaExportItemError, MediaExportSummary, MediaKind, SourceType,
    SyncProgress, SyncSummary, TagUsageSummary,
};
use crate::nso::{
    CoralAlbumProvider, CoralSession, CoralSessionClient, MediaProvider, NintendoAuthClient,
    NxapiAttestationClient, NxapiConfig,
};
use crate::settings::{
    AppSettings, SyncAttemptSummary, SyncPolicy, SyncRuntimeState, SyncScheduleStatus,
};
use crate::sync::{CancellationToken, MediaRepository, SyncEngine};
use crate::transport::{HttpTransport, TransportConfig};

/// Stable API surface intended for flutter_rust_bridge generation.
pub struct CoreApi {
    library_root: PathBuf,
    database: Arc<Database>,
}

impl CoreApi {
    pub fn open(library_root: impl AsRef<Path>) -> CoreResult<Self> {
        let library_root = library_root.as_ref().to_path_buf();
        std::fs::create_dir_all(&library_root)?;
        let database = Arc::new(Database::open(
            library_root.join("database").join("library.sqlite3"),
        )?);
        Ok(Self {
            library_root,
            database,
        })
    }

    pub fn library_root(&self) -> String {
        self.library_root.to_string_lossy().into_owned()
    }

    pub fn save_settings(&self, settings: &AppSettings) -> CoreResult<()> {
        validate_settings(settings)?;
        self.database.set_setting("app.settings", settings)
    }

    pub fn load_settings(&self) -> CoreResult<Option<AppSettings>> {
        let Some(mut settings) = self.database.get_setting::<AppSettings>("app.settings")? else {
            return Ok(None);
        };
        if !matches!(
            settings.sync_policy.active_interval_minutes,
            30 | 45 | 60 | 90 | 120
        ) {
            settings.sync_policy.active_interval_minutes = 30;
            self.database.set_setting("app.settings", &settings)?;
        }
        Ok(Some(settings))
    }

    pub fn save_sync_policy(&self, policy: &SyncPolicy) -> CoreResult<()> {
        policy.validate()?;
        self.database.set_setting("sync.policy", policy)
    }

    pub fn sync_schedule_status(&self, account_id: &str) -> CoreResult<SyncScheduleStatus> {
        let account_id = account_id.trim();
        if account_id.is_empty() {
            return Err(CoreError::InvalidConfig(
                "Nintendo account ID must not be empty".into(),
            ));
        }
        let runtime: SyncRuntimeState = self
            .database
            .get_setting(&sync_runtime_key(account_id))?
            .unwrap_or_default();
        let policy = self
            .load_settings()?
            .map(|settings| settings.sync_policy)
            .unwrap_or_default();
        Ok(policy.schedule_status(&runtime, Utc::now()))
    }

    pub fn record_sync_outcome(
        &self,
        account_id: &str,
        found_new_media: bool,
    ) -> CoreResult<SyncScheduleStatus> {
        let account_id = account_id.trim();
        if account_id.is_empty() {
            return Err(CoreError::InvalidConfig(
                "Nintendo account ID must not be empty".into(),
            ));
        }
        let key = sync_runtime_key(account_id);
        let mut runtime: SyncRuntimeState = self.database.get_setting(&key)?.unwrap_or_default();
        let now = Utc::now();
        runtime.last_successful_sync_at = Some(now);
        if found_new_media || runtime.last_new_media_at.is_none() {
            runtime.last_new_media_at = Some(now);
        }
        self.database.set_setting(&key, &runtime)?;
        let policy = self
            .load_settings()?
            .map(|settings| settings.sync_policy)
            .unwrap_or_default();
        Ok(policy.schedule_status(&runtime, now))
    }

    pub fn sync_account_history(&self, account_id: &str) -> CoreResult<SyncRuntimeState> {
        let account_id = account_id.trim();
        if account_id.is_empty() {
            return Err(CoreError::InvalidConfig(
                "Nintendo account ID must not be empty".into(),
            ));
        }
        Ok(self
            .database
            .get_setting(&sync_runtime_key(account_id))?
            .unwrap_or_default())
    }

    pub fn record_sync_attempt(
        &self,
        account_id: &str,
        status: &str,
        total_found: usize,
        downloaded: usize,
        duplicates: usize,
        failed: usize,
    ) -> CoreResult<SyncRuntimeState> {
        let account_id = account_id.trim();
        if account_id.is_empty() {
            return Err(CoreError::InvalidConfig(
                "Nintendo account ID must not be empty".into(),
            ));
        }
        if !matches!(
            status,
            "success" | "partial_failure" | "failure" | "cancelled"
        ) {
            return Err(CoreError::InvalidConfig(
                "sync attempt status is invalid".into(),
            ));
        }
        if downloaded.saturating_add(duplicates).saturating_add(failed) > total_found {
            return Err(CoreError::InvalidConfig(
                "sync attempt counts exceed the discovered media total".into(),
            ));
        }

        let key = sync_runtime_key(account_id);
        let mut runtime: SyncRuntimeState = self.database.get_setting(&key)?.unwrap_or_default();
        runtime.latest_attempt = Some(SyncAttemptSummary {
            attempted_at: Utc::now(),
            status: status.into(),
            total_found,
            downloaded,
            duplicates,
            failed,
        });
        self.database.set_setting(&key, &runtime)?;
        Ok(runtime)
    }

    pub fn create_nintendo_login_challenge(
        &self,
        proxy_url: Option<String>,
    ) -> CoreResult<LoginChallenge> {
        let transport = HttpTransport::new(TransportConfig {
            proxy_url,
            ..TransportConfig::default()
        })?;
        NintendoAuthClient::new(transport).create_login_challenge()
    }

    pub fn database(&self) -> Arc<Database> {
        Arc::clone(&self.database)
    }

    pub async fn exchange_nintendo_callback(
        &self,
        callback_url: String,
        expected_state: String,
        verifier: String,
        proxy_url: Option<String>,
    ) -> CoreResult<String> {
        let transport = self.transport(proxy_url)?;
        let auth = NintendoAuthClient::new(transport.clone());
        let code = auth.parse_callback(&callback_url, &expected_state)?;
        let attestation = NxapiAttestationClient::new(transport, NxapiConfig::default());
        let nso_version = crate::nso::AttestationService::nso_version(&attestation).await?;
        auth.exchange_session_token_code(&code, &verifier, &nso_version)
            .await
    }

    pub async fn establish_coral_session(
        &self,
        session_token: String,
        proxy_url: Option<String>,
    ) -> CoreResult<CoralSession> {
        let transport = self.transport(proxy_url)?;
        let attestation = NxapiAttestationClient::new(transport.clone(), NxapiConfig::default());
        CoralSessionClient::new(transport, attestation)
            .login_with_session_token(&session_token)
            .await
    }

    pub async fn sync_nso(
        &self,
        session: CoralSession,
        proxy_url: Option<String>,
    ) -> CoreResult<SyncSummary> {
        self.sync_nso_with_cancellation(session, proxy_url, &CancellationToken::default())
            .await
    }

    pub async fn sync_nso_with_cancellation(
        &self,
        session: CoralSession,
        proxy_url: Option<String>,
        cancellation: &CancellationToken,
    ) -> CoreResult<SyncSummary> {
        let transport = self.transport(proxy_url)?;
        let attestation = NxapiAttestationClient::new(transport.clone(), NxapiConfig::default());
        let provider = CoralAlbumProvider::new(transport.clone(), attestation, session);
        let provider_name = provider.provider_name().to_owned();
        let repository = MediaRepository::new(self.media_root()?, Arc::clone(&self.database));
        let engine = SyncEngine::new(provider, transport, repository);
        let cursor = self.database.latest_sync_cursor(&provider_name)?;
        engine.sync(cursor.as_deref(), cancellation).await
    }

    pub fn current_sync_progress(&self) -> CoreResult<Option<SyncProgress>> {
        self.database.current_sync_progress_any()
    }

    pub fn list_media(&self, query: GalleryQuery) -> CoreResult<Vec<MediaAsset>> {
        self.database.list_media(&query)
    }

    pub fn list_albums(&self) -> CoreResult<Vec<AlbumSummary>> {
        self.database.list_albums()
    }

    pub fn list_tags(&self) -> CoreResult<Vec<String>> {
        self.database.list_tags()
    }

    pub fn list_tag_usage(&self) -> CoreResult<Vec<TagUsageSummary>> {
        self.database.list_tag_usage()
    }

    pub fn create_tag(&self, name: String) -> CoreResult<i64> {
        self.database.create_tag(&name)
    }

    pub fn rename_tag(&self, tag_id: i64, new_name: String) -> CoreResult<()> {
        self.database.rename_tag(tag_id, &new_name)
    }

    pub fn delete_tag(&self, tag_id: i64) -> CoreResult<()> {
        self.database.delete_tag(tag_id)
    }

    pub fn list_game_tags(&self) -> CoreResult<Vec<GameTagSummary>> {
        self.database.list_game_tags()
    }

    pub fn list_game_tag_aliases(&self) -> CoreResult<Vec<GameTagAliasSummary>> {
        self.database.list_game_tag_aliases()
    }

    pub fn record_game_tag_selection(&self, game_name: String) -> CoreResult<()> {
        self.database.record_game_tag_selection(&game_name)
    }

    pub fn set_favorite(&self, media_id: i64, favorite: bool) -> CoreResult<()> {
        self.database.set_favorite(media_id, favorite)
    }

    pub fn set_note(&self, media_id: i64, note: String) -> CoreResult<()> {
        self.database.set_note(media_id, &note)
    }

    pub fn add_tag(&self, media_id: i64, tag: String) -> CoreResult<i64> {
        self.database.add_tag(media_id, &tag)
    }

    pub fn replace_tags(&self, media_id: i64, tags: Vec<String>) -> CoreResult<()> {
        self.database.replace_tags(media_id, &tags)
    }

    pub fn create_album(&self, name: String, description: String, smart: bool) -> CoreResult<i64> {
        self.database.create_album(&name, &description, smart)
    }

    pub fn update_album(
        &self,
        album_id: i64,
        name: String,
        description: String,
        smart: bool,
    ) -> CoreResult<()> {
        self.database
            .update_album(album_id, &name, &description, smart)
    }

    pub fn merge_tags(&self, tag_ids: Vec<i64>, target_name: String) -> CoreResult<()> {
        self.database.merge_tags(&tag_ids, &target_name)
    }

    pub fn merge_game_tags(&self, game_names: Vec<String>, target_name: String) -> CoreResult<()> {
        self.database.merge_game_tags(&game_names, &target_name)
    }

    pub fn rename_game_tag(&self, game_name: String, target_name: String) -> CoreResult<()> {
        self.database.rename_game_tag(&game_name, &target_name)
    }

    pub fn list_album_rules(&self, album_id: i64) -> CoreResult<Vec<AlbumRule>> {
        self.database.list_album_rules(album_id)
    }

    pub fn delete_album(&self, album_id: i64) -> CoreResult<()> {
        self.database.delete_album(album_id)
    }

    pub fn replace_album_rules(&self, album_id: i64, rules: Vec<AlbumRule>) -> CoreResult<()> {
        self.database.replace_album_rules(album_id, &rules)
    }

    pub fn add_media_to_album(&self, album_id: i64, media_id: i64) -> CoreResult<()> {
        self.database.add_media_to_album(album_id, media_id)
    }

    pub fn delete_media(&self, media_id: i64) -> CoreResult<MediaDeletionResult> {
        let entry = self.database.media_storage_entry(media_id)?;
        self.delete_media_file(&entry.storage_path, &entry.sha256)?;
        self.database.delete_media_record(media_id)?;
        Ok(MediaDeletionResult {
            removed_from_album: false,
            deleted_from_library: true,
            remaining_album_count: 0,
        })
    }

    pub fn remove_media_from_album_and_cleanup(
        &self,
        album_id: i64,
        media_id: i64,
    ) -> CoreResult<MediaDeletionResult> {
        self.database.remove_media_from_album(album_id, media_id)?;
        let remaining_album_count = self.database.media_album_membership_count(media_id)?;
        if remaining_album_count > 0 {
            return Ok(MediaDeletionResult {
                removed_from_album: true,
                deleted_from_library: false,
                remaining_album_count,
            });
        }
        let entry = self.database.media_storage_entry(media_id)?;
        self.delete_media_file(&entry.storage_path, &entry.sha256)?;
        self.database.delete_media_record(media_id)?;
        Ok(MediaDeletionResult {
            removed_from_album: true,
            deleted_from_library: true,
            remaining_album_count: 0,
        })
    }

    pub async fn relocate_media_library(
        &self,
        settings: AppSettings,
    ) -> CoreResult<LibraryRelocationResult> {
        validate_settings(&settings)?;
        let destination_root = PathBuf::from(settings.library_path.trim());
        if !destination_root.is_absolute() {
            return Err(CoreError::InvalidConfig(
                "media library path must be absolute".into(),
            ));
        }
        tokio::fs::create_dir_all(destination_root.join("originals")).await?;

        let entries = self.database.list_media_storage_entries()?;
        let current_root = self.media_root()?;
        let mut path_updates = Vec::with_capacity(entries.len());
        let mut created_files = Vec::new();
        let mut old_files = Vec::new();
        for entry in &entries {
            let source = managed_media_file_path(
                Path::new(&entry.storage_path),
                &entry.sha256,
                &current_root,
            )?
            .ok_or_else(|| {
                CoreError::InvalidConfig(format!(
                    "media file does not exist: {}",
                    entry.storage_path
                ))
            })?;
            let extension = source
                .extension()
                .and_then(|value| value.to_str())
                .filter(|value| {
                    matches!(
                        value.to_ascii_lowercase().as_str(),
                        "jpg" | "jpeg" | "png" | "webp" | "mp4" | "mov"
                    )
                })
                .unwrap_or_else(|| entry.kind.extension());
            let destination = content_path(&destination_root, &entry.sha256, extension)?;
            if !same_path(&source, &destination) {
                if destination.exists() {
                    verify_file_hash(&destination, &entry.sha256).await?;
                } else {
                    copy_verified(&source, &destination, &entry.sha256).await?;
                    created_files.push(destination.clone());
                }
                old_files.push(source);
            }
            path_updates.push((entry.id, destination.to_string_lossy().into_owned()));
        }

        let moved_files = old_files.len();
        if let Err(error) = self
            .database
            .relocate_media_paths_and_settings(&path_updates, &settings)
        {
            for path in created_files {
                let _ = tokio::fs::remove_file(path).await;
            }
            return Err(error);
        }
        for path in old_files {
            let _ = tokio::fs::remove_file(path).await;
        }
        Ok(LibraryRelocationResult {
            moved_files,
            library_path: destination_root.to_string_lossy().into_owned(),
        })
    }

    pub async fn import_local_files(&self, paths: Vec<String>) -> CoreResult<ImportSummary> {
        self.import_local_paths(paths, SourceType::Folder, None, None)
            .await
    }

    pub async fn import_custom_files(
        &self,
        paths: Vec<String>,
        game_name: String,
    ) -> CoreResult<ImportSummary> {
        let game_name = game_name.trim();
        if game_name.is_empty() {
            return Err(CoreError::InvalidConfig(
                "a game tag is required for custom import".into(),
            ));
        }
        self.import_local_paths(
            paths,
            SourceType::Folder,
            Some("custom-import"),
            Some(sanitize_game_folder(game_name)),
        )
        .await
    }

    pub async fn import_mtp_files(
        &self,
        paths: Vec<String>,
        device_name: String,
    ) -> CoreResult<ImportSummary> {
        let device_name = device_name.trim();
        if !matches!(device_name, "Nintendo Switch" | "Nintendo Switch 2") {
            return Err(CoreError::InvalidConfig(
                "unsupported Nintendo media device".into(),
            ));
        }
        self.import_local_paths(paths, SourceType::Mtp, Some(device_name), None)
            .await
    }

    pub async fn export_media(
        &self,
        media_ids: Vec<i64>,
        destination: String,
        name_format: String,
    ) -> CoreResult<MediaExportSummary> {
        let destination = PathBuf::from(destination.trim());
        if !destination.is_absolute() {
            return Err(CoreError::InvalidConfig(
                "export destination must be an absolute path".into(),
            ));
        }
        let name_format = name_format.trim();
        if name_format.is_empty() {
            return Err(CoreError::InvalidConfig(
                "export name format cannot be empty".into(),
            ));
        }
        tokio::fs::create_dir_all(&destination).await?;
        let entries = self.database.media_export_entries(&media_ids)?;
        let language = self
            .load_settings()?
            .map(|settings| settings.language)
            .unwrap_or_else(|| "zh".into());
        let mut summary = MediaExportSummary {
            total: media_ids.len(),
            exported: 0,
            failed: media_ids.len().saturating_sub(entries.len()),
            errors: Vec::new(),
        };
        for entry in entries {
            match export_media_entry(&entry, &destination, name_format, &language).await {
                Ok(()) => summary.exported += 1,
                Err(error) => {
                    summary.failed += 1;
                    summary.errors.push(MediaExportItemError {
                        media_id: entry.id,
                        name: entry.original_name,
                        message: error.to_string(),
                    });
                }
            }
        }
        Ok(summary)
    }

    pub async fn commit_video_edit(
        &self,
        media_id: i64,
        processed_path: String,
        overwrite: bool,
    ) -> CoreResult<MediaAsset> {
        let source = self.database.media_asset(media_id)?;
        if source.kind != MediaKind::Video {
            return Err(CoreError::InvalidConfig(
                "only videos can be opened in the video editor".into(),
            ));
        }
        let processed_path = PathBuf::from(processed_path);
        if !processed_path.is_file() {
            return Err(CoreError::InvalidConfig(
                "processed video file does not exist".into(),
            ));
        }
        let repository = MediaRepository::new(self.media_root()?, Arc::clone(&self.database));
        let generated_tag = self.generated_media_tag("剪辑", "Edited")?;
        if overwrite {
            let staged = repository.stage_file(&processed_path, "mp4").await?;
            if let Err(error) = self.database.replace_media_content(
                media_id,
                &source.sha256,
                &staged.sha256,
                staged.size,
                &staged.path,
                &generated_tag,
            ) {
                if staged.created {
                    let _ = tokio::fs::remove_file(&staged.path).await;
                }
                return Err(error);
            }
            if !same_path(Path::new(&source.storage_path), &staged.path) {
                let _ = self.delete_media_file(&source.storage_path, &source.sha256);
            }
            return self.database.media_asset(media_id);
        }

        let candidate = edited_media_candidate(
            &source,
            MediaKind::Video,
            SourceType::VideoEdit,
            format!("edited-from:{media_id}"),
            None,
        );
        let (new_id, created) = repository
            .import_file(&candidate, &processed_path, Some("video-editor"))
            .await?;
        self.copy_metadata_to_created_media(&[media_id], new_id, created, &generated_tag)?;
        self.database.media_asset(new_id)
    }

    pub async fn save_video_frame(
        &self,
        media_id: i64,
        bytes: Vec<u8>,
        extension: String,
    ) -> CoreResult<MediaAsset> {
        const MAX_FRAME_BYTES: usize = 32 * 1024 * 1024;
        let source = self.database.media_asset(media_id)?;
        if source.kind != MediaKind::Video {
            return Err(CoreError::InvalidConfig(
                "only videos can provide a captured frame".into(),
            ));
        }
        if bytes.is_empty() || bytes.len() > MAX_FRAME_BYTES {
            return Err(CoreError::InvalidConfig(
                "captured video frame has an invalid size".into(),
            ));
        }
        let extension = extension
            .trim()
            .trim_start_matches('.')
            .to_ascii_lowercase();
        let valid_signature = match extension.as_str() {
            "png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
            "jpg" | "jpeg" => bytes.starts_with(&[0xff, 0xd8, 0xff]),
            _ => false,
        };
        if !valid_signature {
            return Err(CoreError::InvalidConfig(
                "captured video frame is not a supported image".into(),
            ));
        }
        let repository = MediaRepository::new(self.media_root()?, Arc::clone(&self.database));
        let mut candidate = edited_media_candidate(
            &source,
            MediaKind::Image,
            SourceType::VideoFrame,
            format!("frame-from:{media_id}"),
            None,
        );
        candidate.file_extension = Some(extension);
        if let (Some(name), Some(extension)) = (
            candidate.original_name.as_deref(),
            candidate.file_extension.as_deref(),
        ) {
            candidate.original_name = Some(
                Path::new(name)
                    .with_extension(extension)
                    .to_string_lossy()
                    .into_owned(),
            );
        }
        let (new_id, created) = repository
            .import_bytes(&candidate, &bytes, Some("video-editor"))
            .await?;
        let generated_tag = self.generated_media_tag("帧图", "Frame")?;
        self.copy_metadata_to_created_media(&[media_id], new_id, created, &generated_tag)?;
        self.database.media_asset(new_id)
    }

    pub async fn commit_merged_video(
        &self,
        media_ids: Vec<i64>,
        processed_path: String,
    ) -> CoreResult<MediaAsset> {
        if media_ids.len() < 2 {
            return Err(CoreError::InvalidConfig(
                "at least two videos are required for merging".into(),
            ));
        }
        let mut sources = Vec::with_capacity(media_ids.len());
        for media_id in &media_ids {
            let source = self.database.media_asset(*media_id)?;
            if source.kind != MediaKind::Video {
                return Err(CoreError::InvalidConfig(
                    "video merge input contains a non-video item".into(),
                ));
            }
            sources.push(source);
        }
        let processed_path = PathBuf::from(processed_path);
        if !processed_path.is_file() {
            return Err(CoreError::InvalidConfig(
                "merged video file does not exist".into(),
            ));
        }
        let first = &sources[0];
        let same_game = sources
            .iter()
            .all(|source| source.game_name == first.game_name);
        let language = self
            .load_settings()?
            .map(|settings| settings.language)
            .unwrap_or_else(|| "zh".into());
        let game_name = if same_game {
            first.game_name.clone()
        } else if language == "en" {
            "Multiple games".into()
        } else {
            "多个游戏".into()
        };
        let game_title_id = if same_game
            && sources
                .iter()
                .all(|source| source.game_title_id == first.game_title_id)
        {
            first.game_title_id.clone()
        } else {
            None
        };
        let mut candidate = edited_media_candidate(
            first,
            MediaKind::Video,
            SourceType::VideoMerge,
            format!(
                "merged-from:{}",
                media_ids
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(",")
            ),
            Some(game_name),
        );
        candidate.title_id = game_title_id;
        let repository = MediaRepository::new(self.media_root()?, Arc::clone(&self.database));
        let (new_id, created) = repository
            .import_file(&candidate, &processed_path, Some("video-merge"))
            .await?;
        let generated_tag = if language == "en" { "Merged" } else { "合并" };
        self.copy_metadata_to_created_media(&media_ids, new_id, created, generated_tag)?;
        self.database.media_asset(new_id)
    }

    async fn import_local_paths(
        &self,
        paths: Vec<String>,
        source_type: SourceType,
        provider: Option<&str>,
        game_name_override: Option<String>,
    ) -> CoreResult<ImportSummary> {
        let repository = MediaRepository::new(self.media_root()?, Arc::clone(&self.database));
        let mut files = BTreeSet::new();
        for value in paths {
            let path = PathBuf::from(value);
            if path.is_dir() {
                for file in walkdir::WalkDir::new(path)
                    .follow_links(false)
                    .into_iter()
                    .filter_map(Result::ok)
                    .filter(|entry| entry.file_type().is_file())
                    .map(|entry| entry.into_path())
                    .filter(|path| media_kind_from_path(path).is_some())
                {
                    files.insert(file);
                }
            } else if path.is_file() && media_kind_from_path(&path).is_some() {
                files.insert(path);
            }
        }

        let mut summary = ImportSummary {
            total_found: files.len(),
            imported: 0,
            duplicates: 0,
            failed: 0,
            errors: Vec::new(),
        };
        for (index, path) in files.into_iter().enumerate() {
            let kind = media_kind_from_path(&path).expect("filtered media path");
            let captured_at = nintendo_capture_time(&path).or_else(|| file_creation_time(&path));
            let game_name = game_name_override.clone().unwrap_or_else(|| {
                path.parent()
                    .and_then(Path::file_name)
                    .and_then(|name| name.to_str())
                    .filter(|name| !name.eq_ignore_ascii_case("album"))
                    .unwrap_or("未识别游戏")
                    .to_owned()
            });
            let readable_name =
                game_name_override.is_some() || matches!(&source_type, SourceType::Mtp);
            let original_name = if readable_name {
                Some(readable_import_media_name(
                    &game_name,
                    captured_at.unwrap_or_else(Utc::now),
                    nintendo_capture_sequence(&path).unwrap_or((index + 1) as u32),
                    kind,
                ))
            } else {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .map(ToOwned::to_owned)
            };
            let candidate = MediaCandidate {
                remote_id: None,
                title_id: None,
                game_name: game_name.clone(),
                kind,
                content_url: None,
                thumbnail_url: None,
                expected_size: None,
                captured_at,
                uploaded_at: None,
                expires_at: None,
                original_name,
                file_extension: path
                    .extension()
                    .and_then(|extension| extension.to_str())
                    .map(|extension| extension.to_ascii_lowercase()),
                source_type: source_type.clone(),
                source_path: Some(if matches!(&source_type, SourceType::Mtp) {
                    format!(
                        "{}/Album/{game_name}/{}",
                        provider.unwrap_or("Nintendo Switch"),
                        path.file_name()
                            .and_then(|name| name.to_str())
                            .unwrap_or("media")
                    )
                } else {
                    path.to_string_lossy().into_owned()
                }),
            };
            match repository.import_file(&candidate, &path, provider).await {
                Ok((_, true)) => summary.imported += 1,
                Ok((_, false)) => summary.duplicates += 1,
                Err(error) => {
                    summary.failed += 1;
                    summary.errors.push(ImportItemError {
                        path: path.to_string_lossy().into_owned(),
                        message: error.to_string(),
                    });
                }
            }
        }
        Ok(summary)
    }

    fn transport(&self, explicit_proxy: Option<String>) -> CoreResult<HttpTransport> {
        let settings_proxy = self
            .load_settings()?
            .and_then(|settings| settings.proxy_url);
        HttpTransport::new(TransportConfig {
            proxy_url: explicit_proxy.or(settings_proxy),
            ..TransportConfig::default()
        })
    }

    fn media_root(&self) -> CoreResult<PathBuf> {
        Ok(self
            .load_settings()?
            .map(|settings| PathBuf::from(settings.library_path))
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or_else(|| self.library_root.clone()))
    }

    fn copy_metadata_to_created_media(
        &self,
        source_ids: &[i64],
        target_id: i64,
        created: bool,
        generated_tag: &str,
    ) -> CoreResult<()> {
        if !created {
            self.database.add_tag(target_id, generated_tag)?;
            return Ok(());
        }
        if let Err(error) = self
            .database
            .copy_media_metadata(source_ids, target_id, generated_tag)
        {
            if let Ok(entry) = self.database.media_storage_entry(target_id) {
                let _ = self.delete_media_file(&entry.storage_path, &entry.sha256);
            }
            let _ = self.database.delete_media_record(target_id);
            return Err(error);
        }
        Ok(())
    }

    fn generated_media_tag(&self, chinese: &str, english: &str) -> CoreResult<String> {
        let language = self
            .load_settings()?
            .map(|settings| settings.language)
            .unwrap_or_else(|| "zh".into());
        Ok(if language == "en" { english } else { chinese }.to_owned())
    }

    fn delete_media_file(&self, value: &str, sha256: &str) -> CoreResult<()> {
        let path = PathBuf::from(value);
        let media_root = self.media_root()?;
        let Some(canonical) = managed_media_file_path(&path, sha256, &media_root)? else {
            return Ok(());
        };
        std::fs::remove_file(canonical)?;
        Ok(())
    }
}

fn validate_settings(settings: &AppSettings) -> CoreResult<()> {
    settings.sync_policy.validate()?;
    if !matches!(settings.language.as_str(), "zh" | "en") {
        return Err(CoreError::InvalidConfig("language must be zh or en".into()));
    }
    if !matches!(
        settings.close_behavior.as_str(),
        "ask" | "exit" | "minimize_to_tray"
    ) {
        return Err(CoreError::InvalidConfig(
            "close behavior must be ask, exit, or minimize_to_tray".into(),
        ));
    }
    if settings.library_path.trim().is_empty() {
        return Err(CoreError::InvalidConfig(
            "media library path cannot be empty".into(),
        ));
    }
    Ok(())
}

fn edited_media_candidate(
    source: &MediaAsset,
    kind: MediaKind,
    source_type: SourceType,
    source_path: String,
    game_name: Option<String>,
) -> MediaCandidate {
    let game_name = game_name.unwrap_or_else(|| source.game_name.clone());
    let captured_at = source.captured_at.or(Some(source.imported_at));
    let unique_id = uuid::Uuid::new_v4().simple().to_string();
    MediaCandidate {
        remote_id: None,
        title_id: source.game_title_id.clone(),
        game_name: game_name.clone(),
        kind,
        content_url: None,
        thumbnail_url: None,
        expected_size: None,
        captured_at,
        uploaded_at: None,
        expires_at: None,
        original_name: Some(readable_media_name(
            &game_name,
            captured_at.unwrap_or_else(Utc::now),
            Some(&unique_id),
            kind,
        )),
        file_extension: Some(kind.extension().into()),
        source_type,
        source_path: Some(source_path),
    }
}

fn file_creation_time(path: &Path) -> Option<chrono::DateTime<Utc>> {
    let metadata = std::fs::metadata(path).ok()?;
    metadata
        .created()
        .or_else(|_| metadata.modified())
        .ok()
        .map(chrono::DateTime::<Utc>::from)
}

fn sync_runtime_key(account_id: &str) -> String {
    format!("sync.runtime.{account_id}")
}

fn content_path(root: &Path, sha256: &str, extension: &str) -> CoreResult<PathBuf> {
    if sha256.len() != 64 || !sha256.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Err(CoreError::InvalidConfig(
            "stored media hash is invalid".into(),
        ));
    }
    Ok(root
        .join("originals")
        .join(&sha256[0..2])
        .join(&sha256[2..4])
        .join(format!("{sha256}.{extension}")))
}

fn same_path(left: &Path, right: &Path) -> bool {
    if cfg!(windows) {
        left.to_string_lossy()
            .eq_ignore_ascii_case(&right.to_string_lossy())
    } else {
        left == right
    }
}

fn managed_media_file_path(
    path: &Path,
    sha256: &str,
    media_root: &Path,
) -> CoreResult<Option<PathBuf>> {
    if !path.exists() {
        return Ok(None);
    }
    let originals = std::fs::canonicalize(media_root.join("originals"))?;
    let canonical = std::fs::canonicalize(path)?;
    let valid_name = path
        .file_stem()
        .and_then(|value| value.to_str())
        .is_some_and(|stem| stem.eq_ignore_ascii_case(sha256));
    if !canonical.starts_with(&originals) || !valid_name {
        return Err(CoreError::InvalidConfig(
            "refusing to modify a file outside the managed originals directory".into(),
        ));
    }
    Ok(Some(canonical))
}

async fn verify_file_hash(path: &Path, expected: &str) -> CoreResult<()> {
    let mut input = tokio::fs::File::open(path).await?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let read = input.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    let actual = hex::encode(hasher.finalize());
    if actual != expected {
        return Err(CoreError::InvalidConfig(format!(
            "destination already contains different data: {}",
            path.display()
        )));
    }
    Ok(())
}

async fn copy_verified(source: &Path, destination: &Path, expected: &str) -> CoreResult<()> {
    if !source.is_file() {
        return Err(CoreError::InvalidConfig(format!(
            "media file does not exist: {}",
            source.display()
        )));
    }
    let parent = destination
        .parent()
        .ok_or_else(|| CoreError::InvalidConfig("destination has no parent".into()))?;
    tokio::fs::create_dir_all(parent).await?;
    let temporary = destination.with_extension(format!(
        "{}.part",
        destination
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("media")
    ));
    let result = async {
        let mut input = tokio::fs::File::open(source).await?;
        let mut output = tokio::fs::File::create(&temporary).await?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0_u8; 1024 * 1024];
        loop {
            let read = input.read(&mut buffer).await?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
            output.write_all(&buffer[..read]).await?;
        }
        output.flush().await?;
        drop(output);
        let actual = hex::encode(hasher.finalize());
        if actual != expected {
            return Err(CoreError::InvalidConfig(format!(
                "media hash changed while moving: {}",
                source.display()
            )));
        }
        tokio::fs::rename(&temporary, destination).await?;
        Ok(())
    }
    .await;
    if result.is_err() {
        let _ = tokio::fs::remove_file(&temporary).await;
    }
    result
}

fn media_kind_from_path(path: &Path) -> Option<MediaKind> {
    match path
        .extension()
        .and_then(|extension| extension.to_str())?
        .to_ascii_lowercase()
        .as_str()
    {
        "jpg" | "jpeg" | "png" | "webp" => Some(MediaKind::Image),
        "mp4" | "mov" => Some(MediaKind::Video),
        _ => None,
    }
}

fn nintendo_capture_time(path: &Path) -> Option<chrono::DateTime<Utc>> {
    let stem = path.file_stem()?.to_str()?;
    let timestamp = stem.get(..14)?;
    if !timestamp.bytes().all(|value| value.is_ascii_digit()) {
        return None;
    }
    let local = NaiveDateTime::parse_from_str(timestamp, "%Y%m%d%H%M%S").ok()?;
    Local
        .from_local_datetime(&local)
        .single()
        .or_else(|| Local.from_local_datetime(&local).earliest())
        .map(|value| value.with_timezone(&Utc))
}

fn nintendo_capture_sequence(path: &Path) -> Option<u32> {
    let stem = path.file_stem()?.to_str()?;
    let prefix = stem.get(..16)?;
    if !prefix.chars().all(|character| character.is_ascii_digit()) {
        return None;
    }
    prefix.get(14..16)?.parse().ok()
}

async fn export_media_entry(
    entry: &crate::database::MediaExportEntry,
    destination: &Path,
    name_format: &str,
    language: &str,
) -> CoreResult<()> {
    let source = Path::new(&entry.storage_path);
    if !source.is_file() {
        return Err(CoreError::InvalidConfig(format!(
            "media file does not exist: {}",
            entry.storage_path
        )));
    }
    let original_stem = Path::new(&entry.original_name)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or(&entry.original_name);
    let tags = if entry.tags.is_empty() {
        if language == "en" {
            "No tags"
        } else {
            "无标签"
        }
        .to_owned()
    } else {
        entry.tags.join("-")
    };
    let note = if entry.note.trim().is_empty() {
        if language == "en" {
            "No note"
        } else {
            "无备注"
        }
        .to_owned()
    } else {
        entry.note.trim().to_owned()
    };
    let game_name = if entry.game_name.trim().is_empty() {
        if language == "en" {
            "Unknown game"
        } else {
            "未知游戏"
        }
    } else {
        entry.game_name.trim()
    };
    let date = entry
        .timestamp
        .with_timezone(&Local)
        .format("%Y%m%d")
        .to_string();
    let rendered = name_format
        .replace("{相册内名称}", original_stem)
        .replace("{游戏名}", game_name)
        .replace("{年月日}", &date)
        .replace("{标签}", &tags)
        .replace("{备注}", &note);
    let base_name = safe_export_file_stem(&rendered, entry.id);
    let extension = source
        .extension()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("bin");
    let target = unique_export_path(destination, &base_name, extension);
    let part = destination.join(format!(".{base_name}.{}.part", entry.id));
    if part.exists() {
        tokio::fs::remove_file(&part).await?;
    }
    if let Err(error) = tokio::fs::copy(source, &part).await {
        let _ = tokio::fs::remove_file(&part).await;
        return Err(error.into());
    }
    if let Err(error) = tokio::fs::rename(&part, &target).await {
        let _ = tokio::fs::remove_file(&part).await;
        return Err(error.into());
    }
    Ok(())
}

fn safe_export_file_stem(value: &str, media_id: i64) -> String {
    let mut result = String::with_capacity(value.len().min(180));
    let mut previous_space = false;
    for character in value.chars().take(160) {
        if matches!(
            character,
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' | '\0'..='\u{1f}'
        ) {
            continue;
        }
        if character.is_whitespace() {
            if !previous_space && !result.is_empty() {
                result.push(' ');
                previous_space = true;
            }
        } else {
            result.push(character);
            previous_space = false;
        }
    }
    let result = result.trim().trim_end_matches('.');
    let fallback = format!("media-{media_id}");
    let result = if result.is_empty() { &fallback } else { result };
    let reserved = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ];
    if reserved
        .iter()
        .any(|name| result.eq_ignore_ascii_case(name))
    {
        format!("_{result}")
    } else {
        result.to_owned()
    }
}

fn unique_export_path(destination: &Path, base_name: &str, extension: &str) -> PathBuf {
    let first = destination.join(format!("{base_name}.{extension}"));
    if !first.exists() {
        return first;
    }
    for sequence in 2..=10_000 {
        let candidate = destination.join(format!("{base_name} ({sequence}).{extension}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    destination.join(format!(
        "{base_name} ({}).{extension}",
        Utc::now().timestamp_millis()
    ))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use chrono::Local;
    use tempfile::tempdir;

    use super::{nintendo_capture_sequence, nintendo_capture_time, CoreApi};
    use crate::models::{GalleryQuery, MediaDeletionResult, MediaKind};
    use crate::settings::{AppSettings, SyncPolicy};

    #[test]
    fn upgrades_legacy_sync_interval_without_changing_sleep_threshold() {
        let library = tempdir().unwrap();
        let api = CoreApi::open(library.path()).unwrap();
        let mut settings = AppSettings {
            proxy_url: None,
            library_path: library.path().to_string_lossy().into_owned(),
            theme: "ocean".into(),
            language: "zh".into(),
            gallery_columns: 4,
            gallery_rows: 3,
            show_note_preview: true,
            show_game_tag: true,
            compact_tag_display: true,
            auto_play_video: false,
            auto_sync_on_launch: false,
            close_behavior: "ask".into(),
            custom_font_paths: Vec::new(),
            sync_policy: SyncPolicy {
                enabled: true,
                active_interval_minutes: 10,
                sleep_after_hours: 6,
            },
        };
        api.database.set_setting("app.settings", &settings).unwrap();

        settings = api.load_settings().unwrap().unwrap();

        assert_eq!(settings.sync_policy.active_interval_minutes, 30);
        assert_eq!(settings.sync_policy.sleep_after_hours, 6);
    }

    #[tokio::test]
    async fn imports_supported_files_and_reports_duplicates() {
        let library = tempdir().unwrap();
        let source = tempdir().unwrap();
        fs::write(source.path().join("capture.jpg"), b"same media bytes").unwrap();
        fs::write(source.path().join("ignored.txt"), b"not media").unwrap();

        let api = CoreApi::open(library.path()).unwrap();
        let paths = vec![source.path().to_string_lossy().into_owned()];

        let first = api.import_local_files(paths.clone()).await.unwrap();
        assert_eq!(first.total_found, 1);
        assert_eq!(first.imported, 1);
        assert_eq!(first.duplicates, 0);
        assert_eq!(first.failed, 0);

        let second = api.import_local_files(paths).await.unwrap();
        assert_eq!(second.total_found, 1);
        assert_eq!(second.imported, 0);
        assert_eq!(second.duplicates, 1);
        assert_eq!(second.failed, 0);
    }

    #[tokio::test]
    async fn imports_mtp_media_with_readable_display_name() {
        let library = tempdir().unwrap();
        let staging = tempdir().unwrap();
        let game = staging.path().join("Album").join("ゼルダの伝説");
        fs::create_dir_all(&game).unwrap();
        let source = game.join("2026100516091007.jpg");
        fs::write(&source, b"mtp readable display name").unwrap();
        let api = CoreApi::open(library.path()).unwrap();

        api.import_mtp_files(
            vec![source.to_string_lossy().into_owned()],
            "Nintendo Switch 2".into(),
        )
        .await
        .unwrap();

        let media = api.list_media(GalleryQuery::default()).unwrap();
        assert_eq!(media.len(), 1);
        assert!(media[0]
            .original_name
            .starts_with("ゼルダの伝説 - 2026-10-05 "));
        assert!(media[0].original_name.ends_with("[07].jpg"));
    }

    #[tokio::test]
    async fn custom_import_recurses_assigns_game_and_uses_content_addressing() {
        let library = tempdir().unwrap();
        let source = tempdir().unwrap();
        let nested = source.path().join("nested");
        fs::create_dir_all(&nested).unwrap();
        let image = nested.join("photo.jpg");
        let duplicate = nested.join("photo-copy.jpg");
        let video = nested.join("clip.mp4");
        fs::write(&image, b"custom image bytes").unwrap();
        fs::write(&duplicate, b"custom image bytes").unwrap();
        fs::write(&video, b"custom video bytes").unwrap();
        fs::write(nested.join("ignored.txt"), b"not media").unwrap();

        let api = CoreApi::open(library.path()).unwrap();
        let summary = api
            .import_custom_files(
                vec![
                    source.path().to_string_lossy().into_owned(),
                    image.to_string_lossy().into_owned(),
                ],
                "自定义/游戏".into(),
            )
            .await
            .unwrap();

        assert_eq!(summary.total_found, 3);
        assert_eq!(summary.imported, 2);
        assert_eq!(summary.duplicates, 1);
        assert_eq!(summary.failed, 0);
        let media = api.list_media(GalleryQuery::default()).unwrap();
        assert_eq!(media.len(), 2);
        assert!(media.iter().all(|item| item.game_name == "自定义游戏"));
        assert!(media
            .iter()
            .all(|item| item.original_name.starts_with("自定义游戏 - ")));
        assert!(media.iter().all(|item| {
            let path = Path::new(&item.storage_path);
            path.starts_with(library.path().join("originals"))
                && path
                    .file_stem()
                    .is_some_and(|name| name.to_string_lossy() == item.sha256)
        }));
        assert!(image.exists());
        assert!(video.exists());
    }

    #[tokio::test]
    async fn custom_import_requires_a_game_tag() {
        let library = tempdir().unwrap();
        let api = CoreApi::open(library.path()).unwrap();
        let error = api
            .import_custom_files(Vec::new(), "   ".into())
            .await
            .unwrap_err();
        assert!(error.to_string().contains("game tag"));
    }

    #[tokio::test]
    async fn video_editor_overwrites_or_creates_media_without_bypassing_repository() {
        let library = tempdir().unwrap();
        let staging = tempdir().unwrap();
        let game = staging.path().join("Splatoon 3");
        fs::create_dir_all(&game).unwrap();
        let first_source = game.join("2026100412000001.mp4");
        let second_source = game.join("2026100412050002.mp4");
        fs::write(&first_source, b"first source video").unwrap();
        fs::write(&second_source, b"second source video").unwrap();
        let api = CoreApi::open(library.path()).unwrap();
        api.import_local_files(vec![
            first_source.to_string_lossy().into_owned(),
            second_source.to_string_lossy().into_owned(),
        ])
        .await
        .unwrap();
        let original = api
            .list_media(GalleryQuery::default())
            .unwrap()
            .into_iter()
            .find(|media| fs::read(&media.storage_path).unwrap() == b"first source video")
            .unwrap();
        api.set_favorite(original.id, true).unwrap();
        api.set_note(original.id, "edited note".into()).unwrap();
        api.add_tag(original.id, "Edited".into()).unwrap();

        let trimmed = staging.path().join("trimmed.mp4");
        fs::write(&trimmed, b"trimmed copy bytes").unwrap();
        let saved_copy = api
            .commit_video_edit(original.id, trimmed.to_string_lossy().into_owned(), false)
            .await
            .unwrap();
        assert_ne!(saved_copy.id, original.id);
        assert_ne!(saved_copy.original_name, original.original_name);
        assert!(saved_copy.favorite);
        assert_eq!(saved_copy.note.as_deref(), Some("edited note"));
        assert_eq!(saved_copy.tags, vec!["Edited", "剪辑"]);
        assert_eq!(
            fs::read(&saved_copy.storage_path).unwrap(),
            b"trimmed copy bytes"
        );

        let original_path = original.storage_path.clone();
        let replacement = staging.path().join("replacement.mp4");
        fs::write(&replacement, b"replacement video bytes").unwrap();
        let overwritten = api
            .commit_video_edit(
                original.id,
                replacement.to_string_lossy().into_owned(),
                true,
            )
            .await
            .unwrap();
        assert_eq!(overwritten.id, original.id);
        assert_ne!(overwritten.sha256, original.sha256);
        assert_eq!(overwritten.original_name, original.original_name);
        assert_eq!(
            overwritten
                .tags
                .iter()
                .filter(|tag| tag.as_str() == "剪辑")
                .count(),
            1
        );
        assert!(!Path::new(&original_path).exists());
        assert_eq!(
            fs::read(&overwritten.storage_path).unwrap(),
            b"replacement video bytes"
        );

        let frame = api
            .save_video_frame(
                overwritten.id,
                b"\x89PNG\r\n\x1a\nframe bytes".to_vec(),
                "png".into(),
            )
            .await
            .unwrap();
        assert_eq!(frame.kind, crate::models::MediaKind::Image);
        assert!(frame.favorite);
        assert!(frame.tags.contains(&"Edited".to_owned()));
        assert!(frame.tags.contains(&"剪辑".to_owned()));
        assert!(frame.tags.contains(&"帧图".to_owned()));

        let videos = api
            .list_media(GalleryQuery::default())
            .unwrap()
            .into_iter()
            .filter(|media| media.kind == crate::models::MediaKind::Video)
            .collect::<Vec<_>>();
        let merged_file = staging.path().join("merged.mp4");
        fs::write(&merged_file, b"merged video bytes").unwrap();
        let merged = api
            .commit_merged_video(
                videos.iter().map(|media| media.id).collect(),
                merged_file.to_string_lossy().into_owned(),
            )
            .await
            .unwrap();
        assert_eq!(merged.kind, crate::models::MediaKind::Video);
        assert!(merged.tags.contains(&"Edited".to_owned()));
        assert!(merged.tags.contains(&"剪辑".to_owned()));
        assert!(merged.tags.contains(&"合并".to_owned()));
        assert_eq!(
            fs::read(&merged.storage_path).unwrap(),
            b"merged video bytes"
        );
    }

    #[tokio::test]
    async fn video_outputs_use_english_generated_tags_without_duplicates() {
        let library = tempdir().unwrap();
        let staging = tempdir().unwrap();
        let game = staging.path().join("Splatoon 3");
        fs::create_dir_all(&game).unwrap();
        let first = game.join("2026100512000001.mp4");
        let second = game.join("2026100512050002.mp4");
        fs::write(&first, b"english first source").unwrap();
        fs::write(&second, b"english second source").unwrap();
        let api = CoreApi::open(library.path()).unwrap();
        api.save_settings(&AppSettings {
            proxy_url: None,
            library_path: library.path().to_string_lossy().into_owned(),
            theme: "ocean".into(),
            language: "en".into(),
            gallery_columns: 4,
            gallery_rows: 3,
            show_note_preview: true,
            show_game_tag: true,
            compact_tag_display: true,
            auto_play_video: false,
            auto_sync_on_launch: false,
            close_behavior: "ask".into(),
            custom_font_paths: Vec::new(),
            sync_policy: SyncPolicy::default(),
        })
        .unwrap();
        api.import_local_files(vec![
            first.to_string_lossy().into_owned(),
            second.to_string_lossy().into_owned(),
        ])
        .await
        .unwrap();
        let source = api.list_media(GalleryQuery::default()).unwrap()[0].clone();
        api.add_tag(source.id, "Edited".into()).unwrap();

        let edited_path = staging.path().join("english-edited.mp4");
        fs::write(&edited_path, b"english edited result").unwrap();
        let edited = api
            .commit_video_edit(source.id, edited_path.to_string_lossy().into_owned(), false)
            .await
            .unwrap();
        assert_eq!(
            edited
                .tags
                .iter()
                .filter(|tag| tag.as_str() == "Edited")
                .count(),
            1
        );

        let frame = api
            .save_video_frame(
                edited.id,
                b"\x89PNG\r\n\x1a\nenglish frame".to_vec(),
                "png".into(),
            )
            .await
            .unwrap();
        assert!(frame.tags.contains(&"Edited".to_owned()));
        assert!(frame.tags.contains(&"Frame".to_owned()));

        let videos = api
            .list_media(GalleryQuery::default())
            .unwrap()
            .into_iter()
            .filter(|media| media.kind == MediaKind::Video)
            .map(|media| media.id)
            .collect::<Vec<_>>();
        let merged_path = staging.path().join("english-merged.mp4");
        fs::write(&merged_path, b"english merged result").unwrap();
        let merged = api
            .commit_merged_video(videos, merged_path.to_string_lossy().into_owned())
            .await
            .unwrap();
        assert!(merged.tags.contains(&"Edited".to_owned()));
        assert!(merged.tags.contains(&"Merged".to_owned()));
    }

    #[tokio::test]
    async fn exports_media_with_templates_sanitized_names_and_no_overwrite() {
        let library = tempdir().unwrap();
        let staging = tempdir().unwrap();
        let destination = tempdir().unwrap();
        let game = staging.path().join("Album").join("Splatoon 3");
        fs::create_dir_all(&game).unwrap();
        let source = game.join("2026100516091007.jpg");
        fs::write(&source, b"exported media bytes").unwrap();
        let api = CoreApi::open(library.path()).unwrap();
        api.import_mtp_files(
            vec![source.to_string_lossy().into_owned()],
            "Nintendo Switch 2".into(),
        )
        .await
        .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap()[0].clone();
        api.add_tag(media.id, "Festival".into()).unwrap();
        api.add_tag(media.id, "Anarchy".into()).unwrap();
        api.set_note(media.id, "Win:100?".into()).unwrap();

        let template = "{相册内名称}-{游戏名}-{年月日}-{标签}-{备注}";
        let first = api
            .export_media(
                vec![media.id],
                destination.path().to_string_lossy().into_owned(),
                template.into(),
            )
            .await
            .unwrap();
        assert_eq!(first.total, 1);
        assert_eq!(first.exported, 1);
        assert_eq!(first.failed, 0);

        let second = api
            .export_media(
                vec![media.id],
                destination.path().to_string_lossy().into_owned(),
                template.into(),
            )
            .await
            .unwrap();
        assert_eq!(second.exported, 1);
        let mut exported = fs::read_dir(destination.path())
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect::<Vec<_>>();
        exported.sort();
        assert_eq!(exported.len(), 2);
        assert!(exported.iter().all(|path| {
            let name = path.file_name().unwrap().to_string_lossy();
            name.contains("Splatoon 3")
                && name.contains("20261005")
                && name.contains("Anarchy-Festival")
                && name.contains("Win100")
                && !name.contains(':')
                && !name.contains('?')
        }));
        assert!(exported.iter().any(|path| path
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .ends_with(" (2)")));
        assert!(exported
            .iter()
            .all(|path| fs::read(path).unwrap() == b"exported media bytes"));
    }

    #[tokio::test]
    async fn library_delete_removes_database_record_and_original_file() {
        let library = tempdir().unwrap();
        let source = tempdir().unwrap();
        let source_file = source.path().join("capture.jpg");
        fs::write(&source_file, b"delete this media").unwrap();
        let api = CoreApi::open(library.path()).unwrap();
        api.import_local_files(vec![source_file.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap();
        let stored_path = media[0].storage_path.clone();

        let result = api.delete_media(media[0].id).unwrap();

        assert!(result.deleted_from_library);
        assert!(!Path::new(&stored_path).exists());
        assert!(api.list_media(GalleryQuery::default()).unwrap().is_empty());
    }

    #[tokio::test]
    async fn album_removal_keeps_file_until_no_album_contains_media() {
        let library = tempdir().unwrap();
        let source = tempdir().unwrap();
        let source_file = source.path().join("capture.jpg");
        fs::write(&source_file, b"album membership media").unwrap();
        let api = CoreApi::open(library.path()).unwrap();
        api.import_local_files(vec![source_file.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap()[0].clone();
        let first_album = api
            .create_album("First".into(), String::new(), false)
            .unwrap();
        let second_album = api
            .create_album("Second".into(), String::new(), false)
            .unwrap();
        api.add_media_to_album(first_album, media.id).unwrap();
        api.add_media_to_album(second_album, media.id).unwrap();

        let first = api
            .remove_media_from_album_and_cleanup(first_album, media.id)
            .unwrap();
        assert_eq!(
            first,
            MediaDeletionResult {
                removed_from_album: true,
                deleted_from_library: false,
                remaining_album_count: 1,
            }
        );
        assert!(Path::new(&media.storage_path).exists());

        let second = api
            .remove_media_from_album_and_cleanup(second_album, media.id)
            .unwrap();
        assert!(second.deleted_from_library);
        assert!(!Path::new(&media.storage_path).exists());
    }

    #[tokio::test]
    async fn deleting_an_album_keeps_its_media_in_the_library() {
        let library = tempdir().unwrap();
        let source = tempdir().unwrap();
        let source_file = source.path().join("capture.jpg");
        fs::write(&source_file, b"album deletion must keep this media").unwrap();
        let api = CoreApi::open(library.path()).unwrap();
        api.import_local_files(vec![source_file.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let media = api.list_media(GalleryQuery::default()).unwrap()[0].clone();
        let album_id = api
            .create_album("Temporary".into(), String::new(), false)
            .unwrap();
        api.add_media_to_album(album_id, media.id).unwrap();

        api.delete_album(album_id).unwrap();

        assert!(Path::new(&media.storage_path).exists());
        assert_eq!(api.list_media(GalleryQuery::default()).unwrap().len(), 1);
        assert!(api
            .list_albums()
            .unwrap()
            .into_iter()
            .all(|album| album.id != album_id));
    }

    #[tokio::test]
    async fn relocates_and_verifies_managed_originals() {
        let library = tempdir().unwrap();
        let destination = tempdir().unwrap();
        let source = tempdir().unwrap();
        let source_file = source.path().join("capture.jpg");
        fs::write(&source_file, b"move this media").unwrap();
        let api = CoreApi::open(library.path()).unwrap();
        api.import_local_files(vec![source_file.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let before = api.list_media(GalleryQuery::default()).unwrap()[0].clone();
        let settings = AppSettings {
            proxy_url: None,
            library_path: destination.path().to_string_lossy().into_owned(),
            theme: "ocean".into(),
            language: "zh".into(),
            gallery_columns: 4,
            gallery_rows: 3,
            show_note_preview: true,
            show_game_tag: true,
            compact_tag_display: true,
            auto_play_video: false,
            auto_sync_on_launch: false,
            close_behavior: "ask".into(),
            custom_font_paths: Vec::new(),
            sync_policy: SyncPolicy::default(),
        };

        let result = api.relocate_media_library(settings).await.unwrap();
        let after = api.list_media(GalleryQuery::default()).unwrap()[0].clone();

        assert_eq!(result.moved_files, 1);
        assert!(!Path::new(&before.storage_path).exists());
        assert!(Path::new(&after.storage_path).exists());
        assert!(Path::new(&after.storage_path).starts_with(destination.path()));
        assert_eq!(fs::read(after.storage_path).unwrap(), b"move this media");
    }

    #[test]
    fn parses_nintendo_filename_as_local_capture_time() {
        let parsed = nintendo_capture_time(Path::new("2026032723421600_c.jpg")).unwrap();
        let local = parsed.with_timezone(&Local);
        assert_eq!(local.format("%Y%m%d%H%M%S").to_string(), "20260327234216");
        assert!(nintendo_capture_time(Path::new("capture.jpg")).is_none());
        assert_eq!(
            nintendo_capture_sequence(Path::new("2026032723421607_c.jpg")),
            Some(7)
        );
    }

    #[test]
    fn persists_sync_history_per_account_across_core_reopens() {
        let library = tempdir().unwrap();
        let api = CoreApi::open(library.path()).unwrap();

        let recorded = api
            .record_sync_attempt("account-a", "partial_failure", 12, 7, 3, 2)
            .unwrap();

        assert_eq!(
            recorded.latest_attempt.as_ref().unwrap().status,
            "partial_failure"
        );
        assert_eq!(recorded.latest_attempt.as_ref().unwrap().downloaded, 7);
        assert_eq!(
            api.sync_account_history("account-b")
                .unwrap()
                .latest_attempt,
            None
        );
        drop(api);

        let reopened = CoreApi::open(library.path()).unwrap();
        let restored = reopened.sync_account_history("account-a").unwrap();
        assert_eq!(restored.latest_attempt.as_ref().unwrap().total_found, 12);
        assert_eq!(restored.latest_attempt.unwrap().failed, 2);
    }
}
