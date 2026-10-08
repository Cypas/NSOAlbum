use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{CoreError, CoreResult};

pub const MIN_ACTIVE_INTERVAL_MINUTES: u32 = 10;
pub const SLEEP_INTERVAL_MINUTES: u32 = 60;

fn default_language() -> String {
    "zh".into()
}

fn default_true() -> bool {
    true
}

fn default_close_behavior() -> String {
    "ask".into()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncPolicy {
    pub enabled: bool,
    pub active_interval_minutes: u32,
    pub sleep_after_hours: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncRuntimeState {
    pub last_successful_sync_at: Option<DateTime<Utc>>,
    pub last_new_media_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub latest_attempt: Option<SyncAttemptSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncAttemptSummary {
    pub attempted_at: DateTime<Utc>,
    pub status: String,
    pub total_found: usize,
    pub downloaded: usize,
    pub duplicates: usize,
    pub failed: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncScheduleStatus {
    pub last_successful_sync_at: Option<DateTime<Utc>>,
    pub last_new_media_at: Option<DateTime<Utc>>,
    pub sleeping: bool,
    pub interval_minutes: Option<u32>,
    pub next_sync_at: Option<DateTime<Utc>>,
}

impl Default for SyncPolicy {
    fn default() -> Self {
        Self {
            enabled: false,
            active_interval_minutes: MIN_ACTIVE_INTERVAL_MINUTES,
            sleep_after_hours: 24,
        }
    }
}

impl SyncPolicy {
    pub fn validate(&self) -> CoreResult<()> {
        if self.active_interval_minutes < MIN_ACTIVE_INTERVAL_MINUTES {
            return Err(CoreError::InvalidConfig(format!(
                "active sync interval must be at least {MIN_ACTIVE_INTERVAL_MINUTES} minutes"
            )));
        }
        if self.sleep_after_hours == 0 {
            return Err(CoreError::InvalidConfig(
                "sleep threshold must be greater than zero".into(),
            ));
        }
        Ok(())
    }

    pub fn is_sleeping(
        &self,
        last_new_media_at: Option<DateTime<Utc>>,
        now: DateTime<Utc>,
    ) -> bool {
        self.enabled
            && last_new_media_at
                .map(|last| now - last >= Duration::hours(self.sleep_after_hours.into()))
                .unwrap_or(false)
    }

    pub fn effective_interval_minutes(
        &self,
        last_new_media_at: Option<DateTime<Utc>>,
        now: DateTime<Utc>,
    ) -> Option<u32> {
        if !self.enabled {
            None
        } else if self.is_sleeping(last_new_media_at, now) {
            Some(SLEEP_INTERVAL_MINUTES)
        } else {
            Some(
                self.active_interval_minutes
                    .max(MIN_ACTIVE_INTERVAL_MINUTES),
            )
        }
    }

    pub fn schedule_status(
        &self,
        runtime: &SyncRuntimeState,
        now: DateTime<Utc>,
    ) -> SyncScheduleStatus {
        let interval_minutes = self.effective_interval_minutes(runtime.last_new_media_at, now);
        let next_sync_at = interval_minutes.map(|minutes| {
            let candidate = runtime.last_successful_sync_at.unwrap_or(now)
                + Duration::minutes(i64::from(minutes));
            candidate.max(now)
        });
        SyncScheduleStatus {
            last_successful_sync_at: runtime.last_successful_sync_at,
            last_new_media_at: runtime.last_new_media_at,
            sleeping: self.is_sleeping(runtime.last_new_media_at, now),
            interval_minutes,
            next_sync_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    pub proxy_url: Option<String>,
    pub library_path: String,
    pub theme: String,
    #[serde(default = "default_language")]
    pub language: String,
    pub gallery_columns: u8,
    pub gallery_rows: u8,
    pub show_note_preview: bool,
    pub show_game_tag: bool,
    #[serde(default = "default_true")]
    pub compact_tag_display: bool,
    #[serde(default)]
    pub auto_play_video: bool,
    #[serde(default)]
    pub auto_sync_on_launch: bool,
    #[serde(default = "default_close_behavior")]
    pub close_behavior: String,
    #[serde(default)]
    pub custom_font_paths: Vec<String>,
    pub sync_policy: SyncPolicy,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_intervals_below_ten_minutes() {
        let policy = SyncPolicy {
            enabled: true,
            active_interval_minutes: 5,
            sleep_after_hours: 24,
        };
        assert!(policy.validate().is_err());
    }

    #[test]
    fn switches_to_hourly_after_inactivity() {
        let policy = SyncPolicy {
            enabled: true,
            active_interval_minutes: 15,
            sleep_after_hours: 24,
        };
        let now = Utc::now();
        assert_eq!(
            policy.effective_interval_minutes(Some(now - Duration::hours(25)), now),
            Some(60)
        );
    }

    #[test]
    fn schedule_uses_remaining_time_after_restart() {
        let policy = SyncPolicy {
            enabled: true,
            active_interval_minutes: 10,
            sleep_after_hours: 24,
        };
        let now = Utc::now();
        let runtime = SyncRuntimeState {
            last_successful_sync_at: Some(now - Duration::minutes(4)),
            last_new_media_at: Some(now),
            latest_attempt: None,
        };
        let status = policy.schedule_status(&runtime, now);
        assert_eq!(status.interval_minutes, Some(10));
        assert_eq!(status.next_sync_at, Some(now + Duration::minutes(6)));
    }

    #[test]
    fn enables_compact_tag_display_for_older_settings() {
        let settings: AppSettings = serde_json::from_value(serde_json::json!({
            "proxy_url": null,
            "library_path": "C:/library",
            "theme": "ocean",
            "language": "zh",
            "gallery_columns": 4,
            "gallery_rows": 3,
            "show_note_preview": true,
            "show_game_tag": true,
            "auto_play_video": false,
            "sync_policy": {
                "enabled": false,
                "active_interval_minutes": 10,
                "sleep_after_hours": 24
            }
        }))
        .unwrap();

        assert!(settings.compact_tag_display);
        assert!(!settings.auto_sync_on_launch);
        assert_eq!(settings.close_behavior, "ask");
        assert!(settings.custom_font_paths.is_empty());
    }

    #[test]
    fn preserves_ordered_custom_font_paths() {
        let settings: AppSettings = serde_json::from_value(serde_json::json!({
            "proxy_url": null,
            "library_path": "C:/library",
            "theme": "ocean",
            "language": "zh",
            "gallery_columns": 4,
            "gallery_rows": 3,
            "show_note_preview": true,
            "show_game_tag": true,
            "compact_tag_display": true,
            "auto_play_video": false,
            "auto_sync_on_launch": false,
            "close_behavior": "ask",
            "custom_font_paths": [
                "C:/support/custom_fonts/entry-1/first.ttf",
                "C:/support/custom_fonts/entry-2/second.otf"
            ],
            "sync_policy": {
                "enabled": false,
                "active_interval_minutes": 10,
                "sleep_after_hours": 24
            }
        }))
        .unwrap();

        assert_eq!(
            settings.custom_font_paths,
            [
                "C:/support/custom_fonts/entry-1/first.ttf",
                "C:/support/custom_fonts/entry-2/second.otf"
            ]
        );
    }
}
