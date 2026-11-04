use super::*;

pub(super) fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

#[test]
fn creates_an_ephemeral_usb_invitation() {
    // A disabled invitation generator must prevent pairing, not look successful.
    assert!(Invitation::create(Transport::Usb, now()).is_ok());
}

#[test]
fn streaming_profile_is_required_for_both_transports_even_at_the_same_application_version() {
    for transport in [
        Transport::Usb,
        Transport::Tcp("192.168.1.2:40501".parse().unwrap()),
    ] {
        let time = now();
        let invitation = Invitation::create(transport, time).unwrap();
        let original: serde_json::Value =
            serde_json::from_str(&invitation.qr().unwrap().encode().unwrap()).unwrap();
        assert_eq!(original["flow_profile"], "binary-media-v2");
        for profile in [None, Some("stream-window-v1"), Some("binary-media-v99")] {
            let mut value = original.clone();
            value.as_object_mut().unwrap().remove("flow_profile");
            if let Some(profile) = profile {
                value["flow_profile"] = profile.into();
            }
            assert!(matches!(
                Qr::parse(&value.to_string(), time),
                Err(SessionError::VersionMismatch)
            ));
        }
    }
}

#[test]
fn usb_invitation_advertises_explicit_mailbox_profile_not_just_app_build() {
    let invitation = Invitation::create(Transport::Usb, now()).unwrap();
    let value: serde_json::Value =
        serde_json::from_str(&invitation.qr().unwrap().encode().unwrap()).unwrap();
    assert_eq!(value["usb_profile"], "usb-mailbox-v4");
}

#[test]
fn usb_missing_or_unknown_profile_is_rejected_even_with_the_same_app_build() {
    let time = now();
    let build = super::connection::ApplicationBuild {
        version: "0.2.14".into(),
        build_number: "47".into(),
    };
    let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
    invitation.set_app_build(Some(build.clone())).unwrap();
    invitation.delegate_to_phone().unwrap();
    let original: serde_json::Value =
        serde_json::from_str(&invitation.qr().unwrap().encode().unwrap()).unwrap();
    for capability in [
        None,
        Some("usb-mailbox-v1"),
        Some("usb-mailbox-v2"),
        Some("usb-mailbox-v99"),
    ] {
        let mut value = original.clone();
        value.as_object_mut().unwrap().remove("usb_profile");
        if let Some(capability) = capability {
            value["usb_profile"] = capability.into();
        }
        assert_eq!(
            super::connection::inspect_compatible(&value.to_string(), time, &build),
            Err(SessionError::VersionMismatch)
        );
    }
}

#[test]
fn tcp_invitation_preserves_its_format_and_refuses_usb_capability() {
    let time = now();
    let invitation =
        Invitation::create(Transport::Tcp("192.168.31.66:40501".parse().unwrap()), time).unwrap();
    let mut value: serde_json::Value =
        serde_json::from_str(&invitation.qr().unwrap().encode().unwrap()).unwrap();
    assert!(value.get("usb_profile").is_none());
    value["usb_profile"] = "usb-mailbox-v2".into();
    assert!(matches!(
        Qr::parse(&value.to_string(), time),
        Err(SessionError::InvalidQr)
    ));
}

#[test]
fn invitation_connection_reads_optional_wifi_hint_and_usb_without_opening() {
    let time = now();
    let mut wifi =
        Invitation::create(Transport::Tcp("192.168.31.66:40501".parse().unwrap()), time).unwrap();
    wifi.set_wifi_ssid(Some("鱿鱼 Wi-Fi".into())).unwrap();
    let encoded = wifi.qr().unwrap().encode().unwrap();
    let view = super::connection::inspect(&encoded, time).unwrap();
    assert!(!view.usb);
    assert_eq!(view.wifi_ssid.as_deref(), Some("鱿鱼 Wi-Fi"));
    let usb = Invitation::create(Transport::Usb, time).unwrap();
    let encoded = usb.qr().unwrap().encode().unwrap();
    assert!(!encoded.contains("wifi_ssid"));
    let view = super::connection::inspect(&encoded, time).unwrap();
    assert!(view.usb);
    assert_eq!(view.wifi_ssid, None);
    // Only the host clock/monotonic deadline can decide expiry. Phone wall-clock
    // skew remains reportable after the QR-anchored TLS handshake.
    assert!(super::connection::inspect(&encoded, time + 3600).is_ok());
    assert!(super::connection::inspect(&encoded, time - 3600).is_ok());
}

