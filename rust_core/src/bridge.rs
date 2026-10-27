//! Narrow, generator-friendly API consumed by Flutter through
//! `flutter_rust_bridge`. Rust remains the sole owner of SQLite and sync state.

use std::sync::{Mutex, OnceLock};

use crate::api::CoreApi;
use crate::device_sync::driver::{Direction, DriverError};
use crate::device_sync::headless::{
    self, EndpointStatus, HostInfo, JournalInfo, LibraryInfo, RestoreInfo,
};
use crate::device_sync::planner::SyncMode;
use crate::device_sync::read_model::ReadError;
use crate::device_sync::read_model::{
    BackupPageRead, ConflictPageRead, EndpointRead, PreviewRead, RestoreSummaryRead,
};
use crate::device_sync::runtime::DeviceCommandError;
use crate::device_sync::usb::{UsbAction, UsbReply, UsbView};
use crate::models::{
    AlbumRule, AlbumSummary, GalleryQuery, GameTagAliasSummary, GameTagSummary, ImportSummary,
    LibraryRelocationResult, LibraryRootProbe, LoginChallenge, MediaAsset, MediaDeletionResult,
    MediaDetails, MediaExportSummary, NintendoFriendsSnapshot, OperationProgress,
    SeedExportPayload, SplatNetWebSession, SyncProgress, SyncSummary, TagUsageSummary,
};
use crate::nso::CoralSession;
use crate::settings::{AppSettings, SyncPolicy, SyncRuntimeState, SyncScheduleStatus};
use crate::sync::CancellationToken;

static CORE: OnceLock<CoreApi> = OnceLock::new();
static CURRENT_SYNC: Mutex<Option<CancellationToken>> = Mutex::new(None);

