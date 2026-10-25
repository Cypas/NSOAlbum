use super::*;

#[test]
fn v4_native_carrier_and_ipc_accept_eight_mib_and_reject_oversize_before_allocation() {
    let name = "0000000000000000.block";
    let mut receipts = BlockReceipts::default();
    receipts
        .record(Direction::Desktop, name, &vec![1; MAX_BLOCK])
        .unwrap();
    assert_eq!(
        receipts.receipt(Direction::Desktop, name).unwrap(),
        Some(MAX_BLOCK)
    );
    assert!(validate_entries(&[(name.into(), MAX_BLOCK as u64 + 1, false)]).is_err());
    let header = br#"{"method":"write","payload_length":8388608}"#.to_vec();
    let payload = vec![1; MAX_BLOCK];
    let mut packet = Vec::new();
    write_packet(
        &mut packet,
        &IpcPacket {
            header: header.clone(),
            payload: payload.clone(),
        },
    )
    .unwrap();
    let decoded = read_packet(&mut packet.as_slice()).unwrap();
    assert_eq!(decoded.header, header);
    assert_eq!(decoded.payload, payload);
    assert_eq!(
        read_packet(&mut (MAX_IPC as u32 + 1).to_be_bytes().as_slice()),
        Err(NativeError::Bounds)
    );
}

#[test]
fn v3_consumed_prefix_requires_every_read_identity_and_does_not_mutate_on_a_gap() {
    let mut receipts = BlockReceipts::default();
    let identity = BlockIdentity {
        object: 10,
        parent: 20,
        storage: 30,
    };
    receipts
        .record_identified(Direction::Mobile, "0000000000000000.block", &[1], identity)
        .unwrap();
    receipts
        .record_identified(
            Direction::Mobile,
            "0000000000000002.block",
            &[2],
            BlockIdentity {
                object: 12,
                ..identity
            },
        )
        .unwrap();
    assert_eq!(
        receipts.retirement_prefix(Direction::Mobile, "0000000000000002.block"),
        Err(NativeError::InvalidBlock)
    );
    assert_eq!(
        receipts
            .receipt(Direction::Mobile, "0000000000000000.block")
            .unwrap(),
        Some(1)
    );
    receipts
        .record_identified(
            Direction::Mobile,
            "0000000000000001.block",
            &[3],
            BlockIdentity {
                object: 11,
                ..identity
            },
        )
        .unwrap();
    let batch = receipts
        .retirement_prefix(Direction::Mobile, "0000000000000002.block")
        .unwrap();
    assert_eq!(
        batch
            .iter()
            .map(|(_, _, identity)| identity.object)
            .collect::<Vec<_>>(),
        [10, 11, 12]
    );
    for (name, _, _) in batch {
        receipts.retired(Direction::Mobile, &name).unwrap();
    }
    assert!(receipts
        .retirement_prefix(Direction::Mobile, "0000000000000002.block")
        .unwrap()
        .is_empty());
    assert!(receipts
        .retirement_prefix(Direction::Mobile, "000000000000000b.block")
        .is_err());
}

#[test]
fn native_v4_ciphertext_carrier_accepts_exactly_eight_mib_and_rejects_one_extra_byte() {
    let name = "0000000000000000.block";
    let mut receipts = BlockReceipts::default();
    let bytes = vec![0x53; MAX_BLOCK];
    assert!(receipts.record(Direction::Desktop, name, &bytes).is_ok());
    assert_eq!(
        validate_entries(&[(name.into(), MAX_BLOCK as u64, false)]).unwrap(),
        vec![name]
    );
    assert_eq!(
        receipts.record(Direction::Desktop, name, &vec![0; MAX_BLOCK + 1]),
        Err(NativeError::Bounds)
    );
    assert_eq!(
        validate_entries(&[(name.into(), MAX_BLOCK as u64 + 1, false)]),
        Err(NativeError::InvalidBlock)
    );
    // A rejected replacement must not corrupt the last owned receipt.
    assert_eq!(
        receipts.receipt(Direction::Desktop, name).unwrap(),
        Some(MAX_BLOCK)
    );
}

#[test]
fn worker_ipc_accepts_binary_carrier_without_base64_expansion() {
    let payload = vec![0x53; MAX_BLOCK];
    let header = br#"{"method":"write","payload_length":8388608}"#.to_vec();
    let ipc = IpcPacket {
        header: header.clone(),
        payload: payload.clone(),
    };
    let mut encoded = Vec::new();
    write_packet(&mut encoded, &ipc).unwrap();
    assert_eq!(
        u32::from_be_bytes(encoded[..4].try_into().unwrap()) as usize,
        IPC_ENVELOPE_BYTES + header.len() + MAX_BLOCK
    );
    let decoded = read_packet(&mut encoded.as_slice()).unwrap();
    assert_eq!(decoded, ipc);
    let mut rejected = Vec::new();
    assert_eq!(
        write_packet(
            &mut rejected,
            &IpcPacket {
                header,
                payload: vec![0; MAX_BLOCK + 1],
            }
        ),
        Err(NativeError::Bounds)
    );
    assert!(rejected.is_empty());
    // Only the header is available: reject before trying to allocate/read its body.
    for length in [MAX_IPC as u32 + 1, u32::MAX] {
        assert_eq!(
            read_packet(&mut length.to_be_bytes().as_slice()),
            Err(NativeError::Bounds)
        );
    }
}

