//! Bounded, synthetic-only termination at real durable receiver boundaries.
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use super::*;
use crate::api::CoreApi;
use crate::device_sync::recovery::RecoveryOperation;

const CHILD: &str = "device_sync::receiver::process_tests::receiver_process_child";
const TIMEOUT: Duration = Duration::from_secs(20);
const PREFIX: &str = "nsoalbum-receiver-crash-";

struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
#[ignore = "bounded synthetic subprocess entry point; run by receiver_process_crash_boundaries"]
fn receiver_process_child() {
    let root = std::path::PathBuf::from(std::env::var_os("NSOALBUM_RECEIVER_TEST_ROOT").unwrap());
    assert!(root.starts_with(std::env::temp_dir().canonicalize().unwrap()));
    assert!(root
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .starts_with(PREFIX));
    let boundary = std::env::var("NSOALBUM_RECEIVER_TEST_BOUNDARY").unwrap();
    let expected = match boundary.as_str() {
        "prepare" => Some(ApplyBoundary::Prepared),
        "applied" => Some(ApplyBoundary::LibraryApplied),
        "finalized" => Some(ApplyBoundary::Finalized),
        "published" | "rollback" => None,
        _ => panic!("invalid synthetic boundary"),
    };
    let mut stream =
        TcpStream::connect(std::env::var("NSOALBUM_RECEIVER_TEST_ADDRESS").unwrap()).unwrap();
    stream.set_read_timeout(Some(TIMEOUT)).unwrap();
    stream.set_write_timeout(Some(TIMEOUT)).unwrap();
    let source = CoreApi::open(root.join("source")).unwrap();
    let target = CoreApi::open(root.join("target")).unwrap();
    let mut operation = ReceiveOperation::prepare(
        target.database(),
        Snapshot::read(&source.database(), "Synthetic source").unwrap(),
        "Synthetic target",
        SyncMode::Overwrite,
    )
    .unwrap();
    let media = source
        .list_media(crate::models::GalleryQuery::default())
        .unwrap()
        .remove(0);
    let id = operation.operation_id();
    operation
        .staging_mut()
        .begin_file(id, &media.sha256)
        .unwrap();
    operation
        .staging_mut()
        .write_chunk(id, &media.sha256, 0, b"abc")
        .unwrap();
    operation
        .staging_mut()
        .finish_file(
            id,
            &media.sha256,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    let mut auth = operation.authorize().unwrap();
    let cancel = CancellationToken::default();
    let mut file_stream = stream.try_clone().unwrap();
    let result = operation.apply_with_file_progress(
        Some(&mut auth),
        None,
        &cancel,
        &mut |stage| {
            if boundary == "rollback" && stage == ApplyBoundary::Prepared {
                cancel.cancel();
            }
            if Some(stage) == expected {
                stream.write_all(b"B").unwrap();
                let mut ack = [0];
                stream.read_exact(&mut ack).unwrap();
                panic!("parent should terminate only this synthetic child");
            }
        },
        &mut |progress| {
            if boundary == "published"
                && progress.phase == crate::device_sync::staging::Phase::Published
            {
                file_stream.write_all(b"B").unwrap();
                let mut ack = [0];
                file_stream.read_exact(&mut ack).unwrap();
                panic!("parent should terminate only this synthetic child after CAS publication");
            }
        },
    );
    if boundary == "rollback" {
        assert!(result.is_err());
        stream.write_all(b"B").unwrap();
        let mut ack = [0];
        stream.read_exact(&mut ack).unwrap();
    } else {
        result.unwrap();
    }
}

#[test]
fn receiver_process_crash_boundaries_reopen_and_recover_without_auto_undo() {
    for boundary in ["prepare", "published", "applied", "rollback", "finalized"] {
        let root = tempfile::Builder::new()
            .prefix(PREFIX)
            .tempdir_in(std::env::temp_dir().canonicalize().unwrap())
            .unwrap();
        {
            let source = CoreApi::open(root.path().join("source")).unwrap();
            let target = CoreApi::open(root.path().join("target")).unwrap();
            source
                .database()
                .create_tag("incoming after crash")
                .unwrap();
            target
                .database()
                .create_tag("original before crash")
                .unwrap();
            let input = root.path().join("synthetic.jpg");
            std::fs::write(&input, b"abc").unwrap();
            tokio::runtime::Runtime::new()
                .unwrap()
                .block_on(source.import_local_files(vec![input.to_string_lossy().into_owned()]))
                .unwrap();
        }
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let mut process = OwnedChild(
            Command::new(std::env::current_exe().unwrap())
                .args(["--ignored", "--exact", CHILD, "--nocapture"])
                .env("NSOALBUM_RECEIVER_TEST_ROOT", root.path())
                .env("NSOALBUM_RECEIVER_TEST_BOUNDARY", boundary)
                .env("NSOALBUM_RECEIVER_TEST_ADDRESS", address.to_string())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap(),
        );
        let (sender, receiver) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let _ = sender.send(listener.accept());
        });
        let mut stream = match receiver.recv_timeout(TIMEOUT) {
            Ok(result) => result.unwrap().0,
            Err(error) => {
                let _ = TcpStream::connect_timeout(&address, TIMEOUT);
                panic!("synthetic receiver startup failed: {error}");
            }
        };
        stream.set_read_timeout(Some(TIMEOUT)).unwrap();
        let mut signal = [0];
        stream.read_exact(&mut signal).unwrap();
        assert_eq!(signal, [b'B']);
        process.0.kill().unwrap();
        process.0.wait().unwrap();
        let reopened = CoreApi::open(root.path().join("target")).unwrap();
        let tags = reopened.database().list_tags().unwrap();
        if boundary == "finalized" || boundary == "rollback" {
            assert!(!reopened.database().device_sync_recovery_pending());
            assert!(reopened
                .database()
                .device_sync_pending_journal()
                .unwrap()
                .is_none());
            assert_eq!(
                tags.contains(&"incoming after crash".into()),
                boundary == "finalized"
            );
            assert_eq!(
                tags.contains(&"original before crash".into()),
                boundary == "rollback"
            );
        } else {
            assert!(reopened.database().device_sync_recovery_pending());
            assert!(matches!(
                reopened.create_tag("blocked".into()),
                Err(CoreError::LibraryBusy)
            ));
            let journal = reopened
                .database()
                .device_sync_pending_journal()
                .unwrap()
                .unwrap();
            assert_eq!(
                tags.contains(&"incoming after crash".into()),
                boundary == "applied"
            );
            assert_eq!(
                tags.contains(&"original before crash".into()),
                boundary != "applied"
            );
            let mut recover = RecoveryOperation::preview_pending(
                reopened.database(),
                journal.operation_uuid,
                "Synthetic target",
            )
            .unwrap();
            let mut auth = recover.authorize().unwrap();
            recover
                .restore(Some(&mut auth), &CancellationToken::default())
                .unwrap();
            assert!(reopened
                .database()
                .list_tags()
                .unwrap()
                .contains(&"original before crash".into()));
            assert!(!reopened.database().device_sync_recovery_pending());
            reopened
                .create_tag("normal writing restored".into())
                .unwrap();
            if boundary == "published" {
                let orphan=root.path().join("target/originals/ba/78/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.jpg");
                assert_eq!(std::fs::read(orphan).unwrap(), b"abc");
                assert!(reopened
                    .list_media(crate::models::GalleryQuery::default())
                    .unwrap()
                    .is_empty());
            }
        }
    }
}
