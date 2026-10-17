use super::qr::{MAX_TIME, MIN_TIME, SERVER_NAME, TTL};
use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use rustls::{ClientConfig, ClientConnection, Connection, RootCertStore, ServerConnection};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::VecDeque,
    fmt,
    io::{Cursor, ErrorKind, Read, Write},
    sync::Arc,
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum SessionState {
    Handshaking,
    Authenticating,
    AwaitingConfirmation,
    Confirmed,
    Terminal,
}

#[derive(Debug, PartialEq, Eq)]
pub struct PeerInfo {
    pub name: String,
    pub clock_skew_seconds: i64,
    pub role: Role,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Authentication {
    version: u8,
    #[serde(default)]
    control: super::qr::ControlPolicy,
    session_id: String,
    operation_id: String,
    transport: Transport,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    app_build: Option<super::connection::ApplicationBuild>,
    secret: String,
}

impl Drop for Authentication {
    fn drop(&mut self) {
        self.secret.zeroize();
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Hello {
    name: String,
    time: i64,
    role: Role,
}

/// Owns exactly one TLS connection. Received-byte failures are terminal.
/// `now` is trusted local Unix time, never a value supplied by the peer.
pub struct Session {
    connection: Option<Connection>,
    qr: Qr,
    host: bool,
    role: Role,
    name: String,
    deadline: Instant,
    state: SessionState,
    auth_sent: bool,
    authenticated: bool,
    hello_sent: bool,
    local_confirmed: bool,
    remote_confirmed: bool,
    binding: Option<Zeroizing<[u8; 32]>>,
    peer: Option<PeerInfo>,
    pending_ciphertext: Zeroizing<Vec<u8>>,
    plaintext: Zeroizing<Vec<u8>>,
    payloads: VecDeque<Zeroizing<Vec<u8>>>,
}

impl fmt::Debug for Session {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Session")
            .field("state", &self.state)
            .finish_non_exhaustive()
    }
}

fn validate_name(name: &str) -> Result<(), SessionError> {
    if name.len() > 128 || name.trim().is_empty() || name.chars().any(char::is_control) {
        return Err(SessionError::Protocol);
    }
    Ok(())
}

impl Invitation {
    /// A connection attempt consumes the invitation, including failed attempts.
    pub fn accept(&mut self, role: Role, name: &str, now: i64) -> Result<Session, SessionError> {
        let config = self.config.take().ok_or(SessionError::Consumed)?;
        let result = (|| {
            self.qr.validate(now)?;
            if now >= self.qr.wire.expires_at
                || now < self.qr.wire.issued_at - 120
                || self.qr.scanned_at.elapsed() >= Duration::from_secs(TTL as u64)
            {
                return Err(SessionError::Expired);
            }
            validate_name(name)?;
            let mut qr = Qr::parse(&self.qr.encode()?, now)?;
            qr.scanned_at = self.qr.scanned_at;
            let connection =
                Connection::Server(ServerConnection::new(config).map_err(|_| SessionError::Tls)?);
            Ok(Session::new(connection, qr, true, role, name, now))
        })();
        self.qr.wire.secret.zeroize();
        result
    }
}

impl Session {
    pub fn client(qr: Qr, role: Role, name: &str, now: i64) -> Result<Self, SessionError> {
        qr.validate(now)?;
        validate_name(name)?;
        if qr.wire.app_build.is_some() && qr.wire.control != super::qr::ControlPolicy::Phone {
            return Err(SessionError::Protocol);
        }
        let root = STANDARD
            .decode(&qr.wire.root_der)
            .map_err(|_| SessionError::InvalidQr)?;
        let mut roots = RootCertStore::empty();
        roots
            .add(root.into())
            .map_err(|_| SessionError::InvalidQr)?;
        let clock = Arc::new(QrTime {
            issued_at: qr.wire.issued_at as u64,
            scanned_at: qr.scanned_at,
        });
        let mut config = ClientConfig::builder_with_details(
            Arc::new(rustls::crypto::ring::default_provider()),
            clock,
        )
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|_| SessionError::Tls)?
        .with_root_certificates(roots)
        .with_no_client_auth();
        config.resumption = rustls::client::Resumption::disabled();
        config.enable_early_data = false;
        config.alpn_protocols = vec![b"nsoalbum-sync/1".to_vec()];
        let connection = Connection::Client(
            ClientConnection::new(
                Arc::new(config),
                SERVER_NAME.try_into().map_err(|_| SessionError::Tls)?,
            )
            .map_err(|_| SessionError::Tls)?,
        );
        Ok(Self::new(connection, qr, false, role, name, now))
    }

