use super::{headless, read_model::*};

#[test]
fn read_model_pairing_before_hello_is_safe_and_invalid_handles_are_typed() {
    let root = tempfile::tempdir().unwrap();
    let library = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let host = headless::host(&library.handle, "Desktop", None).unwrap();
    let view = headless::read_endpoint(&host.handle);
    assert!(view.error.is_none());
    let state = view.value.unwrap();
    assert!(state.host);
    assert_eq!(state.pairing, PairingStage::Handshaking);
    assert!(state.peer_name.is_none());
    assert!(!state.confirmation_available);
    assert!(state
        .invitation_remaining_ms
        .is_some_and(|ms| ms <= 300_000));
    assert!(state.configuration.is_none());
    let encoded = serde_json::to_string(&state).unwrap();
    assert!(!encoded.contains("secret"));
    assert!(!encoded.contains("root_der"));
    assert!(!encoded.contains(&host.invitation));
    let invalid = headless::read_endpoint("not-a-handle");
    assert_eq!(invalid.error, Some(ReadError::InvalidInput));
    headless::close_endpoint(&host.handle).unwrap();
    headless::close_library(&library.handle).unwrap();
}

#[test]
fn read_model_clock_skew_and_client_invitation_remaining_use_real_session_deadline() {
    use super::{clock::SystemClock, driver::Driver, Invitation, Qr, Role, Session, Transport};
    for skew in [-3600, 3600] {
        let now = chrono::Utc::now().timestamp();
        let mut invitation = Invitation::create(Transport::Usb, now).unwrap();
        let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), now + skew).unwrap();
        let mut host = invitation.accept(Role::Sender, "Desktop", now).unwrap();
        let mut client = Session::client(qr, Role::Receiver, "Phone", now + skew).unwrap();
        for _ in 0..12 {
            let bytes = client.drain_ciphertext(now + skew).unwrap();
            if !bytes.is_empty() {
                host.ingest_ciphertext(&bytes, now).unwrap();
            }
            let bytes = host.drain_ciphertext(now).unwrap();
            if !bytes.is_empty() {
                client.ingest_ciphertext(&bytes, now + skew).unwrap();
            }
        }
        let root = tempfile::tempdir().unwrap();
        let api = crate::api::CoreApi::open(root.path()).unwrap();
        let driver = Driver::new(
            client,
            api.database(),
            "Phone",
            std::sync::Arc::new(SystemClock::default()),
        )
        .unwrap();
        let view = driver.read_view();
        assert_eq!(view.pairing, PairingStage::AwaitingConfirmation);
        assert_eq!(view.peer_clock_skew_seconds, Some(skew));
        assert_eq!(view.peer_name.as_deref(), Some("Desktop"));
        assert!(view.confirmation_available);
        assert!(
            view.invitation_remaining_ms
                .is_some_and(|ms| ms > 290_000 && ms <= 300_000),
            "phone TTL must not subtract the desktop wall-clock expires_at"
        );
    }
}

#[test]
fn read_model_backup_pages_do_not_invent_entries_or_restore_capabilities() {
    let root = tempfile::tempdir().unwrap();
    let library = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let before = headless::library_info(&library.handle).unwrap();
    let page = headless::read_backups(&library.handle, None, 128);
    assert!(page.error.is_none());
    let page = page.value.unwrap();
    assert!(page.items.is_empty());
    assert!(page.next.is_none());
    assert_eq!(
        headless::read_backups(&library.handle, None, 129).error,
        Some(ReadError::InvalidInput)
    );
    assert_eq!(
        headless::read_backups(&library.handle, Some("foreign"), 10).error,
        Some(ReadError::PreviewChanged)
    );
    assert_eq!(before, headless::library_info(&library.handle).unwrap());
    headless::close_library(&library.handle).unwrap();
}

