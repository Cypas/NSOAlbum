use super::{SessionError, Transport};
use base64::{engine::general_purpose::STANDARD, Engine};
use rand::RngCore;
use rcgen::{BasicConstraints, CertificateParams, IsCa, KeyPair, KeyUsagePurpose};
use rustls::{pki_types::PrivatePkcs8KeyDer, ServerConfig};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{fmt, sync::Arc, time::Instant};
use zeroize::Zeroize;

pub(super) const SERVER_NAME: &str = "nsoalbum-sync.local";
pub(super) const MIN_TIME: i64 = 946_684_800;
pub(super) const MAX_TIME: i64 = 4_102_444_800;
pub(super) const TTL: i64 = 300;
pub(super) const USB_PROFILE: &str = "usb-mailbox-v4";
pub(super) const FLOW_PROFILE: &str = "binary-media-v2";

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ControlPolicy {
    #[default]
    DualLocal,
    Phone,
}

/// This object contains an authentication secret. Encode only for transient QR display.
pub struct Qr {
    pub(super) wire: QrWire,
    pub(super) scanned_at: Instant,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct QrWire {
    pub version: u8,
    #[serde(default)]
    pub control: ControlPolicy,
    pub session_id: String,
    pub operation_id: String,
    pub issued_at: i64,
    pub expires_at: i64,
    pub transport: Transport,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usb_profile: Option<String>,
    #[serde(default)]
    pub flow_profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wifi_ssid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_build: Option<super::connection::ApplicationBuild>,
    pub root_der: String,
    pub fingerprint: String,
    pub secret: String,
}

impl Drop for QrWire {
    fn drop(&mut self) {
        self.secret.zeroize();
    }
}

impl fmt::Debug for Qr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Qr([REDACTED])")
    }
}

impl Qr {
    pub fn parse(encoded: &str, now: i64) -> Result<Self, SessionError> {
        if encoded.len() > 8_192 {
            return Err(SessionError::Bounds);
        }
        let wire: QrWire = serde_json::from_str(encoded).map_err(|_| SessionError::InvalidQr)?;
        let result = Self {
            wire,
            scanned_at: Instant::now(),
        };
        result.validate(now)?;
        Ok(result)
    }

    pub fn encode(&self) -> Result<String, SessionError> {
        serde_json::to_string(&self.wire).map_err(|_| SessionError::InvalidQr)
    }

    pub fn transport(&self) -> &Transport {
        &self.wire.transport
    }

    pub fn session_id(&self) -> &str {
        &self.wire.session_id
    }

    pub fn operation_id(&self) -> &str {
        &self.wire.operation_id
    }

    pub fn expires_at(&self) -> i64 {
        self.wire.expires_at
    }

    pub(super) fn validate(&self, now: i64) -> Result<(), SessionError> {
        let w = &self.wire;
        if w.flow_profile.as_deref() != Some(FLOW_PROFILE) {
            return Err(SessionError::VersionMismatch);
        }
        if w.version != 1
            || !valid_hex(&w.session_id, 32)
            || !valid_hex(&w.operation_id, 32)
            || !valid_hex(&w.fingerprint, 64)
            || !valid_hex(&w.secret, 64)
            || !(MIN_TIME..MAX_TIME).contains(&w.issued_at)
            || w.expires_at.checked_sub(w.issued_at) != Some(TTL)
            || w.root_der.len() > 2_736
        {
            return Err(SessionError::InvalidQr);
        }
        validate_transport(&w.transport)?;
        match (&w.transport, w.usb_profile.as_deref()) {
            (Transport::Usb, Some(USB_PROFILE)) | (Transport::Tcp(_), None) => {}
            (Transport::Usb, _) => return Err(SessionError::VersionMismatch),
            (Transport::Tcp(_), Some(_)) => return Err(SessionError::InvalidQr),
        }
        validate_wifi_ssid(&w.transport, w.wifi_ssid.as_deref())?;
        if let Some(build) = &w.app_build {
            build.validate()?;
        }
        let root = STANDARD
            .decode(&w.root_der)
            .map_err(|_| SessionError::InvalidQr)?;
        if root.is_empty() || root.len() > 2_048 {
            return Err(SessionError::InvalidQr);
        }
        if !(MIN_TIME..MAX_TIME).contains(&now) {
            return Err(SessionError::Expired);
        }
        Ok(())
    }
}

fn validate_wifi_ssid(transport: &Transport, ssid: Option<&str>) -> Result<(), SessionError> {
    if ssid.is_some_and(|name| {
        matches!(transport, Transport::Usb)
            || name.is_empty()
            || name.len() > 32
            || name.chars().any(char::is_control)
    }) {
        return Err(SessionError::InvalidQr);
    }
    Ok(())
}

pub(super) fn valid_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub(super) fn validate_transport(transport: &Transport) -> Result<(), SessionError> {
    if let Transport::Tcp(address) = transport {
        let local = match address.ip() {
            std::net::IpAddr::V4(ip) => ip.is_private() || ip.is_link_local() || ip.is_loopback(),
            std::net::IpAddr::V6(ip) => {
                ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local()
            }
        };
        if !local || address.port() == 0 {
            return Err(SessionError::InvalidQr);
        }
    }
    Ok(())
}

