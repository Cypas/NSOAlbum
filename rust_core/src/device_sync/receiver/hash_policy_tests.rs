use super::*;
use crate::api::CoreApi;
use crate::models::{GalleryQuery, MediaAsset};

async fn import(api: &CoreApi, bytes: &[u8], name: &str) -> MediaAsset {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    api.import_local_files(vec![path.to_string_lossy().into_owned()])
        .await
        .unwrap();
    api.list_media(GalleryQuery::default())
        .unwrap()
        .into_iter()
        .next()
        .unwrap()
}

struct Fixture {
    _roots: [tempfile::TempDir; 2],
    source: CoreApi,
    target: CoreApi,
    existing: MediaAsset,
    incoming: MediaAsset,
    receiver: ReceiveOperation,
    work: super::super::work::WorkControl,
}

impl Fixture {
    async fn new() -> Self {
        let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let source = CoreApi::open(roots[0].path()).unwrap();
        let target = CoreApi::open(roots[1].path()).unwrap();
        let existing = import(&target, b"existing original", "existing.jpg").await;
        let incoming = import(&source, b"incoming original", "incoming.jpg").await;
        let work = super::super::work::WorkControl::default();
        let mut receiver = ReceiveOperation::prepare_controlled(
            target.database(),
            Snapshot::read(&source.database(), "Source").unwrap(),
            "Target",
            SyncMode::Merge,
            None,
            &work,
        )
        .unwrap();
        let operation = receiver.operation_id();
        receiver
            .staging_mut()
            .begin_file(operation, &incoming.sha256)
            .unwrap();
        receiver
            .staging_mut()
            .write_chunk(operation, &incoming.sha256, 0, b"incoming original")
            .unwrap();
        receiver
            .staging_mut()
            .finish_file(
                operation,
                &incoming.sha256,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        Self {
            _roots: roots,
            source,
            target,
            existing,
            incoming,
            receiver,
            work,
        }
    }
}

#[tokio::test]
async fn applying_new_media_does_not_hash_the_retained_target_library_again() {
    let mut fixture = Fixture::new().await;
    let verified_bytes = fixture.work.validation_metrics().checksum_read_bytes;
    assert_eq!(
        verified_bytes, 17,
        "the incoming file is initially verified"
    );
    let mut authorization = fixture.receiver.authorize().unwrap();
    let result = fixture
        .receiver
        .apply_guarded(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
            &mut |_| {},
            None,
        )
        .unwrap();

    assert_eq!(result.state, ApplyState::Finalized);
    assert_eq!(
        fixture
            .target
            .list_media(GalleryQuery::default())
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        std::fs::read(&fixture.existing.storage_path).unwrap(),
        b"existing original"
    );
    assert_eq!(
        fixture.work.validation_metrics().checksum_read_bytes,
        verified_bytes,
        "adding one media item must not reread every retained target original"
    );
}

#[tokio::test]
async fn applying_without_full_rehash_still_rejects_truncated_existing_originals() {
    let mut fixture = Fixture::new().await;
    std::fs::OpenOptions::new()
        .write(true)
        .open(&fixture.existing.storage_path)
        .unwrap()
        .set_len(1)
        .unwrap();
    let mut authorization = fixture.receiver.authorize().unwrap();

    assert!(fixture
        .receiver
        .apply_guarded(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
            &mut |_| {},
            None,
        )
        .is_err());
    assert_eq!(
        std::fs::read(&fixture.existing.storage_path).unwrap(),
        b"e",
        "a failed apply must not replace the externally truncated original"
    );
    let target_media = fixture.target.list_media(GalleryQuery::default()).unwrap();
    assert_eq!(target_media.len(), 1);
    assert_eq!(target_media[0].sha256, fixture.existing.sha256);
    assert_eq!(
        std::fs::read(&fixture.incoming.storage_path).unwrap(),
        b"incoming original"
    );
    assert_eq!(
        fixture
            .source
            .list_media(GalleryQuery::default())
            .unwrap()
            .len(),
        1
    );
    assert!(!fixture.target.database().device_sync_recovery_pending());
}