#[test]
fn read_model_errors_use_domain_variants_and_never_export_underlying_text() {
    use super::{
        driver::DriverError, receiver::ReceiverError, staging::StagingError, SessionError,
    };
    use crate::error::CoreError;
    assert_eq!(ReadError::core(&CoreError::LibraryBusy), ReadError::Busy);
    assert_eq!(
        ReadError::core(&CoreError::DeviceSyncRecoveryRequired),
        ReadError::RecoveryRequired
    );
    assert_eq!(
        ReadError::receiver(&ReceiverError::PlanChanged),
        ReadError::PreviewChanged
    );
    assert_eq!(
        ReadError::receiver(&ReceiverError::AuthorizationRequired),
        ReadError::PermissionDenied
    );
    assert_eq!(
        ReadError::staging(&StagingError::ReceivingWindowFull),
        ReadError::WindowFull
    );
    assert_eq!(
        ReadError::staging(&StagingError::InsufficientSpace),
        ReadError::InsufficientSpace
    );
    assert_eq!(
        ReadError::driver(&DriverError::InsufficientSpace),
        ReadError::InsufficientSpace
    );
    assert_eq!(
        ReadError::receiver(&ReceiverError::Staging(StagingError::InsufficientSpace)),
        ReadError::InsufficientSpace
    );
    assert_eq!(
        ReadError::session(&SessionError::Io),
        ReadError::Disconnected
    );
    assert_eq!(ReadError::driver(&DriverError::Timeout), ReadError::Timeout);
    assert_eq!(ReadError::core(&CoreError::Cancelled), ReadError::Cancelled);
    let error = CoreError::InvalidConfig("Busy F:/private/secret credential response".into());
    assert_eq!(ReadError::core(&error), ReadError::InvalidInput);
    assert_eq!(
        ReadError::staging(&StagingError::Database),
        ReadError::Internal
    );
    assert_eq!(
        serde_json::to_string(&ReadError::core(&error)).unwrap(),
        "\"InvalidInput\""
    );
}

#[test]
fn read_model_same_plan_conflicts_count_and_pages_obey_both_limits_and_scope() {
    use super::{
        manifest::{ManifestRecord, MappingKind, MappingRecord},
        planner::{build_plan, SyncMode},
        receiver::Snapshot,
    };
    let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
    let apis = roots
        .iter()
        .map(|r| crate::api::CoreApi::open(r.path()).unwrap())
        .collect::<Vec<_>>();
    let mut source = Snapshot::read(&apis[0].database(), "Source")
        .unwrap()
        .manifest;
    let mut target = Snapshot::read(&apis[1].database(), "Target")
        .unwrap()
        .manifest;
    for index in 0..260 {
        let name = format!("raw-{index:04}-{}", "x".repeat(1000));
        for (manifest, display) in [(&mut source, "Incoming"), (&mut target, "Existing")] {
            manifest
                .records
                .push(ManifestRecord::Mapping(MappingRecord {
                    kind: MappingKind::Game,
                    source_name: name.clone(),
                    target_name: Some(display.into()),
                    revision: None,
                    deleted: false,
                }));
        }
    }
    let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
    let summary = summarize(&plan, &"a".repeat(64), None, &Default::default()).unwrap();
    assert_eq!(summary.conflicts.unknown_revision, 260);
    assert_eq!(summary.conflicts.equal_revision, 0);
    assert_eq!(summary.media, ChangeCounts::default());
    assert_eq!(summary.space.new_staging_bytes, 0);
    assert!(
        summary.receiver_budget.is_none(),
        "source projection cannot claim receiver free space"
    );
    assert!(summary.space.excludes_metadata_and_filesystem_overhead);
    let mut after = None;
    let mut all = Vec::new();
    loop {
        let page = conflict_page(
            &plan,
            "endpoint:session:operation:binding-A",
            after.as_deref(),
            128,
        )
        .unwrap();
        assert!(
            page.items.len() < 128,
            "real long mapping conflicts must hit the byte boundary"
        );
        assert!(serde_json::to_vec(&page).unwrap().len() <= 65_536);
        let next = page.next.clone();
        all.extend(page.items);
        if let Some(cursor) = &next {
            assert_eq!(
                conflict_page(
                    &plan,
                    "endpoint:session:operation:binding-B",
                    Some(cursor),
                    128
                )
                .unwrap_err(),
                ReadError::PreviewChanged
            );
            assert_eq!(
                conflict_page(
                    &plan,
                    "other-endpoint:session:operation:binding-A",
                    Some(cursor),
                    128
                )
                .unwrap_err(),
                ReadError::PreviewChanged
            );
        }
        after = next;
        if after.is_none() {
            break;
        }
    }
    assert_eq!(
        all, plan.conflicts,
        "pages must borrow the same unique plan in order"
    );
    assert_eq!(
        conflict_page(&plan, "scope", None, 129).unwrap_err(),
        ReadError::InvalidInput
    );
    assert_eq!(
        conflict_page(&plan, "scope", Some("bad"), 128).unwrap_err(),
        ReadError::PreviewChanged
    );
}