pub struct Invitation {
    pub(super) qr: Qr,
    pub(super) config: Option<Arc<ServerConfig>>,
}

impl fmt::Debug for Invitation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Invitation([REDACTED])")
    }
}

impl Invitation {
    pub fn delegate_to_phone(&mut self) -> Result<(), SessionError> {
        if self.config.is_none() {
            return Err(SessionError::Consumed);
        }
        self.qr.wire.control = ControlPolicy::Phone;
        Ok(())
    }

    pub fn create(transport: Transport, now: i64) -> Result<Self, SessionError> {
        validate_transport(&transport)?;
        if !(MIN_TIME..MAX_TIME - TTL).contains(&now) {
            return Err(SessionError::InvalidQr);
        }
        let mut root_params =
            CertificateParams::new(Vec::<String>::new()).map_err(|_| SessionError::Tls)?;
        root_params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
        root_params.key_usages = vec![
            KeyUsagePurpose::KeyCertSign,
            KeyUsagePurpose::DigitalSignature,
        ];
        root_params.not_before =
            time::OffsetDateTime::from_unix_timestamp(now - 120).map_err(|_| SessionError::Tls)?;
        root_params.not_after =
            time::OffsetDateTime::from_unix_timestamp(now + TTL).map_err(|_| SessionError::Tls)?;
        let root_key = KeyPair::generate().map_err(|_| SessionError::Tls)?;
        let root = root_params
            .self_signed(&root_key)
            .map_err(|_| SessionError::Tls)?;
        let mut leaf_params =
            CertificateParams::new(vec![SERVER_NAME.to_owned()]).map_err(|_| SessionError::Tls)?;
        leaf_params.not_before =
            time::OffsetDateTime::from_unix_timestamp(now - 120).map_err(|_| SessionError::Tls)?;
        leaf_params.not_after =
            time::OffsetDateTime::from_unix_timestamp(now + TTL).map_err(|_| SessionError::Tls)?;
        leaf_params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ServerAuth];
        let leaf_key = KeyPair::generate().map_err(|_| SessionError::Tls)?;
        let leaf = leaf_params
            .signed_by(&leaf_key, &root, &root_key)
            .map_err(|_| SessionError::Tls)?;
        let mut config =
            ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_protocol_versions(&[&rustls::version::TLS13])
                .map_err(|_| SessionError::Tls)?
                .with_no_client_auth()
                .with_single_cert(
                    vec![leaf.der().clone()],
                    PrivatePkcs8KeyDer::from(leaf_key.serialize_der()).into(),
                )
                .map_err(|_| SessionError::Tls)?;
        config.send_tls13_tickets = 0;
        config.session_storage = Arc::new(rustls::server::NoServerSessionStorage {});
        config.max_early_data_size = 0;
        config.alpn_protocols = vec![b"nsoalbum-sync/1".to_vec()];
        let mut random = [0u8; 64];
        rand::rngs::OsRng
            .try_fill_bytes(&mut random)
            .map_err(|_| SessionError::Tls)?;
        let usb_profile = matches!(&transport, Transport::Usb).then(|| USB_PROFILE.to_owned());
        let wire = QrWire {
            version: 1,
            control: ControlPolicy::DualLocal,
            session_id: hex::encode(&random[..16]),
            operation_id: hex::encode(&random[16..32]),
            secret: hex::encode(&random[32..]),
            issued_at: now,
            expires_at: now + TTL,
            transport,
            usb_profile,
            flow_profile: Some(FLOW_PROFILE.into()),
            wifi_ssid: None,
            app_build: None,
            root_der: STANDARD.encode(root.der()),
            fingerprint: hex::encode(Sha256::digest(leaf.der())),
        };
        random.zeroize();
        Ok(Self {
            qr: Qr {
                wire,
                scanned_at: Instant::now(),
            },
            config: Some(Arc::new(config)),
        })
    }

    pub fn qr(&self) -> Result<&Qr, SessionError> {
        self.config.as_ref().ok_or(SessionError::Consumed)?;
        Ok(&self.qr)
    }

    pub fn set_wifi_ssid(&mut self, ssid: Option<String>) -> Result<(), SessionError> {
        self.config.as_ref().ok_or(SessionError::Consumed)?;
        validate_wifi_ssid(&self.qr.wire.transport, ssid.as_deref())?;
        self.qr.wire.wifi_ssid = ssid;
        Ok(())
    }

    pub fn set_app_build(
        &mut self,
        build: Option<super::connection::ApplicationBuild>,
    ) -> Result<(), SessionError> {
        self.config.as_ref().ok_or(SessionError::Consumed)?;
        if let Some(build) = &build {
            build.validate()?;
        }
        self.qr.wire.app_build = build;
        Ok(())
    }

    pub fn cancel(&mut self) {
        self.config = None;
        self.qr.wire.secret.zeroize();
    }
}
