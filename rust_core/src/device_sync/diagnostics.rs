//! Debug-only, fixed-code diagnostics. Never format application error payloads.

use super::{driver::DriverError, receiver::ReceiverError, SessionError};
use crate::error::CoreError;

#[derive(Clone, Copy, Debug)]
pub(crate) enum Boundary {
    SnapshotLease,
    SnapshotHeader,
    SnapshotPage,
    SnapshotCollector,
    SnapshotSources,
    SnapshotFilter,
    SnapshotFinalHeader,
    SnapshotGenerationChanged,
    ReceiverSourceValidation,
    TargetSnapshot,
    ReceiverPlan,
    ReceiverStaging,
    ReceiverMetadataCost,
    ReceiverBudget,
    ReceiverFinalCheck,
    SnapshotEnd,
    ReceivedSnapshot,
    PreparationJoin,
    PreparedTarget,
    PreparedTargetTransferSet,
    PreviewSummary,
    PreviewSourceDigest,
    PreviewTargetDigest,
    PreviewBinding,
    StageRuntimeEnsure,
    StageMediaEnsure,
    StageRuntimeCanonical,
    StageCacheOpen,
    StageCacheLookup,
    StageOperationCreate,
    PathSyntax,
    PathEnsureStat,
    PathEnsureLink,
    PathEnsureKind,
    PathEnsureCreate,
    PathInspectStat,
    PathInspectLink,
    PathInspectKind,
    PathOpenBeforeStat,
    PathOpenKind,
    PathOpenHandle,
    PathOpenAfterStat,
    #[cfg(unix)]
    PathOpenIdentity,
    PathHeldAncestorIdentity,
    ApplySnapshotBegin,
    ApplySnapshotEnd,
    ApplyBudgetBegin,
    ApplyBudgetEnd,
    ApplyReceiverPrepareBegin,
    ApplyReceiverPrepareEnd,
    BackupOriginalHashBegin,
    BackupOriginalHashEnd,
    ApplyWorkerResult,
    ApplyPermitInactive,
    ApplyPermitLeaseExpired,
    ApplyPermitPublicationBudget,
    ApplyPermitSqlBudget,
    ApplyPermitSqlDeadline,
    ApplySourceLeaseExpired,
    ApplySourceSqlDeadline,
    UsbPoll,
    UsbDrainInput,
    UsbOutput,
}

pub(crate) fn checkpoint(boundary: Boundary) {
    #[cfg(debug_assertions)]
    emit(&checkpoint_record(boundary));
    #[cfg(not(debug_assertions))]
    let _ = boundary;
}

#[cfg(debug_assertions)]
fn checkpoint_record(boundary: Boundary) -> String {
    format!("device_sync boundary={boundary:?} category=Checkpoint reason=none")
}

pub(super) fn core(boundary: Boundary, error: &CoreError) {
    crate::diagnostics::device(&core_record(boundary, error));
    #[cfg(debug_assertions)]
    emit(&core_record(boundary, error));
    #[cfg(not(debug_assertions))]
    let _ = (boundary, error);
}

pub(super) fn receiver(boundary: Boundary, error: &ReceiverError) {
    crate::diagnostics::device(&receiver_record(boundary, error));
    #[cfg(debug_assertions)]
    emit(&receiver_record(boundary, error));
    #[cfg(not(debug_assertions))]
    let _ = (boundary, error);
}

pub(super) fn driver(boundary: Boundary, error: &DriverError) {
    crate::diagnostics::device(&format!("boundary={boundary:?} driver={error:?}"));
    #[cfg(debug_assertions)]
    emit(&format!(
        "device_sync boundary={boundary:?} category=Driver reason={error:?}"
    ));
    #[cfg(not(debug_assertions))]
    let _ = (boundary, error);
}

pub(super) fn channel(boundary: Boundary, error: &SessionError) {
    crate::diagnostics::device(&format!("boundary={boundary:?} session={error:?}"));
    #[cfg(debug_assertions)]
    emit(&format!(
        "device_sync boundary={boundary:?} category=Session reason={error:?}"
    ));
    #[cfg(not(debug_assertions))]
    let _ = (boundary, error);
}

pub(super) fn usb(kind: super::usb::UsbActionKind, error: &super::read_model::ReadError) {
    crate::diagnostics::device(&usb_record(kind, error));
    #[cfg(debug_assertions)]
    emit(&usb_record(kind, error));
    #[cfg(not(debug_assertions))]
    let _ = (kind, error);
}

pub(super) fn measurement(record: &str) {
    crate::diagnostics::device_measurement(record);
    #[cfg(debug_assertions)]
    emit_with_priority(record, 4);
}