pub fn device_sync_open_library(library_root: String) -> Result<LibraryInfo, String> {
    headless::open(library_root)
}
pub fn device_sync_library_info(library: String) -> Result<LibraryInfo, String> {
    headless::library_info(&library)
}
pub fn device_sync_recover_interrupted_sessions(
    library: String,
    sessions: Vec<String>,
) -> Result<(), String> {
    headless::recover_interrupted_sessions(&library, sessions)
}
pub async fn device_sync_close_library(library: String) -> Result<(), String> {
    headless::close_library_async(&library).await
}
pub fn device_sync_journal(
    library: String,
    operation: String,
) -> Result<Option<JournalInfo>, String> {
    headless::journal(&library, &operation)
}
pub fn device_sync_backup_journal(library: String, backup: String) -> Result<JournalInfo, String> {
    headless::backup_journal(&library, &backup)
}
pub fn device_sync_host(
    library: String,
    name: String,
    tcp_address: Option<String>,
) -> Result<HostInfo, String> {
    headless::host(&library, &name, tcp_address.as_deref())
}
pub fn device_sync_client(
    library: String,
    invitation: String,
    name: String,
) -> Result<String, String> {
    headless::client(&library, &invitation, &name)
}
pub fn device_sync_host_tcp(
    library: String,
    name: String,
    address: String,
    wifi_ssid: Option<String>,
    app_build: Option<crate::device_sync::connection::ApplicationBuild>,
) -> Result<HostInfo, String> {
    headless::host_tcp_with_network(&library, &name, &address, wifi_ssid, app_build)
}
pub fn device_sync_inspect_invitation(
    invitation: String,
    app_build: crate::device_sync::connection::ApplicationBuild,
) -> Result<crate::device_sync::connection::InvitationConnection, ReadError> {
    crate::device_sync::connection::inspect_compatible(
        &invitation,
        chrono::Utc::now().timestamp(),
        &app_build,
    )
    .map_err(|error| ReadError::session(&error))
}
pub fn device_sync_client_tcp(
    library: String,
    invitation: String,
    name: String,
) -> Result<String, String> {
    headless::client_tcp(&library, &invitation, &name)
}
pub fn device_sync_host_usb(
    library: String,
    name: String,
    app_build: Option<crate::device_sync::connection::ApplicationBuild>,
) -> Result<HostInfo, String> {
    headless::host_usb_with_build(&library, &name, app_build)
}
pub fn device_sync_client_usb(
    library: String,
    invitation: String,
    name: String,
) -> Result<String, String> {
    headless::client_usb(&library, &invitation, &name)
}
pub fn device_sync_usb_view(endpoint: String) -> Result<UsbView, ReadError> {
    headless::usb_view(&endpoint)
}
pub fn device_sync_usb_select(
    endpoint: String,
    device: String,
    storage: String,
) -> Result<(), ReadError> {
    headless::usb_select(&endpoint, &device, &storage)
}
pub async fn device_sync_usb_next(endpoint: String) -> Result<Option<UsbAction>, ReadError> {
    headless::usb_next(&endpoint).await
}
pub fn device_sync_usb_complete(endpoint: String, reply: UsbReply) -> Result<(), ReadError> {
    headless::usb_complete(&endpoint, reply)
}
pub async fn device_sync_usb_wait_closed(endpoint: String) -> Result<UsbView, ReadError> {
    headless::usb_closed(&endpoint).await
}
pub fn device_sync_status(endpoint: String) -> Result<EndpointStatus, String> {
    headless::status(&endpoint)
}
pub fn device_sync_read_endpoint(endpoint: String) -> EndpointRead {
    headless::read_endpoint(&endpoint)
}
pub fn device_sync_read_preview(endpoint: String) -> PreviewRead {
    headless::read_preview(&endpoint)
}
/// Debug acceptance-test guard; non-Debug binaries reject before endpoint lookup.
pub async fn device_sync_benchmark_require_noop(
    endpoint: String,
    binding: String,
) -> Result<bool, DeviceCommandError> {
    if !cfg!(debug_assertions) {
        return Err(DeviceCommandError::rejected(ReadError::PermissionDenied));
    }
    headless::command(&endpoint, move |driver| {
        driver.benchmark_require_noop(&binding)
    })
    .await
}
/// Fixed-field measurements are available only after successful safe cleanup.
pub fn device_sync_benchmark_metrics(endpoint: String) -> Result<Option<String>, ReadError> {
    headless::benchmark_metrics(&endpoint)
}
pub fn device_sync_read_conflicts(
    endpoint: String,
    binding: String,
    cursor: Option<String>,
    limit: usize,
) -> ConflictPageRead {
    headless::read_conflicts(&endpoint, &binding, cursor.as_deref(), limit)
}
pub fn device_sync_read_backups(
    library: String,
    cursor: Option<String>,
    limit: usize,
) -> BackupPageRead {
    headless::read_backups(&library, cursor.as_deref(), limit)
}
pub fn device_sync_read_restore_summary(restore: String, binding: String) -> RestoreSummaryRead {
    headless::read_restore_summary(&restore, &binding)
}
pub fn device_sync_poll(endpoint: String) -> Result<(), String> {
    headless::tick(&endpoint)
}
pub async fn device_sync_confirmation_code(endpoint: String) -> Result<String, DeviceCommandError> {
    headless::command(&endpoint, |d| d.confirmation_code()).await
}
pub async fn device_sync_confirm(endpoint: String) -> Result<(), DeviceCommandError> {
    headless::command(&endpoint, |d| d.confirm_pairing()).await
}
pub async fn device_sync_consent_controlled(
    endpoint: String,
    accepted: bool,
) -> Result<(), DeviceCommandError> {
    headless::command(&endpoint, move |d| d.consent_controlled(accepted)).await
}
pub async fn device_sync_approve_controlled(
    endpoint: String,
    binding: String,
) -> Result<(), DeviceCommandError> {
    headless::command(&endpoint, move |d| d.approve_controlled_preview(&binding)).await
}
pub async fn device_sync_publish_account_preview(
    endpoint: String,
    binding: String,
    added: u64,
    replaced: u64,
    removed: u64,
    kept: u64,
) -> Result<(), DeviceCommandError> {
    headless::command(&endpoint, move |d| {
        d.publish_account_preview(
            &binding,
            crate::device_sync::read_model::ChangeCounts {
                added,
                replaced,
                removed,
                kept,
            },
        )
    })
    .await
}
pub async fn device_sync_configure(
    endpoint: String,
    phone_to_desktop: bool,
    overwrite: bool,
    include_accounts: bool,
) -> Result<(), DeviceCommandError> {
    headless::command(&endpoint, move |d| {
        d.configure(
            if phone_to_desktop {
                Direction::PhoneToDesktop
            } else {
                Direction::DesktopToPhone
            },
            if overwrite {
                SyncMode::Overwrite
            } else {
                SyncMode::Merge
            },
            include_accounts,
        )
    })
    .await
}
pub async fn device_sync_export_accounts(
    endpoint: String,
    payload: Vec<u8>,
    state_digest: String,
) -> Result<(), DeviceCommandError> {
    let payload = zeroize::Zeroizing::new(payload);
    if payload.len() > crate::device_sync::accounts::MAX_ACCOUNT_BYTES || state_digest.len() > 64 {
        return Err(DeviceCommandError {
            code: crate::device_sync::read_model::ReadError::InvalidInput,
            executed: false,
        });
    }
    headless::command(&endpoint, move |d| {
        d.authorize_accounts_export(&payload, &state_digest)
    })
    .await
}
pub async fn device_sync_receive_accounts(
    endpoint: String,
    state_digest: String,
) -> Result<(), DeviceCommandError> {
    if state_digest.len() > 64 {
        return Err(DeviceCommandError {
            code: crate::device_sync::read_model::ReadError::InvalidInput,
            executed: false,
        });
    }
    headless::command(&endpoint, move |d| {
        d.authorize_accounts_receive(&state_digest)
    })
    .await
}
pub async fn device_sync_decline_accounts(endpoint: String) -> Result<(), DeviceCommandError> {
    headless::command(&endpoint, |d| d.decline_accounts()).await
}
pub async fn device_sync_account_payload(
    endpoint: String,
) -> Result<Option<Vec<u8>>, DeviceCommandError> {
    headless::local_command(&endpoint, |d| {
        d.accounts_payload()
            .map(|payload| payload.map(|p| p.to_vec()))
    })
    .await
}
pub async fn device_sync_approve(endpoint: String) -> Result<(), DeviceCommandError> {
    headless::command(&endpoint, |d| d.approve_preview()).await
}
pub async fn device_sync_approve_accounts(
    endpoint: String,
    binding: String,
    state_digest: String,
    external: String,
) -> Result<(), DeviceCommandError> {
    if binding.len() > 256 || state_digest.len() > 64 || external.len() > 36 {
        return Err(DeviceCommandError {
            code: crate::device_sync::read_model::ReadError::InvalidInput,
            executed: false,
        });
    }
    headless::command(&endpoint, move |d| {
        d.approve_accounts_preview(
            &binding,
            &state_digest,
            uuid::Uuid::parse_str(&external).map_err(|_| DriverError::Protocol)?,
        )
    })
    .await
}
pub async fn device_sync_source_final(
    endpoint: String,
    state_digest: String,
) -> Result<(), DeviceCommandError> {
    if state_digest.len() > 64 {
        return Err(DeviceCommandError {
            code: crate::device_sync::read_model::ReadError::InvalidInput,
            executed: false,
        });
    }
    headless::command(&endpoint, move |d| d.approve_accounts_final(&state_digest)).await
}
pub async fn device_sync_target_final(
    endpoint: String,
    state_digest: String,
) -> Result<(), DeviceCommandError> {
    if state_digest.len() > 64 {
        return Err(DeviceCommandError {
            code: crate::device_sync::read_model::ReadError::InvalidInput,
            executed: false,
        });
    }
    headless::command(&endpoint, move |d| {
        d.approve_accounts_target_final(&state_digest)
    })
    .await
}
pub async fn device_sync_external_check(endpoint: String) -> Result<(), DeviceCommandError> {
    headless::local_command(&endpoint, |d| d.check_external_commit()).await
}
pub async fn device_sync_external_step(endpoint: String) -> Result<(), DeviceCommandError> {
    headless::local_command(&endpoint, |d| d.external_step()).await
}
pub async fn device_sync_finalize_accounts(
    endpoint: String,
    external: String,
) -> Result<(), DeviceCommandError> {
    if external.len() > 36 {
        return Err(DeviceCommandError {
            code: crate::device_sync::read_model::ReadError::InvalidInput,
            executed: false,
        });
    }
    headless::local_command(&endpoint, move |d| {
        d.finalize_accounts(uuid::Uuid::parse_str(&external).map_err(|_| DriverError::Protocol)?)
    })
    .await
}
pub fn device_sync_drain(endpoint: String) -> Result<Vec<u8>, String> {
    headless::drain(&endpoint)
}
pub fn device_sync_ingest(endpoint: String, bytes: Vec<u8>) -> Result<(), String> {
    headless::ingest(&endpoint, &bytes)
}
pub fn device_sync_written(endpoint: String, bytes: usize) -> Result<(), String> {
    headless::written(&endpoint, bytes)
}
pub fn device_sync_finish_success(endpoint: String) -> Result<bool, String> {
    headless::finish_success(&endpoint)
}
pub fn device_sync_cancel_signal(endpoint: String) -> Result<(), String> {
    headless::cancel_signal(&endpoint)
}
pub fn device_sync_detach_transport(endpoint: String) -> Result<(), String> {
    headless::detach_transport_signal(&endpoint)
}
pub async fn device_sync_shutdown(endpoint: String) -> Result<(), String> {
    // Cancel + native settle only. The original Dart coordinator may still need
    // this endpoint's read/journal state before it requests final retirement.
    headless::shutdown_async(&endpoint).await
}
pub async fn device_sync_close_endpoint(endpoint: String) -> Result<(), String> {
    // Called after coordinator/owned I/O cleanup, not as a transport EOF handler.
    headless::close_endpoint_async(&endpoint).await
}
pub fn device_sync_compensate(library: String, operation: String) -> Result<JournalInfo, String> {
    headless::compensate(&library, &operation)
}
pub fn device_sync_preview_restore(library: String, backup: String) -> Result<RestoreInfo, String> {
    headless::preview_restore(&library, &backup)
}
pub fn device_sync_apply_restore(
    restore: String,
    binding: String,
    external: Option<String>,
) -> Result<RestoreInfo, String> {
    headless::apply_restore(&restore, &binding, external.as_deref())
}
pub fn device_sync_validate_restore(restore: String, binding: String) -> Result<(), String> {
    headless::validate_restore(&restore, &binding)
}
pub fn device_sync_finalize_restore(restore: String, external: String) -> Result<(), String> {
    headless::finalize_restore(&restore, &external)
}
pub fn device_sync_close_restore(restore: String) -> Result<(), String> {
    headless::close_restore(&restore)
}
pub fn device_sync_cancel_restore(restore: String) -> Result<(), String> {
    headless::cancel_restore(&restore)
}

