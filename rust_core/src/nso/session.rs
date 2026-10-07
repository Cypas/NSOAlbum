use chrono::{Duration, Utc};
use serde_json::{json, Value};

use crate::error::{CoreError, CoreResult};
use crate::transport::{HttpResponseData, HttpTransport};

use super::attestation::AttestationService;
use super::auth::NintendoAuthClient;
use super::provider::CoralSession;

const CORAL_LOGIN_URL: &str = "https://api-lp1.znc.srv.nintendo.net/v4/Account/Login";

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
        let auth = NintendoAuthClient::new(self.transport.clone());
        let tokens = auth.exchange_session_token(session_token).await?;
        let profile = auth.fetch_profile(&tokens.access_token).await?;
        let parameter = account_login_parameter(&tokens.id_token, &profile.language);

        let mut last_response = None;
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
                        (
                            "User-Agent",
                            format!("com.nintendo.znca/{version}(Android/14)"),
                        ),
                        ("Content-Type", "application/octet-stream".into()),
                        ("Accept", "application/octet-stream,application/json".into()),
                    ],
                    encrypted.body,
                )
                .await?;
            let decoded = self.decode_coral_response(&response).await?;
            if attempt == 0 && is_attestation_rejection(&decoded) {
                last_response = Some(decoded);
                continue;
            }
            response.ensure_success("Coral Account/Login")?;
            let mut session = parse_session(&decoded, &profile)?;
            if let Some(avatar_url) = session.avatar_url.as_deref() {
                session.avatar_bytes = self.transport.download_avatar(avatar_url).await.ok();
            }
            return Ok(session);
        }

        Err(CoreError::Authentication(format!(
            "Coral rejected method-1 attestation twice: {}",
            last_response.unwrap_or(Value::Null)
        )))
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
    matches!(
        value.get("status").and_then(Value::as_i64),
        Some(9403 | 9599)
    ) || matches!(
        value.get("errorMessage").and_then(Value::as_str),
        Some("Invalid token." | "Unexpected error.")
    )
}

fn parse_session(value: &Value, profile: &crate::nso::NintendoProfile) -> CoreResult<CoralSession> {
    let result = value
        .get("result")
        .ok_or_else(|| CoreError::Authentication(format!("Coral login has no result: {value}")))?;
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
        expires_at: Some(Utc::now() + Duration::seconds(expires_in)),
        nickname,
        avatar_url,
        avatar_bytes: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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