    fn new(
        mut connection: Connection,
        qr: Qr,
        host: bool,
        role: Role,
        name: &str,
        now: i64,
    ) -> Self {
        connection.set_buffer_limit(Some(MAX_BUFFER));
        let scan_deadline = qr.scanned_at + Duration::from_secs(TTL as u64);
        let deadline = if host {
            scan_deadline
                .min(Instant::now() + Duration::from_secs((qr.wire.expires_at - now).max(0) as u64))
        } else {
            scan_deadline
        };
        Self {
            connection: Some(connection),
            qr,
            host,
            role,
            name: name.to_owned(),
            deadline,
            state: SessionState::Handshaking,
            auth_sent: false,
            authenticated: false,
            hello_sent: false,
            local_confirmed: false,
            remote_confirmed: false,
            binding: None,
            peer: None,
            pending_ciphertext: Zeroizing::new(Vec::new()),
            plaintext: Zeroizing::new(Vec::new()),
            payloads: VecDeque::new(),
        }
    }

    pub fn state(&self) -> SessionState {
        self.state
    }
    pub(super) fn is_host(&self) -> bool {
        self.host
    }
    pub(crate) fn phone_controlled(&self) -> bool {
        self.qr.wire.control == super::qr::ControlPolicy::Phone
    }
    pub(crate) fn controller(&self) -> bool {
        if self.phone_controlled() {
            !self.host
        } else {
            self.host
        }
    }
    pub fn transport(&self) -> &Transport {
        &self.qr.wire.transport
    }
    pub fn operation_id(&self) -> &str {
        &self.qr.wire.operation_id
    }
    pub fn session_id(&self) -> &str {
        &self.qr.wire.session_id
    }
    pub fn peer_info(&self) -> Option<&PeerInfo> {
        self.peer.as_ref()
    }
    pub(crate) fn invitation_remaining_ms(&self) -> Option<u64> {
        (!matches!(self.state, SessionState::Confirmed | SessionState::Terminal)).then(|| {
            self.deadline
                .saturating_duration_since(Instant::now())
                .as_millis() as u64
        })
    }
    pub(crate) fn confirmation_available(&self, now: i64) -> bool {
        (!self.phone_controlled() || self.controller())
            && self.peer.is_some()
            && self.binding.is_some()
            && matches!(
                self.state,
                SessionState::AwaitingConfirmation | SessionState::Confirmed
            )
            && (self.state == SessionState::Confirmed
                || (Instant::now() < self.deadline
                    && (!self.host
                        || (now < self.qr.wire.expires_at && now >= self.qr.wire.issued_at - 120))))
    }

    pub fn tick(&mut self, now: i64) -> Result<(), SessionError> {
        if self.state == SessionState::Terminal {
            return Err(SessionError::Terminal);
        }
        if !(MIN_TIME..MAX_TIME).contains(&now) {
            return self.fail(SessionError::Expired);
        }
        if self.state != SessionState::Confirmed
            && ((self.host
                && (now >= self.qr.wire.expires_at || now < self.qr.wire.issued_at - 120))
                || Instant::now() >= self.deadline)
        {
            return self.fail(SessionError::Expired);
        }
        Ok(())
    }

    fn fail<T>(&mut self, error: SessionError) -> Result<T, SessionError> {
        self.cancel();
        Err(error)
    }

    pub fn cancel(&mut self) {
        self.connection = None;
        self.qr.wire.secret.zeroize();
        self.binding = None;
        self.pending_ciphertext.zeroize();
        self.plaintext.zeroize();
        self.payloads.clear();
        self.peer = None;
        self.local_confirmed = false;
        self.remote_confirmed = false;
        self.state = SessionState::Terminal;
    }

    /// EOF, adapter failure and transport removal all invalidate authorization.
    pub fn disconnect(&mut self) {
        self.cancel();
    }

    pub fn ingest_ciphertext(&mut self, bytes: &[u8], now: i64) -> Result<(), SessionError> {
        self.tick(now)?;
        if bytes.is_empty() || bytes.len() > MAX_CIPHERTEXT || !self.ready_for_input() {
            return self.fail(SessionError::Bounds);
        }
        self.pending_ciphertext.extend_from_slice(bytes);
        match self.ingest_inner(now) {
            Ok(()) => Ok(()),
            Err(error) => self.fail(error),
        }
    }