pub fn init_core(library_root: String) -> Result<(), String> {
    if CORE.get().is_some() {
        return Ok(());
    }
    crate::diagnostics::configure(std::path::Path::new(&library_root));
    CORE.set(CoreApi::open(library_root).map_err(error_text)?)
        .map_err(|_| "core was initialized concurrently".to_owned())
}

pub fn probe_library_root(library_root: String) -> Result<LibraryRootProbe, String> {
    crate::database::probe_library_root(library_root).map_err(error_text)
}

pub fn load_settings() -> Result<Option<AppSettings>, String> {
    core()?.load_settings().map_err(error_text)
}

pub fn bootstrap_settings() -> Result<Option<AppSettings>, String> {
    core()?.bootstrap_settings().map_err(error_text)
}

pub fn save_settings(settings: AppSettings) -> Result<(), String> {
    core()?.save_settings(&settings).map_err(error_text)
}

pub fn save_sync_policy(policy: SyncPolicy) -> Result<(), String> {
    core()?.save_sync_policy(&policy).map_err(error_text)
}

pub fn set_runtime_proxy_policy(disable_app_proxy: bool) -> Result<(), String> {
    core()?.set_runtime_proxy_policy(disable_app_proxy);
    Ok(())
}

pub fn sync_schedule_status(account_id: String) -> Result<SyncScheduleStatus, String> {
    core()?
        .sync_schedule_status(&account_id)
        .map_err(error_text)
}

