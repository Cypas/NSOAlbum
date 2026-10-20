//! Owned TCP and ordered-mailbox pumps for the same driver. No transport fallback.
use super::*;
use std::io::{ErrorKind, Write};
use std::net::{Shutdown, TcpStream};

pub(crate) mod bundle;

pub struct TcpDriver {
    driver: Driver,
    stream: Option<TcpStream>,
    pending: Vec<u8>,
    written: usize,
    closed: bool,
}
impl TcpDriver {
    /// The invitation listener belongs to the caller and should close after accept.
    pub fn from_stream(stream: TcpStream, driver: Driver) -> Result<Self> {
        Self::from_stream_retaining(stream, driver).map_err(|(_, error)| error)
    }
    pub(crate) fn from_stream_retaining(
        stream: TcpStream,
        mut driver: Driver,
    ) -> std::result::Result<Self, (Box<Driver>, DriverError)> {
        let result = (|| {
            let expected = match driver.session.transport() {
                super::super::Transport::Tcp(address) => *address,
                _ => return Err(DriverError::Protocol),
            };
            let actual = if driver.session.is_host() {
                stream.local_addr()
            } else {
                stream.peer_addr()
            }
            .map_err(|_| DriverError::Channel(SessionError::Io))?;
            if expected != actual {
                return Err(DriverError::Protocol);
            }
            stream
                .set_nonblocking(true)
                .map_err(|_| DriverError::Channel(SessionError::Io))?;
            stream
                .set_nodelay(true)
                .map_err(|_| DriverError::Channel(SessionError::Io))?;
            Ok(())
        })();
        if let Err(error) = result {
            driver.disconnect();
            let _ = stream.shutdown(Shutdown::Both);
            return Err((Box::new(driver), error));
        }
        let control = match stream.try_clone() {
            Ok(control) => control,
            Err(_) => {
                driver.disconnect();
                return Err((Box::new(driver), DriverError::Channel(SessionError::Io)));
            }
        };
        if let Err(error) = driver.set_transport_close(move || {
            let _ = control.shutdown(Shutdown::Both);
        }) {
            return Err((Box::new(driver), error));
        }
        Ok(Self {
            driver,
            stream: Some(stream),
            pending: vec![],
            written: 0,
            closed: false,
        })
    }
    pub fn driver(&self) -> &Driver {
        &self.driver
    }
    pub fn driver_mut(&mut self) -> &mut Driver {
        &mut self.driver
    }
    pub fn is_closed(&self) -> bool {
        self.closed
    }
    pub fn poll(&mut self) -> Result<()> {
        let result = self.poll_inner();
        if result.is_err()
            || (self.driver.state().terminal() && self.driver.state() != State::Completed)
            || self.driver.session.state() == SessionState::Terminal
        {
            self.close();
        }
        result
    }
    fn poll_inner(&mut self) -> Result<()> {
        if self.closed {
            if self.driver.local_apply_installed() {
                return self.driver.poll_local();
            }
            return if self.driver.state() == State::Completed {
                Ok(())
            } else {
                Err(DriverError::Channel(SessionError::Terminal))
            };
        }
        let mut input = [0; 16_384];
        let stream = self
            .stream
            .as_mut()
            .ok_or(DriverError::Channel(SessionError::Terminal))?;
        match if self.driver.ready_for_input() {
            stream.read(&mut input)
        } else {
            Err(std::io::Error::from(ErrorKind::WouldBlock))
        } {
            Ok(0) if self.driver.state() == State::Completed => {
                self.close();
                return Ok(());
            }
            Ok(0) => return Err(DriverError::Channel(SessionError::Io)),
            Ok(count) => self.driver.ingest_ciphertext(&input[..count])?,
            Err(error) if error.kind() == ErrorKind::WouldBlock => {}
            Err(_) => return Err(DriverError::Channel(SessionError::Io)),
        }
        self.driver.poll()?;
        if self.driver.session.state() == SessionState::Terminal {
            return Ok(());
        }
        flush_output(
            &mut self.driver,
            &mut self.pending,
            &mut self.written,
            self.stream
                .as_mut()
                .ok_or(DriverError::Channel(SessionError::Terminal))?,
        )
    }
    pub fn cancel(&mut self) {
        self.driver.cancel();
        self.close();
    }
    fn close(&mut self) {
        self.driver.disconnect();
        self.pending.clear();
        if let Some(stream) = self.stream.take() {
            let _ = stream.shutdown(Shutdown::Both);
        }
        self.closed = true;
        // CommitAck can make Session terminal before flush_output is reached.
        // Freeze terminal TCP timings at transport retirement, not a later UI drop.
        // A detached receiver still applying locally must keep measuring instead.
        if self.driver.state().terminal() {
            self.driver.publish_measurements();
        }
    }
}
impl Drop for TcpDriver {
    fn drop(&mut self) {
        self.close();
    }
}