    fn ingest_inner(&mut self, now: i64) -> Result<(), SessionError> {
        self.read_plaintext(now)?;
        let bytes = std::mem::take(&mut self.pending_ciphertext);
        let mut input = Cursor::new(bytes.as_slice());
        while input.position() < bytes.len() as u64 && self.payloads.len() < 4 {
            let connection = self.connection.as_mut().ok_or(SessionError::Terminal)?;
            if connection
                .read_tls(&mut input)
                .map_err(|_| SessionError::Tls)?
                == 0
            {
                return Err(SessionError::Tls);
            }
            let io = connection
                .process_new_packets()
                .map_err(|_| SessionError::Tls)?;
            if io.peer_has_closed() {
                return Err(SessionError::Io);
            }
            self.handshake_complete()?;
            self.read_plaintext(now)?;
        }
        // A transport block may exceed rustls' incoming plaintext window.
        // Keep only its unconsumed suffix; do not read another block until it
        // is drained by the consumer. The accepted block is capped at 64 KiB.
        self.pending_ciphertext
            .extend_from_slice(&bytes[input.position() as usize..]);
        Ok(())
    }

    fn handshake_complete(&mut self) -> Result<(), SessionError> {
        let connection = self.connection.as_ref().ok_or(SessionError::Terminal)?;
        if connection.is_handshaking() || self.state != SessionState::Handshaking {
            return Ok(());
        }
        if connection.alpn_protocol() != Some(b"nsoalbum-sync/1") {
            return Err(SessionError::Protocol);
        }
        // WebPKI checked chain, name, validity and handshake signatures first.
        // The QR additionally pins the leaf before releasing the bearer secret.
        if !self.host {
            let leaf = connection
                .peer_certificates()
                .and_then(|chain| chain.first())
                .ok_or(SessionError::Tls)?;
            let fingerprint = hex::encode(Sha256::digest(leaf));
            if fingerprint
                .as_bytes()
                .ct_eq(self.qr.wire.fingerprint.as_bytes())
                .unwrap_u8()
                != 1
            {
                return Err(SessionError::Authentication);
            }
        }
        let context = serde_json::to_vec(&(
            1u8,
            &self.qr.wire.session_id,
            &self.qr.wire.operation_id,
            &self.qr.wire.transport,
            &self.qr.wire.app_build,
            self.qr.wire.control,
        ))
        .map_err(|_| SessionError::Protocol)?;
        let exporter = connection
            .export_keying_material([0u8; 32], b"EXPORTER-NSOAlbum-Sync-v1", Some(&context))
            .map_err(|_| SessionError::Tls)?;
        self.binding = Some(Zeroizing::new(exporter));
        self.state = SessionState::Authenticating;
        if !self.host {
            let authentication = Authentication {
                version: 1,
                control: self.qr.wire.control,
                session_id: self.qr.wire.session_id.clone(),
                operation_id: self.qr.wire.operation_id.clone(),
                transport: self.qr.wire.transport.clone(),
                app_build: self.qr.wire.app_build.clone(),
                secret: self.qr.wire.secret.clone(),
            };
            let encoded = Zeroizing::new(
                serde_json::to_vec(&authentication).map_err(|_| SessionError::Protocol)?,
            );
            self.send_frame(1, &encoded)?;
            self.qr.wire.secret.zeroize();
            self.auth_sent = true;
        }
        Ok(())
    }

    fn send_frame(&mut self, kind: u8, payload: &[u8]) -> Result<(), SessionError> {
        let mut frame = Zeroizing::new(Vec::with_capacity(payload.len() + 5));
        frame.extend_from_slice(&((payload.len() + 1) as u32).to_be_bytes());
        frame.push(kind);
        frame.extend_from_slice(payload);
        self.connection
            .as_mut()
            .ok_or(SessionError::Terminal)?
            .writer()
            .write_all(&frame)
            .map_err(|_| SessionError::Bounds)
    }

    fn send_hello(&mut self, now: i64) -> Result<(), SessionError> {
        let hello = Hello {
            name: self.name.clone(),
            time: now,
            role: self.role,
        };
        let bytes = serde_json::to_vec(&hello).map_err(|_| SessionError::Protocol)?;
        self.send_frame(2, &bytes)?;
        self.hello_sent = true;
        Ok(())
    }