pub fn record_sync_outcome(
    account_id: String,
    found_new_media: bool,
) -> Result<SyncScheduleStatus, String> {
    core()?
        .record_sync_outcome(&account_id, found_new_media)
        .map_err(error_text)
}

pub fn sync_account_history(account_id: String) -> Result<SyncRuntimeState, String> {
    core()?
        .sync_account_history(&account_id)
        .map_err(error_text)
}

pub fn record_sync_attempt(
    account_id: String,
    status: String,
    total_found: usize,
    downloaded: usize,
    duplicates: usize,
    skipped_remote: Option<usize>,
    failed: usize,
) -> Result<SyncRuntimeState, String> {
    core()?
        .record_sync_attempt_with_skipped_remote(
            &account_id,
            &status,
            total_found,
            downloaded,
            duplicates,
            skipped_remote,
            failed,
        )
        .map_err(error_text)
}

pub fn create_nintendo_login_challenge(
    proxy_url: Option<String>,
) -> Result<LoginChallenge, String> {
    core()?
        .create_nintendo_login_challenge(proxy_url)
        .map_err(error_text)
}

pub async fn exchange_nintendo_callback(
    callback_url: String,
    expected_state: String,
    verifier: String,
    proxy_url: Option<String>,
) -> Result<String, String> {
    core()?
        .exchange_nintendo_callback(callback_url, expected_state, verifier, proxy_url)
        .await
        .map_err(error_text)
}

