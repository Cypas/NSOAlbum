use super::*;
use crate::api::CoreApi;
use crate::device_sync::planner::SyncMode;
use crate::device_sync::receiver::{CommitGuard, ReceiveOperation, Snapshot};
use crate::error::CoreError;
use crate::sync::CancellationToken;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

struct Guard {
    reject: AtomicBool,
    work: AtomicU64,
}
impl CommitGuard for Guard {
    fn check(&self) -> CoreResult<()> {
        if self.reject.load(Ordering::SeqCst) {
            Err(CoreError::Cancelled)
        } else {
            Ok(())
        }
    }
    fn sql_progress(&self) {
        self.work.fetch_add(2048, Ordering::SeqCst);
        self.reject.store(true, Ordering::SeqCst);
    }
}

#[test]
fn receiver_driver_sql_interrupt_rolls_back_and_removes_handler_for_ordinary_consumers() {
    let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
    let a = CoreApi::open(roots[0].path()).unwrap();
    let b = CoreApi::open(roots[1].path()).unwrap();
    for index in 0..40 {
        a.create_tag(format!("incoming {index}")).unwrap();
    }
    b.create_tag("original".into()).unwrap();
    let before = Snapshot::read(&b.database(), "B").unwrap();
    b.database().connection.lock().unwrap().execute_batch(
        "CREATE TRIGGER driver_expensive_tag AFTER INSERT ON tag BEGIN
         SELECT sum(x) FROM (WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT x FROM n);
         END;"
    ).unwrap();
    let source = Snapshot::read(&a.database(), "A").unwrap();
    let mut receiver =
        ReceiveOperation::prepare(b.database(), source, "B", SyncMode::Overwrite).unwrap();
    let mut authorization = receiver.authorize().unwrap();
    let guard = Arc::new(Guard {
        reject: AtomicBool::new(false),
        work: AtomicU64::new(0),
    });
    assert!(receiver
        .apply_guarded(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
            &mut |_| {},
            Some(guard.clone())
        )
        .is_err());
    assert!(guard.work.load(Ordering::SeqCst) > 0);
    assert_eq!(
        Snapshot::read(&b.database(), "B").unwrap().manifest.records,
        before.manifest.records
    );
    assert!(!b.database().device_sync_recovery_pending());
    b.create_tag("normal after cancelled SQL".into()).unwrap();
    let value: u64 = b.database().connection.lock().unwrap().query_row(
        "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT sum(x) FROM n", [], |row| row.get(0)
    ).unwrap();
    assert_eq!(value, 50_005_000);
}
