//! Narrow, generator-friendly API consumed by Flutter through
//! `flutter_rust_bridge`. Rust remains the sole owner of SQLite and sync state.

use std::sync::{Mutex, OnceLock};

use crate::api::CoreApi;
use crate::models::{
    AlbumRule, AlbumSummary, GalleryQuery, GameTagAliasSummary, GameTagSummary, ImportSummary,
    LibraryRelocationResult, LoginChallenge, MediaAsset, MediaDeletionResult, MediaExportSummary,
    SyncProgress, SyncSummary, TagUsageSummary,
};
use crate::nso::CoralSession;
use crate::settings::{AppSettings, SyncPolicy, SyncRuntimeState, SyncScheduleStatus};
use crate::sync::CancellationToken;

static CORE: OnceLock<CoreApi> = OnceLock::new();
static CURRENT_SYNC: Mutex<Option<CancellationToken>> = Mutex::new(None);

pub fn init_core(library_root: String) -> Result<(), String> {
    if CORE.get().is_some() {
        return Ok(());
    }
    CORE.set(CoreApi::open(library_root).map_err(error_text)?)
        .map_err(|_| "core was initialized concurrently".to_owned())
}

pub fn load_settings() -> Result<Option<AppSettings>, String> {
    core()?.load_settings().map_err(error_text)
}

pub fn save_settings(settings: AppSettings) -> Result<(), String> {
    core()?.save_settings(&settings).map_err(error_text)
}

pub fn save_sync_policy(policy: SyncPolicy) -> Result<(), String> {
    core()?.save_sync_policy(&policy).map_err(error_text)
}

pub fn sync_schedule_status(account_id: String) -> Result<SyncScheduleStatus, String> {
    core()?
        .sync_schedule_status(&account_id)
        .map_err(error_text)
}

pub fn record_sync_outcome(
    account_id: String,
    found_new_media: bool,
) -> Result<SyncScheduleStatus, String> {
    core()?
        .record_sync_outcome(&account_id, found_new_media)
        .map_err(error_text)
}

pub fn sync_account_history(account_id: String) -> Result<SyncRuntimeState, String> {
    core()?
        .sync_account_history(&account_id)
        .map_err(error_text)
}

pub fn record_sync_attempt(
    account_id: String,
    status: String,
    total_found: usize,
    downloaded: usize,
    duplicates: usize,
    failed: usize,
) -> Result<SyncRuntimeState, String> {
    core()?
        .record_sync_attempt(
            &account_id,
            &status,
            total_found,
            downloaded,
            duplicates,
            failed,
        )
        .map_err(error_text)
}

pub fn create_nintendo_login_challenge(
    proxy_url: Option<String>,
) -> Result<LoginChallenge, String> {
    core()?
        .create_nintendo_login_challenge(proxy_url)
        .map_err(error_text)
}

pub async fn exchange_nintendo_callback(
    callback_url: String,
    expected_state: String,
    verifier: String,
    proxy_url: Option<String>,
) -> Result<String, String> {
    core()?
        .exchange_nintendo_callback(callback_url, expected_state, verifier, proxy_url)
        .await
        .map_err(error_text)
}

pub async fn establish_coral_session(
    session_token: String,
    proxy_url: Option<String>,
) -> Result<CoralSession, String> {
    core()?
        .establish_coral_session(session_token, proxy_url)
        .await
        .map_err(error_text)
}

pub async fn sync_nso(
    session: CoralSession,
    proxy_url: Option<String>,
) -> Result<SyncSummary, String> {
    let cancellation = CancellationToken::default();
    {
        let mut current = CURRENT_SYNC
            .lock()
            .map_err(|_| "sync mutex poisoned".to_owned())?;
        if current.is_some() {
            return Err("a sync job is already running".into());
        }
        *current = Some(cancellation.clone());
    }
    let result = core()?
        .sync_nso_with_cancellation(session, proxy_url, &cancellation)
        .await
        .map_err(error_text);
    if let Ok(mut current) = CURRENT_SYNC.lock() {
        *current = None;
    }
    result
}

pub fn cancel_current_sync() -> Result<bool, String> {
    let current = CURRENT_SYNC
        .lock()
        .map_err(|_| "sync mutex poisoned".to_owned())?;
    if let Some(token) = current.as_ref() {
        token.cancel();
        Ok(true)
    } else {
        Ok(false)
    }
}

pub fn current_sync_progress() -> Result<Option<SyncProgress>, String> {
    core()?.current_sync_progress().map_err(error_text)
}

pub fn list_media(query: GalleryQuery) -> Result<Vec<MediaAsset>, String> {
    core()?.list_media(query).map_err(error_text)
}

pub fn list_albums() -> Result<Vec<AlbumSummary>, String> {
    core()?.list_albums().map_err(error_text)
}

pub fn list_tags() -> Result<Vec<String>, String> {
    core()?.list_tags().map_err(error_text)
}

pub fn list_tag_usage() -> Result<Vec<TagUsageSummary>, String> {
    core()?.list_tag_usage().map_err(error_text)
}

pub fn create_tag(name: String) -> Result<i64, String> {
    core()?.create_tag(name).map_err(error_text)
}

pub fn rename_tag(tag_id: i64, new_name: String) -> Result<(), String> {
    core()?.rename_tag(tag_id, new_name).map_err(error_text)
}