pub async fn establish_coral_session(
    session_token: String,
    proxy_url: Option<String>,
) -> Result<CoralSession, String> {
    core()?
        .establish_coral_session(session_token, proxy_url)
        .await
        .map_err(error_text)
}

pub async fn establish_coral_session_for_account(
    session_token: String,
    expected_account: String,
    proxy_url: Option<String>,
) -> Result<CoralSession, String> {
    core()?
        .establish_coral_session_for_account(session_token, expected_account, proxy_url)
        .await
        .map_err(error_text)
}

pub async fn nintendo_friends(
    account_id: String,
    session_token: String,
    operation_id: String,
    proxy_url: Option<String>,
) -> Result<NintendoFriendsSnapshot, String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::Friends,
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::Friends(value) => Ok(value),
        _ => unreachable!("friend tool response"),
    }
}

pub async fn nintendo_friend_avatar(
    account_id: String,
    session_token: String,
    friend_id: String,
    operation_id: String,
    proxy_url: Option<String>,
) -> Result<Vec<u8>, String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::Avatar(friend_id),
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::Avatar(value) => Ok(value),
        _ => unreachable!("avatar tool response"),
    }
}

pub async fn nintendo_friend_play_log(
    account_id: String,
    session_token: String,
    friend_id: String,
    operation_id: String,
    proxy_url: Option<String>,
) -> Result<Vec<crate::models::NintendoFriendGame>, String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::FriendPlayLog(friend_id),
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::FriendPlayLog(value) => Ok(value),
        _ => unreachable!("friend play log response"),
    }
}

pub async fn nintendo_game_image(
    account_id: String,
    session_token: String,
    game_name: String,
    operation_id: String,
    proxy_url: Option<String>,
) -> Result<Vec<u8>, String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::GameImage(game_name),
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::GameImage(value) => Ok(value),
        _ => unreachable!("game image response"),
    }
}

