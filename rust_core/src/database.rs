use std::path::Path;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::album::{kind_from_type, readable_import_media_name, readable_media_name};
use crate::error::CoreResult;
use crate::models::{
    AlbumRule, AlbumSummary, GalleryKindFilter, GalleryQuery, GameTagAliasSummary, GameTagSummary,
    LibraryRootProbe, MediaAsset, MediaCandidate, MediaKind, SyncProgress, TagUsageSummary,
};
use crate::settings::AppSettings;
use crate::smart_album::matches_album_rules;

type AlbumFilter = (
    String,
    Option<String>,
    Vec<AlbumRule>,
    std::collections::HashSet<i64>,
);

#[derive(Debug, Clone)]
pub struct MediaStorageEntry {
    pub id: i64,
    pub sha256: String,
    pub storage_path: String,
    pub kind: MediaKind,
}

#[derive(Debug, Clone)]
pub struct MediaExportEntry {
    pub id: i64,
    pub original_name: String,
    pub storage_path: String,
    pub game_name: String,
    pub timestamp: DateTime<Utc>,
    pub tags: Vec<String>,
    pub note: String,
}

pub struct Database {
    connection: Mutex<Connection>,
}

pub fn probe_library_root(root: impl AsRef<Path>) -> CoreResult<LibraryRootProbe> {
    let root = root.as_ref();
    if !root.exists() {
        return Ok(LibraryRootProbe {
            exists: false,
            database_exists: false,
            database_readable: false,
            media_count: 0,
            account_count: 0,
            settings_count: 0,
        });
    }
    let database_path = root.join("database").join("library.sqlite3");
    if !database_path.exists() {
        return Ok(LibraryRootProbe {
            exists: true,
            database_exists: false,
            database_readable: false,
            media_count: 0,
            account_count: 0,
            settings_count: 0,
        });
    }
    let connection = match Connection::open_with_flags(
        &database_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    ) {
        Ok(connection) => connection,
        Err(_) => {
            return Ok(LibraryRootProbe {
                exists: true,
                database_exists: true,
                database_readable: false,
                media_count: 0,
                account_count: 0,
                settings_count: 0,
            });
        }
    };
    let table_exists = |table: &str| -> rusqlite::Result<bool> {
        connection.query_row(
            "SELECT EXISTS(
               SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1
             )",
            [table],
            |row| row.get(0),
        )
    };
    let count = |sql: &str| -> rusqlite::Result<u64> {
        connection
            .query_row(sql, [], |row| row.get::<_, i64>(0))
            .map(|value| value.max(0) as u64)
    };
    let media_count = if table_exists("media_asset")? {
        count("SELECT COUNT(*) FROM media_asset")?
    } else {
        0
    };
    let settings_count = if table_exists("app_setting")? {
        count("SELECT COUNT(*) FROM app_setting")?
    } else {
        0
    };
    let account_count = if table_exists("app_setting")? {
        connection
            .query_row(
                "SELECT COUNT(*) FROM app_setting WHERE key LIKE 'sync.runtime.%'",
                [],
                |row| row.get::<_, i64>(0),
            )?
            .max(0) as u64
    } else {
        0
    };
    Ok(LibraryRootProbe {
        exists: true,
        database_exists: true,
        database_readable: true,
        media_count,
        account_count,
        settings_count,
    })
}

impl Database {
    pub fn open(path: impl AsRef<Path>) -> CoreResult<Self> {
        if let Some(parent) = path.as_ref().parent() {
            std::fs::create_dir_all(parent)?;
        }
        let connection = Connection::open(path)?;
        connection.execute_batch(
            "PRAGMA foreign_keys = ON;
             PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;",
        )?;
        let database = Self {
            connection: Mutex::new(connection),
        };
        database.migrate()?;
        Ok(database)
    }

