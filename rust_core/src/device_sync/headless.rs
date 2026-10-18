//! Bounded, process-local FRB ownership for Task5 and headless coordinators.
//! Only encrypted channel bytes and transient authorized account projections
//! cross this API. The library journal remains the durable authority.
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};

use uuid::Uuid;

use super::clock::SystemClock;
use super::driver::{Direction, Driver};
use super::planner::SyncMode;
use super::read_model::{self as read, *};
use super::recovery::{JournalEntry, JournalStage, RecoveryOperation};
use super::{Invitation, Qr, Role, Session, Transport};
use crate::api::CoreApi;
use crate::sync::CancellationToken;

const MAX_LIBRARIES: usize = 8;
const MAX_ENDPOINTS: usize = 16;
const MAX_RESTORES: usize = 16;
type Result<T> = std::result::Result<T, String>;
fn invalid() -> String {
    "device-sync local operation is invalid or unavailable".into()
}
fn failure(_: impl std::fmt::Debug) -> String {
    invalid()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LibraryInfo {
    pub handle: String,
    pub library_uuid: String,
    pub generation: u64,
    pub pending_operation: Option<String>,
}
pub struct HostInfo {
    pub handle: String,
    pub invitation: String,
}
#[derive(Clone, Debug)]
pub struct EndpointStatus {
    pub state: String,
    pub terminal: bool,
    pub source: bool,
    pub include_accounts: bool,
    pub overwrite: bool,
    pub session: String,
    pub operation: Option<String>,
    pub target_library: Option<String>,
    pub binding: Option<String>,
    pub backup: Option<String>,
    pub cleanup_pending: bool,
    pub local_apply_installed: bool,
    pub source_grant_issued: bool,
    pub transport_detached: bool,
}
#[derive(Clone, Debug)]
pub struct JournalInfo {
    pub operation: String,
    pub library: String,
    pub backup: String,
    pub external: Option<String>,
    pub stage: String,
}
#[derive(Clone, Debug)]
pub struct RestoreInfo {
    pub handle: String,
    pub operation: String,
    pub library: String,
    pub backup: Option<String>,
    pub binding: String,
    pub current_digest: String,
    pub restored_digest: String,
}

pub(crate) struct Endpoint {
    pub(crate) owner: Mutex<super::runtime::Owner>,
    pub(crate) cancellation: CancellationToken,
    pub(crate) transport_cancel: CancellationToken,
    lifecycle: Arc<super::local_apply::LifecycleControl>,
    work: super::work::WorkControl,
    library: Uuid,
    pub(crate) runtime: Option<Arc<super::runtime::Control>>,
    published: Mutex<EndpointStatus>,
    command_slots: Arc<tokio::sync::Semaphore>,
}
impl Endpoint {
    pub(crate) fn publish(&self, driver: &Driver) {
        *self.published.lock().unwrap_or_else(|e| e.into_inner()) = driver_status(driver);
    }
}
struct Restore {
    api: Arc<CoreApi>,
    recovery: RecoveryOperation,
    receipt: Option<super::recovery::RestoreReceipt>,
    external: Option<Uuid>,
    summary: RestoreSummary,
}
struct RestoreOwner {
    inner: Mutex<Restore>,
    cancellation: CancellationToken,
}
#[derive(Default)]
struct Services {
    libraries: HashMap<Uuid, Arc<CoreApi>>,
    endpoints: HashMap<Uuid, Arc<Endpoint>>,
    restores: HashMap<Uuid, Arc<RestoreOwner>>,
    closing: HashSet<Uuid>,
}
static SERVICES: OnceLock<Mutex<Services>> = OnceLock::new();
fn services() -> &'static Mutex<Services> {
    SERVICES.get_or_init(Default::default)
}
fn id(value: &str) -> Result<Uuid> {
    Uuid::parse_str(value)
        .ok()
        .filter(|v| !v.is_nil())
        .ok_or_else(invalid)
}
fn library(value: &str) -> Result<Arc<CoreApi>> {
    services()
        .lock()
        .map_err(failure)?
        .libraries
        .get(&id(value)?)
        .cloned()
        .ok_or_else(invalid)
}
fn endpoint(value: &str) -> Result<Arc<Endpoint>> {
    services()
        .lock()
        .map_err(failure)?
        .endpoints
        .get(&id(value)?)
        .cloned()
        .ok_or_else(invalid)
}
fn restoring(value: &str) -> Result<Arc<RestoreOwner>> {
    services()
        .lock()
        .map_err(failure)?
        .restores
        .get(&id(value)?)
        .cloned()
        .ok_or_else(invalid)
}
fn with_driver<T>(handle: &str, action: impl FnOnce(&mut Driver) -> Result<T>) -> Result<T> {
    let owner = endpoint(handle)?;
    let mut inner = owner.owner.lock().map_err(failure)?;
    let result = action(inner.driver_mut());
    owner.publish(inner.driver());
    result
}
pub async fn command<T: Send + 'static>(
    handle: &str,
    action: impl FnOnce(&mut Driver) -> std::result::Result<T, super::driver::DriverError>
        + Send
        + 'static,
) -> std::result::Result<T, super::runtime::DeviceCommandError> {
    command_in_domain(handle, super::runtime::CommandDomain::Network, action).await
}
pub(crate) async fn local_command<T: Send + 'static>(
    handle: &str,
    action: impl FnOnce(&mut Driver) -> std::result::Result<T, super::driver::DriverError>
        + Send
        + 'static,
) -> std::result::Result<T, super::runtime::DeviceCommandError> {
    command_in_domain(handle, super::runtime::CommandDomain::Local, action).await
}
async fn command_in_domain<T: Send + 'static>(
    handle: &str,
    domain: super::runtime::CommandDomain,
    action: impl FnOnce(&mut Driver) -> std::result::Result<T, super::driver::DriverError>
        + Send
        + 'static,
) -> std::result::Result<T, super::runtime::DeviceCommandError> {
    use super::runtime::DeviceCommandError;
    let owner = read_owner(handle).map_err(DeviceCommandError::rejected)?;
    if let Some(runtime) = &owner.runtime {
        runtime.call(&owner.cancellation, domain, action).await
    } else {
        let permit = owner
            .command_slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| DeviceCommandError::rejected(ReadError::Busy))?;
        let (result, _permit) = tokio::task::spawn_blocking(move || {
            let mut inner = match owner.owner.lock() {
                Ok(inner) => inner,
                Err(_) => {
                    return (
                        Err(DeviceCommandError::rejected(ReadError::Internal)),
                        permit,
                    )
                }
            };
            let result = super::runtime::admit_command(inner.driver(), &owner.cancellation, domain)
                .and_then(|()| {
                    action(inner.driver_mut()).map_err(|error| DeviceCommandError {
                        code: ReadError::driver(&error),
                        executed: true,
                    })
                });
            owner.publish(inner.driver());
            (result, permit)
        })
        .await
        .map_err(|_| DeviceCommandError {
            code: ReadError::Internal,
            executed: true,
        })?;
        result
    }
}
pub fn open(root: String) -> Result<LibraryInfo> {
    let api = Arc::new(CoreApi::open(root).map_err(failure)?);
    let handle = Uuid::new_v4();
    {
        let mut registry = services().lock().map_err(failure)?;
        if registry.libraries.len() >= MAX_LIBRARIES {
            return Err(invalid());
        }
        registry.libraries.insert(handle, api);
    }
    library_info(&handle.to_string())
}
pub fn close_library(handle: &str) -> Result<()> {
    let closing = ClosingLibrary::begin(handle)?;
    for endpoint in &closing.endpoints {
        cancel_signal(endpoint)?;
    }
    for endpoint in &closing.endpoints {
        retire_for_library_close(endpoint)?;
    }
    services()
        .lock()
        .map_err(failure)?
        .libraries
        .remove(&id(handle)?)
        .ok_or_else(invalid)?;
    Ok(())
}
fn retire_for_library_close(handle: &str) -> Result<()> {
    if endpoint(handle)?.runtime.is_some() {
        close_endpoint(handle)
    } else {
        // Legacy account consumers close their library handle before observing
        // source lease retirement. The same stopped Driver retains that lease.
        shutdown(handle)
    }
}
struct ClosingLibrary {
    library: Uuid,
    endpoints: Vec<String>,
}
impl ClosingLibrary {
    fn begin(handle: &str) -> Result<Self> {
        let library = id(handle)?;
        let mut registry = services().lock().map_err(failure)?;
        if !registry.libraries.contains_key(&library) || !registry.closing.insert(library) {
            return Err(invalid());
        }
        let endpoints = registry
            .endpoints
            .iter()
            .filter(|(_, endpoint)| endpoint.library == library)
            .map(|(id, _)| id.to_string())
            .collect();
        Ok(Self { library, endpoints })
    }
}
impl Drop for ClosingLibrary {
    fn drop(&mut self) {
        services()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .closing
            .remove(&self.library);
    }
}
pub async fn close_library_async(handle: &str) -> Result<()> {
    let closing = ClosingLibrary::begin(handle)?;
    for endpoint in &closing.endpoints {
        cancel_signal(endpoint)?;
    }
    for endpoint in &closing.endpoints {
        shutdown_async(endpoint).await?;
    }
    for endpoint in &closing.endpoints {
        retire_for_library_close(endpoint)?;
    }
    services()
        .lock()
        .map_err(failure)?
        .libraries
        .remove(&closing.library)
        .ok_or_else(invalid)?;
    Ok(())
}
pub fn library_info(handle: &str) -> Result<LibraryInfo> {
    let api = library(handle)?;
    let database = api.database();
    let header = database.device_sync_header().map_err(failure)?;
    Ok(LibraryInfo {
        handle: handle.into(),
        library_uuid: header.library_uuid,
        generation: header.generation,
        pending_operation: database
            .device_sync_pending_journal()
            .map_err(failure)?
            .map(|p| p.operation_uuid.to_string()),
    })
}
fn journal_info(entry: JournalEntry) -> JournalInfo {
    JournalInfo {
        operation: entry.operation_uuid.to_string(),
        library: entry.library_uuid,
        backup: entry.backup_uuid.to_string(),
        external: entry.external_reference.map(|e| e.to_string()),
        stage: match entry.stage {
            JournalStage::Prepared => "prepared",
            JournalStage::LibraryApplied => "library_applied",
            JournalStage::RolledBack => "rolled_back",
            JournalStage::Finalized => "finalized",
        }
        .into(),
    }
}
pub fn journal(handle: &str, operation: &str) -> Result<Option<JournalInfo>> {
    Ok(library(handle)?
        .database()
        .device_sync_journal(id(operation)?)
        .map_err(failure)?
        .map(journal_info))
}
pub fn backup_journal(handle: &str, backup: &str) -> Result<JournalInfo> {
    library(handle)?
        .database()
        .device_sync_backup_journal(id(backup)?)
        .map(journal_info)
        .map_err(failure)
}
fn insert_endpoint(
    driver: Driver,
    library: Uuid,
    start: Option<super::runtime::Start>,
) -> Result<String> {
    let handle = Uuid::new_v4();
    let cancellation = driver.cancellation();
    let lifecycle = driver.lifecycle_control();
    let work = driver.work_control();
    let published = driver_status(&driver);
    let (runtime, receiver) = match start.as_ref() {
        Some(start) => {
            let (control, receiver) = super::runtime::Control::new(start);
            (Some(control), Some(receiver))
        }
        None => (None, None),
    };
    let endpoint = Arc::new(Endpoint {
        owner: Mutex::new(super::runtime::Owner::Plain(driver)),
        cancellation,
        transport_cancel: CancellationToken::default(),
        lifecycle,
        work,
        library,
        runtime,
        published: Mutex::new(published),
        command_slots: Arc::new(tokio::sync::Semaphore::new(16)),
    });
    let mut registry = services().lock().map_err(failure)?;
    if registry.endpoints.len() >= MAX_ENDPOINTS
        || registry.closing.contains(&library)
        || !registry.libraries.contains_key(&library)
    {
        return Err(invalid());
    }
    registry.endpoints.insert(handle, endpoint.clone());
    if let Some(start) = start {
        if super::runtime::launch(endpoint, start, receiver.expect("managed queue")).is_err() {
            registry.endpoints.remove(&handle);
            return Err(invalid());
        }
    }
    Ok(handle.to_string())
}
pub fn host(handle: &str, name: &str, tcp_address: Option<&str>) -> Result<HostInfo> {
    host_started(handle, name, tcp_address, None)
}
fn host_started(
    handle: &str,
    name: &str,
    tcp_address: Option<&str>,
    start: Option<super::runtime::Start>,
) -> Result<HostInfo> {
    host_started_with_build(handle, name, tcp_address, start, None)
}
fn host_started_with_build(
    handle: &str,
    name: &str,
    tcp_address: Option<&str>,
    start: Option<super::runtime::Start>,
    app_build: Option<super::connection::ApplicationBuild>,
) -> Result<HostInfo> {
    let api = library(handle)?;
    let now = chrono::Utc::now().timestamp();
    // Transport ownership is supplied by Task5; this is the same TLS session,
    // not a separate plaintext/testing protocol.
    let transport = match tcp_address {
        Some(address) => Transport::Tcp(address.parse().map_err(failure)?),
        None => Transport::Usb,
    };
    let mut invitation = Invitation::create(transport, now).map_err(failure)?;
    if app_build.is_some() {
        invitation.delegate_to_phone().map_err(failure)?;
    }
    invitation.set_app_build(app_build).map_err(failure)?;
    let encoded = invitation.qr.encode().map_err(failure)?;
    let session = invitation
        .accept(Role::Receiver, name, now)
        .map_err(failure)?;
    let driver = Driver::new(
        session,
        api.database(),
        name,
        Arc::new(SystemClock::default()),
    )
    .map_err(failure)?;
    Ok(HostInfo {
        handle: insert_endpoint(driver, id(handle)?, start)?,
        invitation: encoded,
    })
}
pub fn client(handle: &str, invitation: &str, name: &str) -> Result<String> {
    client_started(handle, invitation, name, None)
}
fn client_started(
    handle: &str,
    invitation: &str,
    name: &str,
    start: Option<super::runtime::Start>,
) -> Result<String> {
    let api = library(handle)?;
    let now = chrono::Utc::now().timestamp();
    let qr = Qr::parse(invitation, now).map_err(failure)?;
    if matches!(start, Some(super::runtime::Start::Usb(_))) && qr.transport() != &Transport::Usb {
        return Err(invalid());
    }
    let session = Session::client(qr, Role::Sender, name, now).map_err(failure)?;
    insert_endpoint(
        Driver::new(
            session,
            api.database(),
            name,
            Arc::new(SystemClock::default()),
        )
        .map_err(failure)?,
        id(handle)?,
        start,
    )
}
pub fn host_usb(handle: &str, name: &str) -> Result<HostInfo> {
    host_started(
        handle,
        name,
        None,
        Some(super::runtime::Start::Usb(super::usb::Start::Native)),
    )
}
pub fn host_usb_with_build(
    handle: &str,
    name: &str,
    app_build: Option<super::connection::ApplicationBuild>,
) -> Result<HostInfo> {
    host_started_with_build(
        handle,
        name,
        None,
        Some(super::runtime::Start::Usb(super::usb::Start::Native)),
        app_build,
    )
}
pub fn client_usb(handle: &str, invitation: &str, name: &str) -> Result<String> {
    client_started(
        handle,
        invitation,
        name,
        Some(super::runtime::Start::Usb(super::usb::Start::Saf)),
    )
}
#[cfg(test)]
pub(crate) fn host_usb_test(handle: &str, name: &str) -> Result<HostInfo> {
    host_started(
        handle,
        name,
        None,
        Some(super::runtime::Start::Usb(
            super::usb::Start::DesktopActions,
        )),
    )
}
#[cfg(test)]
pub(crate) fn host_usb_fixture(handle: &str, path: std::path::PathBuf) -> Result<HostInfo> {
    host_started(
        handle,
        "Fixture",
        None,
        Some(super::runtime::Start::Usb(
            super::usb::Start::NativeFixture(path),
        )),
    )
}
fn usb_control(handle: &str) -> std::result::Result<Arc<super::usb::Control>, ReadError> {
    read_owner(handle)?
        .runtime
        .as_ref()
        .and_then(|r| r.usb.clone())
        .ok_or(ReadError::Unavailable)
}
pub fn usb_view(handle: &str) -> std::result::Result<super::usb::UsbView, ReadError> {
    Ok(usb_control(handle)?.view())
}
pub fn usb_select(handle: &str, device: &str, storage: &str) -> std::result::Result<(), ReadError> {
    usb_control(handle)?.select(device, storage)
}
pub async fn usb_next(
    handle: &str,
) -> std::result::Result<Option<super::usb::UsbAction>, ReadError> {
    usb_control(handle)?.next().await
}
pub fn usb_complete(
    handle: &str,
    reply: super::usb::UsbReply,
) -> std::result::Result<(), ReadError> {
    usb_control(handle)?.complete(reply)
}
pub async fn usb_closed(handle: &str) -> std::result::Result<super::usb::UsbView, ReadError> {
    usb_control(handle)?.wait_closed().await
}
pub(crate) fn host_bound(
    handle: &str,
    name: &str,
    listener: std::net::TcpListener,
) -> Result<HostInfo> {
    host_bound_with_network(handle, name, listener, None, None)
}
fn host_bound_with_network(
    handle: &str,
    name: &str,
    listener: std::net::TcpListener,
    wifi_ssid: Option<String>,
    app_build: Option<super::connection::ApplicationBuild>,
) -> Result<HostInfo> {
    let address = listener.local_addr().map_err(failure)?;
    let api = library(handle)?;
    let now = chrono::Utc::now().timestamp();
    let mut invitation = Invitation::create(Transport::Tcp(address), now).map_err(failure)?;
    invitation.set_wifi_ssid(wifi_ssid).map_err(failure)?;
    if app_build.is_some() {
        invitation.delegate_to_phone().map_err(failure)?;
    }
    invitation.set_app_build(app_build).map_err(failure)?;
    let encoded = invitation.qr.encode().map_err(failure)?;
    let session = invitation
        .accept(Role::Receiver, name, now)
        .map_err(failure)?;
    let driver = Driver::new(
        session,
        api.database(),
        name,
        Arc::new(SystemClock::default()),
    )
    .map_err(failure)?;
    Ok(HostInfo {
        handle: insert_endpoint(
            driver,
            id(handle)?,
            Some(super::runtime::Start::Listen(listener)),
        )?,
        invitation: encoded,
    })
}
pub fn host_tcp(handle: &str, name: &str, address: &str) -> Result<HostInfo> {
    let address = address.parse().map_err(failure)?;
    super::runtime::validate_bind(address).map_err(failure)?;
    let listener = std::net::TcpListener::bind(address).map_err(failure)?;
    host_bound(handle, name, listener)
}
pub fn host_tcp_with_network(
    handle: &str,
    name: &str,
    address: &str,
    wifi_ssid: Option<String>,
    app_build: Option<super::connection::ApplicationBuild>,
) -> Result<HostInfo> {
    let address = address.parse().map_err(failure)?;
    super::runtime::validate_bind(address).map_err(failure)?;
    let listener = std::net::TcpListener::bind(address).map_err(failure)?;
    host_bound_with_network(handle, name, listener, wifi_ssid, app_build)
}
pub fn client_tcp(handle: &str, invitation: &str, name: &str) -> Result<String> {
    let api = library(handle)?;
    let now = chrono::Utc::now().timestamp();
    let qr = Qr::parse(invitation, now).map_err(failure)?;
    let address = match qr.transport() {
        Transport::Tcp(address) => *address,
        _ => return Err(invalid()),
    };
    super::runtime::validate_bind(address).map_err(failure)?;
    client_qr(handle, name, api, qr, address)
}
fn client_qr(
    handle: &str,
    name: &str,
    api: Arc<CoreApi>,
    qr: Qr,
    address: std::net::SocketAddr,
) -> Result<String> {
    let now = chrono::Utc::now().timestamp();
    let session = Session::client(qr, Role::Sender, name, now).map_err(failure)?;
    let driver = Driver::new(
        session,
        api.database(),
        name,
        Arc::new(SystemClock::default()),
    )
    .map_err(failure)?;
    insert_endpoint(
        driver,
        id(handle)?,
        Some(super::runtime::Start::Connect(address)),
    )
}
#[cfg(test)]
pub(crate) fn client_tcp_test(handle: &str, invitation: &str, name: &str) -> Result<String> {
    let qr = Qr::parse(invitation, chrono::Utc::now().timestamp()).map_err(failure)?;
    let address = match qr.transport() {
        Transport::Tcp(address) => *address,
        _ => return Err(invalid()),
    };
    client_qr(handle, name, library(handle)?, qr, address)
}
fn driver_status(d: &Driver) -> EndpointStatus {
    EndpointStatus {
        state: format!("{:?}", d.state()),
        terminal: d.state().terminal(),
        source: d.is_source(),
        include_accounts: d.accounts_included(),
        overwrite: d.overwrite(),
        session: d.session_id().into(),
        operation: d.receive_operation_id().map(|u| u.to_string()),
        target_library: d.target_library_id().map(str::to_owned),
        binding: d.preview_binding().map(str::to_owned),
        backup: d.receipt().map(|r| r.backup_uuid.to_string()),
        cleanup_pending: d.cleanup_pending(),
        local_apply_installed: d.local_apply_installed(),
        source_grant_issued: d.source_grant_issued(),
        transport_detached: d.transport_detached(),
    }
}
pub fn status(handle: &str) -> Result<EndpointStatus> {
    let owner = endpoint(handle)?;
    if let Ok(inner) = owner.owner.try_lock() {
        owner.publish(inner.driver());
    }
    let published = owner.published.lock().map_err(failure)?.clone();
    Ok(published)
}