pub async fn nintendo_friend_code(
    account_id: String,
    session_token: String,
    operation_id: String,
    proxy_url: Option<String>,
) -> Result<crate::models::NintendoFriendCodeSnapshot, String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::FriendCode,
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::FriendCode(value) => Ok(value),
        _ => unreachable!("friend code tool response"),
    }
}

pub async fn nintendo_friend_lookup(
    account_id: String,
    session_token: String,
    friend_code: String,
    operation_id: String,
    proxy_url: Option<String>,
) -> Result<crate::models::NintendoFriendCodeUser, String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::FriendLookup(friend_code),
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::FriendLookup(value) => Ok(value),
        _ => unreachable!("friend lookup tool response"),
    }
}

pub async fn nintendo_send_friend_request(
    account_id: String,
    session_token: String,
    friend_id: String,
    operation_id: String,
    proxy_url: Option<String>,
) -> Result<crate::models::NintendoFriendRequestResult, String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::FriendRequest(friend_id),
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::FriendRequest(value) => Ok(value),
        _ => unreachable!("friend request tool response"),
    }
}

pub async fn nintendo_update_friend_note(
    account_id: String,
    session_token: String,
    friend_id: String,
    note: String,
    operation_id: String,
    proxy_url: Option<String>,
) -> Result<(), String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::FriendNote { friend_id, note },
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::FriendNote => Ok(()),
        _ => unreachable!("friend note tool response"),
    }
}

pub async fn prepare_splatnet_session(
    account_id: String,
    session_token: String,
    operation_id: String,
    force_refresh: bool,
    proxy_url: Option<String>,
) -> Result<SplatNetWebSession, String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::Web { force_refresh },
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::Web(value) => Ok(value),
        _ => unreachable!("web tool response"),
    }
}

pub async fn prepare_seed_export(
    account_id: String,
    session_token: String,
    operation_id: String,
    proxy_url: Option<String>,
) -> Result<SeedExportPayload, String> {
    match core()?
        .account_tool(
            account_id,
            session_token,
            operation_id,
            proxy_url,
            crate::nso::account_tools::ToolRequest::Seed,
        )
        .await
        .map_err(error_text)?
    {
        crate::nso::account_tools::ToolResponse::Seed(value) => Ok(value),
        _ => unreachable!("seed tool response"),
    }
}

pub fn cancel_account_tool_operation(operation_id: String) -> Result<bool, String> {
    core()?
        .cancel_account_tool_operation(operation_id)
        .map_err(error_text)
}

pub fn clear_account_tool_cache(account_id: String) -> Result<(), String> {
    core()?
        .clear_account_tool_cache(account_id)
        .map_err(error_text)
}

pub async fn sync_nso(
    session: CoralSession,
    proxy_url: Option<String>,
) -> Result<SyncSummary, String> {
    let api = core()?;
    let cancellation = CancellationToken::default();
    register_current_sync(&cancellation)?;
    let result = api
        .sync_nso_with_cancellation(session, proxy_url, &cancellation)
        .await
        .map_err(error_text);
    clear_current_sync();
    result
}

pub async fn sync_nso_from_session_token(
    session_token: String,
    proxy_url: Option<String>,
) -> Result<SyncSummary, String> {
    let api = core()?;
    let cancellation = CancellationToken::default();
    register_current_sync(&cancellation)?;
    let result = api
        .sync_nso_from_session_token(session_token, proxy_url, &cancellation)
        .await
        .map_err(error_text);
    clear_current_sync();
    result
}

pub async fn sync_nso_from_session_token_for_account(
    session_token: String,
    expected_account: String,
    proxy_url: Option<String>,
) -> Result<SyncSummary, String> {
    let api = core()?;
    let cancellation = CancellationToken::default();
    register_current_sync(&cancellation)?;
    let result = api
        .sync_nso_from_session_token_for_account(
            session_token,
            expected_account,
            proxy_url,
            &cancellation,
        )
        .await
        .map_err(error_text);
    clear_current_sync();
    result
}

pub fn cancel_current_sync() -> Result<bool, String> {
    let current = CURRENT_SYNC
        .lock()
        .map_err(|_| "sync mutex poisoned".to_owned())?;
    if let Some(token) = current.as_ref() {
        token.cancel();
        Ok(true)
    } else {
        Ok(false)
    }
}

