//! Bounded ordered ciphertext envelopes; MTP filesystem operations are platform-owned.
use super::*;
pub(crate) mod bundle;

/// Each direction owns a separate counter. Only call decode on atomically completed
/// `.block` files in the selected operation mailbox; never follow directories/symlinks.
/// A rejected input poisons this decoder. The caller must disconnect its Session.
#[derive(Default)]
pub struct OrderedCiphertext {
    outgoing: u64,
    incoming: u64,
    terminal: bool,
}
impl OrderedCiphertext {
    pub fn encode(&mut self, bytes: &[u8]) -> Result<(String, Vec<u8>), SessionError> {
        if self.terminal {
            return Err(SessionError::Terminal);
        }
        if bytes.is_empty() || bytes.len() > MAX_CIPHERTEXT {
            return Err(SessionError::Bounds);
        }
        let next = self.outgoing.checked_add(1).ok_or(SessionError::Bounds)?;
        let name = format!("{:016x}.block", self.outgoing);
        let mut block = Vec::with_capacity(bytes.len() + 12);
        block.extend_from_slice(&self.outgoing.to_be_bytes());
        block.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        block.extend_from_slice(bytes);
        self.outgoing = next;
        Ok((name, block))
    }
    pub fn decode(&mut self, name: &str, bytes: &[u8]) -> Result<Vec<u8>, SessionError> {
        if self.terminal {
            return Err(SessionError::Terminal);
        }
        match self.decode_inner(name, bytes) {
            Ok(value) => Ok(value),
            Err(error) => {
                self.terminal = true;
                Err(error)
            }
        }
    }
    fn decode_inner(&mut self, name: &str, bytes: &[u8]) -> Result<Vec<u8>, SessionError> {
        if name.len() != 22 || !name.ends_with(".block") || !super::qr::valid_hex(&name[..16], 16) {
            return Err(SessionError::Protocol);
        }
        if bytes.len() < 13 || bytes.len() > MAX_CIPHERTEXT + 12 {
            return Err(SessionError::Bounds);
        }
        let sequence =
            u64::from_be_bytes(bytes[..8].try_into().map_err(|_| SessionError::Protocol)?);
        let length = u32::from_be_bytes(
            bytes[8..12]
                .try_into()
                .map_err(|_| SessionError::Protocol)?,
        ) as usize;
        if length != bytes.len() - 12 {
            return Err(SessionError::Bounds);
        }
        if sequence != self.incoming || name != format!("{sequence:016x}.block") {
            return Err(SessionError::Protocol);
        }
        self.incoming = self.incoming.checked_add(1).ok_or(SessionError::Bounds)?;
        Ok(bytes[12..].to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ordered_mailbox_roundtrips_only_complete_sequential_bounded_blocks() {
        let mut sender = OrderedCiphertext::default();
        let mut receiver = OrderedCiphertext::default();
        let (name, bytes) = sender.encode(b"first TLS bytes").unwrap();
        assert_eq!(name, "0000000000000000.block");
        assert_eq!(receiver.decode(&name, &bytes).unwrap(), b"first TLS bytes");
        assert!(receiver.decode(&name, &bytes).is_err());
        assert!(receiver.decode("0000000000000001.block", &bytes).is_err());
    }
    #[test]
    fn mailbox_rejects_paths_partial_names_reordering_and_oversized_blocks() {
        for name in [
            "../0000000000000000.block",
            "/0000000000000000.block",
            "0000000000000000.block.part",
            "0000000000000000/BLOCK",
            "000000000000000A.block",
        ] {
            assert!(OrderedCiphertext::default().decode(name, &[0; 9]).is_err());
        }
        let mut sender = OrderedCiphertext::default();
        let _first = sender.encode(b"one").unwrap();
        let (name, bytes) = sender.encode(b"two").unwrap();
        assert!(OrderedCiphertext::default().decode(&name, &bytes).is_err());
        assert_eq!(
            sender.encode(&vec![0; MAX_CIPHERTEXT + 1]),
            Err(SessionError::Bounds)
        );
        assert!(OrderedCiphertext::default()
            .decode("0000000000000000.block", &vec![0; MAX_CIPHERTEXT + 9])
            .is_err());
    }
}
