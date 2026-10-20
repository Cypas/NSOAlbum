//! Restricted ciphertext mailbox policy shared by the isolated native worker.
use std::collections::HashSet;

/// Physical USB carrier only; TLS drain and logical message limits are unchanged.
pub const MAX_BLOCK: usize = 8 * 1024 * 1024;
pub const MAX_ENTRIES: usize = 128;
/// JSON payload, excluding its four-byte framing prefix.
pub const MAX_IPC: usize = 12 * 1024 * 1024;

/// One serialized native operation, not permission to parallelize device I/O.
#[derive(Default)]
pub struct BatchBudget {
    names: HashSet<String>,
    bytes: usize,
}
impl BatchBudget {
    pub fn reserve(&mut self, name: &str, bytes: usize) -> Result<(), NativeError> {
        if !block_name(name) {
            return Err(NativeError::InvalidBlock);
        }
        if self.names.contains(name) {
            return Err(NativeError::Duplicate);
        }
        let total = self.bytes.checked_add(bytes).ok_or(NativeError::Bounds)?;
        if bytes == 0 || self.names.len() >= 4 || total > MAX_BLOCK {
            return Err(NativeError::Bounds);
        }
        self.names.insert(name.into());
        self.bytes = total;
        Ok(())
    }
}

/// Backend-opaque tokens valid only within this worker's open device session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlockIdentity {
    pub object: u64,
    pub parent: u64,
    pub storage: u64,
}

#[cfg(test)]
#[path = "native_io/v2_bounds_tests.rs"]
mod v2_bounds_tests;

pub fn reserve_block_entry(current_entries: usize) -> Result<(), NativeError> {
    if current_entries >= MAX_ENTRIES {
        return Err(NativeError::WindowFull);
    }
    Ok(())
}

pub struct RouteLookup<T> {
    target: String,
    matched: Option<T>,
}
impl<T> RouteLookup<T> {
    pub fn new(target: &str) -> Self {
        Self {
            target: target.into(),
            matched: None,
        }
    }
    pub fn observe(&mut self, name: &str, directory: bool, identity: T) -> Result<(), NativeError> {
        if name == self.target {
            if !directory {
                return Err(NativeError::InvalidScope);
            }
            if self.matched.is_some() {
                return Err(NativeError::Duplicate);
            }
            self.matched = Some(identity);
        }
        Ok(())
    }
    pub fn finish(self) -> Option<T> {
        self.matched
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum NativeError {
    InvalidScope,
    InvalidBlock,
    Bounds,
    WindowFull,
    Duplicate,
    Unavailable,
    Closed,
    Timeout,
    Io,
}

#[derive(Debug, Clone, Copy, Hash, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Desktop,
    Mobile,
}
impl Direction {
    pub fn directory(self) -> &'static str {
        match self {
            Self::Desktop => "desktop",
            Self::Mobile => "mobile",
        }
    }
}
pub fn session_directory(id: &str) -> Result<String, NativeError> {
    if id.len() != 32
        || !id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(NativeError::InvalidScope);
    }
    Ok(format!("s-{id}"))
}
pub fn block_name(name: &str) -> bool {
    name.len() == 22
        && name.ends_with(".block")
        && name.as_bytes()[..16]
            .iter()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
}
pub fn validate_entries(entries: &[(String, u64, bool)]) -> Result<Vec<String>, NativeError> {
    if entries.len() > MAX_ENTRIES {
        return Err(NativeError::Bounds);
    }
    let mut names = HashSet::new();
    let mut complete = Vec::new();
    for (name, size, directory) in entries {
        if !names.insert(name) {
            return Err(NativeError::Duplicate);
        }
        if name.ends_with(".part") {
            continue;
        }
        if !block_name(name) || *directory || *size > MAX_BLOCK as u64 {
            return Err(NativeError::InvalidBlock);
        }
        complete.push(name.clone());
    }
    complete.sort();
    Ok(complete)
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NativeStorage {
    pub id: String,
    pub name: String,
    pub free_bytes: u64,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NativeDevice {
    pub id: String,
    pub name: String,
    pub storages: Vec<NativeStorage>,
}
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields, tag = "method", rename_all = "snake_case")]
pub enum NativeRequest {
    Enumerate,
    Discover {
        operation: String,
        session: String,
    },
    Open {
        device: String,
        storage: String,
        operation: String,
        session: String,
    },
    List {
        operation: String,
        session: String,
        direction: Direction,
    },
    Read {
        operation: String,
        session: String,
        direction: Direction,
        name: String,
    },
    Write {
        operation: String,
        session: String,
        name: String,
        bytes: String,
    },
    Acknowledge {
        operation: String,
        session: String,
        direction: Direction,
        name: String,
    },
    Close,
}
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NativeResponse {
    pub value: Result<serde_json::Value, NativeError>,
}

