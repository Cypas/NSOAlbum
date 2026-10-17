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
