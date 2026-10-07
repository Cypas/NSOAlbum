use async_trait::async_trait;
use chrono::{DateTime, TimeZone, Utc};
use serde_json::{json, Value};

use crate::album::{kind_from_type, readable_media_name};
use crate::error::{CoreError, CoreResult};
use crate::models::{MediaCandidate, ProviderPage, SourceType};
use crate::transport::HttpTransport;

use super::attestation::AttestationService;

const CORAL_BASE_URL: &str = "https://api-lp1.znc.srv.nintendo.net";
const MEDIA_LIST_PATH: &str = "/v4/Media/List";

#[async_trait]
pub trait MediaProvider: Send + Sync {
    fn provider_name(&self) -> &str;
    async fn list_recent(&self, cursor: Option<&str>) -> CoreResult<ProviderPage>;
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CoralSession {
    pub access_token: String,
    pub na_id: Option<String>,
    pub coral_user_id: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub avatar_bytes: Option<Vec<u8>>,
}

pub struct CoralAlbumProvider<A> {
    transport: HttpTransport,
    attestation: A,
    session: CoralSession,
    provider_key: String,
}

impl<A: AttestationService> CoralAlbumProvider<A> {
    pub fn new(transport: HttpTransport, attestation: A, session: CoralSession) -> Self {
        let provider_key = account_provider_key(&session);
        Self {
            transport,
            attestation,
            session,
            provider_key,
        }
    }

    async fn coral_call(&self, path: &str, parameter: Value) -> CoreResult<Value> {
        let url = format!("{CORAL_BASE_URL}{path}");
        let encrypted = self
            .attestation
            .encrypt_request(
                &url,
                &self.session.access_token,
                parameter,
                0,
                self.session.na_id.as_deref(),
                self.session.coral_user_id.as_deref(),
            )
            .await?;
        let version = self.attestation.nso_version().await?;
        let response = self
            .transport
            .post_bytes(
                &url,
                &[
                    (
                        "Authorization",
                        format!("Bearer {}", self.session.access_token),
                    ),
                    (
                        "User-Agent",
                        format!("com.nintendo.znca/{version}(Android/14)"),
                    ),
                    ("X-Platform", "Android".into()),
                    ("X-ProductVersion", version),
                    ("Content-Type", "application/octet-stream".into()),
                    ("Accept", "application/octet-stream,application/json".into()),
                ],
                encrypted.body,
            )
            .await?;
        self.attestation.decrypt_response(&response).await
    }
}

fn account_provider_key(session: &CoralSession) -> String {
    let account_id = session
        .na_id
        .as_deref()
        .or(session.coral_user_id.as_deref())
        .unwrap_or("unknown");
    format!("nso_coral:{account_id}")
}

#[async_trait]
impl<A: AttestationService> MediaProvider for CoralAlbumProvider<A> {
    fn provider_name(&self) -> &str {
        &self.provider_key
    }

    async fn list_recent(&self, _cursor: Option<&str>) -> CoreResult<ProviderPage> {
        let response = self
            .coral_call(MEDIA_LIST_PATH, json!({"parameter": {}}))
            .await?;
        let media = response
            .get("result")
            .and_then(|result| result.get("media"))
            .and_then(Value::as_array)
            .ok_or_else(|| {
                CoreError::Provider("Coral media response has no result.media array".into())
            })?;
        Ok(ProviderPage {
            items: media
                .iter()
                .map(parse_media_item)
                .collect::<CoreResult<Vec<_>>>()?,
            next_cursor: response
                .get("result")
                .and_then(|result| result.get("cursor"))
                .and_then(Value::as_str)
                .map(str::to_owned),
        })
    }
}

fn parse_media_item(item: &Value) -> CoreResult<MediaCandidate> {
    let media_type = item.get("type").and_then(Value::as_str).unwrap_or("image");
    let kind = kind_from_type(media_type);
    let remote_id = text(item, "id");
    let game_name = text(item, "appName").unwrap_or_else(|| "Nintendo Switch".into());
    let captured_at = timestamp(item, "capturedAt");
    let uploaded_at = timestamp(item, "uploadedAt");
    let effective_timestamp = captured_at.or(uploaded_at).unwrap_or_else(Utc::now);
    Ok(MediaCandidate {
        remote_id: remote_id.clone(),
        title_id: text(item, "titleId").or_else(|| text(item, "applicationId")),
        game_name: game_name.clone(),
        kind,
        content_url: text(item, "contentUri"),
        thumbnail_url: text(item, "thumbnailUri"),
        expected_size: item.get("contentLength").and_then(Value::as_u64),
        captured_at,
        uploaded_at,
        expires_at: timestamp(item, "expiresAt"),
        original_name: Some(readable_media_name(
            &game_name,
            effective_timestamp,
            remote_id.as_deref(),
            kind,
        )),
        file_extension: Some(match kind {
            crate::models::MediaKind::Image => "jpg".into(),
            crate::models::MediaKind::Video => "mp4".into(),
        }),
        source_type: SourceType::Nso,
        source_path: None,
    })
}

fn text(item: &Value, key: &str) -> Option<String> {
    item.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn timestamp(item: &Value, key: &str) -> Option<DateTime<Utc>> {
    let raw = item.get(key)?.as_i64()?;
    let seconds = if raw > 10_000_000_000 {
        raw / 1000
    } else {
        raw
    };
    Utc.timestamp_opt(seconds, 0).single()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scopes_provider_key_to_nintendo_account() {
        let session = CoralSession {
            access_token: "token".into(),
            na_id: Some("account-a".into()),
            coral_user_id: Some("123".into()),
            expires_at: None,
            nickname: "Inkling".into(),
            avatar_url: None,
            avatar_bytes: None,
        };

        assert_eq!(account_provider_key(&session), "nso_coral:account-a");
    }

    #[test]
    fn maps_coral_media_fields() {
        let value = json!({
            "id": "remote-1",
            "titleId": "0100",
            "appName": "Splatoon 3",
            "type": "video",
            "contentUri": "https://example.com/video.mp4",
            "contentLength": 42,
            "capturedAt": 1_700_000_000
        });
        let item = parse_media_item(&value).unwrap();
        assert_eq!(item.game_name, "Splatoon 3");
        assert_eq!(item.kind, crate::models::MediaKind::Video);
        assert!(item
            .original_name
            .as_deref()
            .is_some_and(|name| name.starts_with("Splatoon 3 - ") && name.ends_with(".mp4")));
    }
}