    fn migrate(&self) -> CoreResult<()> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        transaction.execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_version (
               version INTEGER NOT NULL
             );
             INSERT INTO schema_version(version)
             SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);

             CREATE TABLE IF NOT EXISTS media_asset (
               id INTEGER PRIMARY KEY,
               sha256 TEXT NOT NULL UNIQUE,
               size INTEGER NOT NULL,
               mime TEXT,
               media_type TEXT NOT NULL,
               width INTEGER,
               height INTEGER,
               duration_ms INTEGER,
               captured_at TEXT,
               uploaded_at TEXT,
               imported_at TEXT NOT NULL,
               game_title_id TEXT,
               source_game_name TEXT NOT NULL DEFAULT '',
               game_name TEXT NOT NULL,
               original_name TEXT NOT NULL,
               storage_path TEXT NOT NULL,
               favorite INTEGER NOT NULL DEFAULT 0,
               status TEXT NOT NULL DEFAULT 'ready'
             );

             CREATE TABLE IF NOT EXISTS media_source (
               id INTEGER PRIMARY KEY,
               media_id INTEGER NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
               source_type TEXT NOT NULL,
               source_path TEXT,
               remote_id TEXT,
               provider TEXT,
               discovered_at TEXT NOT NULL,
               UNIQUE(media_id, source_type, source_path, remote_id)
             );

             CREATE TABLE IF NOT EXISTS tag (
               id INTEGER PRIMARY KEY,
               name TEXT NOT NULL COLLATE NOCASE UNIQUE,
               normalized_name TEXT NOT NULL UNIQUE,
               created_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS media_tag (
               media_id INTEGER NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
               tag_id INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
               PRIMARY KEY(media_id, tag_id)
             );

             CREATE TABLE IF NOT EXISTS note (
               media_id INTEGER PRIMARY KEY REFERENCES media_asset(id) ON DELETE CASCADE,
               text TEXT NOT NULL,
               updated_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS album (
               id INTEGER PRIMARY KEY,
               name TEXT NOT NULL,
               album_type TEXT NOT NULL CHECK(album_type IN ('manual', 'smart')),
               pinned INTEGER NOT NULL DEFAULT 0,
               system_key TEXT UNIQUE,
               created_at TEXT NOT NULL,
               updated_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS album_media (
               album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
               media_id INTEGER NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
               PRIMARY KEY(album_id, media_id)
             );

             CREATE TABLE IF NOT EXISTS album_rule (
               id INTEGER PRIMARY KEY,
               album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
               rule_group INTEGER NOT NULL DEFAULT 0,
               field TEXT NOT NULL,
               operator TEXT NOT NULL,
               value TEXT NOT NULL,
               created_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS app_setting (
               key TEXT PRIMARY KEY,
               value_json TEXT NOT NULL,
               updated_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS game_filter_usage (
               game_name TEXT PRIMARY KEY COLLATE NOCASE,
               selection_count INTEGER NOT NULL DEFAULT 0,
               last_selected_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS game_tag_alias (
               source_name TEXT PRIMARY KEY COLLATE NOCASE,
               target_name TEXT NOT NULL,
               is_intermediate INTEGER NOT NULL DEFAULT 0
             );

             CREATE TABLE IF NOT EXISTS sync_job (
               id TEXT PRIMARY KEY,
               provider TEXT NOT NULL,
               status TEXT NOT NULL,
               total_items INTEGER NOT NULL DEFAULT 0,
               completed_items INTEGER NOT NULL DEFAULT 0,
               failed_items INTEGER NOT NULL DEFAULT 0,
               cursor TEXT,
               error TEXT,
               created_at TEXT NOT NULL,
               updated_at TEXT NOT NULL
             );

             INSERT OR IGNORE INTO album(
               id, name, album_type, pinned, system_key, created_at, updated_at
             ) VALUES (
               1, '收藏', 'smart', 1, 'favorites', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
             );
             INSERT OR IGNORE INTO album_rule(
               album_id, rule_group, field, operator, value, created_at
             ) VALUES (1, 0, 'favorite', 'equals', 'true', CURRENT_TIMESTAMP);",
        )?;
        let schema_version: i64 =
            transaction.query_row("SELECT version FROM schema_version LIMIT 1", [], |row| {
                row.get(0)
            })?;
        if schema_version < 2 {
            backfill_legacy_nso_names(&transaction)?;
            transaction.execute("UPDATE schema_version SET version = 2", [])?;
        }
        if schema_version < 3 {
            let has_description = transaction
                .prepare("PRAGMA table_info(album)")?
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<Result<Vec<_>, _>>()?
                .iter()
                .any(|name| name == "description");
            if !has_description {
                transaction.execute(
                    "ALTER TABLE album ADD COLUMN description TEXT NOT NULL DEFAULT ''",
                    [],
                )?;
            }
            transaction.execute("UPDATE schema_version SET version = 3", [])?;
        }
        if schema_version < 4 {
            backfill_mtp_display_names(&transaction)?;
            transaction.execute("UPDATE schema_version SET version = 4", [])?;
        }
        if schema_version < 5 {
            let has_intermediate = transaction
                .prepare("PRAGMA table_info(game_tag_alias)")?
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<Result<Vec<_>, _>>()?
                .iter()
                .any(|name| name == "is_intermediate");
            if !has_intermediate {
                transaction.execute(
                    "ALTER TABLE game_tag_alias
                     ADD COLUMN is_intermediate INTEGER NOT NULL DEFAULT 0",
                    [],
                )?;
            }
            migrate_game_tag_aliases(&transaction)?;
            transaction.execute("UPDATE schema_version SET version = 5", [])?;
        }
        if schema_version < 6 {
            let has_source_game_name = transaction
                .prepare("PRAGMA table_info(media_asset)")?
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<Result<Vec<_>, _>>()?
                .iter()
                .any(|name| name == "source_game_name");
            if !has_source_game_name {
                transaction.execute(
                    "ALTER TABLE media_asset
                     ADD COLUMN source_game_name TEXT NOT NULL DEFAULT ''",
                    [],
                )?;
            }
            migrate_hidden_source_game_names(&transaction)?;
            transaction.execute("UPDATE schema_version SET version = 6", [])?;
        }
        ensure_required_columns(&transaction)?;
        transaction.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_media_capture
               ON media_asset(captured_at DESC, imported_at DESC);
             CREATE INDEX IF NOT EXISTS idx_media_game ON media_asset(game_title_id, game_name);
             CREATE INDEX IF NOT EXISTS idx_source_remote ON media_source(provider, remote_id);",
        )?;
        if schema_version < 7 {
            transaction.execute("UPDATE schema_version SET version = 7", [])?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn register_media(
        &self,
        sha256: &str,
        size: u64,
        storage_path: &Path,
        candidate: &MediaCandidate,
        provider: Option<&str>,
    ) -> CoreResult<(i64, bool)> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let existing: Option<i64> = transaction
            .query_row(
                "SELECT id FROM media_asset WHERE sha256 = ?1",
                [sha256],
                |row| row.get(0),
            )
            .optional()?;
        let created = existing.is_none();
        let media_id = if let Some(id) = existing {
            id
        } else {
            let imported_at = Utc::now().to_rfc3339();
            let raw_game_name = candidate.game_name.trim();
            let game_name = resolve_game_tag_alias(&transaction, raw_game_name)?;
            let original_name = candidate
                .original_name
                .clone()
                .map(|name| rewrite_generated_name(&name, raw_game_name, &game_name))
                .unwrap_or_else(|| format!("{}.{}", sha256, candidate.storage_extension()));
            transaction.execute(
                "INSERT INTO media_asset(
                   sha256, size, media_type, captured_at, uploaded_at, imported_at,
                   game_title_id, source_game_name, game_name, original_name, storage_path
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    sha256,
                    size as i64,
                    kind_name(candidate.kind),
                    to_text(candidate.captured_at),
                    to_text(candidate.uploaded_at),
                    imported_at,
                    candidate.title_id.as_deref(),
                    raw_game_name,
                    game_name,
                    original_name,
                    storage_path.to_string_lossy(),
                ],
            )?;
            transaction.last_insert_rowid()
        };
        transaction.execute(
            "INSERT OR IGNORE INTO media_source(
               media_id, source_type, source_path, remote_id, provider, discovered_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                media_id,
                serde_json::to_string(&candidate.source_type)?.trim_matches('"'),
                candidate.source_path.as_deref(),
                candidate.remote_id.as_deref(),
                provider,
                Utc::now().to_rfc3339(),
            ],
        )?;
        transaction.commit()?;
        Ok((media_id, created))
    }

    pub fn has_remote_media(&self, provider: &str, remote_id: &str) -> CoreResult<bool> {
        let exists = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM media_source WHERE provider=?1 AND remote_id=?2)",
                params![provider, remote_id],
                |row| row.get(0),
            )?;
        Ok(exists)
    }

    pub fn begin_sync_job(&self, id: &str, provider: &str, cursor: Option<&str>) -> CoreResult<()> {
        let now = Utc::now().to_rfc3339();
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "INSERT INTO sync_job(id, provider, status, cursor, created_at, updated_at)
             VALUES (?1, ?2, 'running', ?3, ?4, ?4)",
                params![id, provider, cursor, now],
            )?;
        Ok(())
    }

    pub fn latest_sync_cursor(&self, provider: &str) -> CoreResult<Option<String>> {
        Ok(self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT cursor FROM sync_job
                 WHERE provider=?1 AND cursor IS NOT NULL
                 ORDER BY updated_at DESC LIMIT 1",
                [provider],
                |row| row.get(0),
            )
            .optional()?)
    }

    pub fn current_sync_progress(&self, provider: &str) -> CoreResult<Option<SyncProgress>> {
        Ok(self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT id, status, total_items, completed_items, failed_items
                 FROM sync_job
                 WHERE provider=?1 AND status='running'
                 ORDER BY updated_at DESC LIMIT 1",
                [provider],
                |row| {
                    let synchronized_items = row.get::<_, i64>(3)?.max(0) as usize;
                    let failed_items = row.get::<_, i64>(4)?.max(0) as usize;
                    Ok(SyncProgress {
                        job_id: row.get(0)?,
                        status: row.get(1)?,
                        total_items: row.get::<_, i64>(2)?.max(0) as usize,
                        processed_items: synchronized_items.saturating_add(failed_items),
                        synchronized_items,
                        failed_items,
                    })
                },
            )
            .optional()?)
    }

    pub fn current_sync_progress_any(&self) -> CoreResult<Option<SyncProgress>> {
        Ok(self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT id, status, total_items, completed_items, failed_items
                 FROM sync_job
                 WHERE status='running'
                 ORDER BY updated_at DESC LIMIT 1",
                [],
                |row| {
                    let synchronized_items = row.get::<_, i64>(3)?.max(0) as usize;
                    let failed_items = row.get::<_, i64>(4)?.max(0) as usize;
                    Ok(SyncProgress {
                        job_id: row.get(0)?,
                        status: row.get(1)?,
                        total_items: row.get::<_, i64>(2)?.max(0) as usize,
                        processed_items: synchronized_items.saturating_add(failed_items),
                        synchronized_items,
                        failed_items,
                    })
                },
            )
            .optional()?)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn update_sync_job(
        &self,
        id: &str,
        status: &str,
        total: usize,
        completed: usize,
        failed: usize,
        cursor: Option<&str>,
        error: Option<&str>,
    ) -> CoreResult<()> {
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "UPDATE sync_job SET status=?2, total_items=?3, completed_items=?4,
             failed_items=?5, cursor=?6, error=?7, updated_at=?8 WHERE id=?1",
                params![
                    id,
                    status,
                    total as i64,
                    completed as i64,
                    failed as i64,
                    cursor,
                    error,
                    Utc::now().to_rfc3339(),
                ],
            )?;
        Ok(())
    }

    pub fn set_favorite(&self, media_id: i64, favorite: bool) -> CoreResult<()> {
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "UPDATE media_asset SET favorite = ?2 WHERE id = ?1",
                params![media_id, favorite],
            )?;
        Ok(())
    }

    pub fn set_note(&self, media_id: i64, text: &str) -> CoreResult<()> {
        self.connection.lock().expect("database mutex poisoned").execute(
            "INSERT INTO note(media_id, text, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(media_id) DO UPDATE SET text=excluded.text, updated_at=excluded.updated_at",
            params![media_id, text, Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub fn add_tag(&self, media_id: i64, name: &str) -> CoreResult<i64> {
        let name = name.trim();
        if name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "tag cannot be empty".into(),
            ));
        }
        let normalized = name.to_lowercase();
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT OR IGNORE INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
            params![name, normalized, Utc::now().to_rfc3339()],
        )?;
        let tag_id: i64 = transaction.query_row(
            "SELECT id FROM tag WHERE normalized_name=?1",
            [normalized],
            |row| row.get(0),
        )?;
        transaction.execute(
            "INSERT OR IGNORE INTO media_tag(media_id, tag_id) VALUES (?1, ?2)",
            params![media_id, tag_id],
        )?;
        transaction.commit()?;
        Ok(tag_id)
    }

    pub fn replace_tags(&self, media_id: i64, names: &[String]) -> CoreResult<()> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        transaction.execute("DELETE FROM media_tag WHERE media_id=?1", [media_id])?;
        for name in names {
            let name = name.trim();
            if name.is_empty() {
                continue;
            }
            let normalized = name.to_lowercase();
            transaction.execute(
                "INSERT OR IGNORE INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
                params![name, normalized, Utc::now().to_rfc3339()],
            )?;
            let tag_id: i64 = transaction.query_row(
                "SELECT id FROM tag WHERE normalized_name=?1",
                [normalized],
                |row| row.get(0),
            )?;
            transaction.execute(
                "INSERT OR IGNORE INTO media_tag(media_id, tag_id) VALUES (?1, ?2)",
                params![media_id, tag_id],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn remove_tag(&self, media_id: i64, tag_id: i64) -> CoreResult<()> {
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "DELETE FROM media_tag WHERE media_id=?1 AND tag_id=?2",
                params![media_id, tag_id],
            )?;
        Ok(())
    }

    pub fn list_tags(&self) -> CoreResult<Vec<String>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement =
            connection.prepare("SELECT name FROM tag ORDER BY name COLLATE NOCASE")?;
        let rows = statement.query_map([], |row| row.get(0))?;
        Ok(rows.collect::<Result<Vec<String>, _>>()?)
    }

    pub fn list_tag_usage(&self) -> CoreResult<Vec<TagUsageSummary>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT t.id, t.name,
                    COUNT(CASE WHEN ma.media_type='image' THEN 1 END),
                    COUNT(CASE WHEN ma.media_type='video' THEN 1 END)
             FROM tag t
             LEFT JOIN media_tag mt ON mt.tag_id=t.id
             LEFT JOIN media_asset ma ON ma.id=mt.media_id AND ma.status='ready'
             GROUP BY t.id, t.name
             ORDER BY t.name COLLATE NOCASE",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(TagUsageSummary {
                id: row.get(0)?,
                name: row.get(1)?,
                image_count: row.get(2)?,
                video_count: row.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn create_tag(&self, name: &str) -> CoreResult<i64> {
        let name = name.trim();
        if name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "tag cannot be empty".into(),
            ));
        }
        let normalized = name.to_lowercase();
        let connection = self.connection.lock().expect("database mutex poisoned");
        let existing: Option<i64> = connection
            .query_row(
                "SELECT id FROM tag WHERE normalized_name=?1",
                [&normalized],
                |row| row.get(0),
            )
            .optional()?;
        if existing.is_some() {
            return Err(crate::error::CoreError::InvalidConfig(
                "a tag with that name already exists".into(),
            ));
        }
        connection.execute(
            "INSERT INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
            params![name, normalized, Utc::now().to_rfc3339()],
        )?;
        Ok(connection.last_insert_rowid())
    }

    pub fn rename_tag(&self, tag_id: i64, new_name: &str) -> CoreResult<()> {
        let new_name = new_name.trim();
        if new_name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "tag cannot be empty".into(),
            ));
        }
        let normalized = new_name.to_lowercase();
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let old_name: String = transaction
            .query_row("SELECT name FROM tag WHERE id=?1", [tag_id], |row| {
                row.get(0)
            })
            .optional()?
            .ok_or_else(|| crate::error::CoreError::InvalidConfig("tag does not exist".into()))?;
        let duplicate: Option<i64> = transaction
            .query_row(
                "SELECT id FROM tag WHERE normalized_name=?1 AND id<>?2",
                params![&normalized, tag_id],
                |row| row.get(0),
            )
            .optional()?;
        if duplicate.is_some() {
            return Err(crate::error::CoreError::InvalidConfig(
                "a tag with that name already exists".into(),
            ));
        }
        transaction.execute(
            "UPDATE tag SET name=?2, normalized_name=?3 WHERE id=?1",
            params![tag_id, new_name, normalized],
        )?;
        transaction.execute(
            "UPDATE album_rule SET value=?1
             WHERE field='tag' AND lower(trim(value))=?2",
            params![new_name, old_name.to_lowercase()],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn delete_tag(&self, tag_id: i64) -> CoreResult<()> {
        let changed = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .execute("DELETE FROM tag WHERE id=?1", [tag_id])?;
        if changed == 0 {
            return Err(crate::error::CoreError::InvalidConfig(
                "tag does not exist".into(),
            ));
        }
        Ok(())
    }

    pub fn merge_tags(&self, tag_ids: &[i64], target_name: &str) -> CoreResult<()> {
        let target_name = target_name.trim();
        if target_name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "merged tag name cannot be empty".into(),
            ));
        }
        let unique_ids = tag_ids
            .iter()
            .copied()
            .collect::<std::collections::BTreeSet<_>>();
        if unique_ids.len() < 2 {
            return Err(crate::error::CoreError::InvalidConfig(
                "select at least two tags to merge".into(),
            ));
        }

        let normalized = target_name.to_lowercase();
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let mut selected = Vec::with_capacity(unique_ids.len());
        for tag_id in unique_ids {
            let name: String = transaction
                .query_row("SELECT name FROM tag WHERE id=?1", [tag_id], |row| {
                    row.get(0)
                })
                .optional()?
                .ok_or_else(|| {
                    crate::error::CoreError::InvalidConfig("tag does not exist".into())
                })?;
            selected.push((tag_id, name));
        }

        let existing_target: Option<i64> = transaction
            .query_row(
                "SELECT id FROM tag WHERE normalized_name=?1",
                [&normalized],
                |row| row.get(0),
            )
            .optional()?;
        let target_id = if let Some(id) = existing_target {
            transaction.execute(
                "UPDATE tag SET name=?2 WHERE id=?1",
                params![id, target_name],
            )?;
            id
        } else {
            transaction.execute(
                "INSERT INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
                params![target_name, normalized, Utc::now().to_rfc3339()],
            )?;
            transaction.last_insert_rowid()
        };

        for (tag_id, old_name) in &selected {
            transaction.execute(
                "INSERT OR IGNORE INTO media_tag(media_id, tag_id)
                 SELECT media_id, ?1 FROM media_tag WHERE tag_id=?2",
                params![target_id, tag_id],
            )?;
            transaction.execute(
                "UPDATE album_rule SET value=?1
                 WHERE field='tag' AND lower(trim(value))=?2",
                params![target_name, old_name.to_lowercase()],
            )?;
        }
        for (tag_id, _) in selected {
            if tag_id != target_id {
                transaction.execute("DELETE FROM tag WHERE id=?1", [tag_id])?;
            }
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn list_game_tags(&self) -> CoreResult<Vec<GameTagSummary>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT TRIM(ma.game_name),
                    COUNT(CASE WHEN ma.media_type='image' THEN 1 END),
                    COUNT(CASE WHEN ma.media_type='video' THEN 1 END),
                    COALESCE(gfu.selection_count, 0)
             FROM media_asset ma
             LEFT JOIN game_filter_usage gfu
               ON gfu.game_name=TRIM(ma.game_name)
             WHERE ma.status='ready' AND TRIM(ma.game_name) <> ''
             GROUP BY TRIM(ma.game_name)
             ORDER BY COALESCE(gfu.selection_count, 0) DESC,
                      COUNT(ma.id) DESC,
                      TRIM(ma.game_name) COLLATE NOCASE",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(GameTagSummary {
                name: row.get(0)?,
                image_count: row.get(1)?,
                video_count: row.get(2)?,
                selection_count: row.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn list_game_tag_aliases(&self) -> CoreResult<Vec<GameTagAliasSummary>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT source_name, target_name
             FROM game_tag_alias
             WHERE is_intermediate=0
             ORDER BY target_name COLLATE NOCASE, source_name COLLATE NOCASE",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(GameTagAliasSummary {
                source_name: row.get(0)?,
                target_name: row.get(1)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn record_game_tag_selection(&self, game_name: &str) -> CoreResult<()> {
        let game_name = game_name.trim();
        if game_name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "game tag cannot be empty".into(),
            ));
        }
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                 VALUES (?1, 1, ?2)
                 ON CONFLICT(game_name) DO UPDATE SET
                   selection_count=selection_count + 1,
                   last_selected_at=excluded.last_selected_at",
                params![game_name, Utc::now().to_rfc3339()],
            )?;
        Ok(())
    }

    pub fn merge_game_tags(&self, game_names: &[String], target_name: &str) -> CoreResult<()> {
        let requested_target = target_name.trim();
        if requested_target.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "merged game tag name cannot be empty".into(),
            ));
        }
        let unique_names = game_names
            .iter()
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .map(|value| (value.to_lowercase(), value.to_owned()))
            .collect::<std::collections::BTreeMap<_, _>>()
            .into_values()
            .collect::<Vec<_>>();
        if unique_names.len() < 2 {
            return Err(crate::error::CoreError::InvalidConfig(
                "select at least two game tags to merge".into(),
            ));
        }

        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let target_name = resolve_game_tag_alias(&transaction, requested_target)?;
        let mut selection_count = 0_i64;
        let target_was_selected = unique_names
            .iter()
            .any(|name| name.eq_ignore_ascii_case(&target_name));
        for old_name in &unique_names {
            let exists: bool = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM media_asset WHERE game_name=?1 COLLATE NOCASE)",
                [old_name],
                |row| row.get(0),
            )?;
            if !exists {
                return Err(crate::error::CoreError::InvalidConfig(format!(
                    "game tag does not exist: {old_name}"
                )));
            }
            selection_count += transaction
                .query_row(
                    "SELECT selection_count FROM game_filter_usage
                     WHERE game_name=?1 COLLATE NOCASE",
                    [old_name],
                    |row| row.get(0),
                )
                .optional()?
                .unwrap_or(0);
            let source_names = source_game_names_for_display(&transaction, old_name)?;
            rewrite_generated_media_names(&transaction, old_name, &target_name)?;
            transaction.execute(
                "UPDATE media_asset SET game_name=?1 WHERE game_name=?2 COLLATE NOCASE",
                params![target_name, old_name],
            )?;
            transaction.execute(
                "UPDATE album_rule SET value=?1
                 WHERE field IN ('game', 'game_tag') AND lower(trim(value))=?2",
                params![target_name, old_name.to_lowercase()],
            )?;
            transaction.execute(
                "UPDATE game_tag_alias SET target_name=?1
                 WHERE target_name=?2 COLLATE NOCASE",
                params![target_name, old_name],
            )?;
            for source_name in source_names {
                if !source_name.eq_ignore_ascii_case(&target_name) {
                    upsert_game_tag_alias(&transaction, &source_name, &target_name)?;
                }
            }
            transaction.execute(
                "DELETE FROM game_filter_usage WHERE game_name=?1 COLLATE NOCASE",
                [old_name],
            )?;
        }
        transaction.execute(
            "DELETE FROM game_tag_alias WHERE source_name=?1 COLLATE NOCASE",
            [&target_name],
        )?;
        if selection_count > 0 {
            if target_was_selected {
                transaction.execute(
                    "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                     VALUES (?1, ?2, ?3)",
                    params![target_name, selection_count, Utc::now().to_rfc3339()],
                )?;
            } else {
                transaction.execute(
                    "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                     VALUES (?1, ?2, ?3)
                     ON CONFLICT(game_name) DO UPDATE SET
                       selection_count=selection_count + excluded.selection_count,
                       last_selected_at=excluded.last_selected_at",
                    params![target_name, selection_count, Utc::now().to_rfc3339()],
                )?;
            }
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn rename_game_tag(&self, game_name: &str, target_name: &str) -> CoreResult<()> {
        let game_name = game_name.trim();
        let requested_target = target_name.trim();
        if game_name.is_empty() || requested_target.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "game tag name cannot be empty".into(),
            ));
        }

        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let target_name = resolve_game_tag_alias(&transaction, requested_target)?;
        let exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM media_asset WHERE game_name=?1 COLLATE NOCASE)",
            [game_name],
            |row| row.get(0),
        )?;
        if !exists {
            return Err(crate::error::CoreError::InvalidConfig(
                "game tag does not exist".into(),
            ));
        }
        if !game_name.eq_ignore_ascii_case(&target_name) {
            let duplicate: bool = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM media_asset WHERE game_name=?1 COLLATE NOCASE)",
                [&target_name],
                |row| row.get(0),
            )?;
            if duplicate {
                return Err(crate::error::CoreError::InvalidConfig(
                    "a game tag with that name already exists; use merge game tags instead".into(),
                ));
            }
        }

        let selection_count = transaction
            .query_row(
                "SELECT selection_count FROM game_filter_usage
                 WHERE game_name=?1 COLLATE NOCASE",
                [game_name],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .unwrap_or(0);
        let source_names = source_game_names_for_display(&transaction, game_name)?;
        rewrite_generated_media_names(&transaction, game_name, &target_name)?;
        transaction.execute(
            "UPDATE media_asset SET game_name=?1 WHERE game_name=?2 COLLATE NOCASE",
            params![target_name, game_name],
        )?;
        transaction.execute(
            "UPDATE album_rule SET value=?1
             WHERE field IN ('game', 'game_tag') AND lower(trim(value))=?2",
            params![target_name, game_name.to_lowercase()],
        )?;
        transaction.execute(
            "UPDATE game_tag_alias SET target_name=?1
             WHERE target_name=?2 COLLATE NOCASE",
            params![target_name, game_name],
        )?;
        for source_name in source_names {
            if !source_name.eq_ignore_ascii_case(&target_name) {
                upsert_game_tag_alias(&transaction, &source_name, &target_name)?;
            }
        }
        transaction.execute(
            "DELETE FROM game_tag_alias WHERE source_name=?1 COLLATE NOCASE",
            [&target_name],
        )?;
        transaction.execute(
            "DELETE FROM game_filter_usage WHERE game_name=?1 COLLATE NOCASE",
            [game_name],
        )?;
        if selection_count > 0 {
            transaction.execute(
                "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(game_name) DO UPDATE SET
                   selection_count=excluded.selection_count,
                   last_selected_at=excluded.last_selected_at",
                params![target_name, selection_count, Utc::now().to_rfc3339()],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn list_albums(&self) -> CoreResult<Vec<AlbumSummary>> {
        let mut albums = {
            let connection = self.connection.lock().expect("database mutex poisoned");
            let mut statement = connection.prepare(
                "SELECT a.id, a.name, a.description, a.album_type, a.pinned, a.system_key
                 FROM album a
                 ORDER BY CASE WHEN a.system_key='favorites' THEN 0 ELSE 1 END,
                          a.pinned DESC, a.updated_at DESC",
            )?;
            let rows = statement.query_map([], |row| {
                Ok(AlbumSummary {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    album_type: row.get(3)?,
                    pinned: row.get::<_, i64>(4)? != 0,
                    system_key: row.get(5)?,
                    media_count: 0,
                })
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        let media = self.load_all_media()?;
        for album in &mut albums {
            let (album_type, system_key, rules, manual_ids) = self.album_filter(album.id)?;
            album.media_count = media
                .iter()
                .filter(|asset| {
                    if system_key.as_deref() == Some("favorites") {
                        asset.favorite
                    } else if album_type == "smart" {
                        matches_album_rules(asset, &rules)
                    } else {
                        manual_ids.contains(&asset.id)
                    }
                })
                .count() as u64;
        }
        Ok(albums)
    }

    pub fn create_album(&self, name: &str, description: &str, smart: bool) -> CoreResult<i64> {
        let name = name.trim();
        if name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "album name cannot be empty".into(),
            ));
        }
        let now = Utc::now().to_rfc3339();
        let connection = self.connection.lock().expect("database mutex poisoned");
        connection.execute(
            "INSERT INTO album(name, description, album_type, pinned, created_at, updated_at)
             VALUES (?1, ?2, ?3, 0, ?4, ?4)",
            params![
                name,
                description.trim(),
                if smart { "smart" } else { "manual" },
                now
            ],
        )?;
        Ok(connection.last_insert_rowid())
    }

    pub fn update_album(
        &self,
        album_id: i64,
        name: &str,
        description: &str,
        smart: bool,
    ) -> CoreResult<()> {
        let name = name.trim();
        if name.is_empty() {
            return Err(crate::error::CoreError::InvalidConfig(
                "album name cannot be empty".into(),
            ));
        }
        let (old_type, system_key, old_rules, _) = self.album_filter(album_id)?;
        if system_key.is_some() {
            return Err(crate::error::CoreError::InvalidConfig(
                "system albums cannot be renamed or converted".into(),
            ));
        }
        let matched_ids = if old_type == "smart" && !smart {
            self.load_all_media()?
                .into_iter()
                .filter(|media| matches_album_rules(media, &old_rules))
                .map(|media| media.id)
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE album SET name=?2, description=?3, album_type=?4, updated_at=?5
             WHERE id=?1 AND system_key IS NULL",
            params![
                album_id,
                name,
                description.trim(),
                if smart { "smart" } else { "manual" },
                Utc::now().to_rfc3339()
            ],
        )?;
        if changed == 0 {
            return Err(crate::error::CoreError::InvalidConfig(
                "system albums cannot be renamed or converted".into(),
            ));
        }
        if old_type != if smart { "smart" } else { "manual" } {
            transaction.execute("DELETE FROM album_media WHERE album_id=?1", [album_id])?;
            transaction.execute("DELETE FROM album_rule WHERE album_id=?1", [album_id])?;
            if !smart {
                for media_id in matched_ids {
                    transaction.execute(
                        "INSERT OR IGNORE INTO album_media(album_id, media_id) VALUES (?1, ?2)",
                        params![album_id, media_id],
                    )?;
                }
            }
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn list_album_rules(&self, album_id: i64) -> CoreResult<Vec<AlbumRule>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT rule_group, field, operator, value FROM album_rule
             WHERE album_id=?1 ORDER BY rule_group, id",
        )?;
        let rows = statement.query_map([album_id], |row| {
            Ok(AlbumRule {
                rule_group: row.get(0)?,
                field: row.get(1)?,
                operator: row.get(2)?,
                value: row.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn delete_album(&self, album_id: i64) -> CoreResult<()> {
        let changed = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "DELETE FROM album WHERE id=?1 AND system_key IS NULL",
                [album_id],
            )?;
        if changed == 0 {
            return Err(crate::error::CoreError::InvalidConfig(
                "system albums cannot be deleted".into(),
            ));
        }
        Ok(())
    }

    pub fn replace_album_rules(&self, album_id: i64, rules: &[AlbumRule]) -> CoreResult<()> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let album_type: String = transaction.query_row(
            "SELECT album_type FROM album WHERE id=?1",
            [album_id],
            |row| row.get(0),
        )?;
        if album_type != "smart" {
            return Err(crate::error::CoreError::InvalidConfig(
                "rules can only be assigned to smart albums".into(),
            ));
        }
        transaction.execute("DELETE FROM album_rule WHERE album_id=?1", [album_id])?;
        for rule in rules {
            transaction.execute(
                "INSERT INTO album_rule(album_id, rule_group, field, operator, value, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    album_id,
                    rule.rule_group,
                    &rule.field,
                    &rule.operator,
                    &rule.value,
                    Utc::now().to_rfc3339()
                ],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn add_media_to_album(&self, album_id: i64, media_id: i64) -> CoreResult<()> {
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .execute(
                "INSERT OR IGNORE INTO album_media(album_id, media_id)
                 SELECT ?1, ?2 WHERE EXISTS(
                   SELECT 1 FROM album WHERE id=?1 AND album_type='manual'
                 )",
                params![album_id, media_id],
            )?;
        Ok(())
    }

    pub fn remove_media_from_album(&self, album_id: i64, media_id: i64) -> CoreResult<()> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let (album_type, system_key): (String, Option<String>) = transaction.query_row(
            "SELECT album_type, system_key FROM album WHERE id=?1",
            [album_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        if system_key.as_deref() == Some("favorites") {
            transaction.execute("UPDATE media_asset SET favorite=0 WHERE id=?1", [media_id])?;
        } else if album_type == "manual" {
            transaction.execute(
                "DELETE FROM album_media WHERE album_id=?1 AND media_id=?2",
                params![album_id, media_id],
            )?;
        } else {
            return Err(crate::error::CoreError::InvalidConfig(
                "media cannot be manually removed from a rule-based smart album".into(),
            ));
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn media_album_membership_count(&self, media_id: i64) -> CoreResult<u64> {
        let media = self
            .load_all_media()?
            .into_iter()
            .find(|asset| asset.id == media_id)
            .ok_or_else(|| {
                crate::error::CoreError::InvalidConfig("media item does not exist".into())
            })?;
        let albums = {
            let connection = self.connection.lock().expect("database mutex poisoned");
            let mut statement =
                connection.prepare("SELECT id, album_type, system_key FROM album ORDER BY id")?;
            let rows = statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            rows
        };
        let mut count = 0_u64;
        for (album_id, album_type, system_key) in albums {
            if system_key.as_deref() == Some("favorites") {
                count += u64::from(media.favorite);
                continue;
            }
            let (_, _, rules, manual_ids) = self.album_filter(album_id)?;
            let included = if album_type == "smart" {
                matches_album_rules(&media, &rules)
            } else {
                manual_ids.contains(&media_id)
            };
            count += u64::from(included);
        }
        Ok(count)
    }

    pub fn media_storage_entry(&self, media_id: i64) -> CoreResult<MediaStorageEntry> {
        self.connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT id, sha256, storage_path, media_type
                 FROM media_asset WHERE id=?1",
                [media_id],
                |row| {
                    let kind: String = row.get(3)?;
                    Ok(MediaStorageEntry {
                        id: row.get(0)?,
                        sha256: row.get(1)?,
                        storage_path: row.get(2)?,
                        kind: if kind == "video" {
                            MediaKind::Video
                        } else {
                            MediaKind::Image
                        },
                    })
                },
            )
            .map_err(Into::into)
    }

    pub fn media_asset(&self, media_id: i64) -> CoreResult<MediaAsset> {
        self.load_all_media()?
            .into_iter()
            .find(|media| media.id == media_id)
            .ok_or_else(|| {
                crate::error::CoreError::InvalidConfig("media item does not exist".into())
            })
    }

    pub fn replace_media_content(
        &self,
        media_id: i64,
        expected_sha256: &str,
        sha256: &str,
        size: u64,
        storage_path: &Path,
        generated_tag: &str,
    ) -> CoreResult<()> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let (stored_sha256, media_type): (String, String) = transaction
            .query_row(
                "SELECT sha256, media_type FROM media_asset WHERE id=?1 AND status='ready'",
                [media_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?
            .ok_or_else(|| {
                crate::error::CoreError::InvalidConfig("media item does not exist".into())
            })?;
        if stored_sha256 != expected_sha256 {
            return Err(crate::error::CoreError::InvalidConfig(
                "media changed while the video editor was open".into(),
            ));
        }
        if media_type != "video" {
            return Err(crate::error::CoreError::InvalidConfig(
                "only videos can be overwritten by the video editor".into(),
            ));
        }
        let collision: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM media_asset WHERE sha256=?1 AND id<>?2)",
            params![sha256, media_id],
            |row| row.get(0),
        )?;
        if collision {
            return Err(crate::error::CoreError::InvalidConfig(
                "the edited video is identical to another item in the library".into(),
            ));
        }
        transaction.execute(
            "UPDATE media_asset SET sha256=?2, size=?3, storage_path=?4 WHERE id=?1",
            params![
                media_id,
                sha256,
                size as i64,
                storage_path.to_string_lossy()
            ],
        )?;
        add_tag_in_transaction(&transaction, media_id, generated_tag)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn copy_media_metadata(
        &self,
        source_ids: &[i64],
        target_id: i64,
        generated_tag: &str,
    ) -> CoreResult<()> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        let target_exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM media_asset WHERE id=?1)",
            [target_id],
            |row| row.get(0),
        )?;
        if !target_exists {
            return Err(crate::error::CoreError::InvalidConfig(
                "target media item does not exist".into(),
            ));
        }

        let mut favorite = false;
        let mut note = None;
        for source_id in source_ids {
            let source_favorite: Option<bool> = transaction
                .query_row(
                    "SELECT favorite<>0 FROM media_asset WHERE id=?1",
                    [source_id],
                    |row| row.get(0),
                )
                .optional()?;
            let Some(source_favorite) = source_favorite else {
                continue;
            };
            favorite |= source_favorite;
            if note.is_none() {
                note = transaction
                    .query_row(
                        "SELECT text FROM note WHERE media_id=?1 AND trim(text)<>''",
                        [source_id],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()?;
            }
            transaction.execute(
                "INSERT OR IGNORE INTO media_tag(media_id, tag_id)
                 SELECT ?2, tag_id FROM media_tag WHERE media_id=?1",
                params![source_id, target_id],
            )?;
            transaction.execute(
                "INSERT OR IGNORE INTO album_media(album_id, media_id)
                 SELECT am.album_id, ?2 FROM album_media am
                 JOIN album a ON a.id=am.album_id
                 WHERE am.media_id=?1 AND a.album_type='manual'",
                params![source_id, target_id],
            )?;
        }
        transaction.execute(
            "UPDATE media_asset SET favorite=?2 WHERE id=?1",
            params![target_id, favorite],
        )?;
        if let Some(note) = note {
            transaction.execute(
                "INSERT INTO note(media_id, text, updated_at) VALUES (?1, ?2, ?3)
                 ON CONFLICT(media_id) DO UPDATE SET text=excluded.text, updated_at=excluded.updated_at",
                params![target_id, note, Utc::now().to_rfc3339()],
            )?;
        }
        add_tag_in_transaction(&transaction, target_id, generated_tag)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn list_media_storage_entries(&self) -> CoreResult<Vec<MediaStorageEntry>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT id, sha256, storage_path, media_type
             FROM media_asset WHERE status='ready' ORDER BY id",
        )?;
        let entries = statement
            .query_map([], |row| {
                let kind: String = row.get(3)?;
                Ok(MediaStorageEntry {
                    id: row.get(0)?,
                    sha256: row.get(1)?,
                    storage_path: row.get(2)?,
                    kind: if kind == "video" {
                        MediaKind::Video
                    } else {
                        MediaKind::Image
                    },
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(entries)
    }

    pub fn media_export_entries(&self, media_ids: &[i64]) -> CoreResult<Vec<MediaExportEntry>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut entries = Vec::with_capacity(media_ids.len());
        for media_id in media_ids {
            let entry = connection
                .query_row(
                    "SELECT ma.id, ma.original_name, ma.storage_path, ma.game_name,
                            COALESCE(ma.captured_at, ma.imported_at),
                            COALESCE(n.text, ''),
                            COALESCE((
                              SELECT group_concat(name, char(31)) FROM (
                                SELECT t.name AS name
                                FROM media_tag mt
                                JOIN tag t ON t.id=mt.tag_id
                                WHERE mt.media_id=ma.id
                                ORDER BY t.name COLLATE NOCASE
                              )
                            ), '')
                     FROM media_asset ma
                     LEFT JOIN note n ON n.media_id=ma.id
                     WHERE ma.id=?1 AND ma.status='ready'",
                    [media_id],
                    |row| {
                        Ok((
                            row.get::<_, i64>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, String>(3)?,
                            row.get::<_, String>(4)?,
                            row.get::<_, String>(5)?,
                            row.get::<_, String>(6)?,
                        ))
                    },
                )
                .optional()?;
            let Some((id, original_name, storage_path, game_name, timestamp, note, tags)) = entry
            else {
                continue;
            };
            let timestamp = DateTime::parse_from_rfc3339(&timestamp)
                .map(|value| value.with_timezone(&Utc))
                .map_err(|error| {
                    crate::error::CoreError::Provider(format!(
                        "invalid stored export timestamp: {error}"
                    ))
                })?;
            entries.push(MediaExportEntry {
                id,
                original_name,
                storage_path,
                game_name,
                timestamp,
                tags: tags
                    .split('\u{1f}')
                    .filter(|value| !value.is_empty())
                    .map(ToOwned::to_owned)
                    .collect(),
                note,
            });
        }
        Ok(entries)
    }

    pub fn delete_media_record(&self, media_id: i64) -> CoreResult<()> {
        let changed = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .execute("DELETE FROM media_asset WHERE id=?1", [media_id])?;
        if changed == 0 {
            return Err(crate::error::CoreError::InvalidConfig(
                "media item does not exist".into(),
            ));
        }
        Ok(())
    }

    pub fn relocate_media_paths_and_settings(
        &self,
        paths: &[(i64, String)],
        settings: &AppSettings,
    ) -> CoreResult<()> {
        let mut connection = self.connection.lock().expect("database mutex poisoned");
        let transaction = connection.transaction()?;
        for (media_id, path) in paths {
            transaction.execute(
                "UPDATE media_asset SET storage_path=?2 WHERE id=?1",
                params![media_id, path],
            )?;
        }
        transaction.execute(
            "INSERT INTO app_setting(key, value_json, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at",
            params![
                "app.settings",
                serde_json::to_string(settings)?,
                Utc::now().to_rfc3339()
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn list_media(&self, query: &GalleryQuery) -> CoreResult<Vec<MediaAsset>> {
        let mut media = self.load_all_media()?;
        media.retain(|asset| match query.kind {
            GalleryKindFilter::All => true,
            GalleryKindFilter::Image => asset.kind == MediaKind::Image,
            GalleryKindFilter::Video => asset.kind == MediaKind::Video,
        });
        if query.favorite_only {
            media.retain(|asset| asset.favorite);
        }
        if !query.game_names.is_empty() {
            media.retain(|asset| query.game_names.contains(&asset.game_name));
        }
        if query.captured_from.is_some() || query.captured_until.is_some() {
            media.retain(|asset| {
                let timestamp = asset.captured_at.unwrap_or(asset.imported_at);
                query.captured_from.is_none_or(|from| timestamp >= from)
                    && query.captured_until.is_none_or(|until| timestamp < until)
            });
        }
        if let Some(album_id) = query.album_id {
            let (album_type, system_key, rules, manual_ids) = self.album_filter(album_id)?;
            if system_key.as_deref() == Some("favorites") {
                media.retain(|asset| asset.favorite);
            } else if album_type == "smart" {
                media.retain(|asset| matches_album_rules(asset, &rules));
            } else {
                media.retain(|asset| manual_ids.contains(&asset.id));
            }
        }
        if !query.newest_first {
            media.reverse();
        }
        let start = query.offset as usize;
        let end = start
            .saturating_add(query.limit.clamp(1, 500) as usize)
            .min(media.len());
        if start >= media.len() {
            return Ok(Vec::new());
        }
        Ok(media[start..end].to_vec())
    }

    fn load_all_media(&self) -> CoreResult<Vec<MediaAsset>> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let mut statement = connection.prepare(
            "SELECT m.id, m.sha256, m.original_name, m.storage_path, m.media_type,
                    m.captured_at, m.imported_at, m.game_title_id, m.game_name,
                    m.favorite, n.text
             FROM media_asset m LEFT JOIN note n ON n.media_id=m.id
             WHERE m.status='ready'
             ORDER BY COALESCE(m.captured_at, m.imported_at) DESC, m.id DESC",
        )?;
        let base_rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, String>(8)?,
                row.get::<_, i64>(9)? != 0,
                row.get::<_, Option<String>>(10)?,
            ))
        })?;
        let mut media = Vec::new();
        for row in base_rows {
            let (
                id,
                sha256,
                original_name,
                storage_path,
                kind,
                captured,
                imported,
                title_id,
                game_name,
                favorite,
                note,
            ) = row?;
            let mut tag_statement = connection.prepare(
                "SELECT t.name FROM tag t JOIN media_tag mt ON mt.tag_id=t.id
                 WHERE mt.media_id=?1 ORDER BY t.name COLLATE NOCASE",
            )?;
            let tags = tag_statement
                .query_map([id], |row| row.get(0))?
                .collect::<Result<Vec<String>, _>>()?;
            media.push(MediaAsset {
                id,
                sha256,
                original_name,
                storage_path,
                kind: if kind == "video" {
                    MediaKind::Video
                } else {
                    MediaKind::Image
                },
                captured_at: parse_datetime(captured.as_deref())?,
                imported_at: parse_datetime(Some(&imported))?.unwrap_or_else(Utc::now),
                game_title_id: title_id,
                game_name,
                favorite,
                note,
                tags,
            });
        }
        Ok(media)
    }

    fn album_filter(&self, album_id: i64) -> CoreResult<AlbumFilter> {
        let connection = self.connection.lock().expect("database mutex poisoned");
        let (album_type, system_key) = connection.query_row(
            "SELECT album_type, system_key FROM album WHERE id=?1",
            [album_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let mut rule_statement = connection.prepare(
            "SELECT rule_group, field, operator, value FROM album_rule
             WHERE album_id=?1 ORDER BY rule_group, id",
        )?;
        let rules = rule_statement
            .query_map([album_id], |row| {
                Ok(AlbumRule {
                    rule_group: row.get(0)?,
                    field: row.get(1)?,
                    operator: row.get(2)?,
                    value: row.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut media_statement =
            connection.prepare("SELECT media_id FROM album_media WHERE album_id=?1")?;
        let manual_ids = media_statement
            .query_map([album_id], |row| row.get(0))?
            .collect::<Result<std::collections::HashSet<i64>, _>>()?;
        Ok((album_type, system_key, rules, manual_ids))
    }

    pub fn set_setting<T: Serialize>(&self, key: &str, value: &T) -> CoreResult<()> {
        self.connection.lock().expect("database mutex poisoned").execute(
            "INSERT INTO app_setting(key, value_json, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at",
            params![key, serde_json::to_string(value)?, Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub fn get_setting<T: DeserializeOwned>(&self, key: &str) -> CoreResult<Option<T>> {
        let json: Option<String> = self
            .connection
            .lock()
            .expect("database mutex poisoned")
            .query_row(
                "SELECT value_json FROM app_setting WHERE key = ?1",
                [key],
                |row| row.get(0),
            )
            .optional()?;
        json.map(|value| serde_json::from_str(&value).map_err(Into::into))
            .transpose()
    }
}

fn add_tag_in_transaction(
    transaction: &rusqlite::Transaction<'_>,
    media_id: i64,
    name: &str,
) -> CoreResult<()> {
    let name = name.trim();
    if name.is_empty() {
        return Err(crate::error::CoreError::InvalidConfig(
            "tag cannot be empty".into(),
        ));
    }
    let normalized = name.to_lowercase();
    transaction.execute(
        "INSERT OR IGNORE INTO tag(name, normalized_name, created_at) VALUES (?1, ?2, ?3)",
        params![name, normalized, Utc::now().to_rfc3339()],
    )?;
    let tag_id: i64 = transaction.query_row(
        "SELECT id FROM tag WHERE normalized_name=?1",
        [normalized],
        |row| row.get(0),
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO media_tag(media_id, tag_id) VALUES (?1, ?2)",
        params![media_id, tag_id],
    )?;
    Ok(())
}

fn source_game_names_for_display(
    transaction: &rusqlite::Transaction<'_>,
    display_name: &str,
) -> CoreResult<Vec<String>> {
    let mut statement = transaction.prepare(
        "SELECT DISTINCT NULLIF(TRIM(source_game_name), '')
         FROM media_asset
         WHERE game_name=?1 COLLATE NOCASE",
    )?;
    let mut names = statement
        .query_map([display_name], |row| row.get::<_, Option<String>>(0))?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    if names.is_empty() {
        names.push(display_name.trim().to_owned());
    }
    Ok(names)
}

fn upsert_game_tag_alias(
    transaction: &rusqlite::Transaction<'_>,
    source_name: &str,
    target_name: &str,
) -> CoreResult<()> {
    let source_name = source_name.trim();
    let target_name = target_name.trim();
    if source_name.is_empty() || target_name.is_empty() {
        return Ok(());
    }
    transaction.execute(
        "INSERT INTO game_tag_alias(
           source_name, target_name, is_intermediate
         ) VALUES (?1, ?2, 0)
         ON CONFLICT(source_name) DO UPDATE SET
           target_name=excluded.target_name,
           is_intermediate=0",
        params![source_name, target_name],
    )?;
    Ok(())
}

fn resolve_game_tag_alias(
    transaction: &rusqlite::Transaction<'_>,
    source_name: &str,
) -> CoreResult<String> {
    let mut current = source_name.trim().to_owned();
    let mut visited = std::collections::HashSet::new();
    loop {
        let key = current.to_lowercase();
        if !visited.insert(key) {
            return Err(crate::error::CoreError::InvalidConfig(format!(
                "game tag alias cycle detected at '{current}'"
            )));
        }
        let next = transaction
            .query_row(
                "SELECT target_name FROM game_tag_alias
                 WHERE source_name=?1 COLLATE NOCASE",
                [&current],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(next) = next else {
            return Ok(current);
        };
        if next.trim().is_empty() {
            return Ok(current);
        }
        current = next.trim().to_owned();
    }
}

fn rewrite_generated_name(name: &str, old_game_name: &str, new_game_name: &str) -> String {
    let old_prefixes = [
        format!("{} - ", crate::album::sanitize_game_folder(old_game_name)),
        format!("{old_game_name} - "),
    ];
    let new_prefix = format!("{} - ", crate::album::sanitize_game_folder(new_game_name));
    old_prefixes
        .iter()
        .find_map(|prefix| name.strip_prefix(prefix))
        .map(|suffix| format!("{new_prefix}{suffix}"))
        .unwrap_or_else(|| name.to_owned())
}

fn rewrite_generated_media_names(
    transaction: &rusqlite::Transaction<'_>,
    old_game_name: &str,
    new_game_name: &str,
) -> CoreResult<()> {
    let names = {
        let mut statement = transaction.prepare(
            "SELECT id, original_name
             FROM media_asset
             WHERE game_name=?1 COLLATE NOCASE",
        )?;
        let rows = statement
            .query_map([old_game_name], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    for (media_id, original_name) in names {
        let rewritten = rewrite_generated_name(&original_name, old_game_name, new_game_name);
        if rewritten != original_name {
            transaction.execute(
                "UPDATE media_asset SET original_name=?1 WHERE id=?2",
                params![rewritten, media_id],
            )?;
        }
    }
    Ok(())
}

fn kind_name(kind: MediaKind) -> &'static str {
    match kind {
        MediaKind::Image => "image",
        MediaKind::Video => "video",
    }
}

fn to_text(value: Option<DateTime<Utc>>) -> Option<String> {
    value.map(|value| value.to_rfc3339())
}

fn parse_datetime(value: Option<&str>) -> CoreResult<Option<DateTime<Utc>>> {
    value
        .map(|value| {
            DateTime::parse_from_rfc3339(value)
                .map(|value| value.with_timezone(&Utc))
                .map_err(|error| {
                    crate::error::CoreError::Provider(format!("invalid stored timestamp: {error}"))
                })
        })
        .transpose()
}

fn backfill_legacy_nso_names(connection: &Connection) -> CoreResult<()> {
    let mut statement = connection.prepare(
        "SELECT m.id, m.sha256, m.original_name, m.game_name, m.media_type,
                m.captured_at, m.uploaded_at, m.imported_at,
                (SELECT s.remote_id FROM media_source s
                 WHERE s.media_id = m.id AND s.source_type = 'nso'
                 ORDER BY s.id LIMIT 1)
         FROM media_asset m
         WHERE EXISTS (
           SELECT 1 FROM media_source s
           WHERE s.media_id = m.id AND s.source_type = 'nso'
         )",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, String>(7)?,
                row.get::<_, Option<String>>(8)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);

    for (
        id,
        sha256,
        original_name,
        game_name,
        media_type,
        captured,
        uploaded,
        imported,
        remote_id,
    ) in rows
    {
        if !is_hash_fallback_name(&original_name, &sha256) {
            continue;
        }
        let timestamp = captured
            .as_deref()
            .or(uploaded.as_deref())
            .unwrap_or(&imported);
        let Ok(timestamp) = DateTime::parse_from_rfc3339(timestamp) else {
            continue;
        };
        let kind = if media_type.eq_ignore_ascii_case("video") {
            MediaKind::Video
        } else {
            MediaKind::Image
        };
        let readable_name = readable_media_name(
            &game_name,
            timestamp.with_timezone(&Utc),
            remote_id.as_deref(),
            kind,
        );
        connection.execute(
            "UPDATE media_asset SET original_name = ?1 WHERE id = ?2",
            params![readable_name, id],
        )?;
    }
    Ok(())
}

fn backfill_mtp_display_names(connection: &Connection) -> CoreResult<()> {
    let entries = {
        let mut statement = connection.prepare(
            "SELECT DISTINCT ma.id, ma.game_name, ma.media_type, ma.captured_at,
                    ms.source_path
             FROM media_asset ma
             JOIN media_source ms ON ms.media_id=ma.id
             WHERE ms.source_type='mtp' AND ma.captured_at IS NOT NULL",
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for (index, (media_id, game_name, media_type, captured_at, source_path)) in
        entries.into_iter().enumerate()
    {
        let Ok(timestamp) = DateTime::parse_from_rfc3339(&captured_at) else {
            continue;
        };
        let sequence = source_path
            .as_deref()
            .and_then(mtp_sequence_from_path)
            .unwrap_or((index + 1) as u32);
        let name = readable_import_media_name(
            &game_name,
            timestamp.with_timezone(&Utc),
            sequence,
            kind_from_type(&media_type),
        );
        connection.execute(
            "UPDATE media_asset SET original_name=?1 WHERE id=?2",
            params![name, media_id],
        )?;
    }
    Ok(())
}

fn migrate_game_tag_aliases(transaction: &rusqlite::Transaction<'_>) -> CoreResult<()> {
    let aliases = {
        let mut statement = transaction.prepare(
            "SELECT source_name, target_name
             FROM game_tag_alias
             ORDER BY source_name COLLATE NOCASE",
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    let direct = aliases
        .iter()
        .map(|(source, target)| (source.to_lowercase(), target.clone()))
        .collect::<std::collections::HashMap<_, _>>();
    let intermediate_sources = aliases
        .iter()
        .map(|(_, target)| target.to_lowercase())
        .collect::<std::collections::HashSet<_>>();

    for (source, target) in &aliases {
        let final_target = resolve_alias_from_map(target, &direct)?;
        transaction.execute(
            "UPDATE game_tag_alias
             SET target_name=?1, is_intermediate=?2
             WHERE source_name=?3 COLLATE NOCASE",
            params![
                final_target,
                intermediate_sources.contains(&source.to_lowercase()) as i64,
                source
            ],
        )?;
    }

    let game_names = {
        let mut statement = transaction.prepare(
            "SELECT DISTINCT game_name FROM media_asset
             WHERE TRIM(game_name) <> ''",
        )?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for old_name in game_names {
        let final_name = resolve_game_tag_alias(transaction, &old_name)?;
        if old_name.eq_ignore_ascii_case(&final_name) {
            continue;
        }
        rewrite_generated_media_names(transaction, &old_name, &final_name)?;
        transaction.execute(
            "UPDATE media_asset SET game_name=?1
             WHERE game_name=?2 COLLATE NOCASE",
            params![final_name, old_name],
        )?;
        transaction.execute(
            "UPDATE album_rule SET value=?1
             WHERE field IN ('game', 'game_tag')
               AND lower(trim(value))=?2",
            params![final_name, old_name.to_lowercase()],
        )?;
        let usage = transaction
            .query_row(
                "SELECT selection_count FROM game_filter_usage
                 WHERE game_name=?1 COLLATE NOCASE",
                [&old_name],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .unwrap_or(0);
        transaction.execute(
            "DELETE FROM game_filter_usage WHERE game_name=?1 COLLATE NOCASE",
            [&old_name],
        )?;
        if usage > 0 {
            transaction.execute(
                "INSERT INTO game_filter_usage(game_name, selection_count, last_selected_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(game_name) DO UPDATE SET
                   selection_count=selection_count + excluded.selection_count,
                   last_selected_at=excluded.last_selected_at",
                params![final_name, usage, Utc::now().to_rfc3339()],
            )?;
        }
    }
    Ok(())
}

fn migrate_hidden_source_game_names(transaction: &rusqlite::Transaction<'_>) -> CoreResult<()> {
    let visible_aliases = {
        let mut statement = transaction.prepare(
            "SELECT source_name, target_name
             FROM game_tag_alias
             WHERE is_intermediate=0
             ORDER BY source_name COLLATE NOCASE",
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    for (source_name, target_name) in visible_aliases {
        transaction.execute(
            "UPDATE media_asset
             SET source_game_name=?1
             WHERE game_name=?2 COLLATE NOCASE
               AND TRIM(source_game_name) = ''",
            params![source_name, target_name],
        )?;
    }
    transaction.execute(
        "UPDATE media_asset
         SET source_game_name=game_name
         WHERE TRIM(source_game_name) = ''",
        [],
    )?;
    transaction.execute("DELETE FROM game_tag_alias WHERE is_intermediate=1", [])?;
    transaction.execute("UPDATE game_tag_alias SET is_intermediate=0", [])?;
    Ok(())
}

fn ensure_required_columns(connection: &Connection) -> CoreResult<()> {
    let required = [
        ("album", "description", "TEXT NOT NULL DEFAULT ''"),
        (
            "game_tag_alias",
            "is_intermediate",
            "INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "media_asset",
            "source_game_name",
            "TEXT NOT NULL DEFAULT ''",
        ),
    ];
    for (table, column, definition) in required {
        let exists: bool = connection
            .prepare(&format!("PRAGMA table_info({table})"))?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?
            .iter()
            .any(|name| name == column);
        if !exists {
            connection.execute(
                &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
                [],
            )?;
        }
    }
    Ok(())
}

fn resolve_alias_from_map(
    source_name: &str,
    aliases: &std::collections::HashMap<String, String>,
) -> CoreResult<String> {
    let mut current = source_name.trim().to_owned();
    let mut visited = std::collections::HashSet::new();
    loop {
        if !visited.insert(current.to_lowercase()) {
            return Err(crate::error::CoreError::InvalidConfig(format!(
                "game tag alias cycle detected at '{current}'"
            )));
        }
        let Some(next) = aliases.get(&current.to_lowercase()) else {
            return Ok(current);
        };
        current = next.trim().to_owned();
    }
}

fn mtp_sequence_from_path(value: &str) -> Option<u32> {
    let stem = Path::new(value).file_stem()?.to_str()?;
    let prefix = stem.get(..16)?;
    if !prefix.chars().all(|character| character.is_ascii_digit()) {
        return None;
    }
    prefix.get(14..16)?.parse().ok()
}

fn is_hash_fallback_name(name: &str, sha256: &str) -> bool {
    sha256.len() == 64
        && sha256.chars().all(|ch| ch.is_ascii_hexdigit())
        && Path::new(name)
            .file_stem()
            .and_then(|value| value.to_str())
            .is_some_and(|stem| stem.eq_ignore_ascii_case(sha256))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::SourceType;

    #[test]
    fn creates_default_favorites_album() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let count: i64 = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM album WHERE system_key='favorites'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn migrates_album_descriptions_from_schema_v2() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite3");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE schema_version(version INTEGER NOT NULL);
                     INSERT INTO schema_version(version) VALUES (2);
                     CREATE TABLE album(
                       id INTEGER PRIMARY KEY,
                       name TEXT NOT NULL,
                       album_type TEXT NOT NULL,
                       pinned INTEGER NOT NULL DEFAULT 0,
                       system_key TEXT UNIQUE,
                       created_at TEXT NOT NULL,
                       updated_at TEXT NOT NULL
                     );
                     INSERT INTO album(name, album_type, created_at, updated_at)
                     VALUES ('Legacy', 'manual', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
                )
                .unwrap();
        }

        let database = Database::open(&path).unwrap();
        let legacy = database
            .list_albums()
            .unwrap()
            .into_iter()
            .find(|album| album.name == "Legacy")
            .unwrap();
        assert_eq!(legacy.description, "");
        let version: i64 = database
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT version FROM schema_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, 7);
    }

    #[test]
    fn repairs_missing_required_columns_when_schema_version_is_current() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite3");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE schema_version(version INTEGER NOT NULL);
                     INSERT INTO schema_version(version) VALUES (7);
                     CREATE TABLE album(
                       id INTEGER PRIMARY KEY, name TEXT NOT NULL,
                       album_type TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
                       system_key TEXT UNIQUE, created_at TEXT NOT NULL,
                       updated_at TEXT NOT NULL
                     );
                     CREATE TABLE game_tag_alias(
                       source_name TEXT PRIMARY KEY COLLATE NOCASE,
                       target_name TEXT NOT NULL
                     );
                     CREATE TABLE media_asset(
                       id INTEGER PRIMARY KEY, sha256 TEXT NOT NULL UNIQUE,
                       size INTEGER NOT NULL, media_type TEXT NOT NULL,
                       captured_at TEXT, game_title_id TEXT,
                       imported_at TEXT NOT NULL, game_name TEXT NOT NULL,
                       original_name TEXT NOT NULL, storage_path TEXT NOT NULL,
                       status TEXT NOT NULL
                     );",
                )
                .unwrap();
        }

        let database = Database::open(&path).unwrap();
        let connection = database.connection.lock().unwrap();
        for (table, column) in [
            ("album", "description"),
            ("game_tag_alias", "is_intermediate"),
            ("media_asset", "source_game_name"),
        ] {
            let found: i64 = connection
                .query_row(
                    &format!(
                        "SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name='{column}'"
                    ),
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(found, 1, "missing {table}.{column}");
        }
    }

    #[test]
    fn protects_the_system_favorites_album() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let favorites = database
            .list_albums()
            .unwrap()
            .into_iter()
            .find(|album| album.system_key.as_deref() == Some("favorites"))
            .unwrap();

        assert!(database
            .update_album(favorites.id, "Renamed", "", false)
            .is_err());
        assert!(database.delete_album(favorites.id).is_err());
    }

    #[test]
    fn converting_smart_album_to_manual_preserves_current_matches() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let media_id = {
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, 'Splatoon 3',
                               'capture.jpg', 'capture.jpg', 'ready')",
                    params!["a".repeat(64), Utc::now().to_rfc3339()],
                )
                .unwrap();
            connection.last_insert_rowid()
        };
        database.add_tag(media_id, "festival").unwrap();
        let album_id = database
            .create_album("Festival", "Festival highlights", true)
            .unwrap();
        database
            .replace_album_rules(
                album_id,
                &[AlbumRule {
                    rule_group: 0,
                    field: "tag".into(),
                    operator: "equals".into(),
                    value: "festival".into(),
                }],
            )
            .unwrap();

        database
            .update_album(album_id, "Festival archive", "Archived matches", false)
            .unwrap();
        database.replace_tags(media_id, &[]).unwrap();

        let album = database
            .list_albums()
            .unwrap()
            .into_iter()
            .find(|album| album.id == album_id)
            .unwrap();
        assert_eq!(album.album_type, "manual");
        assert_eq!(album.name, "Festival archive");
        assert_eq!(album.description, "Archived matches");
        assert_eq!(album.media_count, 1);
        assert!(database.list_album_rules(album_id).unwrap().is_empty());
    }

    #[test]
    fn counts_album_media_with_the_same_membership_rules_as_gallery_queries() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        let mut media_ids = Vec::new();
        {
            let connection = database.connection.lock().unwrap();
            for (index, favorite, status) in [
                (1, true, "ready"),
                (2, false, "ready"),
                (3, false, "ready"),
                (4, true, "failed"),
            ] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, favorite, status
                         ) VALUES (?1, 42, 'image', ?2, 'Game', ?3, ?3, ?4, ?5)",
                        params![
                            format!("{index:064x}"),
                            &now,
                            format!("media-{index}.jpg"),
                            favorite,
                            status,
                        ],
                    )
                    .unwrap();
                media_ids.push(connection.last_insert_rowid());
            }
        }

        let manual_album = database.create_album("Manual", "", false).unwrap();
        database
            .add_media_to_album(manual_album, media_ids[2])
            .unwrap();
        let smart_album = database.create_album("Smart", "", true).unwrap();
        database.add_tag(media_ids[1], "庆典").unwrap();
        database
            .replace_album_rules(
                smart_album,
                &[AlbumRule {
                    rule_group: 0,
                    field: "tag".into(),
                    operator: "equals".into(),
                    value: "庆典".into(),
                }],
            )
            .unwrap();

        let albums = database.list_albums().unwrap();
        let count = |name: &str| {
            albums
                .iter()
                .find(|album| album.name == name)
                .unwrap()
                .media_count
        };
        assert_eq!(count("收藏"), 1);
        assert_eq!(count("Manual"), 1);
        assert_eq!(count("Smart"), 1);
    }

    #[test]
    fn reports_current_sync_progress() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        database.begin_sync_job("job-1", "nso_coral", None).unwrap();
        database
            .update_sync_job("job-1", "running", 10, 3, 1, None, None)
            .unwrap();

        let progress = database
            .current_sync_progress("nso_coral")
            .unwrap()
            .unwrap();
        assert_eq!(progress.total_items, 10);
        assert_eq!(progress.synchronized_items, 3);
        assert_eq!(progress.failed_items, 1);
        assert_eq!(progress.processed_items, 4);
    }

    #[test]
    fn keeps_sync_cursors_separate_by_nintendo_account() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        database
            .begin_sync_job("job-a", "nso_coral:account-a", Some("cursor-a"))
            .unwrap();
        database
            .begin_sync_job("job-b", "nso_coral:account-b", Some("cursor-b"))
            .unwrap();

        assert_eq!(
            database
                .latest_sync_cursor("nso_coral:account-a")
                .unwrap()
                .as_deref(),
            Some("cursor-a")
        );
        assert_eq!(
            database
                .latest_sync_cursor("nso_coral:account-b")
                .unwrap()
                .as_deref(),
            Some("cursor-b")
        );
    }

    #[test]
    fn lists_media_in_requested_capture_time_order() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        {
            let connection = database.connection.lock().unwrap();
            for (sha, name, captured) in [
                ("a".repeat(64), "older.jpg", "2026-10-01T08:00:00+00:00"),
                ("b".repeat(64), "newer.jpg", "2026-10-03T08:00:00+00:00"),
            ] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, captured_at, imported_at,
                           game_name, original_name, storage_path
                         ) VALUES (?1, 42, 'image', ?2, ?2, 'Game', ?3, ?3)",
                        params![sha, captured, name],
                    )
                    .unwrap();
            }
        }

        let newest = database.list_media(&GalleryQuery::default()).unwrap();
        assert_eq!(newest[0].original_name, "newer.jpg");

        let oldest = database
            .list_media(&GalleryQuery {
                newest_first: false,
                ..GalleryQuery::default()
            })
            .unwrap();
        assert_eq!(oldest[0].original_name, "older.jpg");
    }

    #[test]
    fn lists_distinct_game_tags_from_the_whole_library() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        {
            let connection = database.connection.lock().unwrap();
            for (index, game) in ["Zelda", "Splatoon 3", "Zelda"].into_iter().enumerate() {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at,
                           game_name, original_name, storage_path
                         ) VALUES (?1, 42, 'image', ?2, ?3, ?4, ?4)",
                        params![
                            format!("{:064x}", index + 1),
                            Utc::now().to_rfc3339(),
                            game,
                            format!("game-{index}.jpg")
                        ],
                    )
                    .unwrap();
            }
        }

        assert_eq!(
            database.list_game_tags().unwrap(),
            vec![
                GameTagSummary {
                    name: "Zelda".into(),
                    image_count: 2,
                    video_count: 0,
                    selection_count: 0,
                },
                GameTagSummary {
                    name: "Splatoon 3".into(),
                    image_count: 1,
                    video_count: 0,
                    selection_count: 0,
                },
            ]
        );

        database.record_game_tag_selection("Splatoon 3").unwrap();
        database.record_game_tag_selection("Splatoon 3").unwrap();
        let ranked = database.list_game_tags().unwrap();
        assert_eq!(ranked[0].name, "Splatoon 3");
        assert_eq!(ranked[0].selection_count, 2);
    }

    #[test]
    fn manages_custom_tags_and_reports_media_usage() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        let media_ids = {
            let connection = database.connection.lock().unwrap();
            let mut ids = Vec::new();
            for (index, media_type) in [(1, "image"), (2, "video")] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, status
                         ) VALUES (?1, 42, ?2, ?3, 'Game', ?4, ?4, 'ready')",
                        params![
                            format!("{index:064x}"),
                            media_type,
                            &now,
                            format!("media-{index}")
                        ],
                    )
                    .unwrap();
                ids.push(connection.last_insert_rowid());
            }
            ids
        };
        let tag_id = database.add_tag(media_ids[0], "庆典").unwrap();
        database.add_tag(media_ids[1], "庆典").unwrap();
        let smart_album = database.create_album("庆典相册", "", true).unwrap();
        database
            .replace_album_rules(
                smart_album,
                &[AlbumRule {
                    rule_group: 0,
                    field: "tag".into(),
                    operator: "equals".into(),
                    value: "庆典".into(),
                }],
            )
            .unwrap();

        assert_eq!(
            database.list_tag_usage().unwrap(),
            vec![TagUsageSummary {
                id: tag_id,
                name: "庆典".into(),
                image_count: 1,
                video_count: 1,
            }]
        );

        database.rename_tag(tag_id, "祭典").unwrap();
        assert_eq!(database.list_tags().unwrap(), vec!["祭典".to_string()]);
        assert_eq!(
            database
                .list_albums()
                .unwrap()
                .into_iter()
                .find(|album| album.id == smart_album)
                .unwrap()
                .media_count,
            2
        );

        database.delete_tag(tag_id).unwrap();
        assert!(database.list_tag_usage().unwrap().is_empty());
        assert!(database
            .list_media(&GalleryQuery::default())
            .unwrap()
            .iter()
            .all(|media| media.tags.is_empty()));
    }

    #[test]
    fn creates_unassigned_custom_tags() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();

        let tag_id = database.create_tag("旅行").unwrap();
        let tags = database.list_tag_usage().unwrap();

        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].id, tag_id);
        assert_eq!(tags[0].name, "旅行");
        assert_eq!(tags[0].image_count, 0);
        assert_eq!(tags[0].video_count, 0);
        assert!(database.create_tag("旅行").is_err());
    }

    #[test]
    fn merges_custom_tags_and_updates_smart_rules() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        let media_ids = {
            let connection = database.connection.lock().unwrap();
            let mut ids = Vec::new();
            for index in 1..=2 {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, status
                         ) VALUES (?1, 42, 'image', ?2, 'Game', ?3, ?3, 'ready')",
                        params![format!("{index:064x}"), &now, format!("media-{index}.jpg")],
                    )
                    .unwrap();
                ids.push(connection.last_insert_rowid());
            }
            ids
        };
        let first = database.add_tag(media_ids[0], "Ranked").unwrap();
        let second = database.add_tag(media_ids[1], "Anarchy").unwrap();
        let album_id = database.create_album("Modes", "", true).unwrap();
        database
            .replace_album_rules(
                album_id,
                &[
                    AlbumRule {
                        rule_group: 0,
                        field: "tag".into(),
                        operator: "equals".into(),
                        value: "Ranked".into(),
                    },
                    AlbumRule {
                        rule_group: 1,
                        field: "tag".into(),
                        operator: "equals".into(),
                        value: "Anarchy".into(),
                    },
                ],
            )
            .unwrap();

        database
            .merge_tags(&[first, second], "Competitive")
            .unwrap();

        assert_eq!(database.list_tags().unwrap(), vec!["Competitive"]);
        assert!(database
            .list_media(&GalleryQuery::default())
            .unwrap()
            .iter()
            .all(|media| media.tags == ["Competitive"]));
        assert!(database
            .list_album_rules(album_id)
            .unwrap()
            .iter()
            .all(|rule| rule.value == "Competitive"));
        assert_eq!(
            database
                .list_albums()
                .unwrap()
                .into_iter()
                .find(|album| album.id == album_id)
                .unwrap()
                .media_count,
            2
        );
    }

    #[test]
    fn merges_game_tags_and_applies_aliases_to_future_imports() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        {
            let connection = database.connection.lock().unwrap();
            for (index, game) in [(1, "Splatoon 3"), (2, "斯普拉遁3")] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, status
                         ) VALUES (?1, 42, 'image', ?2, ?3, ?4, ?4, 'ready')",
                        params![
                            format!("{index:064x}"),
                            &now,
                            game,
                            format!("game-{index}.jpg")
                        ],
                    )
                    .unwrap();
            }
        }
        database.record_game_tag_selection("Splatoon 3").unwrap();
        database.record_game_tag_selection("Splatoon 3").unwrap();
        database.record_game_tag_selection("斯普拉遁3").unwrap();
        let album_id = database.create_album("Splatoon", "", true).unwrap();
        database
            .replace_album_rules(
                album_id,
                &[AlbumRule {
                    rule_group: 0,
                    field: "game".into(),
                    operator: "equals".into(),
                    value: "斯普拉遁3".into(),
                }],
            )
            .unwrap();

        database
            .merge_game_tags(
                &["Splatoon 3".into(), "斯普拉遁3".into()],
                "Splatoon 3 / 斯普拉遁3",
            )
            .unwrap();

        let games = database.list_game_tags().unwrap();
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].name, "Splatoon 3 / 斯普拉遁3");
        assert_eq!(games[0].image_count, 2);
        assert_eq!(games[0].selection_count, 3);
        assert_eq!(
            database.list_album_rules(album_id).unwrap()[0].value,
            "Splatoon 3 / 斯普拉遁3"
        );

        let candidate = MediaCandidate {
            remote_id: None,
            title_id: None,
            game_name: "斯普拉遁3".into(),
            kind: MediaKind::Image,
            content_url: None,
            thumbnail_url: None,
            expected_size: None,
            captured_at: None,
            uploaded_at: None,
            expires_at: None,
            original_name: Some("future.jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Folder,
            source_path: Some("future.jpg".into()),
        };
        database
            .register_media(
                &"f".repeat(64),
                42,
                Path::new("future.jpg"),
                &candidate,
                None,
            )
            .unwrap();
        assert!(database
            .list_media(&GalleryQuery::default())
            .unwrap()
            .iter()
            .all(|media| media.game_name == "Splatoon 3 / 斯普拉遁3"));
    }

    #[test]
    fn renames_game_tag_and_applies_alias_to_future_imports() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        {
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, 'Zelda',
                               'Zelda - 2026-10-04 12-30-00 [12345678].jpg',
                               'originals/aa/bb/hash.jpg', 'ready')",
                    params!["1".repeat(64), now],
                )
                .unwrap();
        }

        database.rename_game_tag("Zelda", "塞尔达传说").unwrap();
        assert_eq!(database.list_game_tags().unwrap()[0].name, "塞尔达传说");
        let media = database.list_media(&GalleryQuery::default()).unwrap();
        assert_eq!(
            media[0].original_name,
            "塞尔达传说 - 2026-10-04 12-30-00 [12345678].jpg"
        );
        assert_eq!(media[0].storage_path, "originals/aa/bb/hash.jpg");
        assert_eq!(
            database
                .list_game_tag_aliases()
                .unwrap()
                .into_iter()
                .map(|alias| (alias.source_name, alias.target_name))
                .collect::<Vec<_>>(),
            vec![("Zelda".to_owned(), "塞尔达传说".to_owned())]
        );

        let candidate = MediaCandidate {
            remote_id: None,
            title_id: None,
            game_name: "Zelda".into(),
            kind: MediaKind::Image,
            content_url: None,
            thumbnail_url: None,
            expected_size: None,
            captured_at: None,
            uploaded_at: None,
            expires_at: None,
            original_name: Some("future.jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Mtp,
            source_path: Some("Nintendo Switch/Album/Zelda/future.jpg".into()),
        };
        database
            .register_media(
                &"2".repeat(64),
                42,
                Path::new("future.jpg"),
                &candidate,
                Some("Nintendo Switch"),
            )
            .unwrap();
        assert!(database
            .list_media(&GalleryQuery::default())
            .unwrap()
            .iter()
            .all(|media| media.game_name == "塞尔达传说"));
    }

    #[test]
    fn game_tag_replacement_preserves_custom_names_and_updates_merge_names() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        {
            let connection = database.connection.lock().unwrap();
            for (index, game, name) in [
                (1, "BOTW", "BOTW - 2026-10-04 12-30-00 [01].mp4"),
                (2, "The Legend of Zelda", "user-picked-name.jpg"),
            ] {
                connection
                    .execute(
                        "INSERT INTO media_asset(
                           sha256, size, media_type, imported_at, game_name,
                           original_name, storage_path, status
                         ) VALUES (?1, 42, ?2, ?3, ?4, ?5, ?5, 'ready')",
                        params![
                            format!("{index:064x}"),
                            if index == 1 { "video" } else { "image" },
                            &now,
                            game,
                            name
                        ],
                    )
                    .unwrap();
            }
        }

        database
            .merge_game_tags(&["BOTW".into(), "The Legend of Zelda".into()], "王国之泪")
            .unwrap();

        let mut media = database.list_media(&GalleryQuery::default()).unwrap();
        media.sort_by_key(|item| item.id);
        assert_eq!(
            media[0].original_name,
            "王国之泪 - 2026-10-04 12-30-00 [01].mp4"
        );
        assert_eq!(media[1].original_name, "user-picked-name.jpg");
        assert_eq!(
            database
                .list_game_tag_aliases()
                .unwrap()
                .into_iter()
                .map(|alias| (alias.source_name, alias.target_name))
                .collect::<Vec<_>>(),
            vec![
                ("BOTW".to_owned(), "王国之泪".to_owned()),
                ("The Legend of Zelda".to_owned(), "王国之泪".to_owned()),
            ]
        );
    }

    #[test]
    fn replacing_game_tag_with_existing_target_requires_merge() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        let connection = database.connection.lock().unwrap();
        for (index, game) in [(1, "BOTW"), (2, "王国之泪")] {
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, ?3, ?4, ?4, 'ready')",
                    params![
                        format!("{index:064x}"),
                        &now,
                        game,
                        format!("{game} - 2026-10-04 12-30-00 [01].jpg")
                    ],
                )
                .unwrap();
        }
        drop(connection);

        let error = database.rename_game_tag("BOTW", "王国之泪").unwrap_err();
        assert!(error.to_string().contains("merge"));
    }

    #[test]
    fn flattens_repeated_game_tag_replacements_and_resolves_new_media() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let now = Utc::now().to_rfc3339();
        {
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, source_game_name, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, 'A', 'A',
                               'A - 2026-10-04 12-30-00 [01].jpg',
                               'originals/aa/bb/a.jpg', 'ready')",
                    params!["a".repeat(64), &now],
                )
                .unwrap();
        }

        database.rename_game_tag("A", "B").unwrap();
        database.rename_game_tag("B", "C").unwrap();

        let aliases = database.list_game_tag_aliases().unwrap();
        assert_eq!(
            aliases
                .iter()
                .map(|alias| (&alias.source_name, &alias.target_name))
                .collect::<Vec<_>>(),
            vec![(&"A".to_owned(), &"C".to_owned())]
        );

        let candidate = MediaCandidate {
            remote_id: Some("remote-b".into()),
            title_id: None,
            game_name: "A".into(),
            kind: MediaKind::Image,
            content_url: None,
            thumbnail_url: None,
            expected_size: None,
            captured_at: Some(Utc::now()),
            uploaded_at: None,
            expires_at: None,
            original_name: Some("A - 2026-10-04 12-31-00 [02].jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Nso,
            source_path: None,
        };
        database
            .register_media(
                &"b".repeat(64),
                42,
                Path::new("originals/aa/bb/b.jpg"),
                &candidate,
                Some("nso"),
            )
            .unwrap();

        let mut media = database.list_media(&GalleryQuery::default()).unwrap();
        media.sort_by_key(|item| item.id);
        assert_eq!(media[0].game_name, "C");
        assert_eq!(media[0].original_name, "C - 2026-10-04 12-30-00 [01].jpg");
        assert_eq!(media[1].game_name, "C");
        assert_eq!(media[1].original_name, "C - 2026-10-04 12-31-00 [02].jpg");
    }

    #[test]
    fn migrates_legacy_alias_chain_and_repairs_media_names() {
        let directory = tempfile::tempdir().unwrap();
        {
            let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
            let connection = database.connection.lock().unwrap();
            let now = Utc::now().to_rfc3339();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, imported_at, game_name,
                       original_name, storage_path, status
                     ) VALUES (?1, 42, 'image', ?2, 'B',
                               'B - 2026-10-04 12-30-00 [01].jpg',
                               'originals/aa/bb/b.jpg', 'ready')",
                    params!["b".repeat(64), &now],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO game_tag_alias(
                       source_name, target_name, is_intermediate
                     ) VALUES ('A', 'B', 0), ('B', 'C', 0)",
                    [],
                )
                .unwrap();
            connection
                .execute("UPDATE schema_version SET version = 4", [])
                .unwrap();
        }

        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let aliases = database.list_game_tag_aliases().unwrap();
        assert_eq!(aliases.len(), 1);
        assert_eq!(aliases[0].source_name, "A");
        assert_eq!(aliases[0].target_name, "C");
        let media = database.list_media(&GalleryQuery::default()).unwrap();
        assert_eq!(media[0].game_name, "C");
        assert_eq!(media[0].original_name, "C - 2026-10-04 12-30-00 [01].jpg");
        let source_name: String = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT source_game_name FROM media_asset WHERE id=?1",
                [media[0].id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(source_name, "A");
    }

    #[test]
    fn rejects_game_tag_alias_cycles_during_import() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        {
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO game_tag_alias(
                       source_name, target_name, is_intermediate
                     ) VALUES ('A', 'B', 0), ('B', 'A', 0)",
                    [],
                )
                .unwrap();
        }
        let candidate = MediaCandidate {
            remote_id: None,
            title_id: None,
            game_name: "A".into(),
            kind: MediaKind::Image,
            content_url: None,
            thumbnail_url: None,
            expected_size: None,
            captured_at: None,
            uploaded_at: None,
            expires_at: None,
            original_name: Some("A - 2026-10-04 12-30-00 [01].jpg".into()),
            file_extension: Some("jpg".into()),
            source_type: SourceType::Nso,
            source_path: None,
        };
        let error = database
            .register_media(
                &"c".repeat(64),
                42,
                Path::new("originals/aa/bb/c.jpg"),
                &candidate,
                Some("nso"),
            )
            .unwrap_err();
        assert!(error.to_string().contains("cycle"));
    }

    #[test]
    fn backfills_readable_mtp_display_names() {
        let directory = tempfile::tempdir().unwrap();
        let database = Database::open(directory.path().join("library.sqlite3")).unwrap();
        let connection = database.connection.lock().unwrap();
        connection
            .execute(
                "INSERT INTO media_asset(
                   sha256, size, media_type, captured_at, imported_at, game_name,
                   original_name, storage_path, status
                 ) VALUES (?1, 42, 'image', ?2, ?2, 'Zelda', ?3, ?3, 'ready')",
                params![
                    "3".repeat(64),
                    "2026-10-05T08:09:10+00:00",
                    "2026100516091007.jpg"
                ],
            )
            .unwrap();
        let media_id = connection.last_insert_rowid();
        connection
            .execute(
                "INSERT INTO media_source(
                   media_id, source_type, source_path, provider, discovered_at
                 ) VALUES (?1, 'mtp', ?2, 'Nintendo Switch 2', ?3)",
                params![
                    media_id,
                    "Nintendo Switch 2/Album/Zelda/2026100516091007.jpg",
                    Utc::now().to_rfc3339()
                ],
            )
            .unwrap();

        backfill_mtp_display_names(&connection).unwrap();
        let name: String = connection
            .query_row(
                "SELECT original_name FROM media_asset WHERE id=?1",
                [media_id],
                |row| row.get(0),
            )
            .unwrap();
        assert!(name.starts_with("Zelda - 2026-10-05 "));
        assert!(name.ends_with("[07].jpg"));
    }

    #[test]
    fn migrates_legacy_nso_hash_name_to_readable_name() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite3");
        let sha256 = "a".repeat(64);
        {
            let database = Database::open(&path).unwrap();
            let connection = database.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO media_asset(
                       sha256, size, media_type, captured_at, imported_at,
                       game_name, original_name, storage_path
                     ) VALUES (?1, 42, 'image', ?2, ?2, 'Splatoon 3', ?3, 'originals/a.jpg')",
                    params![
                        &sha256,
                        "2026-10-04T07:30:12+00:00",
                        format!("{sha256}.jpg")
                    ],
                )
                .unwrap();
            let media_id = connection.last_insert_rowid();
            connection
                .execute(
                    "INSERT INTO media_source(
                       media_id, source_type, remote_id, provider, discovered_at
                     ) VALUES (?1, 'nso', 'remote-12345678', 'nso_coral', ?2)",
                    params![media_id, "2026-10-04T07:30:12+00:00"],
                )
                .unwrap();
            connection
                .execute("UPDATE schema_version SET version = 1", [])
                .unwrap();
        }

        let database = Database::open(&path).unwrap();
        let original_name: String = database
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT original_name FROM media_asset WHERE sha256 = ?1",
                [&sha256],
                |row| row.get(0),
            )
            .unwrap();
        assert!(original_name.starts_with("Splatoon 3 - 2026-10-04 "));
        assert!(original_name.ends_with("[12345678].jpg"));
    }
}
