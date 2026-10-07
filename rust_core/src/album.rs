use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Local, Utc};
use unicode_normalization::UnicodeNormalization;
use walkdir::WalkDir;

use crate::models::{MediaCandidate, MediaKind};

#[derive(Debug, Default)]
pub struct ExistingAlbumIndex {
    pub names_and_prefixes: HashSet<String>,
    pub folder_by_prefix: HashMap<String, String>,
}

#[derive(Debug, Clone)]
pub struct AlbumDestination {
    pub folder: PathBuf,
    pub filename: String,
    pub full_path: PathBuf,
}

pub fn capture_timestamp_prefix(timestamp: DateTime<Utc>) -> String {
    timestamp
        .with_timezone(&Local)
        .format("%Y%m%d%H%M%S00")
        .to_string()
}

pub fn readable_media_name(
    game_name: &str,
    timestamp: DateTime<Utc>,
    remote_id: Option<&str>,
    kind: MediaKind,
) -> String {
    let game_name = sanitize_game_folder(game_name);
    let timestamp = timestamp.with_timezone(&Local).format("%Y-%m-%d %H-%M-%S");
    let suffix = remote_id
        .map(|value| {
            value
                .chars()
                .filter(|ch| ch.is_ascii_alphanumeric())
                .collect::<String>()
        })
        .filter(|value| !value.is_empty())
        .map(|value| {
            let start = value.len().saturating_sub(8);
            format!(" [{}]", &value[start..])
        })
        .unwrap_or_default();
    format!("{game_name} - {timestamp}{suffix}.{}", kind.extension())
}

pub fn readable_import_media_name(
    game_name: &str,
    timestamp: DateTime<Utc>,
    sequence: u32,
    kind: MediaKind,
) -> String {
    let game_name = sanitize_game_folder(game_name);
    let timestamp = timestamp.with_timezone(&Local).format("%Y-%m-%d %H-%M-%S");
    format!(
        "{game_name} - {timestamp} [{sequence:02}].{}",
        kind.extension()
    )
}

pub fn sanitize_game_folder(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut previous_space = false;
    for ch in value.trim().chars() {
        let replacement = match ch {
            '‐' | '‑' | '‒' | '–' | '—' | '―' | '−' | '﹘' | '﹣' | '－' => {
                Some('-')
            }
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' | '\0'..='\u{1f}' => None,
            _ => Some(ch),
        };
        if let Some(ch) = replacement {
            if ch.is_whitespace() {
                if !previous_space && !result.is_empty() {
                    result.push(' ');
                    previous_space = true;
                }
            } else {
                result.push(ch);
                previous_space = false;
            }
        }
    }
    let cleaned = result.trim_end_matches([' ', '.']).trim();
    if cleaned.is_empty() {
        "Other".into()
    } else {
        cleaned.into()
    }
}

pub fn normalized_game_name(value: &str) -> String {
    value
        .nfkd()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

pub fn index_existing_album(root: &Path) -> ExistingAlbumIndex {
    let mut index = ExistingAlbumIndex::default();
    if !root.exists() {
        return index;
    }
    for entry in WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
    {
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        let filename = path
            .file_name()
            .and_then(|v| v.to_str())
            .unwrap_or_default();
        let lower = filename.to_lowercase();
        if lower.ends_with(".part") || lower.ends_with(".tmp") {
            continue;
        }
        if entry.metadata().map(|m| m.len() == 0).unwrap_or(true) {
            continue;
        }
        let mut prefix = path
            .file_stem()
            .and_then(|v| v.to_str())
            .unwrap_or_default()
            .to_string();
        if prefix.ends_with("_c") {
            prefix.truncate(prefix.len() - 2);
        } else if prefix.ends_with("-00") {
            prefix.truncate(prefix.len() - 3);
        }
        index.names_and_prefixes.insert(lower);
        index.names_and_prefixes.insert(prefix.to_lowercase());
        if let Some(folder) = path
            .parent()
            .and_then(Path::file_name)
            .and_then(|v| v.to_str())
        {
            index
                .folder_by_prefix
                .entry(prefix.to_lowercase())
                .or_insert_with(|| folder.into());
        }
    }
    index
}

pub fn resolve_game_folder(album_root: &Path, game_name: &str) -> String {
    let fallback = sanitize_game_folder(game_name);
    let target = normalized_game_name(game_name);
    let Ok(entries) = std::fs::read_dir(album_root) else {
        return fallback;
    };
    let directories: Vec<String> = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    if let Some(exact) = directories
        .iter()
        .find(|name| name.eq_ignore_ascii_case(&fallback))
    {
        return exact.clone();
    }
    if let Some(normalized) = directories
        .iter()
        .find(|name| normalized_game_name(name) == target)
    {
        return normalized.clone();
    }
    if target.len() >= 6 {
        if let Some(fuzzy) = directories.iter().find(|name| {
            let current = normalized_game_name(name);
            current.len() >= 6 && (current.contains(&target) || target.contains(&current))
        }) {
            return fuzzy.clone();
        }
    }
    fallback
}

pub fn plan_destination(root: &Path, candidate: &MediaCandidate) -> AlbumDestination {
    let album_root = if root
        .file_name()
        .and_then(|v| v.to_str())
        .is_some_and(|v| v.eq_ignore_ascii_case("album"))
    {
        root.to_path_buf()
    } else {
        root.join("Album")
    };
    let folder_name = resolve_game_folder(&album_root, &candidate.game_name);
    let folder = album_root.join(folder_name);
    let prefix = capture_timestamp_prefix(candidate.effective_timestamp());
    let extension = candidate.kind.extension();
    let filename = format!("{prefix}_c.{extension}");
    let full_path = folder.join(&filename);
    AlbumDestination {
        folder,
        filename,
        full_path,
    }
}

pub fn preserve_capture_timestamp(path: &Path, timestamp: DateTime<Utc>) -> std::io::Result<()> {
    let seconds = timestamp.timestamp();
    let nanos = timestamp.timestamp_subsec_nanos();
    let file_time = filetime::FileTime::from_unix_time(seconds, nanos);
    filetime::set_file_times(path, file_time, file_time)
}

pub fn kind_from_type(value: &str) -> MediaKind {
    if value.eq_ignore_ascii_case("video") {
        MediaKind::Video
    } else {
        MediaKind::Image
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_cross_platform_folder_names() {
        assert_eq!(sanitize_game_folder(" Mario: Kart / 8* "), "Mario Kart 8");
        assert_eq!(sanitize_game_folder(""), "Other");
    }

    #[test]
    fn creates_readable_media_name() {
        let timestamp = DateTime::parse_from_rfc3339("2026-10-04T07:30:12Z")
            .unwrap()
            .with_timezone(&Utc);
        let name = readable_media_name(
            "Splatoon 3: Splatfest",
            timestamp,
            Some("remote-capture-12345678"),
            MediaKind::Video,
        );
        assert!(name.starts_with("Splatoon 3 Splatfest - 2026-10-04 "));
        assert!(name.ends_with("[12345678].mp4"));
    }

    #[test]
    fn creates_readable_usb_import_name() {
        let timestamp = DateTime::parse_from_rfc3339("2026-10-05T08:09:10Z")
            .unwrap()
            .with_timezone(&Utc);
        let name =
            readable_import_media_name("The Legend of Zelda", timestamp, 7, MediaKind::Image);
        assert!(name.starts_with("The Legend of Zelda - 2026-10-05 "));
        assert!(name.ends_with("[07].jpg"));
    }
}
