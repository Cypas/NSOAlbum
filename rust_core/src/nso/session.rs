use chrono::Utc;
use serde_json::{json, Value};

use crate::error::{CoreError, CoreResult};
use crate::transport::{nintendo_user_agent, HttpResponseData, HttpTransport};

use super::attestation::AttestationService;
use super::auth::NintendoAuthClient;
use super::provider::CoralSession;

const CORAL_LOGIN_URL: &str = "https://api-lp1.znc.srv.nintendo.net/v4/Account/Login";

#[derive(Clone)]
pub(crate) struct AuthenticatedCoralSession {
    pub session: CoralSession,
    pub language: String,
    pub country: String,
}

/// Process-only intermediate credentials; the enclosing account entry owns
/// account, session-token and proxy isolation. Never serialize this cache.
pub(crate) struct CachedNintendoIdentity {
    tokens: super::NintendoTokens,
    profile: super::NintendoProfile,
    expires_at: chrono::DateTime<Utc>,
}

impl CachedNintendoIdentity {
    fn usable(&self, now: chrono::DateTime<Utc>) -> bool {
        super::token_expiry::reusable(self.expires_at, now)
    }
}

fn account_login_parameter(id_token: &str, language: &str) -> Value {
    json!({
        "language": language,
        "naIdToken": id_token,
        "f": "",
        "requestId": "",
        "timestamp": 0,
    })
}

#[derive(Clone)]
pub struct CoralSessionClient<A> {
    transport: HttpTransport,
    attestation: A,
}

impl<A: AttestationService> CoralSessionClient<A> {
    pub fn new(transport: HttpTransport, attestation: A) -> Self {
        Self {
            transport,
            attestation,
        }
    }

    pub async fn login_with_session_token(&self, session_token: &str) -> CoreResult<CoralSession> {
        Ok(self.login_with_account_info(session_token).await?.session)
    }

    pub(crate) async fn login_with_account_info(
        &self,
        session_token: &str,
    ) -> CoreResult<AuthenticatedCoralSession> {
        self.login_with_identity_cache(session_token, &mut None)
            .await
    }

    pub(crate) async fn login_with_identity_cache(
        &self,
        session_token: &str,
        cache: &mut Option<CachedNintendoIdentity>,
    ) -> CoreResult<AuthenticatedCoralSession> {
        let auth = NintendoAuthClient::new(self.transport.clone());
        if !cache
            .as_ref()
            .is_some_and(|identity| identity.usable(Utc::now()))
        {
            let (tokens, expires_at) = auth
                .exchange_session_token_with_expiry(session_token)
                .await?;
            let profile = auth.fetch_profile(&tokens.access_token).await?;
            *cache = Some(CachedNintendoIdentity {
                tokens,
                profile,
                expires_at,
            });
        }
        let identity = cache.as_ref().expect("populated identity cache");
        let tokens = &identity.tokens;
        let profile = &identity.profile;
        let parameter = account_login_parameter(&tokens.id_token, &profile.language);

        for attempt in 0..2 {
            let encrypted = self
                .attestation
                .encrypt_request(
                    CORAL_LOGIN_URL,
                    &tokens.id_token,
                    parameter.clone(),
                    1,
                    Some(&profile.id),
                    None,
                )
                .await?;
            let version = self.attestation.nso_version().await?;
            let response = self
                .transport
                .post_bytes_raw(
                    CORAL_LOGIN_URL,
                    &[
                        ("X-Platform", "Android".into()),
                        ("X-ProductVersion", version.clone()),
                        ("User-Agent", nintendo_user_agent(&version)),
                        ("Content-Type", "application/octet-stream".into()),
                        ("Accept", "application/octet-stream,application/json".into()),
                    ],
                    encrypted.body,
                )
                .await?;
            response.ensure_success_redacted("Coral Account/Login")?;
            let decoded = self.decode_coral_response(&response).await?;
            if attempt == 0 && is_attestation_rejection(&decoded) {
                continue;
            }
            if is_attestation_rejection(&decoded) {
                return Err(CoreError::Authentication(
                    "Coral rejected account authentication".into(),
                ));
            }
            super::conditions::ensure_coral_success(&decoded)?;
            let mut session = parse_session(&decoded, profile)?;
            if let Some(avatar_url) = session.avatar_url.as_deref() {
                session.avatar_bytes = self
                    .transport
                    .clone()
                    .with_nso_downloads(&version)
                    .download_avatar(avatar_url)
                    .await
                    .ok();
            }
            return Ok(AuthenticatedCoralSession {
                session,
                language: profile.language.clone(),
                country: profile.country.clone(),
            });
        }

        Err(CoreError::Authentication(
            "Coral rejected account authentication".into(),
        ))
    }

    async fn decode_coral_response(&self, response: &HttpResponseData) -> CoreResult<Value> {
        if response.body.is_empty() {
            return Err(CoreError::Authentication(
                "Coral returned an empty response".into(),
            ));
        }
        match self.attestation.decrypt_response(&response.body).await {
            Ok(value) => Ok(value),
            Err(decrypt_error) => serde_json::from_slice(&response.body).map_err(|_| decrypt_error),
        }
    }
}