/// One bounded write attempt; retained bytes survive partial writes/backpressure.
pub(super) fn flush_output(
    driver: &mut Driver,
    pending: &mut Vec<u8>,
    written: &mut usize,
    sink: &mut impl Write,
) -> Result<()> {
    if pending.is_empty() {
        *pending = driver.drain_ciphertext()?;
        *written = 0;
    }
    if !pending.is_empty() {
        match sink.write(&pending[*written..]) {
            Ok(0) => return Err(DriverError::Channel(SessionError::Io)),
            Ok(count) => {
                driver.ciphertext_written(count)?;
                *written += count;
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {}
            Err(_) => return Err(DriverError::Channel(SessionError::Io)),
        }
        if *written == pending.len() {
            pending.clear();
            *written = 0;
        }
    }
    if pending.is_empty() {
        driver.finish_success();
    }
    Ok(())
}

/// Ordered TLS block conversion. Native I/O owners must close their worker on
/// any error and ACK only a name returned by accept; WindowFull retains output.
#[derive(Default)]
pub struct MailboxPump {
    order: super::super::mailbox::OrderedCiphertext,
    pending: Option<(String, Vec<u8>)>,
    blocked: bool,
    terminal: bool,
}
impl MailboxPump {
    pub fn accept(&mut self, driver: &mut Driver, name: &str, block: &[u8]) -> Result<String> {
        if self.terminal {
            return Err(DriverError::Protocol);
        }
        let result = (|| {
            let bytes = self.order.decode(name, block)?;
            driver.ingest_ciphertext(&bytes)?;
            // TLS has accepted the entire ordered block before the ACK is exposed.
            Ok(name.to_owned())
        })();
        if result.is_err() {
            self.terminal = true;
            driver.disconnect();
        }
        result
    }
    pub fn outgoing(&mut self, driver: &mut Driver) -> Result<Option<(&str, &[u8])>> {
        self.outgoing_inner(driver)
    }
    fn outgoing_inner(&mut self, driver: &mut Driver) -> Result<Option<(&str, &[u8])>> {
        if driver.state() == State::Completed && driver.session.state() == SessionState::Terminal {
            self.pending = None;
            self.blocked = false;
            self.terminal = true;
            return Ok(None);
        }
        if self.terminal {
            if driver.state() == State::Completed {
                return Ok(None);
            }
            return Err(DriverError::Protocol);
        }
        if self.blocked {
            return Ok(None);
        }
        if self.pending.is_none() {
            let ciphertext = driver.drain_ciphertext()?;
            if !ciphertext.is_empty() {
                // Session drain is bounded, not a TLS-record boundary.
                if ciphertext.len() > super::super::MAX_CIPHERTEXT {
                    return Err(DriverError::Bounds);
                }
                self.pending = Some(self.order.encode(&ciphertext)?);
            } else {
                self.finish_success(driver);
            }
        }
        Ok(self
            .pending
            .as_ref()
            .map(|(name, bytes)| (name.as_str(), bytes.as_slice())))
    }
    /// Call only after this entire block's actual atomic write has completed.
    pub fn written(&mut self, driver: &mut Driver) -> Result<()> {
        if let Some((_, block)) = self.pending.take() {
            driver.ciphertext_written(block.len() - 12)?;
        }
        Ok(())
    }
    /// Local native owners consume completion here; SAF async teardown is external.
    pub fn finish_success(&mut self, driver: &mut Driver) -> bool {
        if self.pending.is_none() && !self.blocked && driver.finish_success() {
            self.terminal = true;
            return true;
        }
        false
    }
    pub fn window_full(&mut self) {
        self.blocked = true;
    }
    /// Call only after an actual counterpart read/ACK has retired a block.
    pub fn capacity_released(&mut self) {
        self.blocked = false;
    }
    pub fn buffered_bytes(&self) -> usize {
        self.pending.as_ref().map_or(0, |(_, b)| b.len())
    }
    pub fn close(&mut self, driver: &mut Driver) {
        self.terminal = true;
        self.pending = None;
        driver.disconnect();
    }
}
