use super::accounts::{AccountCollector, AccountSet, MAX_ACCOUNTS, MAX_ACCOUNT_BYTES};

const PAYLOAD: &str = r#"{"version":1,"accounts":[{"account_id":"a","nickname":"Alice","session_token":"synthetic-secret"}]}"#;

#[test]
fn account_payload_projects_only_versioned_identity_nickname_and_token() {
    let accounts = AccountSet::from_json(PAYLOAD.as_bytes()).unwrap();
    assert_eq!(accounts.len(), 1);
    assert!(!format!("{accounts:?}").contains("synthetic-secret"));
    let output = accounts.to_json().unwrap();
    assert_eq!(&*output, PAYLOAD.as_bytes());
    for input in [
        PAYLOAD.replace("\"version\":1", "\"version\":2"),
        PAYLOAD.replace(
            "\"nickname\":\"Alice\"",
            "\"nickname\":\"Alice\",\"avatar_url\":\"x\"",
        ),
        PAYLOAD.replace("\"account_id\":\"a\"", "\"account_id\":\"\""),
        PAYLOAD.replace(
            "\"session_token\":\"synthetic-secret\"",
            "\"session_token\":\"\"",
        ),
    ] {
        let error = AccountSet::from_json(input.as_bytes()).unwrap_err();
        assert!(!error.to_string().contains("synthetic-secret"));
    }
}

#[test]
fn account_payload_rejects_duplicate_unsorted_and_bounded_input() {
    let record = r#"{"account_id":"a","nickname":"Alice","session_token":"synthetic-secret"}"#;
    for count in [2, MAX_ACCOUNTS + 1] {
        let input = format!(
            r#"{{"version":1,"accounts":[{}]}}"#,
            vec![record; count].join(",")
        );
        assert!(AccountSet::from_json(input.as_bytes()).is_err());
    }
    let input = vec![b' '; MAX_ACCOUNT_BYTES + 1];
    assert!(AccountSet::from_json(&input).is_err());
    let input = PAYLOAD.replace("synthetic-secret", &"x".repeat(8193));
    assert!(AccountSet::from_json(input.as_bytes()).is_err());
}

#[test]
fn account_segments_are_ordered_bounded_and_verified_before_exposure() {
    let accounts = AccountSet::from_json(PAYLOAD.as_bytes()).unwrap();
    let mut collector = AccountCollector::default();
    let first = &PAYLOAD.as_bytes()[..25];
    assert!(collector.part(0, PAYLOAD.len(), first).is_ok());
    assert!(collector.part(0, PAYLOAD.len(), first).is_err());
    assert!(collector.finish(&accounts.digest().unwrap()).is_err());
    let mut collector = AccountCollector::default();
    collector.part(0, PAYLOAD.len(), first).unwrap();
    collector
        .part(25, PAYLOAD.len(), &PAYLOAD.as_bytes()[25..])
        .unwrap();
    assert_eq!(
        collector.finish(&accounts.digest().unwrap()).unwrap().len(),
        1
    );
    assert!(AccountCollector::default()
        .part(0, MAX_ACCOUNT_BYTES + 1, b"x")
        .is_err());
}
