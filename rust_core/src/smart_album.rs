use std::collections::BTreeMap;

use crate::models::{AlbumRule, MediaAsset, MediaKind};

/// Rules in the same group are ANDed; groups are ORed.
pub fn matches_album_rules(media: &MediaAsset, rules: &[AlbumRule]) -> bool {
    if rules.is_empty() {
        return false;
    }
    let mut groups: BTreeMap<i64, Vec<&AlbumRule>> = BTreeMap::new();
    for rule in rules {
        groups.entry(rule.rule_group).or_default().push(rule);
    }
    groups
        .values()
        .any(|group| group.iter().all(|rule| matches_rule(media, rule)))
}

fn matches_rule(media: &MediaAsset, rule: &AlbumRule) -> bool {
    let expected = rule.value.trim();
    match rule.field.as_str() {
        "favorite" => compare_bool(media.favorite, &rule.operator, expected),
        "game" | "game_tag" => compare_text(&media.game_name, &rule.operator, expected),
        "note" => compare_text(
            media.note.as_deref().unwrap_or_default(),
            &rule.operator,
            expected,
        ),
        "type" => {
            let actual = match media.kind {
                MediaKind::Image => "image",
                MediaKind::Video => "video",
            };
            compare_text(actual, &rule.operator, expected)
        }
        "tag" => match rule.operator.as_str() {
            "not_equals" | "not_contains" => media
                .tags
                .iter()
                .all(|tag| compare_text(tag, &rule.operator, expected)),
            _ => media
                .tags
                .iter()
                .any(|tag| compare_text(tag, &rule.operator, expected)),
        },
        _ => false,
    }
}

fn compare_bool(actual: bool, operator: &str, expected: &str) -> bool {
    let expected = matches!(expected.to_ascii_lowercase().as_str(), "1" | "true" | "yes");
    match operator {
        "equals" => actual == expected,
        "not_equals" => actual != expected,
        _ => false,
    }
}

fn compare_text(actual: &str, operator: &str, expected: &str) -> bool {
    let actual = actual.to_lowercase();
    let expected = expected.to_lowercase();
    match operator {
        "equals" => actual == expected,
        "not_equals" => actual != expected,
        "contains" => actual.contains(&expected),
        "not_contains" => !actual.contains(&expected),
        "starts_with" => actual.starts_with(&expected),
        "ends_with" => actual.ends_with(&expected),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;

    fn media() -> MediaAsset {
        MediaAsset {
            id: 1,
            sha256: "a".into(),
            original_name: "a.jpg".into(),
            storage_path: "a.jpg".into(),
            kind: MediaKind::Image,
            captured_at: None,
            imported_at: Utc::now(),
            game_title_id: None,
            game_name: "Splatoon 3".into(),
            favorite: true,
            note: Some("金色旗鱼".into()),
            tags: vec!["庆典".into()],
        }
    }

    #[test]
    fn ands_within_group_and_ors_between_groups() {
        let rules = vec![
            AlbumRule {
                rule_group: 0,
                field: "tag".into(),
                operator: "equals".into(),
                value: "庆典".into(),
            },
            AlbumRule {
                rule_group: 0,
                field: "note".into(),
                operator: "contains".into(),
                value: "旗鱼".into(),
            },
            AlbumRule {
                rule_group: 1,
                field: "game".into(),
                operator: "equals".into(),
                value: "Other".into(),
            },
        ];
        assert!(matches_album_rules(&media(), &rules));
    }
}
