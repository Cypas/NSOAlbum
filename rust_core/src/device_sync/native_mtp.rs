//! Used exclusively in the disposable native worker, never the UI process.
use super::io_metrics::{IoMetrics, IoStep};
use super::native_io::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use futures::{Stream, StreamExt};
use mtp_rs::mtp::{
    Backend, ListingItem, MtpDevice, NewObjectInfo, ObjectHandle, ObjectInfo, Storage, StorageId,
};
use std::collections::HashSet;
use std::time::Instant;

#[derive(Default)]
pub struct MtpWorker {
    devices: Vec<(String, String)>,
    device: Option<MtpDevice>,
    storage: Option<Storage>,
    operation: Option<(String, String)>,
    folders: Option<[ObjectHandle; 2]>,
    receipts: BlockReceipts,
    indexes: [Option<Vec<ObjectInfo>>; 2],
    timings: IoMetrics,
}
fn builder() -> mtp_rs::mtp::MtpDeviceBuilder {
    MtpDevice::builder()
        .backend(if cfg!(windows) {
            Backend::Wpd
        } else {
            Backend::Usb
        })
        .timeout(std::time::Duration::from_secs(5))
}
fn io<T>(value: Result<T, impl std::fmt::Debug>) -> Result<T, NativeError> {
    value.map_err(|_| NativeError::Unavailable)
}
async fn children(storage: &Storage, parent: ObjectHandle) -> Result<Vec<ObjectInfo>, NativeError> {
    stable_children(|| read_children(storage, parent)).await
}
async fn stable_children<F, T>(mut read: F) -> Result<Vec<ObjectInfo>, NativeError>
where
    F: FnMut() -> T,
    T: std::future::Future<Output = Result<Vec<ObjectInfo>, NativeError>>,
{
    for attempt in 0..3 {
        let nodes = read().await?;
        // WPD can enumerate an object that disappears before GetValues. The
        // backend represents that failed property read as this exact placeholder.
        // Never accept or silently omit it: reload the whole bounded snapshot.
        if !nodes
            .iter()
            .any(|node| node.filename.is_empty() && node.size == 0 && !node.is_folder())
        {
            return Ok(nodes);
        }
        if attempt < 2 {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    }
    Err(NativeError::Unavailable)
}
async fn read_children(
    storage: &Storage,
    parent: ObjectHandle,
) -> Result<Vec<ObjectInfo>, NativeError> {
    let mut listing = io(storage.list_objects_stream(listing_parent(parent)).await)?;
    if listing.total() > MAX_ENTRIES {
        return Err(NativeError::Bounds);
    }
    let mut found = Vec::new();
    let mut names = HashSet::new();
    let mut handles = HashSet::new();
    while let Some(item) = listing.next().await {
        let ListingItem::Object(node) = io(item)? else {
            return Err(NativeError::Unavailable);
        };
        if node.parent != parent
            || node.storage_id != storage.id()
            || (!node.filename.is_empty() && !names.insert(node.filename.clone()))
            || !handles.insert(node.handle)
        {
            return Err(NativeError::Duplicate);
        }
        found.push(node);
        if found.len() > MAX_ENTRIES {
            return Err(NativeError::Bounds);
        }
    }
    Ok(found)
}
fn listing_parent(parent: ObjectHandle) -> Option<ObjectHandle> {
    (parent != ObjectHandle::ROOT).then_some(parent)
}
fn block_identity(node: &ObjectInfo) -> BlockIdentity {
    BlockIdentity {
        object: node.handle.0,
        parent: node.parent.0,
        storage: node.storage_id.0,
    }
}
fn refreshed_block_identity(
    listed: &ObjectInfo,
    current: &ObjectInfo,
) -> Result<BlockIdentity, NativeError> {
    let expected = block_identity(listed);
    let actual = block_identity(current);
    // WPD standalone object_info has no storage context and reports default.
    // The immediately preceding bounded listing supplies storage membership;
    // still require the same object and parent, and reject any known mismatch.
    #[cfg(windows)]
    let actual = BlockIdentity {
        storage: if actual.storage == StorageId::default().0 {
            expected.storage
        } else {
            actual.storage
        },
        ..actual
    };
    if actual != expected {
        return Err(NativeError::InvalidBlock);
    }
    Ok(expected)
}
struct RouteEntry {
    handle: ObjectHandle,
    parent: ObjectHandle,
    storage: StorageId,
    name: String,
    directory: bool,
}
async fn scan_route_entries(
    parent: ObjectHandle,
    storage: StorageId,
    name: &str,
    entries: impl Stream<Item = Result<RouteEntry, NativeError>>,
) -> Result<Option<ObjectHandle>, NativeError> {
    futures::pin_mut!(entries);
    let mut lookup = RouteLookup::new(name);
    while let Some(entry) = entries.next().await {
        let node = entry?;
        if node.parent != parent || node.storage != storage {
            return Err(NativeError::InvalidScope);
        }
        lookup.observe(&node.name, node.directory, node.handle)?;
    }
    Ok(lookup.finish())
}
async fn directory(
    storage: &Storage,
    parent: ObjectHandle,
    name: &str,
    create: bool,
    timing: &mut IoMetrics,
) -> Result<ObjectHandle, NativeError> {
    match find_directory(storage, parent, name).await? {
        Some(handle) => Ok(handle),
        None if create => {
            let started = Instant::now();
            let answer = io(storage.create_folder(Some(parent), name).await);
            timing.elapsed(IoStep::Create, started, 0);
            answer
        }
        None => Err(NativeError::Unavailable),
    }
}
async fn find_directory(
    storage: &Storage,
    parent: ObjectHandle,
    name: &str,
) -> Result<Option<ObjectHandle>, NativeError> {
    // Routing retains only one matching entry; historical siblings are not a block window.
    // The parent process still bounds execution time and owns cancellation.
    let listing = io(storage.list_objects_stream(listing_parent(parent)).await)?;
    let entries = futures::stream::unfold(listing, |mut listing| async move {
        let item = listing.next().await?;
        let entry = io(item).and_then(|item| {
            let ListingItem::Object(node) = item else {
                return Err(NativeError::Unavailable);
            };
            Ok(RouteEntry {
                handle: node.handle,
                parent: node.parent,
                storage: node.storage_id,
                directory: node.is_folder(),
                name: node.filename,
            })
        });
        Some((entry, listing))
    });
    scan_route_entries(parent, storage.id(), name, entries).await
}
impl MtpWorker {
    pub fn record_ipc_decode(&mut self, started: Instant, bytes: usize) {
        self.timings
            .elapsed(IoStep::IpcDecode, started, bytes as u64);
    }
    pub fn record_ipc_encode(&mut self, started: Instant, bytes: usize) {
        self.timings
            .elapsed(IoStep::IpcEncode, started, bytes as u64);
    }
    fn scope(&self, operation: &str, session: &str) -> Result<(), NativeError> {
        if self.operation.as_ref() != Some(&(operation.into(), session.into())) {
            return Err(NativeError::Closed);
        }
        Ok(())
    }
    pub async fn execute(
        &mut self,
        request: NativeRequest,
    ) -> Result<serde_json::Value, NativeError> {
        match request {
            NativeRequest::Discover { operation, session } => {
                self.discover(operation, session).await
            }
            NativeRequest::Enumerate => {
                if self.device.is_some() {
                    return Err(NativeError::Closed);
                }
                self.devices.clear();
                eprintln!("MTP_WORKER enumerate start");
                let candidates = io(MtpDevice::list_devices())?;
                eprintln!("MTP_WORKER enumerate candidates={}", candidates.len());
                if candidates.len() > 16 {
                    return Err(NativeError::Bounds);
                }
                let mut results = Vec::new();
                for candidate in candidates {
                    // WPD serial differs from USB serial on some phones. Resolve location once,
                    // retain only the opened backend's serial for unambiguous later reopening.
                    eprintln!("MTP_WORKER open start");
                    let device = io(builder().open_by_location(candidate.location_id).await)?;
                    eprintln!("MTP_WORKER open complete");
                    let serial = device.device_info().serial_number.clone();
                    if serial.is_empty() || self.devices.iter().any(|(_, s)| s == &serial) {
                        return Err(NativeError::Unavailable);
                    }
                    let id = uuid::Uuid::new_v4().simple().to_string();
                    eprintln!("MTP_WORKER storages start");
                    let storages = io(device.storages().await)?;
                    eprintln!("MTP_WORKER storages complete");
                    if storages.len() > 16 {
                        return Err(NativeError::Bounds);
                    }
                    let entries = storages
                        .iter()
                        .filter(|s| s.info().is_writable)
                        .map(|s| NativeStorage {
                            id: format!("{:016x}", s.id().0),
                            name: s.info().description.chars().take(128).collect(),
                            free_bytes: s.info().free_space,
                        })
                        .collect();
                    results.push(NativeDevice {
                        id: id.clone(),
                        name: device.device_info().model.chars().take(128).collect(),
                        storages: entries,
                    });
                    self.devices.push((id, serial));
                    drop(storages);
                    eprintln!("MTP_WORKER close start");
                    io(device.close().await)?;
                    eprintln!("MTP_WORKER close complete");
                }
                serde_json::to_value(results).map_err(|_| NativeError::Io)
            }
            NativeRequest::Open {
                device,
                storage,
                operation,
                session,
            } => {
                if self.operation.is_some() {
                    return Err(NativeError::Closed);
                }
                session_directory(&operation)?;
                let session_name = session_directory(&session)?;
                let serial = self
                    .devices
                    .iter()
                    .find(|(id, _)| id == &device)
                    .ok_or(NativeError::InvalidScope)?
                    .1
                    .clone();
                if storage.len() != 16
                    || !storage
                        .bytes()
                        .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
                {
                    return Err(NativeError::InvalidScope);
                }
                eprintln!("MTP_WORKER session open start");
                let device = io(builder().open_by_serial(&serial).await)?;
                eprintln!(
                    "MTP_WORKER session open complete upload={} rename={} folder={}",
                    device.capabilities().can_upload,
                    device.capabilities().can_rename,
                    device.capabilities().can_create_folder
                );
                if !device.capabilities().can_upload
                    || !device.capabilities().can_rename
                    || !device.capabilities().can_create_folder
                {
                    return Err(NativeError::Unavailable);
                }
                let selected = io(device.storages().await)?
                    .into_iter()
                    .find(|s| format!("{:016x}", s.id().0) == storage && s.info().is_writable)
                    .ok_or(NativeError::InvalidScope)?;
                eprintln!("MTP_WORKER session storage selected");
                let documents = directory(
                    &selected,
                    ObjectHandle::ROOT,
                    "Documents",
                    false,
                    &mut self.timings,
                )
                .await?;
                eprintln!("MTP_WORKER Documents found");
                let root = directory(
                    &selected,
                    documents,
                    "NSOAlbumSync",
                    true,
                    &mut self.timings,
                )
                .await?;
                eprintln!("MTP_WORKER exchange root found");
                let folder =
                    directory(&selected, root, &session_name, true, &mut self.timings).await?;
                let desktop =
                    directory(&selected, folder, "desktop", true, &mut self.timings).await?;
                let mobile =
                    directory(&selected, folder, "mobile", true, &mut self.timings).await?;
                self.device = Some(device);
                self.storage = Some(selected);
                self.folders = Some([desktop, mobile]);
                self.operation = Some((operation, session));
                Ok(serde_json::Value::Null)
            }
            NativeRequest::List {
                operation,
                session,
                direction,
            } => {
                self.scope(&operation, &session)?;
                let nodes = self.nodes(direction).await?;
                #[cfg(debug_assertions)]
                for node in &nodes {
                    if !node.filename.ends_with(".part")
                        && (!block_name(&node.filename)
                            || node.is_folder()
                            || node.size > MAX_BLOCK as u64)
                    {
                        eprintln!(
                            "device_sync boundary=UsbEntry category=InvalidBlock reason={:?} validName{} directory{} size{}",
                            direction,
                            block_name(&node.filename),
                            node.is_folder(),
                            node.size
                        );
                    }
                }
                let names = validate_entries(
                    &nodes
                        .iter()
                        .map(|n| (n.filename.clone(), n.size, n.is_folder()))
                        .collect::<Vec<_>>(),
                )?;
                self.indexes[direction_index(direction)] = Some(nodes);
                Ok(serde_json::json!(names))
            }
            NativeRequest::Read {
                operation,
                session,
                direction,
                name,
            } => {
                self.scope(&operation, &session)?;
                if !block_name(&name) {
                    return Err(NativeError::InvalidBlock);
                }
                let mut nodes = self.cached_nodes(direction).await?;
                if !nodes.iter().any(|node| node.filename == name) {
                    nodes = self.nodes(direction).await?;
                    self.indexes[direction_index(direction)] = Some(nodes.clone());
                }
                validate_entries(
                    &nodes
                        .iter()
                        .map(|n| (n.filename.clone(), n.size, n.is_folder()))
                        .collect::<Vec<_>>(),
                )?;
                let node = nodes
                    .into_iter()
                    .find(|n| n.filename == name)
                    .ok_or(NativeError::InvalidBlock)?;
                let started = Instant::now();
                let bytes = io(self
                    .storage
                    .as_ref()
                    .ok_or(NativeError::Closed)?
                    .read_range(node.handle, 0, (MAX_BLOCK + 1) as u32)
                    .await)?;
                self.timings
                    .elapsed(IoStep::PayloadRead, started, bytes.len() as u64);
                if bytes.is_empty()
                    || bytes.len() > MAX_BLOCK
                    || (node.size > 0 && bytes.len() != node.size as usize)
                {
                    return Err(NativeError::InvalidBlock);
                }
                self.receipts
                    .record_identified(direction, &name, &bytes, block_identity(&node))?;
                let started = Instant::now();
                let size = bytes.len();
                let encoded = STANDARD.encode(bytes);
                self.timings
                    .elapsed(IoStep::IpcEncode, started, size as u64);
                Ok(serde_json::json!(encoded))
            }
            NativeRequest::Write {
                operation,
                session,
                name,
                bytes,
            } => {
                self.scope(&operation, &session)?;
                if !block_name(&name) || bytes.len() > MAX_BLOCK.div_ceil(3) * 4 {
                    return Err(NativeError::InvalidBlock);
                }
                let started = Instant::now();
                let bytes = STANDARD
                    .decode(bytes)
                    .map_err(|_| NativeError::InvalidBlock)?;
                self.timings
                    .elapsed(IoStep::IpcDecode, started, bytes.len() as u64);
                if bytes.is_empty() || bytes.len() > MAX_BLOCK {
                    return Err(NativeError::Bounds);
                }
                let part = format!("{name}.part");
                let mut nodes = self.cached_nodes(Direction::Desktop).await?;
                if nodes.len() >= MAX_ENTRIES {
                    nodes = self.nodes(Direction::Desktop).await?;
                    self.indexes[0] = Some(nodes.clone());
                }
                if nodes
                    .iter()
                    .any(|n| n.filename == name || n.filename == part)
                {
                    return Err(NativeError::Duplicate);
                }
                reserve_block_entry(nodes.len())?;
                let storage = self.storage.as_ref().ok_or(NativeError::Closed)?;
                let parent = self.folders.ok_or(NativeError::Closed)?[0];
                let size = bytes.len();
                let stream = futures::stream::iter([Ok(bytes::Bytes::from(bytes))]);
                // mtp-rs exposes creation, stream writes and Commit as one upload.
                // Report this combined interval honestly; SAF splits them below.
                let started = Instant::now();
                let handle = io(storage
                    .upload(
                        Some(parent),
                        NewObjectInfo::file(&part, size as u64),
                        stream,
                    )
                    .await)?;
                self.timings
                    .elapsed(IoStep::CreateWrite, started, size as u64);
                let started = Instant::now();
                let uploaded = io(storage.get_object_info(handle).await)?;
                self.timings.elapsed(IoStep::Properties, started, 0);
                if uploaded.size != size as u64
                    || uploaded.parent != parent
                    || uploaded.filename != part
                {
                    return Err(NativeError::InvalidBlock);
                }
                let started = Instant::now();
                io(storage.rename(handle, &name).await)?;
                self.timings.elapsed(IoStep::Rename, started, 0);
                let started = Instant::now();
                let mut completed = io(storage.get_object_info(handle).await)?;
                self.timings.elapsed(IoStep::Properties, started, 0);
                if completed.filename != name
                    || completed.size != size as u64
                    || completed.parent != parent
                {
                    return Err(NativeError::InvalidBlock);
                }
                completed.storage_id = storage.id();
                nodes.push(completed);
                self.indexes[0] = Some(nodes);
                Ok(serde_json::Value::Null)
            }
            NativeRequest::Close => {
                self.operation = None;
                self.folders = None;
                self.indexes = Default::default();
                self.storage = None;
                if let Some(device) = self.device.take() {
                    io(device.close().await)?;
                }
                Ok(serde_json::Value::Null)
            }
            NativeRequest::Acknowledge {
                operation,
                session,
                direction,
                name,
            } => {
                self.scope(&operation, &session)?;
                let receipts = self.receipts.retirement_prefix(direction, &name)?;
                let storage = self.storage.as_ref().ok_or(NativeError::Closed)?;
                // Validate the whole read-owned prefix using exact object IDs;
                // no directory enumeration or body read is needed for cleanup.
                for (name, expected_length, identity) in &receipts {
                    let mut listed = ObjectInfo::default();
                    listed.handle = ObjectHandle(identity.object);
                    listed.parent = ObjectHandle(identity.parent);
                    listed.storage_id = StorageId(identity.storage);
                    let started = Instant::now();
                    let current = io(storage.get_object_info(listed.handle).await)?;
                    self.timings.elapsed(IoStep::Properties, started, 0);
                    if current.filename != *name
                        || current.is_folder()
                        || (current.size > 0 && current.size != *expected_length as u64)
                    {
                        return Err(NativeError::InvalidBlock);
                    }
                    self.receipts.require_identity(
                        direction,
                        name,
                        refreshed_block_identity(&listed, &current)?,
                    )?;
                }
                for (name, _, identity) in receipts {
                    let started = Instant::now();
                    io(storage.delete(ObjectHandle(identity.object)).await)?;
                    self.timings.elapsed(IoStep::Cleanup, started, 0);
                    self.receipts.retired(direction, &name)?;
                    if let Some(nodes) = &mut self.indexes[direction_index(direction)] {
                        nodes.retain(|node| node.filename != name);
                    }
                }
                Ok(serde_json::Value::Null)
            }
        }
    }
    async fn discover(
        &mut self,
        operation: String,
        session: String,
    ) -> Result<serde_json::Value, NativeError> {
        if self.device.is_some() || self.operation.is_some() {
            return Err(NativeError::Closed);
        }
        session_directory(&operation)?;
        let session_name = session_directory(&session)?;
        let candidates = io(MtpDevice::list_devices())?;
        if candidates.len() > 16 {
            return Err(NativeError::Bounds);
        }
        let candidate_count = candidates.len();
        let mut opened = 0;
        let mut found = None;
        for candidate in candidates {
            // Enumeration is advisory. A disconnected/unavailable candidate is
            // not the phone possessing this invitation and cannot be selected.
            let Ok(device) = builder().open_by_location(candidate.location_id).await else {
                continue;
            };
            opened += 1;
            let storages = io(device.storages().await)?;
            if storages.len() > 16 {
                return Err(NativeError::Bounds);
            }
            let mut matched = None;
            for storage in storages {
                if !storage.info().is_writable {
                    continue;
                }
                let Some(documents) =
                    find_directory(&storage, ObjectHandle::ROOT, "Documents").await?
                else {
                    continue;
                };
                let Some(root) = find_directory(&storage, documents, "NSOAlbumSync").await? else {
                    continue;
                };
                let Some(folder) = find_directory(&storage, root, &session_name).await? else {
                    continue;
                };
                let Some(mobile) = find_directory(&storage, folder, "mobile").await? else {
                    continue;
                };
                let Some(desktop) = find_directory(&storage, folder, "desktop").await? else {
                    continue;
                };
                let nodes = children(&storage, mobile).await?;
                let names = validate_entries(
                    &nodes
                        .iter()
                        .map(|n| (n.filename.clone(), n.size, n.is_folder()))
                        .collect::<Vec<_>>(),
                )?;
                if !names.iter().any(|name| name == "0000000000000000.block") {
                    continue;
                }
                if matched.is_some() || found.is_some() {
                    return Err(NativeError::Duplicate);
                }
                if !device.capabilities().can_upload
                    || !device.capabilities().can_rename
                    || !device.capabilities().can_create_folder
                {
                    return Err(NativeError::Unavailable);
                }
                matched = Some((storage, [desktop, mobile]));
            }
            if let Some((storage, folders)) = matched {
                found = Some((device, storage, folders));
            } else {
                io(device.close().await)?;
            }
        }
        let Some((device, storage, folders)) = found else {
            return if candidate_count != 0 && opened == 0 {
                Err(NativeError::Unavailable)
            } else {
                Ok(serde_json::json!(false))
            };
        };
        // This merely opens a candidate ciphertext mailbox, never authorizes a
        // peer. The existing TLS, invitation proof and phone consent still run.
        self.device = Some(device);
        self.storage = Some(storage);
        self.folders = Some(folders);
        self.operation = Some((operation, session));
        Ok(serde_json::json!(true))
    }
    async fn nodes(&mut self, direction: Direction) -> Result<Vec<ObjectInfo>, NativeError> {
        let index = match direction {
            Direction::Desktop => 0,
            Direction::Mobile => 1,
        };
        let started = Instant::now();
        let answer = children(
            self.storage.as_ref().ok_or(NativeError::Closed)?,
            self.folders.ok_or(NativeError::Closed)?[index],
        )
        .await;
        self.timings.elapsed(IoStep::Enumerate, started, 0);
        answer
    }
    async fn cached_nodes(&mut self, direction: Direction) -> Result<Vec<ObjectInfo>, NativeError> {
        let index = direction_index(direction);
        if let Some(nodes) = &self.indexes[index] {
            return Ok(nodes.clone());
        }
        let nodes = self.nodes(direction).await?;
        validate_entries(
            &nodes
                .iter()
                .map(|node| (node.filename.clone(), node.size, node.is_folder()))
                .collect::<Vec<_>>(),
        )?;
        self.indexes[index] = Some(nodes.clone());
        Ok(nodes)
    }
}

impl Drop for MtpWorker {
    fn drop(&mut self) {
        eprintln!("{} site=worker", self.timings);
    }
}

fn direction_index(direction: Direction) -> usize {
    match direction {
        Direction::Desktop => 0,
        Direction::Mobile => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn child(name: &str, size: u64) -> ObjectInfo {
        let mut child = ObjectInfo::default();
        child.handle = ObjectHandle(9);
        child.storage_id = StorageId(3);
        child.parent = ObjectHandle(7);
        child.filename = name.into();
        child.size = size;
        child
    }
    #[test]
    #[cfg(windows)]
    fn wpd_standalone_metadata_can_omit_storage_without_changing_the_listed_identity() {
        let listed = child("0000000000000000.block", 42);
        let mut current = child("0000000000000000.block", 42);
        // mtp-rs WPD object_info explicitly returns unknown/default storage.
        current.storage_id = StorageId::default();
        assert_eq!(
            refreshed_block_identity(&listed, &current),
            Ok(block_identity(&listed))
        );
    }
    #[test]
    fn refreshed_metadata_rejects_changed_object_parent_and_known_storage() {
        let listed = child("0000000000000000.block", 42);
        for change in 0..3 {
            let mut current = child("0000000000000000.block", 42);
            match change {
                0 => current.handle = ObjectHandle(10),
                1 => current.parent = ObjectHandle(8),
                _ => current.storage_id = StorageId(4),
            }
            assert_eq!(
                refreshed_block_identity(&listed, &current),
                Err(NativeError::InvalidBlock)
            );
        }
    }
    #[tokio::test]
    async fn vanished_wpd_property_placeholder_reloads_instead_of_rejecting_valid_block() {
        let mut reads = 0;
        let nodes = stable_children(|| {
            reads += 1;
            std::future::ready(Ok(vec![if reads == 1 {
                child("", 0)
            } else {
                child("0000000000000000.block", 42)
            }]))
        })
        .await
        .unwrap();
        assert_eq!(reads, 2);
        assert_eq!(nodes[0].filename, "0000000000000000.block");
        assert_eq!(nodes[0].size, 42);
    }
    #[tokio::test]
    async fn persistent_wpd_placeholder_is_bounded_and_never_accepted() {
        let mut reads = 0;
        let result = stable_children(|| {
            reads += 1;
            std::future::ready(Ok(vec![child("", 0)]))
        })
        .await;
        assert_eq!(result.unwrap_err(), NativeError::Unavailable);
        assert_eq!(reads, 3);
    }
    #[tokio::test]
    async fn named_invalid_block_is_not_hidden_as_a_wpd_placeholder() {
        let mut reads = 0;
        let nodes = stable_children(|| {
            reads += 1;
            std::future::ready(Ok(vec![child("unexpected.block", 0)]))
        })
        .await
        .unwrap();
        assert_eq!(reads, 1);
        assert_eq!(
            validate_entries(
                &nodes
                    .iter()
                    .map(|n| (n.filename.clone(), n.size, n.is_folder()))
                    .collect::<Vec<_>>()
            ),
            Err(NativeError::InvalidBlock)
        );
    }
    #[test]
    fn storage_root_listing_is_not_object_handle_zero() {
        assert_eq!(listing_parent(ObjectHandle::ROOT), None);
        assert_eq!(listing_parent(ObjectHandle(9)), Some(ObjectHandle(9)));
    }
    fn historical_routes() -> impl Stream<Item = Result<RouteEntry, NativeError>> {
        futures::stream::iter((0..140).map(|i| {
            Ok(RouteEntry {
                handle: ObjectHandle(i + 10),
                parent: ObjectHandle(7),
                storage: StorageId(3),
                name: format!("s-{i:032x}"),
                directory: true,
            })
        }))
    }
    #[tokio::test]
    async fn route_stream_reopens_old_and_new_sessions_beyond_the_block_window() {
        assert_eq!(
            scan_route_entries(
                ObjectHandle(7),
                StorageId(3),
                "s-00000000000000000000000000000000",
                historical_routes()
            )
            .await
            .unwrap(),
            Some(ObjectHandle(10))
        );
        assert_eq!(
            scan_route_entries(
                ObjectHandle(7),
                StorageId(3),
                "s-0000000000000000000000000000008b",
                historical_routes()
            )
            .await
            .unwrap(),
            Some(ObjectHandle(149))
        );
        assert_eq!(
            scan_route_entries(
                ObjectHandle(7),
                StorageId(3),
                "s-ffffffffffffffffffffffffffffffff",
                historical_routes()
            )
            .await
            .unwrap(),
            None
        );
    }
    #[tokio::test]
    async fn routing_does_not_accept_an_entry_from_another_parent_or_storage() {
        assert_eq!(
            scan_route_entries(
                ObjectHandle(8),
                StorageId(3),
                "s-00000000000000000000000000000000",
                historical_routes()
            )
            .await,
            Err(NativeError::InvalidScope)
        );
        assert_eq!(
            scan_route_entries(
                ObjectHandle(7),
                StorageId(4),
                "s-00000000000000000000000000000000",
                historical_routes()
            )
            .await,
            Err(NativeError::InvalidScope)
        );
    }
}