fn is_attestation_rejection(value: &Value) -> bool {
    if let Some(status) = value.get("status").and_then(Value::as_i64) {
        return matches!(status, 9403 | 9599);
    }
    matches!(
        value.get("errorMessage").and_then(Value::as_str),
        Some("Invalid token." | "Unexpected error.")
    )
}

fn parse_session(value: &Value, profile: &crate::nso::NintendoProfile) -> CoreResult<CoralSession> {
    let result = value
        .get("result")
        .ok_or_else(|| CoreError::Authentication("Coral login has no result".into()))?;
    let credential = result
        .get("webApiServerCredential")
        .ok_or_else(|| CoreError::Authentication("Coral login has no credential".into()))?;
    let access_token = credential
        .get("accessToken")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::Authentication("Coral login has no accessToken".into()))?;
    let expires_in = credential
        .get("expiresIn")
        .and_then(Value::as_i64)
        .unwrap_or(7200)
        .max(1);
    let user = result.get("user");
    let coral_user_id = user.and_then(|user| user.get("id")).map(|id| {
        id.as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| id.to_string())
    });
    let nickname = user
        .and_then(|user| user.get("name").or_else(|| user.get("nickname")))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&profile.nickname)
        .to_owned();
    let avatar_url = user
        .and_then(|user| {
            user.get("imageUri")
                .or_else(|| user.get("image2Uri"))
                .and_then(Value::as_str)
        })
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .or_else(|| profile.avatar_url().map(str::to_owned));
    Ok(CoralSession {
        access_token: access_token.into(),
        na_id: Some(profile.id.clone()),
        coral_user_id,
        expires_at: Some(super::token_expiry::expires_at(
            access_token,
            Some(expires_in),
            Utc::now(),
        )),
        nickname,
        avatar_url,
        avatar_bytes: None,
    })
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;

    pub(crate) fn synthetic_identity() -> CachedNintendoIdentity {
        CachedNintendoIdentity {
            tokens: super::super::NintendoTokens {
                access_token: "synthetic-access".into(),
                id_token: "synthetic-id".into(),
            },
            profile: serde_json::from_value(json!({
                "id": "account-a", "nickname": "Synthetic",
                "language": "ja-JP", "country": "JP", "birthday": "2000-01-01"
            }))
            .unwrap(),
            expires_at: Utc::now() + chrono::Duration::hours(1),
        }
    }

    #[test]
    fn nintendo_identity_cache_requires_expiry_safety_window() {
        use chrono::TimeZone;
        let now = Utc.timestamp_opt(1_000, 0).unwrap();
        let mut identity = CachedNintendoIdentity {
            tokens: super::super::NintendoTokens {
                access_token: "synthetic-access".into(),
                id_token: "synthetic-id".into(),
            },
            profile: serde_json::from_value(json!({
                "id": "synthetic-account", "nickname": "Synthetic",
                "language": "en-GB", "country": "GB", "birthday": "2000-01-01"
            }))
            .unwrap(),
            expires_at: now + chrono::Duration::seconds(301),
        };
        assert!(identity.usable(now));
        identity.expires_at = now + chrono::Duration::seconds(300);
        assert!(!identity.usable(now));
        identity.expires_at = now - chrono::Duration::seconds(1);
        assert!(!identity.usable(now));
    }

    #[test]
    fn explicit_account_and_rate_errors_never_retry_based_on_generic_token_text() {
        for status in [429, 9437, 9407, 9424, 9428, 9450] {
            assert!(
                !is_attestation_rejection(
                    &json!({"status": status, "errorMessage": "Invalid token."})
                ),
                "{status}"
            );
        }
    }

    #[test]
    fn recognizes_only_retryable_nintendo_codes() {
        assert!(is_attestation_rejection(&json!({"status": 9403})));
        assert!(is_attestation_rejection(&json!({"status": 9599})));
        assert!(!is_attestation_rejection(&json!({"status": 9000})));
    }

    #[test]
    fn account_login_parameter_uses_current_fields() {
        let parameter = account_login_parameter("id-token", "zh-Hans");

        assert!(parameter.get("naBirthday").is_none());
        assert!(parameter.get("naCountry").is_none());
    }

    #[test]
    fn parses_nickname_and_avatar_from_coral_user() {
        let profile = crate::nso::NintendoProfile {
            id: "na-1".into(),
            nickname: "Nintendo nickname".into(),
            language: "zh-Hans".into(),
            country: "CN".into(),
            birthday: "2000-01-01".into(),
            image_uri: None,
            mii: None,
        };
        let session = parse_session(
            &json!({
                "result": {
                    "webApiServerCredential": {
                        "accessToken": "coral-token",
                        "expiresIn": 7200
                    },
                    "user": {
                        "id": "123456",
                        "name": "Inkling",
                        "imageUri": "https://example.com/avatar.png"
                    }
                }
            }),
            &profile,
        )
        .unwrap();

        assert_eq!(session.nickname, "Inkling");
        assert_eq!(
            session.avatar_url.as_deref(),
            Some("https://example.com/avatar.png")
        );
        assert_eq!(session.coral_user_id.as_deref(), Some("123456"));
    }
}