    fn read_plaintext(&mut self, now: i64) -> Result<(), SessionError> {
        let mut chunk = Zeroizing::new([0u8; 4096]);
        loop {
            // Parse retained bytes first. A socket read / TLS record is not an
            // application frame boundary: one legal block may contain >4 frames.
            while self.plaintext.len() >= 4 {
                let length = u32::from_be_bytes(
                    self.plaintext[..4]
                        .try_into()
                        .map_err(|_| SessionError::Protocol)?,
                ) as usize;
                if length == 0 || length > MAX_PAYLOAD + 1 {
                    return Err(SessionError::Bounds);
                }
                if self.plaintext.len() >= 5 && self.plaintext[4] != 4 && length > MAX_CONTROL {
                    return Err(SessionError::Bounds);
                }
                if self.plaintext.len() < length + 4 {
                    break;
                }
                if self.plaintext[4] == 4 && self.payloads.len() >= 4 {
                    return Ok(());
                }
                let frame = Zeroizing::new(self.plaintext.drain(..length + 4).collect::<Vec<_>>());
                self.handle_frame(frame[4], &frame[5..], now)?;
            }
            if self.payloads.len() >= 4 {
                return Ok(());
            }
            let count = match self
                .connection
                .as_mut()
                .ok_or(SessionError::Terminal)?
                .reader()
                .read(chunk.as_mut())
            {
                Ok(0) => return Ok(()),
                Ok(count) => count,
                Err(error) if error.kind() == ErrorKind::WouldBlock => return Ok(()),
                Err(_) => return Err(SessionError::Tls),
            };
            self.plaintext.extend_from_slice(&chunk[..count]);
            if self.plaintext.len() > MAX_PAYLOAD + 5 + 4096 {
                return Err(SessionError::Bounds);
            }
        }
    }

    fn handle_frame(&mut self, kind: u8, bytes: &[u8], now: i64) -> Result<(), SessionError> {
        match kind {
            1 if self.host && !self.authenticated && self.state == SessionState::Authenticating => {
                let auth: Authentication =
                    serde_json::from_slice(bytes).map_err(|_| SessionError::Protocol)?;
                if auth.version != 1
                    || auth.session_id != self.qr.wire.session_id
                    || auth.operation_id != self.qr.wire.operation_id
                    || auth.transport != self.qr.wire.transport
                    || auth.app_build != self.qr.wire.app_build
                    || auth.control != self.qr.wire.control
                    || auth
                        .secret
                        .as_bytes()
                        .ct_eq(self.qr.wire.secret.as_bytes())
                        .unwrap_u8()
                        != 1
                {
                    return Err(SessionError::Authentication);
                }
                self.authenticated = true;
                self.qr.wire.secret.zeroize();
                self.send_hello(now)?;
            }
            2 if self.peer.is_none() && (self.authenticated || (!self.host && self.auth_sent)) => {
                let hello: Hello =
                    serde_json::from_slice(bytes).map_err(|_| SessionError::Protocol)?;
                validate_name(&hello.name)?;
                if !(MIN_TIME..MAX_TIME).contains(&hello.time) || hello.role == self.role {
                    return Err(SessionError::Protocol);
                }
                self.peer = Some(PeerInfo {
                    name: hello.name,
                    clock_skew_seconds: now - hello.time,
                    role: hello.role,
                });
                if !self.hello_sent {
                    self.send_hello(now)?;
                }
                self.state = SessionState::AwaitingConfirmation;
                // The invitation delegates this one connection only. The host
                // sends its binding after authenticating the invitation holder.
                if self.phone_controlled() && self.host {
                    let binding = self
                        .binding
                        .as_ref()
                        .ok_or(SessionError::Protocol)?
                        .to_vec();
                    self.send_frame(3, &binding)?;
                    self.local_confirmed = true;
                }
            }
            3 if self.peer.is_some() && !self.remote_confirmed => {
                let binding = self.binding.as_ref().ok_or(SessionError::Protocol)?;
                if bytes.ct_eq(binding.as_ref()).unwrap_u8() != 1 {
                    return Err(SessionError::Authentication);
                }
                self.remote_confirmed = true;
                self.update_confirmed();
            }
            4 if self.state == SessionState::Confirmed => {
                if self.payloads.len() >= 4 {
                    return Err(SessionError::Bounds);
                }
                self.payloads.push_back(Zeroizing::new(bytes.to_vec()));
            }
            _ => return Err(SessionError::Protocol),
        }
        Ok(())
    }

    fn update_confirmed(&mut self) {
        if self.local_confirmed && self.remote_confirmed {
            self.state = SessionState::Confirmed;
        }
    }

    pub fn confirm(&mut self, now: i64) -> Result<(), SessionError> {
        self.tick(now)?;
        if (self.phone_controlled() && !self.controller())
            || self.state != SessionState::AwaitingConfirmation
            || self.local_confirmed
        {
            return Err(SessionError::NotConfirmed);
        }
        let binding = self
            .binding
            .as_ref()
            .ok_or(SessionError::Protocol)?
            .to_vec();
        if let Err(error) = self.send_frame(3, &binding) {
            return self.fail(error);
        }
        self.local_confirmed = true;
        self.update_confirmed();
        Ok(())
    }