pub fn read_packet(reader: &mut impl std::io::Read) -> Result<Vec<u8>, NativeError> {
    let mut header = [0; 4];
    reader
        .read_exact(&mut header)
        .map_err(|_| NativeError::Io)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_IPC {
        return Err(NativeError::Bounds);
    }
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes).map_err(|_| NativeError::Io)?;
    Ok(bytes)
}
pub fn write_packet(writer: &mut impl std::io::Write, bytes: &[u8]) -> Result<(), NativeError> {
    if bytes.is_empty() || bytes.len() > MAX_IPC {
        return Err(NativeError::Bounds);
    }
    writer
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .map_err(|_| NativeError::Io)?;
    writer.write_all(bytes).map_err(|_| NativeError::Io)?;
    writer.flush().map_err(|_| NativeError::Io)
}

#[derive(Default)]
pub struct BlockReceipts {
    lengths: std::collections::HashMap<(Direction, String), usize>,
    identities: std::collections::HashMap<(Direction, String), BlockIdentity>,
    next: [u64; 2],
}
impl BlockReceipts {
    /// Preflight a bounded, already-read contiguous prefix. No deletion or
    /// receipt mutation happens if any sequence is missing.
    pub fn retirement_prefix(
        &self,
        direction: Direction,
        through: &str,
    ) -> Result<Vec<(String, usize, BlockIdentity)>, NativeError> {
        let end = Self::sequence(through)?;
        let next = self.next(direction);
        if end < next {
            return Ok(vec![]);
        }
        if end == u64::MAX || end - next >= 8 {
            return Err(NativeError::InvalidBlock);
        }
        (next..=end)
            .map(|sequence| {
                let name = format!("{sequence:016x}.block");
                let key = (direction, name.clone());
                let length = *self.lengths.get(&key).ok_or(NativeError::InvalidBlock)?;
                let identity = *self.identities.get(&key).ok_or(NativeError::InvalidBlock)?;
                Ok((name, length, identity))
            })
            .collect()
    }
    pub fn record_identified(
        &mut self,
        direction: Direction,
        name: &str,
        bytes: &[u8],
        identity: BlockIdentity,
    ) -> Result<(), NativeError> {
        if bytes.is_empty() || bytes.len() > MAX_BLOCK {
            return Err(NativeError::Bounds);
        }
        let key = (direction, name.to_owned());
        if self
            .identities
            .get(&key)
            .is_some_and(|saved| *saved != identity)
            || self
                .lengths
                .get(&key)
                .is_some_and(|saved| *saved != bytes.len())
        {
            return Err(NativeError::InvalidBlock);
        }
        self.record(direction, name, bytes)?;
        self.identities.insert(key, identity);
        Ok(())
    }
    pub fn require_identity(
        &self,
        direction: Direction,
        name: &str,
        identity: BlockIdentity,
    ) -> Result<(), NativeError> {
        if self.identities.get(&(direction, name.into())) == Some(&identity) {
            Ok(())
        } else {
            Err(NativeError::InvalidBlock)
        }
    }
    fn sequence(name: &str) -> Result<u64, NativeError> {
        if !block_name(name) {
            return Err(NativeError::InvalidBlock);
        }
        u64::from_str_radix(&name[..16], 16).map_err(|_| NativeError::InvalidBlock)
    }
    fn next(&self, direction: Direction) -> u64 {
        self.next[if direction == Direction::Desktop {
            0
        } else {
            1
        }]
    }
    pub fn record(
        &mut self,
        direction: Direction,
        name: &str,
        bytes: &[u8],
    ) -> Result<(), NativeError> {
        Self::sequence(name)?;
        if bytes.is_empty() || bytes.len() > MAX_BLOCK {
            return Err(NativeError::Bounds);
        }
        let key = (direction, name.to_owned());
        if !self.lengths.contains_key(&key) && self.lengths.len() >= MAX_ENTRIES {
            return Err(NativeError::Bounds);
        }
        self.lengths.insert(key, bytes.len());
        Ok(())
    }
    pub fn receipt(&self, direction: Direction, name: &str) -> Result<Option<usize>, NativeError> {
        let sequence = Self::sequence(name)?;
        if sequence < self.next(direction) {
            return Ok(None);
        }
        if sequence != self.next(direction) || sequence == u64::MAX {
            return Err(NativeError::InvalidBlock);
        }
        self.lengths
            .get(&(direction, name.into()))
            .copied()
            .map(Some)
            .ok_or(NativeError::InvalidBlock)
    }
    pub fn retired(&mut self, direction: Direction, name: &str) -> Result<(), NativeError> {
        if self.receipt(direction, name)?.is_some() {
            self.lengths.remove(&(direction, name.into()));
            self.identities.remove(&(direction, name.into()));
            self.next[if direction == Direction::Desktop {
                0
            } else {
                1
            }] += 1;
        }
        Ok(())
    }
}