pub fn delete_tag(tag_id: i64) -> Result<(), String> {
    core()?.delete_tag(tag_id).map_err(error_text)
}

pub fn merge_tags(tag_ids: Vec<i64>, target_name: String) -> Result<(), String> {
    core()?.merge_tags(tag_ids, target_name).map_err(error_text)
}

pub fn list_game_tags() -> Result<Vec<GameTagSummary>, String> {
    core()?.list_game_tags().map_err(error_text)
}

pub fn list_game_tag_aliases() -> Result<Vec<GameTagAliasSummary>, String> {
    core()?.list_game_tag_aliases().map_err(error_text)
}

pub fn record_game_tag_selection(game_name: String) -> Result<(), String> {
    core()?
        .record_game_tag_selection(game_name)
        .map_err(error_text)
}

pub fn merge_game_tags(game_names: Vec<String>, target_name: String) -> Result<(), String> {
    core()?
        .merge_game_tags(game_names, target_name)
        .map_err(error_text)
}

pub fn rename_game_tag(game_name: String, target_name: String) -> Result<(), String> {
    core()?
        .rename_game_tag(game_name, target_name)
        .map_err(error_text)
}

pub async fn import_local_files(paths: Vec<String>) -> Result<ImportSummary, String> {
    core()?.import_local_files(paths).await.map_err(error_text)
}

pub async fn import_custom_files(
    paths: Vec<String>,
    game_name: String,
) -> Result<ImportSummary, String> {
    core()?
        .import_custom_files(paths, game_name)
        .await
        .map_err(error_text)
}

pub async fn import_mtp_files(
    paths: Vec<String>,
    device_name: String,
) -> Result<ImportSummary, String> {
    core()?
        .import_mtp_files(paths, device_name)
        .await
        .map_err(error_text)
}

pub async fn export_media(
    media_ids: Vec<i64>,
    destination: String,
    name_format: String,
) -> Result<MediaExportSummary, String> {
    core()?
        .export_media(media_ids, destination, name_format)
        .await
        .map_err(error_text)
}

pub async fn commit_video_edit(
    media_id: i64,
    processed_path: String,
    overwrite: bool,
) -> Result<MediaAsset, String> {
    core()?
        .commit_video_edit(media_id, processed_path, overwrite)
        .await
        .map_err(error_text)
}

pub async fn save_video_frame(
    media_id: i64,
    bytes: Vec<u8>,
    extension: String,
) -> Result<MediaAsset, String> {
    core()?
        .save_video_frame(media_id, bytes, extension)
        .await
        .map_err(error_text)
}

pub async fn commit_merged_video(
    media_ids: Vec<i64>,
    processed_path: String,
) -> Result<MediaAsset, String> {
    core()?
        .commit_merged_video(media_ids, processed_path)
        .await
        .map_err(error_text)
}

pub fn set_favorite(media_id: i64, favorite: bool) -> Result<(), String> {
    core()?.set_favorite(media_id, favorite).map_err(error_text)
}

pub fn set_note(media_id: i64, note: String) -> Result<(), String> {
    core()?.set_note(media_id, note).map_err(error_text)
}

pub fn add_tag(media_id: i64, tag: String) -> Result<i64, String> {
    core()?.add_tag(media_id, tag).map_err(error_text)
}

pub fn replace_tags(media_id: i64, tags: Vec<String>) -> Result<(), String> {
    core()?.replace_tags(media_id, tags).map_err(error_text)
}

pub fn create_album(name: String, description: String, smart: bool) -> Result<i64, String> {
    core()?
        .create_album(name, description, smart)
        .map_err(error_text)
}

pub fn update_album(
    album_id: i64,
    name: String,
    description: String,
    smart: bool,
) -> Result<(), String> {
    core()?
        .update_album(album_id, name, description, smart)
        .map_err(error_text)
}

pub fn list_album_rules(album_id: i64) -> Result<Vec<AlbumRule>, String> {
    core()?.list_album_rules(album_id).map_err(error_text)
}

pub fn delete_album(album_id: i64) -> Result<(), String> {
    core()?.delete_album(album_id).map_err(error_text)
}

pub fn replace_album_rules(album_id: i64, rules: Vec<AlbumRule>) -> Result<(), String> {
    core()?
        .replace_album_rules(album_id, rules)
        .map_err(error_text)
}

pub fn add_media_to_album(album_id: i64, media_id: i64) -> Result<(), String> {
    core()?
        .add_media_to_album(album_id, media_id)
        .map_err(error_text)
}

pub fn delete_media(media_id: i64) -> Result<MediaDeletionResult, String> {
    core()?.delete_media(media_id).map_err(error_text)
}

pub fn remove_media_from_album(
    album_id: i64,
    media_id: i64,
) -> Result<MediaDeletionResult, String> {
    core()?
        .remove_media_from_album_and_cleanup(album_id, media_id)
        .map_err(error_text)
}

pub async fn relocate_media_library(
    settings: AppSettings,
) -> Result<LibraryRelocationResult, String> {
    core()?
        .relocate_media_library(settings)
        .await
        .map_err(error_text)
}

fn core() -> Result<&'static CoreApi, String> {
    CORE.get()
        .ok_or_else(|| "core is not initialized; call init_core first".into())
}

fn error_text(error: impl std::fmt::Display) -> String {
    error.to_string()
}