pub fn current_sync_progress() -> Result<Option<SyncProgress>, String> {
    core()?.current_sync_progress().map_err(error_text)
}

pub fn list_media(query: GalleryQuery) -> Result<Vec<MediaAsset>, String> {
    core()?.list_media(query).map_err(error_text)
}

pub fn list_media_page(
    request: crate::models::GalleryPageRequest,
) -> Result<crate::models::GalleryPage, String> {
    core()?.list_media_page(request).map_err(error_text)
}

pub fn media_details(media_id: i64) -> Result<MediaDetails, String> {
    core()?.media_details(media_id).map_err(error_text)
}

pub fn list_albums() -> Result<Vec<AlbumSummary>, String> {
    core()?.list_albums().map_err(error_text)
}

pub fn list_tags() -> Result<Vec<String>, String> {
    core()?.list_tags().map_err(error_text)
}

pub fn list_tag_usage() -> Result<Vec<TagUsageSummary>, String> {
    core()?.list_tag_usage().map_err(error_text)
}

pub fn create_tag(name: String) -> Result<i64, String> {
    core()?.create_tag(name).map_err(error_text)
}

pub fn rename_tag(tag_id: i64, new_name: String) -> Result<(), String> {
    core()?.rename_tag(tag_id, new_name).map_err(error_text)
}

pub fn delete_tag(tag_id: i64) -> Result<(), String> {
    core()?.delete_tag(tag_id).map_err(error_text)
}

pub fn merge_tags(tag_ids: Vec<i64>, target_name: String) -> Result<(), String> {
    core()?.merge_tags(tag_ids, target_name).map_err(error_text)
}

pub fn list_game_tags() -> Result<Vec<GameTagSummary>, String> {
    core()?.list_game_tags().map_err(error_text)
}

pub fn list_game_media_counts(
    album_id: Option<i64>,
) -> Result<Vec<crate::models::GameMediaCount>, String> {
    core()?.list_game_media_counts(album_id).map_err(error_text)
}

pub fn list_game_tag_aliases() -> Result<Vec<GameTagAliasSummary>, String> {
    core()?.list_game_tag_aliases().map_err(error_text)
}

pub fn record_game_tag_selection(game_name: String) -> Result<(), String> {
    core()?
        .record_game_tag_selection(game_name)
        .map_err(error_text)
}

pub fn merge_game_tags(game_names: Vec<String>, target_name: String) -> Result<(), String> {
    core()?
        .merge_game_tags(game_names, target_name)
        .map_err(error_text)
}

pub fn rename_game_tag(game_name: String, target_name: String) -> Result<(), String> {
    core()?
        .rename_game_tag(game_name, target_name)
        .map_err(error_text)
}

pub async fn import_local_files(paths: Vec<String>) -> Result<ImportSummary, String> {
    core()?.import_local_files(paths).await.map_err(error_text)
}

pub async fn import_custom_files(
    paths: Vec<String>,
    game_name: String,
) -> Result<ImportSummary, String> {
    core()?
        .import_custom_files(paths, game_name)
        .await
        .map_err(error_text)
}

pub async fn import_custom_files_with_progress(
    paths: Vec<String>,
    game_name: String,
    operation_id: String,
) -> Result<ImportSummary, String> {
    core()?
        .import_custom_files_with_progress(paths, game_name, operation_id)
        .await
        .map_err(error_text)
}

pub fn current_import_progress(operation_id: String) -> Result<Option<OperationProgress>, String> {
    core()?
        .current_import_progress(&operation_id)
        .map_err(error_text)
}

pub async fn import_mtp_files(
    paths: Vec<String>,
    device_name: String,
) -> Result<ImportSummary, String> {
    core()?
        .import_mtp_files(paths, device_name)
        .await
        .map_err(error_text)
}

