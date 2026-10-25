use super::headless;

#[test]
fn headless_service_uses_real_temp_journal_and_external_restore_boundary() {
    let root = tempfile::tempdir().unwrap();
    let opened = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    assert!(uuid::Uuid::parse_str(&opened.library_uuid).is_ok());
    assert!(opened.pending_operation.is_none());
    assert_eq!(opened, headless::library_info(&opened.handle).unwrap());
    assert!(
        headless::journal(&opened.handle, &uuid::Uuid::new_v4().to_string())
            .unwrap()
            .is_none()
    );
    headless::close_library(&opened.handle).unwrap();
    assert!(headless::library_info(&opened.handle).is_err());
}

#[test]
fn opening_unpaired_host_does_not_create_interrupted_sync_state() {
    let root = tempfile::tempdir().unwrap();
    let opened = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let invitation = headless::host(&opened.handle, "Synthetic", Some("127.0.0.1:1")).unwrap();
    assert!(headless::library_info(&opened.handle)
        .unwrap()
        .interrupted_sessions
        .is_none());
    headless::close_endpoint(&invitation.handle).unwrap();
    assert!(headless::library_info(&opened.handle)
        .unwrap()
        .interrupted_sessions
        .is_none());
    headless::close_library(&opened.handle).unwrap();
}

#[test]
fn recovery_cannot_clear_another_handle_active_on_the_same_library() {
    let root = tempfile::tempdir().unwrap();
    let api = crate::api::CoreApi::open(root.path()).unwrap();
    let session = uuid::Uuid::new_v4();
    api.database()
        .device_sync_begin_session(session, uuid::Uuid::new_v4())
        .unwrap();
    let first = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let second = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let host = headless::host(&first.handle, "Synthetic", Some("127.0.0.1:1")).unwrap();
    assert!(
        headless::recover_interrupted_sessions(&second.handle, vec![session.to_string()]).is_err()
    );
    assert_eq!(
        api.database()
            .device_sync_unfinished_sessions()
            .unwrap()
            .len(),
        1
    );
    headless::close_endpoint(&host.handle).unwrap();
    headless::recover_interrupted_sessions(&second.handle, vec![session.to_string()]).unwrap();
    assert!(api
        .database()
        .device_sync_unfinished_sessions()
        .unwrap()
        .is_empty());
    headless::close_library(&first.handle).unwrap();
    headless::close_library(&second.handle).unwrap();
}