#[test]
fn invitation_connection_version_and_build_must_both_match() {
    use super::connection::ApplicationBuild;
    let time = now();
    let local = ApplicationBuild {
        version: "0.2.14".into(),
        build_number: "47".into(),
    };
    let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
    let legacy = invitation.qr().unwrap().encode().unwrap();
    assert_eq!(
        super::connection::inspect_compatible(&legacy, time, &local),
        Err(SessionError::VersionMismatch)
    );
    invitation.set_app_build(Some(local.clone())).unwrap();
    invitation.delegate_to_phone().unwrap();
    let encoded = invitation.qr().unwrap().encode().unwrap();
    assert_eq!(
        super::connection::inspect_compatible(&encoded, time, &local)
            .unwrap()
            .app_build,
        Some(local)
    );
    for other in [
        ApplicationBuild {
            version: "0.2.15".into(),
            build_number: "47".into(),
        },
        ApplicationBuild {
            version: "0.2.14".into(),
            build_number: "48".into(),
        },
    ] {
        assert_eq!(
            super::connection::inspect_compatible(&encoded, time, &other),
            Err(SessionError::VersionMismatch)
        );
    }
}

#[test]
fn phone_controller_product_inspection_rejects_same_build_dual_local_invitation() {
    let time = now();
    let local = super::connection::ApplicationBuild {
        version: "0.2.14".into(),
        build_number: "47".into(),
    };
    let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
    invitation.set_app_build(Some(local.clone())).unwrap();
    let encoded = invitation.qr().unwrap().encode().unwrap();
    assert_eq!(
        super::connection::inspect_compatible(&encoded, time, &local),
        Err(SessionError::Protocol)
    );
}

#[test]
fn phone_controller_managed_client_rejects_build_identified_dual_local_invitation() {
    let time = now();
    let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
    invitation
        .set_app_build(Some(super::connection::ApplicationBuild {
            version: "0.2.14".into(),
            build_number: "47".into(),
        }))
        .unwrap();
    let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time).unwrap();
    assert!(matches!(
        Session::client(qr, Role::Sender, "Synthetic", time),
        Err(SessionError::Protocol)
    ));
}

#[test]
fn invitation_connection_app_build_is_bounded_and_bound_to_authentication() {
    use super::connection::ApplicationBuild;
    let time = now();
    let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
    for (version, build) in [
        ("", "47"),
        ("0.2.14", ""),
        ("0.2.14", "x"),
        ("0.2.14\n", "47"),
        ("a very long invalid version string", "47"),
    ] {
        assert!(invitation
            .set_app_build(Some(ApplicationBuild {
                version: version.into(),
                build_number: build.into()
            }))
            .is_err());
    }
    invitation
        .set_app_build(Some(ApplicationBuild {
            version: "0.2.14".into(),
            build_number: "47".into(),
        }))
        .unwrap();
    invitation.delegate_to_phone().unwrap();
    let mut wire: serde_json::Value =
        serde_json::from_str(&invitation.qr().unwrap().encode().unwrap()).unwrap();
    wire["app_build"]["build_number"] = serde_json::json!("48");
    let qr = Qr::parse(&wire.to_string(), time).unwrap();
    let mut host = invitation.accept(Role::Receiver, "Desktop", time).unwrap();
    let mut client = Session::client(qr, Role::Sender, "Phone", time).unwrap();
    assert_eq!(
        pump(&mut host, &mut client, time),
        Err(SessionError::Authentication)
    );
    assert_ne!(host.state(), SessionState::Confirmed);
}

#[test]
fn invitation_connection_rejects_malformed_oversized_and_usb_network_hints() {
    let time = now();
    let mut wifi =
        Invitation::create(Transport::Tcp("192.168.31.66:40501".parse().unwrap()), time).unwrap();
    for bad in ["", "a\nb", "bad\u{0}name", &"网".repeat(11)] {
        assert!(wifi.set_wifi_ssid(Some(bad.into())).is_err());
    }
    wifi.set_wifi_ssid(Some("a".repeat(32))).unwrap();
    let mut value: serde_json::Value =
        serde_json::from_str(&wifi.qr().unwrap().encode().unwrap()).unwrap();
    for bad in [serde_json::json!("a".repeat(33)), serde_json::json!(42)] {
        value["wifi_ssid"] = bad;
        assert!(super::connection::inspect(&value.to_string(), time).is_err());
    }
    value["wifi_ssid"] = serde_json::json!("valid-name");
    value["transport"] = serde_json::json!({"kind":"usb"});
    assert!(super::connection::inspect(&value.to_string(), time).is_err());
    assert!(super::connection::inspect(&" ".repeat(8193), time).is_err());
}

