//! JWT claims are cache hints only, never proof of authenticity.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::{DateTime, Duration, Utc};

pub(crate) fn expires_at(
    token: &str,
    expires_in: Option<i64>,
    now: DateTime<Utc>,
) -> DateTime<Utc> {
    let provider = expires_in.and_then(|seconds| {
        now.checked_add_signed(Duration::seconds(seconds.clamp(0, 31_536_000)))
    });
    let jwt = (|| {
        if token.len() > 32 * 1024 {
            return None;
        }
        let mut parts = token.split('.');
        let _header = parts.next()?;
        let payload = parts.next()?;
        let _signature = parts.next()?;
        if parts.next().is_some() {
            return None;
        }
        let bytes = URL_SAFE_NO_PAD.decode(payload.trim_end_matches('=')).ok()?;
        let claims: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
        DateTime::from_timestamp(claims.get("exp")?.as_i64()?, 0)
    })();
    match (jwt, provider) {
        (Some(jwt), Some(provider)) => jwt.min(provider),
        (Some(jwt), None) => jwt,
        (None, Some(provider)) => provider,
        (None, None) => now + Duration::seconds(60),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
    use chrono::TimeZone;

    fn jwt(payload: &str) -> String {
        format!("e30.{}.signature", URL_SAFE_NO_PAD.encode(payload))
    }

    #[test]
    fn cache_expiry_uses_earlier_jwt_or_provider_expiry_without_extending_either() {
        let now = chrono::Utc.timestamp_opt(1_000, 0).unwrap();
        assert_eq!(
            expires_at(&jwt(r#"{"exp":1100}"#), Some(500), now).timestamp(),
            1100
        );
        assert_eq!(
            expires_at(&jwt(r#"{"exp":1800}"#), Some(500), now).timestamp(),
            1500
        );
        assert_eq!(
            expires_at(&jwt(r#"{"exp":900}"#), Some(500), now).timestamp(),
            900
        );
    }

    #[test]
    fn opaque_or_invalid_token_falls_back_to_provider_or_short_cache_lifetime() {
        let now = chrono::Utc.timestamp_opt(1_000, 0).unwrap();
        for token in ["opaque", "x.invalid.x", "x.e30.x", "x.e30.x.extra"] {
            assert_eq!(expires_at(token, Some(300), now).timestamp(), 1300);
            assert_eq!(expires_at(token, None, now).timestamp(), 1060);
        }
        assert_eq!(
            expires_at(&jwt(r#"{"exp":"1100"}"#), None, now).timestamp(),
            1060
        );
    }
}
