//! Bounded, advisory invitation projection. This is not proof of peer identity.
use super::{Qr, SessionError, Transport};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApplicationBuild {
    pub version: String,
    pub build_number: String,
}

impl ApplicationBuild {
    pub(super) fn validate(&self) -> Result<(), SessionError> {
        let parts: Vec<_> = self.version.split('.').collect();
        if self.version.len() > 32
            || parts.len() != 3
            || parts.iter().any(|part| {
                part.is_empty()
                    || !part.bytes().all(|b| b.is_ascii_digit())
                    || (part.len() > 1 && part.starts_with('0'))
            })
            || self.build_number.is_empty()
            || self.build_number.len() > 10
            || !self.build_number.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(SessionError::InvalidQr);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvitationConnection {
    pub usb: bool,
    pub wifi_ssid: Option<String>,
    pub app_build: Option<ApplicationBuild>,
}

pub fn inspect(encoded: &str, now: i64) -> Result<InvitationConnection, SessionError> {
    let qr = Qr::parse(encoded, now)?;
    Ok(project(&qr))
}

fn project(qr: &Qr) -> InvitationConnection {
    InvitationConnection {
        usb: matches!(qr.transport(), Transport::Usb),
        wifi_ssid: qr.wire.wifi_ssid.clone(),
        app_build: qr.wire.app_build.clone(),
    }
}

pub fn inspect_compatible(
    encoded: &str,
    now: i64,
    local: &ApplicationBuild,
) -> Result<InvitationConnection, SessionError> {
    local.validate()?;
    let qr = Qr::parse(encoded, now)?;
    let info = project(&qr);
    if info.app_build.as_ref() != Some(local) {
        return Err(SessionError::VersionMismatch);
    }
    if qr.wire.control != super::qr::ControlPolicy::Phone {
        return Err(SessionError::Protocol);
    }
    Ok(info)
}