    /// Display all six digits at both endpoints before each local confirmation.
    pub fn confirmation_code(&mut self, now: i64) -> Result<String, SessionError> {
        self.tick(now)?;
        if self.peer.is_none() {
            return Err(SessionError::NotConfirmed);
        }
        let binding = self.binding.as_ref().ok_or(SessionError::NotConfirmed)?;
        let code = u32::from_be_bytes(
            binding[..4]
                .try_into()
                .map_err(|_| SessionError::Protocol)?,
        ) % 1_000_000;
        Ok(format!("{code:06}"))
    }

    /// Caller must bind application manifests and previews to operation_id.
    pub fn send_payload(&mut self, bytes: &[u8], now: i64) -> Result<(), SessionError> {
        self.tick(now)?;
        if self.state != SessionState::Confirmed {
            return Err(SessionError::NotConfirmed);
        }
        if bytes.len() > MAX_PAYLOAD {
            return Err(SessionError::Bounds);
        }
        if let Err(error) = self.send_frame(4, bytes) {
            return self.fail(error);
        }
        Ok(())
    }

    /// Returned plaintext and its zeroization become the caller's responsibility.
    pub fn receive_payload(&mut self, now: i64) -> Result<Option<Vec<u8>>, SessionError> {
        self.tick(now)?;
        if self.state != SessionState::Confirmed {
            return Err(SessionError::NotConfirmed);
        }
        let payload = self
            .payloads
            .pop_front()
            .map(|mut data| std::mem::take(&mut *data));
        // Refill only the released slots, without consuming another network
        // block or increasing the four-item queue.
        if let Err(error) = self.ingest_inner(now) {
            return self.fail(error);
        }
        Ok(payload)
    }

    pub(crate) fn ready_for_input(&self) -> bool {
        self.payloads.len() < 4 && self.pending_ciphertext.is_empty()
    }

    pub fn drain_ciphertext(&mut self, now: i64) -> Result<Vec<u8>, SessionError> {
        self.tick(now)?;
        let mut output = BoundedOutput(Vec::new());
        let connection = self.connection.as_mut().ok_or(SessionError::Terminal)?;
        while connection.wants_write() && output.0.len() < MAX_CIPHERTEXT {
            if connection.write_tls(&mut output).is_err() {
                return self.fail(SessionError::Tls);
            }
        }
        Ok(output.0)
    }
}

struct BoundedOutput(Vec<u8>);
/// The scanned QR is the client's ephemeral trust/time anchor. Server-side
/// expiry and single-use consumption still use the server's real clock.
#[derive(Debug)]
struct QrTime {
    issued_at: u64,
    scanned_at: Instant,
}
impl rustls::time_provider::TimeProvider for QrTime {
    fn current_time(&self) -> Option<rustls::pki_types::UnixTime> {
        let seconds = self
            .issued_at
            .checked_add(self.scanned_at.elapsed().as_secs())?;
        Some(rustls::pki_types::UnixTime::since_unix_epoch(
            Duration::from_secs(seconds),
        ))
    }
}
impl Write for BoundedOutput {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let size = bytes.len().min(MAX_CIPHERTEXT - self.0.len());
        self.0.extend_from_slice(&bytes[..size]);
        Ok(size)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod security_tests {
    use super::super::tests::{confirmed, now, pair, pump};
    use super::*;
    use rcgen::{BasicConstraints, CertificateParams, IsCa, KeyPair, KeyUsagePurpose};
    use rustls::{pki_types::PrivatePkcs8KeyDer, ServerConfig};

    #[test]
    fn phone_controller_delegation_tampering_fails_authentication_and_consumes_invitation() {
        for phone_policy in [false, true] {
            let time = now();
            let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
            if phone_policy {
                invitation.delegate_to_phone().unwrap();
            }
            let mut qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time).unwrap();
            qr.wire.control = if phone_policy {
                super::super::qr::ControlPolicy::DualLocal
            } else {
                super::super::qr::ControlPolicy::Phone
            };
            let mut host = invitation.accept(Role::Receiver, "Desktop", time).unwrap();
            let mut client = Session::client(qr, Role::Sender, "Phone", time).unwrap();
            assert_eq!(
                pump(&mut host, &mut client, time),
                Err(SessionError::Authentication)
            );
            assert_eq!(host.state(), SessionState::Terminal);
            assert!(matches!(
                invitation.accept(Role::Receiver, "Desktop", time),
                Err(SessionError::Consumed)
            ));
            assert_eq!(invitation.delegate_to_phone(), Err(SessionError::Consumed));
        }
    }

