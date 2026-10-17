//! Used exclusively in the disposable native worker, never the UI process.
use super::native_io::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use futures::{Stream, StreamExt};
use mtp_rs::mtp::{
    Backend, ListingItem, MtpDevice, NewObjectInfo, ObjectHandle, ObjectInfo, Storage, StorageId,
};
use std::collections::HashSet;

#[derive(Default)]
pub struct MtpWorker {
    devices: Vec<(String, String)>,
    device: Option<MtpDevice>,
    storage: Option<Storage>,
    operation: Option<(String, String)>,
    folders: Option<[ObjectHandle; 2]>,
    receipts: BlockReceipts,
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
            || !names.insert(node.filename.clone())
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
) -> Result<ObjectHandle, NativeError> {
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
    match scan_route_entries(parent, storage.id(), name, entries).await? {
        Some(handle) => Ok(handle),
        None if create => io(storage.create_folder(Some(parent), name).await),
        None => Err(NativeError::Unavailable),
    }
}
impl MtpWorker {
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
                let documents =
                    directory(&selected, ObjectHandle::ROOT, "Documents", false).await?;
                eprintln!("MTP_WORKER Documents found");
                let root = directory(&selected, documents, "NSOAlbumSync", true).await?;
                eprintln!("MTP_WORKER exchange root found");
                let folder = directory(&selected, root, &session_name, true).await?;
                let desktop = directory(&selected, folder, "desktop", true).await?;
                let mobile = directory(&selected, folder, "mobile", true).await?;
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
                let names = validate_entries(
                    &nodes
                        .iter()
                        .map(|n| (n.filename.clone(), n.size, n.is_folder()))
                        .collect::<Vec<_>>(),
                )?;
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
                let nodes = self.nodes(direction).await?;
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
                let bytes = io(self
                    .storage
                    .as_ref()
                    .ok_or(NativeError::Closed)?
                    .read_range(node.handle, 0, (MAX_BLOCK + 1) as u32)
                    .await)?;
                if bytes.len() != node.size as usize || bytes.len() > MAX_BLOCK {
                    return Err(NativeError::InvalidBlock);
                }
                self.receipts.record(direction, &name, &bytes)?;
                Ok(serde_json::json!(STANDARD.encode(bytes)))
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
                let bytes = STANDARD
                    .decode(bytes)
                    .map_err(|_| NativeError::InvalidBlock)?;
                if bytes.is_empty() || bytes.len() > MAX_BLOCK {
                    return Err(NativeError::Bounds);
                }
                let part = format!("{name}.part");
                let nodes = self.nodes(Direction::Desktop).await?;
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
                let handle = io(storage
                    .upload(
                        Some(parent),
                        NewObjectInfo::file(&part, size as u64),
                        stream,
                    )
                    .await)?;
                let uploaded = io(storage.get_object_info(handle).await)?;
                if uploaded.size != size as u64
                    || uploaded.parent != parent
                    || uploaded.filename != part
                {
                    return Err(NativeError::InvalidBlock);
                }
                if self
                    .nodes(Direction::Desktop)
                    .await?
                    .iter()
                    .any(|n| n.filename == name)
                {
                    return Err(NativeError::Duplicate);
                }
                io(storage.rename(handle, &name).await)?;
                let completed = io(storage.get_object_info(handle).await)?;
                if completed.filename != name
                    || completed.size != size as u64
                    || completed.parent != parent
                {
                    return Err(NativeError::InvalidBlock);
                }
                Ok(serde_json::Value::Null)
            }
            NativeRequest::Close => {
                self.operation = None;
                self.folders = None;
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
                use sha2::Digest;
                self.scope(&operation, &session)?;
                let Some(expected_hash) = self.receipts.receipt(direction, &name)? else {
                    return Ok(serde_json::Value::Null);
                };
                let nodes = self.nodes(direction).await?;
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
                let storage = self.storage.as_ref().ok_or(NativeError::Closed)?;
                let bytes = io(storage
                    .read_range(node.handle, 0, (MAX_BLOCK + 1) as u32)
                    .await)?;
                if bytes.len() != node.size as usize
                    || bytes.len() > MAX_BLOCK
                    || <[u8; 32]>::from(sha2::Sha256::digest(&bytes)) != expected_hash
                {
                    return Err(NativeError::InvalidBlock);
                }
                io(storage.delete(node.handle).await)?;
                self.receipts.retired(direction, &name)?;
                Ok(serde_json::Value::Null)
            }
        }
    }
    async fn nodes(&self, direction: Direction) -> Result<Vec<ObjectInfo>, NativeError> {
        let index = match direction {
            Direction::Desktop => 0,
            Direction::Mobile => 1,
        };
        children(
            self.storage.as_ref().ok_or(NativeError::Closed)?,
            self.folders.ok_or(NativeError::Closed)?[index],
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
