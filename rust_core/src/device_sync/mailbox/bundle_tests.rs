use super::*;

#[test]
fn v4_carrier_aggregates_four_mib_and_accepts_eight_mib_without_changing_tls_drains() {
    let drains = vec![vec![0x53; 65_536]; 64];
    let first = BundleEncoder::default().encode(&drains).unwrap();
    assert!(first.bytes.len() > 4 * 1024 * 1024);
    assert_eq!(&first.bytes[..8], b"NSOUSB4\0");
    assert_eq!(
        BundleDecoder::default()
            .decode(&first.name, &first.bytes)
            .unwrap(),
        drains
    );
    let mut full = vec![vec![1; 65_536]; 127];
    full.push(vec![2; 65_000]);
    let mut encoder = BundleEncoder::default();
    assert_eq!(encoder.encode(&full).unwrap().bytes.len(), 8 * 1024 * 1024);
    full[127].push(1);
    assert!(encoder.encode(&full).is_err());
    let mut old = first.bytes.clone();
    old[6] = b'3';
    assert!(BundleDecoder::default().decode(&first.name, &old).is_err());
}

#[test]
fn bundle_encoding_matches_an_independent_single_drain_golden() {
    let encoded = BundleEncoder::default().encode(&[vec![b'a']]).unwrap();
    assert_eq!(encoded.name, "0000000000000000.block");
    assert_eq!(
        encoded.bytes,
        [
            b'N', b'S', b'O', b'U', b'S', b'B', b'4', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 1,
            0, 0, 0, 0, 0, 1, b'a',
        ]
    );
    assert_eq!(encoded.ciphertext_bytes, 1);
}

#[test]
fn bounded_bundle_roundtrip_preserves_tls_drain_order_and_identity() {
    let drains = vec![vec![1; 65_536], vec![2; 10], vec![3; 32_768]];
    let mut encoder = BundleEncoder::default();
    let mut decoder = BundleDecoder::default();
    let first = encoder.encode(&drains).unwrap();
    assert_eq!(decoder.decode(&first.name, &first.bytes).unwrap(), drains);
    let second = encoder.encode(&[vec![4]]).unwrap();
    assert_eq!(second.name, "0000000000000001.block");
    assert_eq!(
        decoder.decode(&second.name, &second.bytes).unwrap(),
        vec![vec![4]]
    );
}

#[test]
fn exact_total_bound_is_accepted_and_one_extra_byte_is_rejected_before_sequence_changes() {
    let mut encoder = BundleEncoder::default();
    let mut drains = vec![vec![0; 65_536]; 127];
    drains.push(vec![1; 65_000]);
    let encoded = encoder.encode(&drains).unwrap();
    assert_eq!(encoded.bytes.len(), 8 * 1024 * 1024);
    drains[127].push(1);
    assert!(encoder.encode(&drains).is_err());
    let next = encoder.encode(&[vec![1]]).unwrap();
    assert_eq!(next.name, "0000000000000001.block");
}

#[test]
fn malformed_lengths_flags_and_trailing_bytes_poison_the_decoder() {
    let encoded = BundleEncoder::default().encode(&[vec![1]]).unwrap();
    let mut cases = vec![];
    for (offset, value) in [(0, b'X'), (19, 255), (21, 5), (23, 1), (27, 255)] {
        let mut corrupt = encoded.bytes.clone();
        corrupt[offset] = value;
        cases.push(corrupt);
    }
    cases.push(encoded.bytes[..28].to_vec());
    let mut trailing = encoded.bytes.clone();
    trailing.push(0);
    cases.push(trailing);
    for bytes in cases {
        let mut decoder = BundleDecoder::default();
        assert!(decoder.decode(&encoded.name, &bytes).is_err());
        assert!(decoder.decode(&encoded.name, &encoded.bytes).is_err());
    }
}

#[test]
fn duplicate_jump_and_path_names_never_become_acknowledgeable() {
    let mut encoder = BundleEncoder::default();
    let first = encoder.encode(&[vec![1]]).unwrap();
    let next = encoder.encode(&[vec![2]]).unwrap();
    assert!(BundleDecoder::default()
        .decode(&next.name, &next.bytes)
        .is_err());
    for name in ["../0000000000000000.block", "0000000000000000.block.part"] {
        assert!(BundleDecoder::default().decode(name, &first.bytes).is_err());
    }
    let mut decoder = BundleDecoder::default();
    decoder.decode(&first.name, &first.bytes).unwrap();
    assert!(decoder.decode(&first.name, &first.bytes).is_err());
}

#[test]
fn empty_or_too_many_drains_and_oversized_tls_drains_are_rejected() {
    let mut encoder = BundleEncoder::default();
    for drains in [
        vec![],
        vec![vec![]],
        vec![vec![1]; 129],
        vec![vec![1; 65_537]],
    ] {
        assert!(encoder.encode(&drains).is_err());
    }
    assert_eq!(
        encoder.encode(&[vec![1]]).unwrap().name,
        "0000000000000000.block"
    );
}

#[test]
fn media_buffer_flushes_partial_output_after_fifty_milliseconds() {
    let mut buffer = BundleBuffer::default();
    buffer.push(vec![1; 32_768], FlushHint::Media, 100).unwrap();
    assert!(!buffer.ready(149));
    assert!(buffer.ready(150));
    assert_eq!(buffer.take(), vec![vec![1; 32_768]]);
    assert!(!buffer.ready(1_000));
}

#[test]
fn control_output_and_a_full_credit_window_flush_without_waiting_for_target() {
    let mut buffer = BundleBuffer::default();
    buffer.push(vec![1], FlushHint::Media, 100).unwrap();
    assert!(!buffer.ready(100));
    buffer.push(vec![2], FlushHint::Immediate, 101).unwrap();
    assert!(buffer.ready(101));
    assert_eq!(buffer.take(), vec![vec![1], vec![2]]);
    for _ in 0..128 {
        buffer.push(vec![3], FlushHint::Media, 200).unwrap();
    }
    assert!(buffer.ready(200));
    assert!(buffer.push(vec![9], FlushHint::Media, 200).is_err());
    assert_eq!(buffer.take(), vec![vec![3]; 128]);
}

#[test]
fn size_target_flushes_and_credit_stall_can_publish_a_smaller_partial_bundle() {
    let mut buffer = BundleBuffer::default();
    buffer.push(vec![1; 65_536], FlushHint::Media, 0).unwrap();
    assert!(!buffer.ready(0));
    for _ in 0..63 {
        buffer.push(vec![2; 65_536], FlushHint::Media, 0).unwrap();
    }
    assert!(buffer.ready(0));
    buffer.take();
    buffer.push(vec![4], FlushHint::Media, 10).unwrap();
    // An owner that has no more authorized output may flush without waiting.
    assert_eq!(buffer.take(), vec![vec![4]]);
}