pub async fn export_media(
    media_ids: Vec<i64>,
    destination: String,
    name_format: String,
) -> Result<MediaExportSummary, String> {
    core()?
        .export_media(media_ids, destination, name_format)
        .await
        .map_err(error_text)
}

pub async fn commit_video_edit(
    media_id: i64,
    processed_path: String,
    overwrite: bool,
) -> Result<MediaAsset, String> {
    core()?
        .commit_video_edit(media_id, processed_path, overwrite)
        .await
        .map_err(error_text)
}

pub async fn save_video_frame(
    media_id: i64,
    bytes: Vec<u8>,
    extension: String,
) -> Result<MediaAsset, String> {
    core()?
        .save_video_frame(media_id, bytes, extension)
        .await
        .map_err(error_text)
}

pub async fn commit_merged_video(
    media_ids: Vec<i64>,
    processed_path: String,
) -> Result<MediaAsset, String> {
    core()?
        .commit_merged_video(media_ids, processed_path)
        .await
        .map_err(error_text)
}

pub fn set_favorite(media_id: i64, favorite: bool) -> Result<(), String> {
    core()?.set_favorite(media_id, favorite).map_err(error_text)
}

pub fn set_note(media_id: i64, note: String) -> Result<(), String> {
    core()?.set_note(media_id, note).map_err(error_text)
}

pub fn add_tag(media_id: i64, tag: String) -> Result<i64, String> {
    core()?.add_tag(media_id, tag).map_err(error_text)
}

pub fn replace_tags(media_id: i64, tags: Vec<String>) -> Result<(), String> {
    core()?.replace_tags(media_id, tags).map_err(error_text)
}

pub fn create_album(name: String, description: String, smart: bool) -> Result<i64, String> {
    core()?
        .create_album(name, description, smart)
        .map_err(error_text)
}

pub fn update_album(
    album_id: i64,
    name: String,
    description: String,
    smart: bool,
) -> Result<(), String> {
    core()?
        .update_album(album_id, name, description, smart)
        .map_err(error_text)
}

pub fn list_album_rules(album_id: i64) -> Result<Vec<AlbumRule>, String> {
    core()?.list_album_rules(album_id).map_err(error_text)
}

pub fn delete_album(album_id: i64) -> Result<(), String> {
    core()?.delete_album(album_id).map_err(error_text)
}

pub fn replace_album_rules(album_id: i64, rules: Vec<AlbumRule>) -> Result<(), String> {
    core()?
        .replace_album_rules(album_id, rules)
        .map_err(error_text)
}

pub fn add_media_to_album(album_id: i64, media_id: i64) -> Result<(), String> {
    core()?
        .add_media_to_album(album_id, media_id)
        .map_err(error_text)
}

pub fn delete_media(media_id: i64) -> Result<MediaDeletionResult, String> {
    core()?.delete_media(media_id).map_err(error_text)
}

pub fn remove_media_from_album(
    album_id: i64,
    media_id: i64,
) -> Result<MediaDeletionResult, String> {
    core()?
        .remove_media_from_album_and_cleanup(album_id, media_id)
        .map_err(error_text)
}

pub async fn relocate_media_library(
    settings: AppSettings,
) -> Result<LibraryRelocationResult, String> {
    core()?
        .relocate_media_library(settings)
        .await
        .map_err(error_text)
}

fn core() -> Result<&'static CoreApi, String> {
    CORE.get()
        .ok_or_else(|| "core is not initialized; call init_core first".into())
}

fn register_current_sync(cancellation: &CancellationToken) -> Result<(), String> {
    let mut current = CURRENT_SYNC
        .lock()
        .map_err(|_| "sync mutex poisoned".to_owned())?;
    if current.is_some() {
        return Err("a sync job is already running".into());
    }
    *current = Some(cancellation.clone());
    Ok(())
}

fn clear_current_sync() {
    if let Ok(mut current) = CURRENT_SYNC.lock() {
        *current = None;
    }
}

fn error_text(error: impl std::fmt::Display) -> String {
    crate::diagnostics::event("core", "operation_failed", None);
    error.to_string()
}
