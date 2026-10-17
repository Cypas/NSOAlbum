//! Bounded TCP adapter for the same in-memory TLS engine.
use super::*;
use std::{
    io::{ErrorKind, Read, Write},
    net::{Shutdown, TcpStream},
    time::Duration,
};

pub struct TcpAdapter {
    stream: TcpStream,
    pub session: Session,
}
impl TcpAdapter {
    pub fn connect(mut session: Session) -> Result<Self, SessionError> {
        let address = match session.transport() {
            Transport::Tcp(address) => *address,
            _ => {
                session.disconnect();
                return Err(SessionError::Protocol);
            }
        };
        match TcpStream::connect_timeout(&address, Duration::from_secs(5)) {
            Ok(stream) => Self::from_stream(stream, session),
            Err(_) => {
                session.disconnect();
                Err(SessionError::Io)
            }
        }
    }
    pub fn from_stream(stream: TcpStream, mut session: Session) -> Result<Self, SessionError> {
        let result = (|| {
            if !matches!(session.transport(), Transport::Tcp(_)) {
                return Err(SessionError::Protocol);
            }
            let peer = stream.peer_addr().map_err(|_| SessionError::Io)?;
            super::qr::validate_transport(&Transport::Tcp(peer))?;
            let expected = match session.transport() {
                Transport::Tcp(address) => *address,
                _ => return Err(SessionError::Protocol),
            };
            let actual = if session.is_host() {
                stream.local_addr().map_err(|_| SessionError::Io)?
            } else {
                peer
            };
            if expected != actual {
                return Err(SessionError::Protocol);
            }
            stream
                .set_read_timeout(Some(Duration::from_millis(10)))
                .map_err(|_| SessionError::Io)?;
            stream
                .set_write_timeout(Some(Duration::from_secs(5)))
                .map_err(|_| SessionError::Io)?;
            stream.set_nodelay(true).map_err(|_| SessionError::Io)?;
            Ok(())
        })();
        if let Err(error) = result {
            session.disconnect();
            return Err(error);
        }
        Ok(Self { stream, session })
    }
    /// One bounded read/flush step, never reconnecting or switching transport.
    /// A read timeout means "no bytes yet", not a new authentication attempt.
    pub fn poll(&mut self, now: i64) -> Result<(), SessionError> {
        let result = self.session.tick(now).and_then(|_| self.poll_inner(now));
        if result.is_err() {
            self.session.disconnect();
            let _ = self.stream.shutdown(Shutdown::Both);
        }
        result
    }
    fn poll_inner(&mut self, now: i64) -> Result<(), SessionError> {
        let output = self.session.drain_ciphertext(now)?;
        self.stream
            .write_all(&output)
            .map_err(|_| SessionError::Io)?;
        let mut input = [0u8; 16_384];
        match self.stream.read(&mut input) {
            Ok(0) => Err(SessionError::Io),
            Ok(count) => self.session.ingest_ciphertext(&input[..count], now),
            Err(error) if matches!(error.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock) => {
                Ok(())
            }
            Err(_) => Err(SessionError::Io),
        }
    }
}
impl Drop for TcpAdapter {
    fn drop(&mut self) {
        self.session.disconnect();
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    #[test]
    fn tcp_terminal_tick_immediately_closes_real_peer_socket() {
        for expired in [false, true] {
            let time = chrono::Utc::now().timestamp();
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let mut invitation = Invitation::create(Transport::Tcp(address), time).unwrap();
            let mut peer = TcpStream::connect(address).unwrap();
            peer.set_read_timeout(Some(Duration::from_millis(100)))
                .unwrap();
            let (server, _) = listener.accept().unwrap();
            let mut adapter = TcpAdapter::from_stream(
                server,
                invitation.accept(Role::Sender, "Desktop", time).unwrap(),
            )
            .unwrap();
            if !expired {
                adapter.session.cancel();
            }
            assert_eq!(
                adapter.poll(if expired { time + 300 } else { time }),
                Err(if expired {
                    SessionError::Expired
                } else {
                    SessionError::Terminal
                })
            );
            let mut byte = [0];
            assert_eq!(peer.read(&mut byte).unwrap(), 0);
        }
    }
    #[test]
    fn tcp_loopback_runs_real_tls_and_disconnect_is_terminal_without_retry() {
        let time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let mut invitation = Invitation::create(Transport::Tcp(address), time).unwrap();
        let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time).unwrap();
        let socket = TcpStream::connect(address).unwrap();
        let (server, _) = listener.accept().unwrap();
        let mut host = TcpAdapter::from_stream(
            server,
            invitation.accept(Role::Receiver, "Desktop", time).unwrap(),
        )
        .unwrap();
        let mut client = TcpAdapter::from_stream(
            socket,
            Session::client(qr, Role::Sender, "Phone", time).unwrap(),
        )
        .unwrap();
        for _ in 0..20 {
            client.poll(time).unwrap();
            host.poll(time).unwrap();
            if host.session.peer_info().is_some() && client.session.peer_info().is_some() {
                break;
            }
        }
        host.session.confirm(time).unwrap();
        client.session.confirm(time).unwrap();
        for _ in 0..4 {
            client.poll(time).unwrap();
            host.poll(time).unwrap();
        }
        client.session.send_payload(b"actual TCP", time).unwrap();
        for _ in 0..4 {
            client.poll(time).unwrap();
            host.poll(time).unwrap();
        }
        assert_eq!(
            host.session.receive_payload(time).unwrap(),
            Some(b"actual TCP".to_vec())
        );
        drop(client);
        assert_eq!(host.poll(time), Err(SessionError::Io));
        assert_eq!(host.session.state(), SessionState::Terminal);
        assert_eq!(host.poll(time), Err(SessionError::Terminal));
    }
    #[test]
    fn connected_client_must_match_the_qr_endpoint_not_another_local_service() {
        let time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let other = TcpListener::bind("127.0.0.1:0").unwrap();
        let invitation =
            Invitation::create(Transport::Tcp(listener.local_addr().unwrap()), time).unwrap();
        let qr = Qr::parse(&invitation.qr().unwrap().encode().unwrap(), time).unwrap();
        let session = Session::client(qr, Role::Sender, "Phone", time).unwrap();
        let stream = TcpStream::connect(other.local_addr().unwrap()).unwrap();
        assert!(matches!(
            TcpAdapter::from_stream(stream, session),
            Err(SessionError::Protocol)
        ));
    }
}