pub(super) fn pair(transport: Transport, host_role: Role) -> (Invitation, Session, Session, i64) {
    let time = now();
    let mut invitation = Invitation::create(transport, time).unwrap();
    let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time).unwrap();
    let host = invitation.accept(host_role, "Desktop", time).unwrap();
    let client_role = if host_role == Role::Sender {
        Role::Receiver
    } else {
        Role::Sender
    };
    let client = Session::client(qr, client_role, "Phone", time).unwrap();
    (invitation, host, client, time)
}

pub(super) fn pump(
    host: &mut Session,
    client: &mut Session,
    time: i64,
) -> Result<(), SessionError> {
    for _ in 0..12 {
        let bytes = client.drain_ciphertext(time)?;
        if !bytes.is_empty() {
            host.ingest_ciphertext(&bytes, time)?;
        }
        let bytes = host.drain_ciphertext(time)?;
        if !bytes.is_empty() {
            client.ingest_ciphertext(&bytes, time)?;
        }
    }
    Ok(())
}

pub(super) fn confirmed(host_role: Role) -> (Session, Session, i64) {
    let (_, mut host, mut client, time) = pair(Transport::Usb, host_role);
    pump(&mut host, &mut client, time).unwrap();
    host.confirm(time).unwrap();
    client.confirm(time).unwrap();
    pump(&mut host, &mut client, time).unwrap();
    (host, client, time)
}

#[test]
fn real_tls_requires_both_explicit_confirmations_for_both_directions() {
    for role in [Role::Sender, Role::Receiver] {
        let (_, mut host, mut client, time) = pair(Transport::Usb, role);
        assert_eq!(
            host.send_payload(b"forbidden", time),
            Err(SessionError::NotConfirmed)
        );
        pump(&mut host, &mut client, time).unwrap();
        assert_eq!(host.state(), SessionState::AwaitingConfirmation);
        assert_eq!(
            host.confirmation_code(time).unwrap(),
            client.confirmation_code(time).unwrap()
        );
        assert_eq!(host.peer_info().unwrap().name, "Phone");
        host.confirm(time).unwrap();
        pump(&mut host, &mut client, time).unwrap();
        assert_eq!(
            host.send_payload(b"still forbidden", time),
            Err(SessionError::NotConfirmed)
        );
        assert_eq!(
            client.receive_payload(time),
            Err(SessionError::NotConfirmed)
        );
        client.confirm(time).unwrap();
        pump(&mut host, &mut client, time).unwrap();
        host.send_payload(b"original media", time).unwrap();
        client.send_payload(b"preview", time).unwrap();
        pump(&mut host, &mut client, time).unwrap();
        assert_eq!(
            client.receive_payload(time).unwrap(),
            Some(b"original media".to_vec())
        );
        assert_eq!(
            host.receive_payload(time).unwrap(),
            Some(b"preview".to_vec())
        );
    }
}

#[test]
fn invitation_cannot_be_reused_and_debug_never_reveals_secret() {
    let time = now();
    let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
    let secret = invitation.qr().unwrap().wire.secret.clone();
    assert!(!format!("{invitation:?}").contains(&secret));
    assert!(!format!("{:?}", invitation.qr().unwrap()).contains(&secret));
    invitation.accept(Role::Sender, "Desktop", time).unwrap();
    assert!(matches!(
        invitation.accept(Role::Sender, "Desktop", time),
        Err(SessionError::Consumed)
    ));
    assert!(matches!(invitation.qr(), Err(SessionError::Consumed)));
}

#[test]
fn qr_rejects_public_addresses_unknown_fields_and_invalid_lengths() {
    let time = now();
    assert!(Invitation::create(Transport::Tcp("8.8.8.8:443".parse().unwrap()), time).is_err());
    assert!(Invitation::create(Transport::Tcp("192.168.1.1:0".parse().unwrap()), time).is_err());
    let invitation = Invitation::create(Transport::Usb, time).unwrap();
    let mut value: serde_json::Value =
        serde_json::from_str(&invitation.qr().unwrap().encode().unwrap()).unwrap();
    for (key, bad) in [
        ("version", serde_json::json!(2)),
        ("secret", serde_json::json!("bad")),
        ("session_id", serde_json::json!("../path")),
        ("operation_id", serde_json::json!("1".repeat(33))),
        ("unexpected", serde_json::json!(true)),
        ("expires_at", serde_json::json!(time + 301)),
        ("root_der", serde_json::json!("A".repeat(2737))),
    ] {
        let old = value.get(key).cloned();
        value[key] = bad;
        assert!(Qr::parse(&value.to_string(), time).is_err(), "{key}");
        if let Some(old) = old {
            value[key] = old;
        } else {
            value.as_object_mut().unwrap().remove(key);
        }
    }
    assert!(matches!(
        Qr::parse(&" ".repeat(8193), time),
        Err(SessionError::Bounds)
    ));
}

