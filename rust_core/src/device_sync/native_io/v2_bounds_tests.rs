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
    let mut packet = Vec::new();
    write_packet(&mut packet, &vec![1; MAX_IPC]).unwrap();
    assert_eq!(read_packet(&mut packet.as_slice()).unwrap().len(), MAX_IPC);
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
fn worker_ipc_accepts_exactly_twelve_mib_without_relaxing_declared_length_rejection() {
    let payload = vec![b'a'; MAX_IPC];
    let mut encoded = Vec::new();
    write_packet(&mut encoded, &payload).unwrap();
    assert_eq!(&encoded[..4], &(MAX_IPC as u32).to_be_bytes());
    assert_eq!(read_packet(&mut encoded.as_slice()).unwrap(), payload);
    let mut rejected = Vec::new();
    assert_eq!(
        write_packet(&mut rejected, &vec![0; MAX_IPC + 1]),
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