fn core_record(boundary: Boundary, error: &CoreError) -> String {
    let (category, reason) = match error {
        CoreError::LibraryBusy => ("LibraryBusy", "none"),
        CoreError::LibraryLockUnavailable => ("LibraryLockUnavailable", "none"),
        CoreError::LibraryReferenced => ("LibraryReferenced", "none"),
        CoreError::LibraryRootOwnership => ("LibraryRootOwnership", "none"),
        CoreError::DeviceSyncRecoveryRequired => ("DeviceSyncRecoveryRequired", "none"),
        CoreError::InvalidConfig(value) => ("InvalidConfig", known_reason(value)),
        CoreError::Authentication(_) => ("Authentication", "other"),
        CoreError::Provider(_) => ("Provider", "other"),
        CoreError::RateLimited { .. } => ("RateLimited", "none"),
        CoreError::UnsafeMediaUrl(_) => ("UnsafeMediaUrl", "other"),
        CoreError::DownloadTooLarge { .. } => ("DownloadTooLarge", "none"),
        CoreError::DownloadLengthMismatch { .. } => ("DownloadLengthMismatch", "none"),
        CoreError::Database(error) => (
            "Database",
            match error {
                rusqlite::Error::SqliteFailure(code, _) => match code.code {
                    rusqlite::ErrorCode::DatabaseBusy => "sqlite_busy",
                    rusqlite::ErrorCode::DatabaseLocked => "sqlite_locked",
                    rusqlite::ErrorCode::OperationInterrupted => "sqlite_interrupted",
                    rusqlite::ErrorCode::ConstraintViolation => "sqlite_constraint",
                    _ => "sqlite_other",
                },
                _ => "other",
            },
        ),
        CoreError::Network(_) | CoreError::NetworkRequest { .. } => ("Network", "other"),
        CoreError::Io(error) => (
            "Io",
            match error.kind() {
                std::io::ErrorKind::PermissionDenied => "permission_denied",
                std::io::ErrorKind::NotFound => "not_found",
                std::io::ErrorKind::AlreadyExists => "already_exists",
                std::io::ErrorKind::InvalidData => "invalid_data",
                std::io::ErrorKind::TimedOut => "timed_out",
                _ => "other",
            },
        ),
        CoreError::Url(_) => ("Url", "other"),
        CoreError::Json(_) => ("Json", "other"),
        CoreError::Cancelled => ("Cancelled", "none"),
    };
    format!("device_sync boundary={boundary:?} category={category} reason={reason}")
}

fn known_reason(value: &str) -> &'static str {
    match value {
        "device sync: noncanonical tag" => "noncanonical_tag",
        "device sync: duplicate or noncanonical media tag" => "noncanonical_media_tag",
        "device sync: invalid media length" => "invalid_media_length",
        "device sync: invalid media extension" => "invalid_media_extension",
        "device sync: display name must not be a path" => "display_name_is_path",
        "device sync: invalid or oversized text" => "invalid_text",
        "device sync: invalid UUID" => "invalid_uuid",
        "device sync: invalid SHA-256" => "invalid_sha",
        "device sync: too many media tags" => "too_many_media_tags",
        "device sync: invalid album type or system identity" => "invalid_album_identity",
        "device sync: invalid album rule" => "invalid_album_rule",
        "device sync: duplicate manifest record" => "duplicate_manifest_record",
        "device sync: system favorites album is missing" => "missing_favorites",
        "device sync: orphan album rule" => "orphan_album_rule",
        "device sync: orphan album member" => "orphan_album_member",
        "device sync: manual album has rules" => "manual_album_rules",
        "device sync: derived album must not contain frozen members" => "derived_album_members",
        "device sync: media refers to missing or deleted tag" => "missing_media_tag",
        "device sync: invalid mapping tombstone" => "invalid_mapping_tombstone",
        "device sync: invalid self mapping" => "invalid_self_mapping",
        "device sync: mapping cycle" => "mapping_cycle",
        "device sync: invalid active mapping" => "invalid_active_mapping",
        "device sync: invalid source display name" => "invalid_source_display_name",
        "device sync: source descriptions do not match manifest" => "source_manifest_mismatch",
        "device sync: unrelated or duplicate source description" => "invalid_source_identity",
        "device sync: library changed; restart the manifest" => "snapshot_generation_changed",
        "device-sync snapshot changed" => "snapshot_generation_changed",
        "device sync: same SHA-256 declares incompatible length or type" => "incompatible_media",
        "device sync: same album UUID has incompatible source identity" => "incompatible_album",
        "device sync: final media tag has no live catalog identity" => "missing_final_tag",
        "preparation byte limit exceeded" => "preparation_byte_limit",
        "preparation bytes regressed" => "preparation_bytes_regressed",
        _ => "other",
    }
}

fn receiver_record(boundary: Boundary, error: &ReceiverError) -> String {
    match error {
        ReceiverError::Core(error) => core_record(boundary, error),
        ReceiverError::Staging(error) => {
            // StagingError is a data-free enum; Debug cannot include user data.
            format!("device_sync boundary={boundary:?} category=Staging reason={error:?}")
        }
        ReceiverError::AuthorizationRequired => format!(
            "device_sync boundary={boundary:?} category=Receiver reason=AuthorizationRequired"
        ),
        ReceiverError::AuthorizationMismatch => format!(
            "device_sync boundary={boundary:?} category=Receiver reason=AuthorizationMismatch"
        ),
        ReceiverError::PlanChanged => {
            format!("device_sync boundary={boundary:?} category=Receiver reason=PlanChanged")
        }
        ReceiverError::InvalidState => {
            format!("device_sync boundary={boundary:?} category=Receiver reason=InvalidState")
        }
    }
}