fn read_id(handle: &str) -> std::result::Result<Uuid, ReadError> {
    Uuid::parse_str(handle)
        .ok()
        .filter(|id| !id.is_nil())
        .ok_or(ReadError::InvalidInput)
}
fn read_owner(handle: &str) -> std::result::Result<Arc<Endpoint>, ReadError> {
    let id = read_id(handle)?;
    services()
        .lock()
        .map_err(|_| ReadError::Internal)?
        .endpoints
        .get(&id)
        .cloned()
        .ok_or(ReadError::Unavailable)
}
fn read_library(handle: &str) -> std::result::Result<Arc<CoreApi>, ReadError> {
    let id = read_id(handle)?;
    services()
        .lock()
        .map_err(|_| ReadError::Internal)?
        .libraries
        .get(&id)
        .cloned()
        .ok_or(ReadError::Unavailable)
}
fn read_lock<T>(mutex: &Mutex<T>) -> std::result::Result<std::sync::MutexGuard<'_, T>, ReadError> {
    mutex.try_lock().map_err(|error| match error {
        std::sync::TryLockError::WouldBlock => ReadError::Busy,
        std::sync::TryLockError::Poisoned(_) => ReadError::Internal,
    })
}
pub fn read_endpoint(handle: &str) -> EndpointRead {
    let owner = match read_owner(handle) {
        Ok(owner) => owner,
        Err(error) => {
            return EndpointRead {
                value: None,
                error: Some(error),
                progress: ProgressView::observing(&Default::default()),
                tcp: None,
            }
        }
    };
    let mut progress = ProgressView::observing(&owner.work);
    let tcp = owner
        .runtime
        .as_ref()
        .filter(|runtime| runtime.usb.is_none())
        .map(|runtime| runtime.view());
    let result = read_lock(&owner.owner).map(|inner| inner.driver().read_view());
    match result {
        Ok(value) => {
            progress = value.progress.clone();
            EndpointRead {
                value: Some(value),
                progress,
                error: None,
                tcp,
            }
        }
        Err(error) => EndpointRead {
            value: None,
            progress,
            error: Some(error),
            tcp,
        },
    }
}
pub fn read_preview(handle: &str) -> PreviewRead {
    (|| {
        let owner = read_owner(handle)?;
        let inner = read_lock(&owner.owner)?;
        let driver = inner.driver();
        if driver.state().terminal() {
            return Err(ReadError::PreviewChanged);
        }
        driver
            .preview_summary()
            .cloned()
            .ok_or(ReadError::Unavailable)
    })()
    .into()
}
pub fn read_conflicts(
    handle: &str,
    binding: &str,
    after: Option<&str>,
    limit: usize,
) -> ConflictPageRead {
    (|| {
        read::check_limit(limit)?;
        let owner = read_owner(handle)?;
        let inner = read_lock(&owner.owner)?;
        let driver = inner.driver();
        if driver.state().terminal() || driver.preview_binding() != Some(binding) {
            return Err(ReadError::PreviewChanged);
        }
        let plan = driver.plan().ok_or(ReadError::Unavailable)?;
        let scope = format!("conflict:{handle}:{}:{binding}", driver.session_id());
        read::conflict_page(plan, &scope, after, limit)
    })()
    .into()
}
pub fn read_backups(handle: &str, after: Option<&str>, limit: usize) -> BackupPageRead {
    (|| {
        read::check_limit(limit)?;
        let api = read_library(handle)?;
        let scope = format!("backup:{handle}");
        let after = after
            .map(|value| {
                let raw = read::position(&scope, value)?;
                let position = raw.parse::<i64>().map_err(|_| ReadError::PreviewChanged)?;
                if position.to_string() != raw {
                    return Err(ReadError::PreviewChanged);
                }
                Ok(position)
            })
            .transpose()?;
        let items = api
            .database()
            .device_sync_backup_metadata_scan(after, limit + 1)
            .map_err(|e| ReadError::core(&e))?;
        let mut page = BackupPage {
            items: vec![],
            next: None,
        };
        let more = items.len() > limit;
        let mut previous_position = None;
        for (index, (position, item)) in items.into_iter().take(limit).enumerate() {
            page.next = Some(read::cursor(&scope, &position.to_string()));
            page.items.push(item);
            if !read::fits(&page)? {
                page.items.pop();
                let previous = previous_position.ok_or(ReadError::InvalidInput)?;
                page.next = Some(read::cursor(&scope, &format!("{previous}")));
                return Ok(page);
            }
            previous_position = Some(position);
            if index + 1 == limit && more {
                return Ok(page);
            }
        }
        page.next = None;
        Ok(page)
    })()
    .into()
}
pub fn read_restore_summary(handle: &str, binding: &str) -> RestoreSummaryRead {
    (|| {
        let id = read_id(handle)?;
        let owner = services()
            .lock()
            .map_err(|_| ReadError::Internal)?
            .restores
            .get(&id)
            .cloned()
            .ok_or(ReadError::Unavailable)?;
        let restore = read_lock(&owner.inner)?;
        if restore.receipt.is_some() || restore.summary.binding != binding {
            return Err(ReadError::PreviewChanged);
        }
        owner
            .cancellation
            .check()
            .map_err(|error| ReadError::core(&error))?;
        Ok(restore.summary.clone())
    })()
    .into()
}
pub fn tick(handle: &str) -> Result<()> {
    reject_managed_io(handle)?;
    with_driver(handle, |d| d.poll().map_err(failure))
}
pub fn confirmation_code(handle: &str) -> Result<String> {
    with_driver(handle, |d| d.confirmation_code().map_err(failure))
}
pub fn confirm(handle: &str) -> Result<()> {
    with_driver(handle, |d| d.confirm_pairing().map_err(failure))
}
pub fn configure(
    handle: &str,
    phone_to_desktop: bool,
    overwrite: bool,
    accounts: bool,
) -> Result<()> {
    with_driver(handle, |d| {
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
            accounts,
        )
        .map_err(failure)
    })
}
pub fn export_accounts(handle: &str, payload: &[u8], state: &str) -> Result<()> {
    with_driver(handle, |d| {
        d.authorize_accounts_export(payload, state).map_err(failure)
    })
}
pub fn receive_accounts(handle: &str, state: &str) -> Result<()> {
    with_driver(handle, |d| {
        d.authorize_accounts_receive(state).map_err(failure)
    })
}
pub fn decline_accounts(handle: &str) -> Result<()> {
    with_driver(handle, |d| d.decline_accounts().map_err(failure))
}
pub fn account_payload(handle: &str) -> Result<Option<Vec<u8>>> {
    with_driver(handle, |d| {
        Ok(d.accounts_payload()
            .map_err(failure)?
            .map(|bytes| bytes.to_vec()))
    })
}
pub fn approve(handle: &str) -> Result<()> {
    with_driver(handle, |d| d.approve_preview().map_err(failure))
}
pub fn approve_accounts(handle: &str, binding: &str, current: &str, external: &str) -> Result<()> {
    let external = id(external)?;
    with_driver(handle, |d| {
        d.approve_accounts_preview(binding, current, external)
            .map_err(failure)
    })
}
pub fn source_final(handle: &str, current: &str) -> Result<()> {
    with_driver(handle, |d| {
        d.approve_accounts_final(current).map_err(failure)
    })
}
pub fn target_final(handle: &str, current: &str) -> Result<()> {
    with_driver(handle, |d| {
        d.approve_accounts_target_final(current).map_err(failure)
    })
}
pub fn external_check(handle: &str) -> Result<()> {
    with_driver(handle, |d| d.check_external_commit().map_err(failure))
}
pub fn external_step(handle: &str) -> Result<()> {
    with_driver(handle, |d| d.external_step().map_err(failure))
}
pub fn finalize_accounts(handle: &str, external: &str) -> Result<()> {
    let external = id(external)?;
    with_driver(handle, |d| d.finalize_accounts(external).map_err(failure))
}
pub fn drain(handle: &str) -> Result<Vec<u8>> {
    reject_managed_io(handle)?;
    with_driver(handle, |d| d.drain_ciphertext().map_err(failure))
}
pub fn ingest(handle: &str, bytes: &[u8]) -> Result<()> {
    reject_managed_io(handle)?;
    with_driver(handle, |d| d.ingest_ciphertext(bytes).map_err(failure))
}
pub fn written(handle: &str, bytes: usize) -> Result<()> {
    reject_managed_io(handle)?;
    with_driver(handle, |d| d.ciphertext_written(bytes).map_err(failure))
}
pub fn finish_success(handle: &str) -> Result<bool> {
    reject_managed_io(handle)?;
    with_driver(handle, |d| Ok(d.finish_success()))
}
fn reject_managed_io(handle: &str) -> Result<()> {
    if endpoint(handle)?.runtime.is_some() {
        return Err(invalid());
    }
    Ok(())
}
/// Independent from the Driver mutex, including a currently scanning poll.
pub fn detach_transport_signal(handle: &str) -> Result<()> {
    let owner = endpoint(handle)?;
    if owner.runtime.is_none() {
        return Err(invalid());
    }
    // Natural transport failure is not an operation-cancel/settle/retire signal.
    owner.transport_cancel.cancel();
    if let Some(usb) = owner
        .runtime
        .as_ref()
        .and_then(|runtime| runtime.usb.as_ref())
    {
        usb.detach();
    }
    Ok(())
}
/// Independent local cancellation, including a currently scanning poll.
pub fn cancel_signal(handle: &str) -> Result<()> {
    let owner = endpoint(handle)?;
    owner.lifecycle.cancel();
    owner.transport_cancel.cancel();
    if let Some(runtime) = &owner.runtime {
        runtime.request_settle();
    }
    if let Some(usb) = owner.runtime.as_ref().and_then(|r| r.usb.as_ref()) {
        usb.cancel();
    }
    Ok(())
}
pub fn shutdown(handle: &str) -> Result<()> {
    cancel_signal(handle)?;
    if let Some(runtime) = &endpoint(handle)?.runtime {
        runtime.wait_settled();
    }
    with_driver(handle, |d| {
        d.cancel();
        d.finish_shutdown();
        Ok(())
    })
}
pub async fn shutdown_async(handle: &str) -> Result<()> {
    let owner = endpoint(handle)?;
    cancel_signal(handle)?;
    if let Some(runtime) = &owner.runtime {
        runtime.settled().await;
        Ok(())
    } else {
        let handle = handle.to_owned();
        tokio::task::spawn_blocking(move || shutdown(&handle))
            .await
            .map_err(failure)?
    }
}
pub async fn close_endpoint_async(handle: &str) -> Result<()> {
    shutdown_async(handle).await?;
    ensure_retirable(handle)?;
    let owner = endpoint(handle)?;
    if let Some(runtime) = &owner.runtime {
        runtime.retire();
        runtime.stopped().await;
    }
    remove_endpoint(handle)
}
pub fn close_endpoint(handle: &str) -> Result<()> {
    shutdown(handle)?;
    ensure_retirable(handle)?;
    if let Some(runtime) = &endpoint(handle)?.runtime {
        runtime.retire();
        runtime.wait_stopped();
    }
    remove_endpoint(handle)
}
fn remove_endpoint(handle: &str) -> Result<()> {
    services()
        .lock()
        .map_err(failure)?
        .endpoints
        .remove(&id(handle)?)
        .ok_or_else(invalid)?;
    Ok(())
}
fn ensure_retirable(handle: &str) -> Result<()> {
    if status(handle)?.cleanup_pending {
        return Err("device-sync issued lease cleanup is pending".into());
    }
    Ok(())
}
pub fn compensate(handle: &str, operation: &str) -> Result<JournalInfo> {
    let api = library(handle)?;
    let mut recovery = RecoveryOperation::preview_pending(api.database(), id(operation)?, "Local")
        .map_err(failure)?;
    let mut authorization = recovery.authorize().map_err(failure)?;
    recovery
        .restore(Some(&mut authorization), &CancellationToken::default())
        .map_err(failure)?;
    journal(handle, operation)?.ok_or_else(invalid)
}
pub fn preview_restore(handle: &str, backup: &str) -> Result<RestoreInfo> {
    let api = library(handle)?;
    let cancellation = CancellationToken::default();
    let work = super::work::WorkControl::new(cancellation.clone());
    let metadata = api
        .database()
        .device_sync_backup_metadata(id(backup)?)
        .map_err(failure)?;
    let recovery =
        RecoveryOperation::preview_backup_controlled(api.database(), id(backup)?, "Local", &work)
            .map_err(failure)?;
    let operation = recovery.operation_id().to_string();
    let library = recovery.current().manifest.header.library_uuid.clone();
    let binding = recovery.preview_binding().map_err(failure)?;
    let current_digest = recovery.current().digest().map_err(failure)?;
    let restored_digest = recovery.restored().digest().map_err(failure)?;
    let plan = super::planner::build_plan(
        &recovery.restored().manifest,
        &recovery.current().manifest,
        SyncMode::Overwrite,
    )
    .map_err(failure)?;
    let counts = read::summarize(&plan, &binding, None, &Default::default()).map_err(failure)?;
    let summary = RestoreSummary {
        binding: binding.clone(),
        current_digest: current_digest.clone(),
        restored_digest: restored_digest.clone(),
        media: counts.media,
        albums: counts.albums,
        includes_accounts: metadata.includes_accounts.ok_or_else(invalid)?,
    };
    let handle = Uuid::new_v4();
    let mut registry = services().lock().map_err(failure)?;
    if registry.restores.len() >= MAX_RESTORES {
        return Err(invalid());
    }
    registry.restores.insert(
        handle,
        Arc::new(RestoreOwner {
            inner: Mutex::new(Restore {
                api,
                recovery,
                receipt: None,
                external: None,
                summary,
            }),
            cancellation,
        }),
    );
    Ok(RestoreInfo {
        handle: handle.to_string(),
        operation,
        library,
        backup: None,
        binding,
        current_digest,
        restored_digest,
    })
}
pub fn validate_restore(handle: &str, binding: &str) -> Result<()> {
    let owner = restoring(handle)?;
    let restore = owner.inner.lock().map_err(failure)?;
    owner.cancellation.check().map_err(failure)?;
    if restore.receipt.is_some()
        || binding != restore.recovery.preview_binding().map_err(failure)?
    {
        return Err(invalid());
    }
    restore.recovery.validate_preview().map_err(failure)
}
pub fn apply_restore(handle: &str, binding: &str, external: Option<&str>) -> Result<RestoreInfo> {
    let owner = restoring(handle)?;
    let mut restore = owner.inner.lock().map_err(failure)?;
    if restore.receipt.is_some()
        || binding != restore.recovery.preview_binding().map_err(failure)?
    {
        return Err(invalid());
    }
    let external = external.map(id).transpose()?;
    let library = restore
        .recovery
        .current()
        .manifest
        .header
        .library_uuid
        .clone();
    let summary = restore.summary.clone();
    let mut authorization = restore.recovery.authorize().map_err(failure)?;
    let receipt = restore
        .recovery
        .restore_with_external(Some(&mut authorization), external, &owner.cancellation)
        .map_err(failure)?;
    let operation = receipt.operation_uuid;
    let backup = receipt.backup_uuid;
    restore.receipt = Some(receipt);
    restore.external = external;
    Ok(RestoreInfo {
        handle: handle.into(),
        operation: operation.to_string(),
        library,
        backup: Some(backup.to_string()),
        binding: summary.binding,
        current_digest: summary.current_digest,
        restored_digest: summary.restored_digest,
    })
}
pub fn finalize_restore(handle: &str, external: &str) -> Result<()> {
    let owner = restoring(handle)?;
    let restore = owner.inner.lock().map_err(failure)?;
    owner.cancellation.check().map_err(failure)?;
    let external = id(external)?;
    if restore.external != Some(external) {
        return Err(invalid());
    }
    let operation = restore.receipt.as_ref().ok_or_else(invalid)?.operation_uuid;
    let mut recovery = RecoveryOperation::preview_pending_controlled(
        restore.api.database(),
        operation,
        "Local",
        &super::work::WorkControl::new(owner.cancellation.clone()),
    )
    .map_err(failure)?;
    let mut authorization = recovery.authorize().map_err(failure)?;
    recovery
        .finalize_guarded(
            Some(&mut authorization),
            Some(external),
            &owner.cancellation,
            None,
        )
        .map_err(failure)
}
pub fn close_restore(handle: &str) -> Result<()> {
    services()
        .lock()
        .map_err(failure)?
        .restores
        .remove(&id(handle)?)
        .ok_or_else(invalid)?;
    Ok(())
}
pub fn cancel_restore(handle: &str) -> Result<()> {
    restoring(handle)?.cancellation.cancel();
    Ok(())
}

