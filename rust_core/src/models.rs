use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NintendoFriend {
    pub friend_id: String,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub note: String,
    pub is_favorite: bool,
    pub presence: String,
    pub game_name: Option<String>,
    pub game_image_url: Option<String>,
    pub total_play_time_minutes: Option<u32>,
    pub first_played_at: Option<DateTime<Utc>>,
    pub logout_at: Option<DateTime<Utc>>,
    pub activity: Option<String>,
    pub in_game_name: Option<String>,
    pub friendship_source: Option<String>,
    #[serde(default)]
    pub friendship_game_name: Option<String>,
    pub friend_created_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NintendoFriendsSnapshot {
    pub friends: Vec<NintendoFriend>,
    pub updated_at: DateTime<Utc>,
    pub activity_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NintendoFriendCodeSnapshot {
    pub friend_code: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NintendoFriendCodeUser {
    pub friend_id: String,
    pub nickname: String,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NintendoFriendGame {
    pub name: String,
    pub image_url: Option<String>,
    pub total_play_time_minutes: Option<u32>,
    pub first_played_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NintendoFriendRequestResult {
    pub friend_id: String,
    pub accepted: bool,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct SplatNetWebSession {
    pub game_web_token: String,
    pub expires_at: DateTime<Utc>,
    pub language: String,
    pub country: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SeedExportPayload {
    pub file_name: String,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaKind {
    Image,
    Video,
}

impl MediaKind {
    pub fn extension(self) -> &'static str {
        match self {
            Self::Image => "jpg",
            Self::Video => "mp4",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceType {
    Nso,
    SdCard,
    Folder,
    Usb,
    Mtp,
    VideoEdit,
    VideoFrame,
    VideoMerge,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaCandidate {
    pub remote_id: Option<String>,
    pub title_id: Option<String>,
    pub game_name: String,
    pub kind: MediaKind,
    pub content_url: Option<String>,
    pub thumbnail_url: Option<String>,
    pub expected_size: Option<u64>,
    pub captured_at: Option<DateTime<Utc>>,
    pub uploaded_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
    pub original_name: Option<String>,
    pub file_extension: Option<String>,
    pub source_type: SourceType,
    pub source_path: Option<String>,
}

impl MediaCandidate {
    pub fn effective_timestamp(&self) -> DateTime<Utc> {
        self.captured_at
            .or(self.uploaded_at)
            .unwrap_or_else(Utc::now)
    }

    pub fn storage_extension(&self) -> &str {
        self.file_extension
            .as_deref()
            .filter(|value| matches!(*value, "jpg" | "jpeg" | "png" | "webp" | "mp4" | "mov"))
            .unwrap_or_else(|| self.kind.extension())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaAsset {
    pub id: i64,
    pub sha256: String,
    pub original_name: String,
    pub storage_path: String,
    pub kind: MediaKind,
    pub captured_at: Option<DateTime<Utc>>,
    pub imported_at: Option<DateTime<Utc>>,
    pub game_title_id: Option<String>,
    pub game_name: String,
    pub favorite: bool,
    pub note: Option<String>,
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TagUsageSummary {
    pub id: i64,
    pub name: String,
    pub image_count: u64,
    pub video_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameTagSummary {
    pub name: String,
    pub image_count: u64,
    pub video_count: u64,
    pub selection_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameTagAliasSummary {
    pub source_name: String,
    pub target_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaDeletionResult {
    pub removed_from_album: bool,
    pub deleted_from_library: bool,
    pub remaining_album_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryRelocationResult {
    pub moved_files: usize,
    pub library_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryRootProbe {
    pub exists: bool,
    pub database_exists: bool,
    pub database_readable: bool,
    pub media_count: u64,
    pub account_count: u64,
    pub settings_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncSummary {
    pub job_id: String,
    pub total_found: usize,
    pub downloaded: usize,
    pub duplicates: usize,
    pub skipped_remote: usize,
    pub failed: usize,
    pub new_media_at: Option<DateTime<Utc>>,
    pub cursor: Option<String>,
    pub errors: Vec<SyncItemError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncProgress {
    pub job_id: String,
    pub status: String,
    pub total_items: usize,
    pub processed_items: usize,
    pub synchronized_items: usize,
    pub failed_items: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncItemError {
    pub remote_id: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportSummary {
    pub total_found: usize,
    pub imported: usize,
    pub duplicates: usize,
    pub failed: usize,
    pub errors: Vec<ImportItemError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportItemError {
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OperationProgress {
    pub operation_id: String,
    pub kind: String,
    pub phase: String,
    pub status: String,
    pub total_items: Option<usize>,
    pub processed_items: usize,
    pub processed_bytes: Option<u64>,
    pub total_bytes: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaExportSummary {
    pub total: usize,
    pub exported: usize,
    pub failed: usize,
    pub errors: Vec<MediaExportItemError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaExportItemError {
    pub media_id: i64,
    pub name: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderPage {
    pub items: Vec<MediaCandidate>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GalleryKindFilter {
    All,
    Image,
    Video,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapturedOnThisDay {
    pub month: u32,
    pub day: u32,
    pub before_year: i32,
    pub utc_offset_seconds: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GalleryQuery {
    pub kind: GalleryKindFilter,
    pub limit: u32,
    pub offset: u32,
    pub favorite_only: bool,
    pub album_id: Option<i64>,
    pub newest_first: bool,
    #[serde(default)]
    pub game_names: Vec<String>,
    pub captured_from: Option<DateTime<Utc>>,
    pub captured_until: Option<DateTime<Utc>>,
    #[serde(default)]
    pub captured_on_this_day: Option<CapturedOnThisDay>,
}

impl Default for GalleryQuery {
    fn default() -> Self {
        Self {
            kind: GalleryKindFilter::All,
            limit: 100,
            offset: 0,
            favorite_only: false,
            album_id: None,
            newest_first: true,
            game_names: Vec::new(),
            captured_from: None,
            captured_until: None,
            captured_on_this_day: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlbumSummary {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub album_type: String,
    pub pinned: bool,
    pub system_key: Option<String>,
    pub media_count: u64,
    #[serde(default)]
    pub source_device_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlbumRule {
    pub rule_group: i64,
    pub field: String,
    pub operator: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginChallenge {
    pub authorization_url: String,
    pub state: String,
    pub verifier: String,
}