    #[derive(Debug)]
    struct TestResolver(Arc<rustls::sign::CertifiedKey>);
    impl rustls::server::ResolvesServerCert for TestResolver {
        fn resolve(
            &self,
            _: rustls::server::ClientHello<'_>,
        ) -> Option<Arc<rustls::sign::CertifiedKey>> {
            Some(self.0.clone())
        }
    }

    fn bad_certificate_invitation(kind: &str, time: i64) -> Invitation {
        let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
        let mut ca = CertificateParams::new(Vec::<String>::new()).unwrap();
        ca.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        ca.key_usages = vec![KeyUsagePurpose::KeyCertSign];
        let ca_key = KeyPair::generate().unwrap();
        let root = ca.self_signed(&ca_key).unwrap();
        let name = if kind == "name" {
            "wrong.local"
        } else {
            SERVER_NAME
        };
        let mut params = CertificateParams::new(vec![name.to_string()]).unwrap();
        params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ServerAuth];
        if kind == "expired" {
            params.not_before = time::OffsetDateTime::from_unix_timestamp(time - 600).unwrap();
            params.not_after = time::OffsetDateTime::from_unix_timestamp(time - 1).unwrap();
        }
        if kind == "not_yet_valid" {
            params.not_before = time::OffsetDateTime::from_unix_timestamp(time + 600).unwrap();
            params.not_after = time::OffsetDateTime::from_unix_timestamp(time + 900).unwrap();
        }
        let key = KeyPair::generate().unwrap();
        let leaf = params.signed_by(&key, &root, &ca_key).unwrap();
        invitation.qr.wire.root_der = STANDARD.encode(root.der());
        invitation.qr.wire.fingerprint = hex::encode(Sha256::digest(leaf.der()));
        let signing_key = if kind == "signature" {
            KeyPair::generate().unwrap()
        } else {
            key
        };
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let loaded = provider
            .key_provider
            .load_private_key(PrivatePkcs8KeyDer::from(signing_key.serialize_der()).into())
            .unwrap();
        let certified = rustls::sign::CertifiedKey::new(vec![leaf.der().clone()], loaded);
        let mut config = ServerConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_no_client_auth()
            .with_cert_resolver(Arc::new(TestResolver(Arc::new(certified))));
        config.send_tls13_tickets = 0;
        config.alpn_protocols = vec![b"nsoalbum-sync/1".to_vec()];
        invitation.config = Some(Arc::new(config));
        invitation
    }