#[cfg(test)]
pub(crate) mod owner_test_tools {
    use super::*;
    pub(crate) static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    pub(crate) fn runtime_api(handle: &str) -> Arc<CoreApi> {
        library(handle).unwrap()
    }
    pub(crate) fn phone_usb_actions(handle: &str, name: &str) -> HostInfo {
        host_started_with_build(
            handle,
            name,
            None,
            Some(super::super::runtime::Start::Usb(
                super::super::usb::Start::DesktopActions,
            )),
            Some(super::super::connection::ApplicationBuild {
                version: "0.2.14".into(),
                build_number: "47".into(),
            }),
        )
        .unwrap()
    }

    pub(crate) fn with_existing_restore(
        root: String,
        backup: &str,
        test: impl FnOnce(Arc<crate::database::Database>, &str, &RestoreInfo),
    ) {
        with_restore_response(root, backup, |database, library, preview, _| {
            test(database, library, preview);
            let owner = restoring(&preview.handle).unwrap();
            let restore = owner.inner.lock().unwrap();
            assert!(restore.receipt.is_none());
            // A consumed capability would return AuthorizationMismatch before
            // checking cancellation. The original same preview remains unconsumed.
            assert!(matches!(
                restore.recovery.validate_preview(),
                Err(super::super::receiver::ReceiverError::Core(
                    crate::error::CoreError::Cancelled
                ))
            ));
        });
    }

    pub(crate) fn with_restore_response(
        root: String,
        backup: &str,
        test: impl FnOnce(Arc<crate::database::Database>, &str, &RestoreInfo, &CancellationToken),
    ) {
        struct Owners {
            library: String,
            restore: String,
        }
        impl Drop for Owners {
            fn drop(&mut self) {
                close_restore(&self.restore).unwrap();
                close_library(&self.library).unwrap();
            }
        }
        let opened = open(root).unwrap();
        let preview = preview_restore(&opened.handle, backup).unwrap();
        let _owners = Owners {
            library: opened.handle.clone(),
            restore: preview.handle.clone(),
        };
        let api = library(&opened.handle).unwrap();
        let owner = restoring(&preview.handle).unwrap();
        test(
            api.database(),
            &opened.handle,
            &preview,
            &owner.cancellation,
        );
    }
}

#[cfg(test)]
#[path = "runtime_local_apply_tests.rs"]
mod runtime_local_apply_tests;