#[test]
fn expiry_cancels_pending_but_does_not_interrupt_confirmed_media() {
    let (mut host, mut client, time) = confirmed(Role::Sender);
    host.send_payload(b"long transfer", time + 301).unwrap();
    pump(&mut host, &mut client, time + 301).unwrap();
    assert_eq!(
        client.receive_payload(time + 301).unwrap(),
        Some(b"long transfer".to_vec())
    );
    let (_, mut pending, _, time) = pair(Transport::Usb, Role::Sender);
    assert_eq!(pending.tick(time + 300), Err(SessionError::Expired));
    assert_eq!(pending.tick(time), Err(SessionError::Terminal));
}

#[test]
fn cancel_or_disconnect_destroys_authorization_and_queued_plaintext() {
    for disconnect in [false, true] {
        let (mut host, mut client, time) = confirmed(Role::Sender);
        host.send_payload(b"secret account selection", time)
            .unwrap();
        pump(&mut host, &mut client, time).unwrap();
        if disconnect {
            client.disconnect();
        } else {
            client.cancel();
        }
        assert_eq!(client.state(), SessionState::Terminal);
        assert_eq!(client.receive_payload(time), Err(SessionError::Terminal));
        assert_eq!(client.drain_ciphertext(time), Err(SessionError::Terminal));
    }
}

#[test]
fn wrong_secret_or_session_or_transport_or_fingerprint_is_terminal() {
    for field in [
        "secret",
        "session_id",
        "operation_id",
        "transport",
        "fingerprint",
        "root_der",
    ] {
        let time = now();
        let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
        let mut qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time).unwrap();
        match field {
            "secret" => qr.wire.secret = "00".repeat(32),
            "session_id" => qr.wire.session_id = "00".repeat(16),
            "operation_id" => qr.wire.operation_id = "00".repeat(16),
            "transport" => {
                qr.wire.transport = Transport::Tcp("127.0.0.1:12345".parse().unwrap());
                // Keep the forged TCP QR schema-valid so this still tests TLS
                // authentication binding, not the earlier USB-only field check.
                qr.wire.usb_profile = None;
            }
            "fingerprint" => qr.wire.fingerprint = "00".repeat(32),
            "root_der" => {
                let other = Invitation::create(Transport::Usb, time).unwrap();
                qr.wire.root_der = other.qr.wire.root_der.clone();
            }
            _ => unreachable!(),
        }
        let mut host = invitation.accept(Role::Sender, "Desktop", time).unwrap();
        let mut client = Session::client(qr, Role::Receiver, "Phone", time).unwrap();
        assert!(pump(&mut host, &mut client, time).is_err(), "{field}");
        assert!(host.state() == SessionState::Terminal || client.state() == SessionState::Terminal);
    }
}

#[test]
fn device_names_and_clock_input_are_bounded_before_pairing() {
    for name in ["", " \t", "unsafe\nname", &"x".repeat(129)] {
        let mut invitation = Invitation::create(Transport::Usb, now()).unwrap();
        assert!(invitation.accept(Role::Sender, name, now()).is_err());
    }
    assert!(Invitation::create(Transport::Usb, 0).is_err());
}

#[test]
fn ciphertext_tamper_and_replay_are_rejected_by_real_tls() {
    for replay in [false, true] {
        let (mut host, mut client, time) = confirmed(Role::Sender);
        host.send_payload(b"payload", time).unwrap();
        let mut bytes = host.drain_ciphertext(time).unwrap();
        if replay {
            client.ingest_ciphertext(&bytes, time).unwrap();
        } else {
            let last = bytes.len() - 1;
            bytes[last] ^= 1;
        }
        assert!(client.ingest_ciphertext(&bytes, time).is_err());
        assert_eq!(client.state(), SessionState::Terminal);
    }
}

#[test]
fn oversized_ciphertext_and_payload_are_rejected_without_unbounded_buffers() {
    let (mut host, mut client, time) = confirmed(Role::Sender);
    assert_eq!(
        host.send_payload(&vec![0; MAX_PAYLOAD + 1], time),
        Err(SessionError::Bounds)
    );
    assert_eq!(
        client.ingest_ciphertext(&vec![0; MAX_CIPHERTEXT + 1], time),
        Err(SessionError::Bounds)
    );
    assert_eq!(client.state(), SessionState::Terminal);
}