#[test]
fn native_write_request_uses_raw_payload_and_checks_declared_length() {
    let payload = vec![0, 255, 1, 128];
    let request = NativeRequest::Write {
        operation: "a".repeat(32),
        session: "b".repeat(32),
        name: "0000000000000000.block".into(),
        bytes: payload.clone(),
    };
    let packet = request.into_packet().unwrap();
    let header: serde_json::Value = serde_json::from_slice(&packet.header).unwrap();
    assert_eq!(header["payload_length"], payload.len());
    assert_eq!(packet.payload, payload);
    assert!(header.get("bytes").is_none());
    assert_eq!(
        NativeRequest::from_packet(packet).unwrap(),
        NativeRequest::Write {
            operation: "a".repeat(32),
            session: "b".repeat(32),
            name: "0000000000000000.block".into(),
            bytes: vec![0, 255, 1, 128],
        }
    );

    let mut malformed = NativeRequest::Write {
        operation: "a".repeat(32),
        session: "b".repeat(32),
        name: "0000000000000000.block".into(),
        bytes: vec![1, 2, 3],
    }
    .into_packet()
    .unwrap();
    malformed.payload.push(4);
    assert_eq!(
        NativeRequest::from_packet(malformed),
        Err(NativeError::Bounds)
    );
    assert_eq!(
        NativeRequest::from_packet(IpcPacket {
            header: br#"{"method":"read","operation":"a","session":"b","direction":"desktop","name":"0000000000000000.block"}"#.to_vec(),
            payload: vec![1],
        }),
        Err(NativeError::InvalidBlock)
    );
}

#[test]
fn native_read_response_keeps_binary_body_outside_json_header() {
    let payload = vec![0, 255, 1, 128];
    let packet = response_packet(Ok(serde_json::Value::Null), payload.clone()).unwrap();
    let header: serde_json::Value = serde_json::from_slice(&packet.header).unwrap();
    assert_eq!(header["payload_length"], payload.len());
    assert!(header["value"]["Ok"].is_null());
    assert_eq!(packet.payload, payload);
    let response = response_from_packet(packet).unwrap();
    assert!(response.value.is_null());
    assert_eq!(response.payload, vec![0, 255, 1, 128]);
    assert_eq!(
        response_packet(Err(NativeError::InvalidBlock), vec![1]),
        Err(NativeError::Bounds)
    );
    assert_eq!(
        response_packet(Ok(serde_json::json!(true)), vec![1]),
        Err(NativeError::InvalidBlock)
    );
}

#[test]
fn ipc_decoders_enforce_bounds_for_directly_constructed_packets() {
    assert_eq!(
        NativeRequest::from_packet(IpcPacket {
            header: vec![b' '; MAX_IPC_HEADER + 1],
            payload: vec![],
        }),
        Err(NativeError::Bounds)
    );
    assert_eq!(
        NativeRequest::from_packet(IpcPacket {
            header: br#"{"method":"enumerate"}"#.to_vec(),
            payload: vec![0; MAX_BLOCK + 1],
        }),
        Err(NativeError::Bounds)
    );
    assert_eq!(
        response_from_packet(IpcPacket {
            header: vec![b' '; MAX_IPC_HEADER + 1],
            payload: vec![],
        }),
        Err(NativeError::Bounds)
    );
}

#[test]
fn legacy_json_only_worker_framing_is_rejected() {
    let legacy_body = br#"{"method":"enumerate"}"#;
    let mut packet = Vec::new();
    packet.extend_from_slice(&(legacy_body.len() as u32).to_be_bytes());
    packet.extend_from_slice(legacy_body);
    assert_eq!(read_packet(&mut packet.as_slice()), Err(NativeError::Io));
}

#[test]
fn ipc_framing_rejects_truncation_and_inconsistent_lengths() {
    let mut encoded = vec![];
    write_packet(
        &mut encoded,
        &IpcPacket {
            header: br#"{"method":"close"}"#.to_vec(),
            payload: vec![0, 255, 128],
        },
    )
    .unwrap();
    for cut in [0, 3, 4, 12, 19, 20, encoded.len() - 1] {
        assert_eq!(
            read_packet(&mut &encoded[..cut]),
            Err(NativeError::Io),
            "truncated packet at {cut}"
        );
    }
    for (offset, declared) in [
        (12, 0),
        (12, MAX_IPC_HEADER as u32 + 1),
        (16, MAX_BLOCK as u32 + 1),
        (16, 2),
    ] {
        let mut malformed = encoded.clone();
        malformed[offset..offset + 4].copy_from_slice(&declared.to_be_bytes());
        assert_eq!(
            read_packet(&mut malformed.as_slice()),
            Err(NativeError::Bounds)
        );
    }
}