fn usb_record(kind: super::usb::UsbActionKind, error: &super::read_model::ReadError) -> String {
    format!("device_sync boundary=UsbAction action={kind:?} category=ReadError reason={error:?}")
}

#[cfg(debug_assertions)]
fn emit(record: &str) {
    emit_with_priority(record, 6);
}

#[cfg(all(debug_assertions, not(target_os = "android")))]
fn emit_with_priority(record: &str, _priority: i32) {
    use std::io::Write;
    // A closed diagnostic stream must not alter transfer behavior.
    let _ = writeln!(std::io::stderr().lock(), "{record}");
}

#[cfg(all(debug_assertions, target_os = "android"))]
fn emit_with_priority(record: &str, priority: i32) {
    #[link(name = "log")]
    extern "C" {
        fn __android_log_write(
            priority: libc::c_int,
            tag: *const libc::c_char,
            text: *const libc::c_char,
        ) -> libc::c_int;
    }
    if let Ok(record) = std::ffi::CString::new(record) {
        // Both tag and message originate only from static enums/allowlists.
        unsafe {
            let _ = __android_log_write(priority, c"NSOAlbumDeviceSync".as_ptr(), record.as_ptr());
        }
    }
}

#[cfg(all(test, debug_assertions))]
mod tests {
    use super::*;

    #[test]
    fn diagnostic_apply_checkpoints_contain_only_fixed_phase_codes() {
        for (boundary, expected) in [
            (
                Boundary::ApplySnapshotBegin,
                "device_sync boundary=ApplySnapshotBegin category=Checkpoint reason=none",
            ),
            (
                Boundary::BackupOriginalHashEnd,
                "device_sync boundary=BackupOriginalHashEnd category=Checkpoint reason=none",
            ),
            (
                Boundary::ApplyPermitLeaseExpired,
                "device_sync boundary=ApplyPermitLeaseExpired category=Checkpoint reason=none",
            ),
        ] {
            assert_eq!(checkpoint_record(boundary), expected);
        }
    }

    #[test]
    fn diagnostic_known_static_reasons_are_distinguished_without_error_payloads() {
        let error = CoreError::InvalidConfig("device sync: noncanonical tag".into());
        assert_eq!(
            core_record(Boundary::TargetSnapshot, &error),
            "device_sync boundary=TargetSnapshot category=InvalidConfig reason=noncanonical_tag"
        );
    }

    #[test]
    fn diagnostic_unknown_private_payloads_never_enter_records() {
        for payload in [
            "/private/user/library.sqlite?token=synthetic-private-token",
            "device sync: noncanonical tag\n/private/user/private-media.jpg",
            "secret-account-id; original-file-name; session-secret",
        ] {
            let record = core_record(
                Boundary::TargetSnapshot,
                &CoreError::InvalidConfig(payload.into()),
            );
            assert_eq!(
                record,
                "device_sync boundary=TargetSnapshot category=InvalidConfig reason=other"
            );
        }
    }

    #[test]
    fn diagnostic_nested_io_database_and_json_payloads_remain_private() {
        let errors = [
            CoreError::Io(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "/private/user/media?token=synthetic-secret",
            )),
            CoreError::Database(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
                Some("private-table private-account private-path".into()),
            )),
            CoreError::Json(serde_json::from_str::<u64>("\"private-value\"").unwrap_err()),
        ];
        for (error, expected) in errors.into_iter().zip([
            "device_sync boundary=TargetSnapshot category=Io reason=permission_denied",
            "device_sync boundary=TargetSnapshot category=Database reason=sqlite_busy",
            "device_sync boundary=TargetSnapshot category=Json reason=other",
        ]) {
            assert_eq!(core_record(Boundary::TargetSnapshot, &error), expected);
            assert_eq!(
                receiver_record(Boundary::TargetSnapshot, &ReceiverError::Core(error)),
                expected
            );
        }
        assert_eq!(
            receiver_record(
                Boundary::ReceiverStaging,
                &ReceiverError::Staging(super::super::staging::StagingError::UnsafePath)
            ),
            "device_sync boundary=ReceiverStaging category=Staging reason=UnsafePath"
        );
    }

    #[test]
    fn diagnostic_usb_records_take_only_action_kind_and_safe_error() {
        assert_eq!(
            usb_record(
                super::super::usb::UsbActionKind::Open,
                &super::super::read_model::ReadError::InvalidInput,
            ),
            "device_sync boundary=UsbAction action=Open category=ReadError reason=InvalidInput"
        );
    }
}