#[cfg(test)]
mod retirement_tests {
    use super::*;
    #[test]
    fn acknowledged_window_handles_more_than_128_blocks_without_unbounded_history() {
        let mut receipts = BlockReceipts::default();
        for sequence in 0..140 {
            let name = format!("{sequence:016x}.block");
            assert_eq!(
                receipts.receipt(Direction::Mobile, &name),
                Err(NativeError::InvalidBlock)
            );
            receipts
                .record(Direction::Mobile, &name, &[1, 2, 3])
                .unwrap();
            assert_eq!(
                receipts.receipt(Direction::Mobile, &name).unwrap().unwrap(),
                3
            );
            receipts.retired(Direction::Mobile, &name).unwrap();
            assert_eq!(receipts.receipt(Direction::Mobile, &name).unwrap(), None);
        }
        assert_eq!(
            receipts.receipt(Direction::Desktop, "../0000000000000000.block"),
            Err(NativeError::InvalidBlock)
        );
        assert_eq!(
            receipts.receipt(Direction::Desktop, "0000000000000000.block"),
            Err(NativeError::InvalidBlock)
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scope_never_accepts_paths_or_noncanonical_ids() {
        assert_eq!(
            session_directory("0123456789abcdef0123456789abcdef").unwrap(),
            "s-0123456789abcdef0123456789abcdef"
        );
        for id in [
            "",
            "../",
            "ABCDEF0123456789abcdef0123456789ab",
            "0123456789abcdef0123456789abcdef/",
        ] {
            assert_eq!(session_directory(id), Err(NativeError::InvalidScope));
        }
    }
    #[test]
    fn completed_entries_are_bounded_unique_fixed_names_only() {
        assert!(block_name("0000000000000000.block"));
        for name in [
            "../0000000000000000.block",
            "000000000000000A.block",
            "0000000000000000.block.part",
        ] {
            assert!(!block_name(name));
        }
        let entries = vec![
            ("0000000000000001.block.part".into(), 0, false),
            ("0000000000000002.block".into(), 0, false),
            ("0000000000000000.block".into(), 123, false),
        ];
        assert_eq!(
            validate_entries(&entries).unwrap(),
            ["0000000000000000.block", "0000000000000002.block"]
        );
        assert_eq!(
            validate_entries(&[
                ("0000000000000000.block".into(), 3, false),
                ("0000000000000000.block".into(), 3, false),
            ]),
            Err(NativeError::Duplicate)
        );
        for (name, size, folder) in [
            ("bad", 3, false),
            ("0000000000000000.block", MAX_BLOCK as u64 + 1, false),
            ("0000000000000000.block", 1, true),
        ] {
            assert_eq!(
                validate_entries(&[(name.into(), size, folder)]),
                Err(NativeError::InvalidBlock)
            );
        }
        // OS metadata may lag behind a completed MTP rename. Ciphertext
        // framing/authentication is validated after actual bounded reads.
        for size in [0, 1, 3, 12, MAX_BLOCK as u64] {
            assert_eq!(
                validate_entries(&[("0000000000000000.block".into(), size, false)]),
                Ok(vec!["0000000000000000.block".into()])
            );
        }
        assert_eq!(
            validate_entries(&vec![("a.part".into(), 0, false); 129]),
            Err(NativeError::Bounds)
        );
    }
    #[test]
    fn a_full_window_rejects_reservation_without_poisoning_existing_blocks() {
        let mut entries = (0..128)
            .map(|i| (format!("{i:016x}.block"), 3, false))
            .collect::<Vec<_>>();
        let mut receipts = BlockReceipts::default();
        receipts
            .record(Direction::Desktop, "0000000000000000.block", &[1, 2, 3])
            .unwrap();
        let before = entries.clone();
        if reserve_block_entry(entries.len()).is_ok() {
            entries.push(("0000000000000080.block.part".into(), 0, false));
        }
        assert_eq!(entries, before, "rejection must not create a 129th part");
        assert_eq!(validate_entries(&entries).unwrap().len(), 128);
        assert!(receipts
            .receipt(Direction::Desktop, "0000000000000000.block")
            .unwrap()
            .is_some());
        receipts
            .retired(Direction::Desktop, "0000000000000000.block")
            .unwrap();
        entries.remove(0);
        reserve_block_entry(entries.len()).unwrap();
        entries.push(("0000000000000080.block".into(), 3, false));
        assert_eq!(validate_entries(&entries).unwrap().len(), 128);
    }
    #[test]
    fn routing_lookup_accepts_old_and_new_sessions_after_140_independent_sessions() {
        let sessions = (0..140).map(|i| format!("s-{i:032x}")).collect::<Vec<_>>();
        for target in [
            "s-00000000000000000000000000000000",
            "s-0000000000000000000000000000008b",
            "s-ffffffffffffffffffffffffffffffff",
        ] {
            let mut lookup = RouteLookup::new(target);
            for (identity, name) in sessions.iter().enumerate() {
                lookup.observe(name, true, identity).unwrap();
            }
            assert_eq!(
                lookup.finish(),
                match target {
                    "s-00000000000000000000000000000000" => Some(0),
                    "s-0000000000000000000000000000008b" => Some(139),
                    _ => None,
                }
            );
        }
        let mut duplicate = RouteLookup::new("desktop");
        duplicate.observe("desktop", true, 1).unwrap();
        assert_eq!(
            duplicate.observe("desktop", true, 2),
            Err(NativeError::Duplicate)
        );
        let mut not_a_folder = RouteLookup::new("mobile");
        assert_eq!(
            not_a_folder.observe("mobile", false, 1),
            Err(NativeError::InvalidScope)
        );
    }
}