#[test]
fn ipc_framing_handles_short_reads_and_writes_and_reports_broken_pipe() {
    use std::io::{Read, Write};
    struct ShortWriter {
        bytes: Vec<u8>,
        remaining: usize,
    }
    impl Write for ShortWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if self.remaining == 0 {
                return Err(std::io::ErrorKind::BrokenPipe.into());
            }
            let count = bytes.len().min(3).min(self.remaining);
            self.bytes.extend_from_slice(&bytes[..count]);
            self.remaining -= count;
            Ok(count)
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    struct ShortReader<'a>(&'a [u8]);
    impl Read for ShortReader<'_> {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            let count = bytes.len().min(2);
            self.0.read(&mut bytes[..count])
        }
    }
    let packet = IpcPacket {
        header: br#"{"value":{"Ok":null},"payload_length":4}"#.to_vec(),
        payload: vec![0, 128, 255, 3],
    };
    let mut writer = ShortWriter {
        bytes: vec![],
        remaining: usize::MAX,
    };
    write_packet(&mut writer, &packet).unwrap();
    assert_eq!(
        read_packet(&mut ShortReader(&writer.bytes)).unwrap(),
        packet
    );
    let mut broken = ShortWriter {
        bytes: vec![],
        remaining: 25,
    };
    assert_eq!(write_packet(&mut broken, &packet), Err(NativeError::Io));
    assert_eq!(
        read_packet(&mut broken.bytes.as_slice()),
        Err(NativeError::Io)
    );
}

#[test]
fn response_payload_must_match_the_native_operation() {
    assert!(validate_response_payload(
        NativeResponse {
            value: serde_json::Value::Null,
            payload: vec![1, 2, 3],
        },
        true,
    )
    .is_ok());
    assert_eq!(
        validate_response_payload(
            NativeResponse {
                value: serde_json::Value::Null,
                payload: vec![],
            },
            true,
        ),
        Err(NativeError::InvalidBlock)
    );
    assert_eq!(
        validate_response_payload(
            NativeResponse {
                value: serde_json::Value::Null,
                payload: vec![1],
            },
            false,
        ),
        Err(NativeError::InvalidBlock)
    );
}

#[test]
fn native_receipt_rejects_same_bytes_replaced_by_a_different_session_object() {
    let name = "0000000000000000.block";
    let original = BlockIdentity {
        object: 7,
        parent: 9,
        storage: 11,
    };
    let mut receipts = BlockReceipts::default();
    receipts
        .record_identified(Direction::Mobile, name, &[1, 2, 3], original)
        .unwrap();
    receipts
        .require_identity(Direction::Mobile, name, original)
        .unwrap();
    for replacement in [
        BlockIdentity {
            object: 8,
            ..original
        },
        BlockIdentity {
            parent: 10,
            ..original
        },
        BlockIdentity {
            storage: 12,
            ..original
        },
    ] {
        assert_eq!(
            receipts.require_identity(Direction::Mobile, name, replacement),
            Err(NativeError::InvalidBlock),
        );
        assert_eq!(
            receipts.record_identified(Direction::Mobile, name, &[1, 2, 3], replacement),
            Err(NativeError::InvalidBlock),
        );
        receipts
            .require_identity(Direction::Mobile, name, original)
            .unwrap();
    }
    receipts.retired(Direction::Mobile, name).unwrap();
    assert_eq!(
        receipts.require_identity(Direction::Mobile, name, original),
        Err(NativeError::InvalidBlock),
    );
}

#[test]
fn native_batch_reservation_is_bounded_and_rejection_does_not_consume_the_window() {
    let mut batch = BatchBudget::default();
    for sequence in 0..4 {
        batch
            .reserve(&format!("{sequence:016x}.block"), 65_536)
            .unwrap();
    }
    assert_eq!(
        batch.reserve("0000000000000004.block", 1),
        Err(NativeError::Bounds)
    );
    let mut batch = BatchBudget::default();
    batch
        .reserve("0000000000000000.block", MAX_BLOCK - 1)
        .unwrap();
    assert_eq!(
        batch.reserve("0000000000000001.block", 2),
        Err(NativeError::Bounds)
    );
    batch.reserve("0000000000000001.block", 1).unwrap();
    assert_eq!(
        batch.reserve("0000000000000001.block", 1),
        Err(NativeError::Duplicate)
    );
    for name in ["../0000000000000002.block", "000000000000000A.block"] {
        assert_eq!(
            BatchBudget::default().reserve(name, 1),
            Err(NativeError::InvalidBlock)
        );
    }
    assert_eq!(
        BatchBudget::default().reserve("0000000000000000.block", 0),
        Err(NativeError::Bounds)
    );
    assert_eq!(
        BatchBudget::default().reserve("0000000000000000.block", usize::MAX),
        Err(NativeError::Bounds)
    );
}