    #[test]
    fn standard_verifier_rejects_wrong_name_expired_leaf_and_invalid_handshake_signature() {
        for kind in ["name", "expired", "not_yet_valid", "signature"] {
            let time = now();
            let mut invitation = bad_certificate_invitation(kind, time);
            let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time).unwrap();
            let mut host = invitation.accept(Role::Sender, "Desktop", time).unwrap();
            let mut client = Session::client(qr, Role::Receiver, "Phone", time).unwrap();
            assert_eq!(
                pump(&mut host, &mut client, time),
                Err(SessionError::Tls),
                "{kind}"
            );
            assert_eq!(client.state(), SessionState::Terminal);
        }
    }

    #[test]
    fn forged_control_frames_and_unconfirmed_application_data_fail_closed() {
        for kind in [0, 4, 255] {
            let (_, mut host, mut client, time) = pair(Transport::Usb, Role::Sender);
            pump(&mut host, &mut client, time).unwrap();
            host.send_frame(kind, b"not authorized").unwrap();
            assert_eq!(
                pump(&mut host, &mut client, time),
                Err(SessionError::Protocol)
            );
            assert_eq!(client.state(), SessionState::Terminal);
        }
    }

    #[test]
    fn malformed_frame_lengths_are_rejected_before_declared_allocation() {
        for header in [
            vec![255, 255, 255, 255],
            vec![0, 0, 0, 0],
            vec![0, 0, 32, 0, 1],
        ] {
            let (mut host, mut client, time) = confirmed(Role::Sender);
            host.connection
                .as_mut()
                .unwrap()
                .writer()
                .write_all(&header)
                .unwrap();
            assert_eq!(
                pump(&mut host, &mut client, time),
                Err(SessionError::Bounds)
            );
            assert_eq!(client.state(), SessionState::Terminal);
        }
    }

    #[test]
    fn coalesced_tls_payloads_wait_for_the_four_item_consumer_window() {
        for fragment in [usize::MAX, 7] {
            let (mut host, mut client, time) = confirmed(Role::Sender);
            for value in 0_u8..13 {
                host.send_payload(&[value; 23], time).unwrap();
            }
            let ciphertext = host.drain_ciphertext(time).unwrap();
            if fragment == usize::MAX {
                client.ingest_ciphertext(&ciphertext, time).unwrap();
            } else {
                // Stop network reads at the consumer window; retain the
                // remaining transport bytes rather than inventing a frame ACK.
                let mut received = Vec::new();
                for bytes in ciphertext.chunks(fragment) {
                    while client.payloads.len() == 4 {
                        received.push(client.receive_payload(time).unwrap().unwrap()[0]);
                    }
                    client.ingest_ciphertext(bytes, time).unwrap();
                    assert!(client.payloads.len() <= 4);
                }
                while let Some(payload) = client.receive_payload(time).unwrap() {
                    received.push(payload[0]);
                }
                assert_eq!(received, (0_u8..13).collect::<Vec<_>>());
                continue;
            }
            assert_eq!(client.payloads.len(), 4);
            for value in 0_u8..13 {
                assert_eq!(client.receive_payload(time).unwrap(), Some(vec![value; 23]));
                assert!(client.payloads.len() <= 4);
            }
            assert_eq!(client.receive_payload(time).unwrap(), None);
            assert_eq!(client.state(), SessionState::Confirmed);
        }
    }

    #[test]
    fn coalesced_block_above_tls_plaintext_limit_is_retained_with_backpressure() {
        let (mut host, mut client, time) = confirmed(Role::Sender);
        for value in 0_u8..13 {
            host.send_payload(&[value; 3000], time).unwrap();
        }
        let ciphertext = host.drain_ciphertext(time).unwrap();
        assert!(ciphertext.len() > 16_384 && ciphertext.len() <= MAX_CIPHERTEXT);
        client.ingest_ciphertext(&ciphertext, time).unwrap();
        assert!(!client.ready_for_input());
        assert!(!client.pending_ciphertext.is_empty());
        for value in 0_u8..13 {
            assert_eq!(
                client.receive_payload(time).unwrap(),
                Some(vec![value; 3000])
            );
            assert!(client.payloads.len() <= 4);
            assert!(client.plaintext.len() <= MAX_PAYLOAD + 5 + 4096);
            assert!(client.pending_ciphertext.len() <= MAX_CIPHERTEXT);
        }
        assert_eq!(client.receive_payload(time).unwrap(), None);
        assert!(client.ready_for_input());
    }

    #[test]
    fn coalesced_pending_frames_are_discarded_on_cancel() {
        let (mut host, mut client, time) = confirmed(Role::Sender);
        for _ in 0..12 {
            host.send_payload(&[7; 3000], time).unwrap();
        }
        client
            .ingest_ciphertext(&host.drain_ciphertext(time).unwrap(), time)
            .unwrap();
        assert!(!client.pending_ciphertext.is_empty());
        client.cancel();
        assert!(client.pending_ciphertext.is_empty());
        assert!(client.payloads.is_empty());
        assert!(client.plaintext.is_empty());
        assert!(client.connection.is_none());
        assert_eq!(client.receive_payload(time), Err(SessionError::Terminal));
    }

    #[test]
    fn bounded_queue_preserves_payload_order_and_rejects_fifth_unconsumed_frame() {
        let (mut host, mut client, time) = confirmed(Role::Sender);
        for value in 0u8..4 {
            host.send_payload(&[value], time).unwrap();
            pump(&mut host, &mut client, time).unwrap();
        }
        for value in 0u8..4 {
            assert_eq!(client.receive_payload(time).unwrap(), Some(vec![value]));
        }
        for _ in 0..4 {
            host.send_payload(b"queued", time).unwrap();
            pump(&mut host, &mut client, time).unwrap();
        }
        host.send_payload(b"overflow", time).unwrap();
        assert_eq!(
            pump(&mut host, &mut client, time),
            Err(SessionError::Bounds)
        );
        assert_eq!(client.receive_payload(time), Err(SessionError::Terminal));
    }

    #[test]
    fn maximum_payload_streams_across_bounded_ciphertext_blocks() {
        let (mut host, mut client, time) = confirmed(Role::Sender);
        let payload = vec![123; MAX_PAYLOAD];
        host.send_payload(&payload, time).unwrap();
        pump(&mut host, &mut client, time).unwrap();
        assert_eq!(client.receive_payload(time).unwrap(), Some(payload));
    }

    #[test]
    fn authenticated_peer_metadata_rejects_controls_bad_times_and_equal_roles() {
        for hello in [
            serde_json::json!({"name":"bad\nname","time":now(),"role":"sender"}),
            serde_json::json!({"name":"Desktop","time":0,"role":"sender"}),
            serde_json::json!({"name":"Desktop","time":now(),"role":"receiver"}),
            serde_json::json!({"name":"Desktop","time":now(),"role":"sender","extra":"forbidden"}),
        ] {
            let (_, mut host, mut client, time) = pair(Transport::Usb, Role::Sender);
            pump(&mut host, &mut client, time).unwrap();
            client.peer = None;
            host.send_frame(2, &serde_json::to_vec(&hello).unwrap())
                .unwrap();
            assert_eq!(
                pump(&mut host, &mut client, time),
                Err(SessionError::Protocol)
            );
        }
    }

    #[test]
    fn same_role_peer_is_rejected_and_sas_is_unique_to_each_tls_connection() {
        let (_, mut host, mut client, time) = pair(Transport::Usb, Role::Sender);
        client.role = Role::Sender;
        assert_eq!(
            pump(&mut host, &mut client, time),
            Err(SessionError::Protocol)
        );
        let (first, _, _) = confirmed(Role::Sender);
        let (second, _, _) = confirmed(Role::Sender);
        assert_ne!(
            first.binding.as_ref().unwrap().as_ref(),
            second.binding.as_ref().unwrap().as_ref()
        );
    }

    #[test]
    fn invalid_confirmation_binding_and_protocol_version_cannot_authorize() {
        let (_, mut host, mut client, time) = pair(Transport::Usb, Role::Sender);
        pump(&mut host, &mut client, time).unwrap();
        host.send_frame(3, &[0; 32]).unwrap();
        assert_eq!(
            pump(&mut host, &mut client, time),
            Err(SessionError::Authentication)
        );
        let (_, mut host, mut client, time) = pair(Transport::Usb, Role::Sender);
        pump(&mut host, &mut client, time).unwrap();
        host.authenticated = false;
        host.state = SessionState::Authenticating;
        let invalid = serde_json::json!({"version":2,"session_id":host.session_id(),"operation_id":host.operation_id(),"transport":{"kind":"usb"},"secret":"00".repeat(32)});
        client
            .send_frame(1, &serde_json::to_vec(&invalid).unwrap())
            .unwrap();
        assert_eq!(
            pump(&mut host, &mut client, time),
            Err(SessionError::Authentication)
        );
    }

    #[test]
    fn pending_monotonic_deadline_cannot_be_extended_by_wall_clock_rollback() {
        let (_, mut host, _, time) = pair(Transport::Usb, Role::Sender);
        host.deadline = Instant::now() - Duration::from_secs(1);
        assert_eq!(host.tick(time - 1), Err(SessionError::Expired));
    }

    #[test]
    fn anchored_certificate_time_allows_both_signs_of_wall_clock_skew_and_reports_skew() {
        for skew in [-3_600, 3_600] {
            let time = now();
            let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
            let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time + skew).unwrap();
            let mut host = invitation.accept(Role::Sender, "Desktop", time).unwrap();
            let mut client = Session::client(qr, Role::Receiver, "Phone", time + skew).unwrap();
            for _ in 0..12 {
                let bytes = client.drain_ciphertext(time + skew).unwrap();
                if !bytes.is_empty() {
                    host.ingest_ciphertext(&bytes, time).unwrap();
                }
                let bytes = host.drain_ciphertext(time).unwrap();
                if !bytes.is_empty() {
                    client.ingest_ciphertext(&bytes, time + skew).unwrap();
                }
            }
            assert_eq!(host.peer_info().unwrap().clock_skew_seconds, -skew);
            assert_eq!(client.peer_info().unwrap().clock_skew_seconds, skew);
            host.confirm(time).unwrap();
            client.confirm(time + skew).unwrap();
        }
    }

    #[test]
    fn forged_qr_clock_cannot_bypass_certificate_validity_or_expired_host_invitation() {
        for shift in [-3_600, 3_600] {
            let time = now();
            let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
            let mut qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time).unwrap();
            qr.wire.issued_at += shift;
            qr.wire.expires_at += shift;
            let mut host = invitation.accept(Role::Sender, "Desktop", time).unwrap();
            let mut client = Session::client(qr, Role::Receiver, "Phone", time).unwrap();
            assert_eq!(pump(&mut host, &mut client, time), Err(SessionError::Tls));
        }
        let time = now();
        let mut invitation = Invitation::create(Transport::Usb, time).unwrap();
        assert!(matches!(
            invitation.accept(Role::Sender, "Desktop", time + 300),
            Err(SessionError::Expired)
        ));
        assert!(matches!(
            invitation.accept(Role::Sender, "Desktop", time),
            Err(SessionError::Consumed)
        ));
        let (_, _, mut client, time) = pair(Transport::Usb, Role::Sender);
        client.deadline = Instant::now() - Duration::from_secs(1);
        assert_eq!(client.tick(time - 3_600), Err(SessionError::Expired));
    }
}
