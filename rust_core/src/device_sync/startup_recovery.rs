//! Durable interrupted-session recovery; apply journals remain authoritative.

use super::recovery::JournalStage;
use crate::database::Database;
use crate::error::{CoreError, CoreResult};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InterruptedSession {
    pub session: Uuid,
    pub channel: Uuid,
    pub operation: Option<Uuid>,
}

pub(crate) fn recover_session(database: &Database, record: &InterruptedSession) -> CoreResult<()> {
    if let Some(operation) = record.operation {
        if database
            .device_sync_journal(operation)?
            .is_some_and(|journal| {
                matches!(
                    journal.stage,
                    JournalStage::Prepared | JournalStage::LibraryApplied
                )
            })
        {
            return Err(CoreError::DeviceSyncRecoveryRequired);
        }
        super::staging::cleanup_interrupted_operation(database, operation)?;
    }
    database.device_sync_clear_session(record)
}

#[cfg(test)]
mod tests {
    use crate::api::CoreApi;
    use uuid::Uuid;

    #[test]
    fn confirmed_session_survives_reopen_and_clears_only_its_exact_identity() {
        let root = tempfile::tempdir().unwrap();
        let session = Uuid::new_v4();
        let channel = Uuid::new_v4();
        let staged = Uuid::new_v4();
        {
            let api = CoreApi::open(root.path()).unwrap();
            assert!(api
                .database()
                .device_sync_unfinished_sessions()
                .unwrap()
                .is_empty());
            api.database()
                .device_sync_begin_session(session, channel)
                .unwrap();
            api.database()
                .device_sync_bind_session_staging(session, staged)
                .unwrap();
            assert!(api
                .database()
                .device_sync_bind_session_staging(session, Uuid::new_v4())
                .is_err());
        }
        let api = CoreApi::open(root.path()).unwrap();
        let sessions = api.database().device_sync_unfinished_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session, session);
        assert_eq!(sessions[0].operation, Some(staged));
        let new_session = Uuid::new_v4();
        api.database()
            .device_sync_begin_session(new_session, Uuid::new_v4())
            .unwrap();
        api.database()
            .device_sync_clear_session(&sessions[0])
            .unwrap();
        let remaining = api.database().device_sync_unfinished_sessions().unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].session, new_session);
        // A stale completed row cannot erase any later session.
        api.database()
            .device_sync_clear_session(&sessions[0])
            .unwrap();
        assert_eq!(
            api.database().device_sync_unfinished_sessions().unwrap(),
            remaining
        );
    }

    #[test]
    fn recovery_cleans_only_owned_unapplied_parts_and_keeps_originals_and_cache() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let database = api.database();
        let session = Uuid::new_v4();
        let operation = Uuid::new_v4();
        database
            .device_sync_begin_session(session, Uuid::new_v4())
            .unwrap();
        database
            .device_sync_bind_session_staging(session, operation)
            .unwrap();
        let (runtime, _) = database.device_sync_file_roots().unwrap();
        let directory = runtime.join(operation.to_string());
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(
            directory.join(format!("{}-fixture.part", Uuid::new_v4())),
            b"partial",
        )
        .unwrap();
        std::fs::create_dir_all(runtime.join("verified-v1")).unwrap();
        std::fs::write(runtime.join("verified-v1/retained"), b"verified").unwrap();
        let unrelated = runtime.join(Uuid::new_v4().to_string());
        std::fs::create_dir(&unrelated).unwrap();
        super::recover_session(
            &database,
            &database.device_sync_unfinished_sessions().unwrap()[0],
        )
        .unwrap();
        assert!(!directory.exists());
        assert!(unrelated.exists());
        assert!(runtime.join("verified-v1/retained").exists());
        assert!(database
            .device_sync_unfinished_sessions()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn unexpected_staging_content_fails_closed_without_clearing_marker() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let database = api.database();
        let session = Uuid::new_v4();
        let operation = Uuid::new_v4();
        database
            .device_sync_begin_session(session, Uuid::new_v4())
            .unwrap();
        database
            .device_sync_bind_session_staging(session, operation)
            .unwrap();
        let (runtime, _) = database.device_sync_file_roots().unwrap();
        let directory = runtime.join(operation.to_string());
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("not-an-owned-part.jpg"), b"keep").unwrap();
        let before = database.device_sync_unfinished_sessions().unwrap();
        assert!(super::recover_session(&database, &before[0]).is_err());
        assert_eq!(database.device_sync_unfinished_sessions().unwrap(), before);
        assert!(directory.join("not-an-owned-part.jpg").exists());
    }

    #[test]
    fn linked_part_cannot_delete_a_file_outside_the_owned_operation() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let database = api.database();
        let session = Uuid::new_v4();
        let operation = Uuid::new_v4();
        database
            .device_sync_begin_session(session, Uuid::new_v4())
            .unwrap();
        database
            .device_sync_bind_session_staging(session, operation)
            .unwrap();
        let (runtime, _) = database.device_sync_file_roots().unwrap();
        let directory = runtime.join(operation.to_string());
        std::fs::create_dir_all(&directory).unwrap();
        let outside = root.path().join("synthetic-original");
        std::fs::write(&outside, b"keep").unwrap();
        let link = directory.join(format!("{}-fixture.part", Uuid::new_v4()));
        std::fs::hard_link(&outside, link).unwrap();
        let before = database.device_sync_unfinished_sessions().unwrap();
        assert!(super::recover_session(&database, &before[0]).is_err());
        assert_eq!(std::fs::read(outside).unwrap(), b"keep");
        assert_eq!(database.device_sync_unfinished_sessions().unwrap(), before);
    }
}
