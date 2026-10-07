use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::engine::general_purpose::{STANDARD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::Mutex;

use crate::error::{CoreError, CoreResult};
use crate::transport::{HttpResponseData, HttpTransport};

const DEFAULT_ZNCA_BASE_URL: &str = "https://nxapi-znca-api.fancy.org.uk/api/znca";
const DEFAULT_OAUTH_URL: &str = "https://nxapi-auth.fancy.org.uk/api/oauth/token";
const DEFAULT_CLIENT_ID: &str = "K25kIeO_LRjaijJlPNs8og";
// This is a compatibility identifier, not the Coral app version. It must be
// updated deliberately when nxapi changes its Coral request implementation.
const ZNCA_CLIENT_VERSION: &str = "d8fAZDPzwimzQ7c6";

fn is_incompatible_client(response: &HttpResponseData) -> bool {
    response.status == 400
        && response
            .json::<Value>()
            .ok()
            .and_then(|value| {
                value
                    .get("error")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .as_deref()
            == Some("incompatible_client")
}

fn oauth_client_authentication_error(response: &HttpResponseData) -> Option<String> {
    if response.status != 401 {
        return None;
    }
    let value = response.json::<Value>().ok()?;
    if value.get("error").and_then(Value::as_str) != Some("invalid_client") {
        return None;
    }
    let description = value
        .get("error_description")
        .and_then(Value::as_str)
        .unwrap_or("client authentication was rejected");
    Some(format!(
        "NXAPI OAuth client authentication is required for client id {}: {description}. Configure the matching nxapi-auth client secret/client assertion; it must not be bundled in the app.",
        DEFAULT_CLIENT_ID
    ))
}

fn build_f_request_body(
    url: &str,
    access_token: &str,
    parameter: Value,
    method: u8,
    na_id: &str,
    coral_user_id: Option<&str>,
) -> CoreResult<Value> {
    let mut body = json!({
        "token": access_token,
        "hash_method": method,
        "na_id": na_id,
        "encrypt_token_request": {
            "url": url,
            "parameter": parameter,
        },
    });
    if method == 2 {
        let coral_user_id = coral_user_id
            .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()));
        let coral_user_id = coral_user_id.ok_or_else(|| {
            CoreError::Authentication("NXAPI /f method 2 requires a numeric coral_user_id".into())
        })?;
        body["coral_user_id"] = Value::String(coral_user_id.into());
    }
    Ok(body)
}

fn requires_client_id(path: &str) -> bool {
    matches!(path, "/encrypt-request" | "/decrypt-response")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedRequest {
    pub body: Vec<u8>,
    pub request_id: String,
    pub timestamp: i64,
}

#[async_trait]
pub trait AttestationService: Send + Sync {
    async fn encrypt_request(
        &self,
        url: &str,
        access_token: &str,
        parameter: Value,
        method: u8,
        na_id: Option<&str>,
        coral_user_id: Option<&str>,
    ) -> CoreResult<EncryptedRequest>;

    async fn decrypt_response(&self, encrypted: &[u8]) -> CoreResult<Value>;

    async fn nso_version(&self) -> CoreResult<String>;
}

#[derive(Debug, Clone)]
pub struct NxapiConfig {
    pub znca_base_url: String,
    pub oauth_url: String,
    pub client_id: String,
    pub user_agent: String,
}

impl Default for NxapiConfig {
    fn default() -> Self {
        Self {
            znca_base_url: DEFAULT_ZNCA_BASE_URL.into(),
            oauth_url: DEFAULT_OAUTH_URL.into(),
            client_id: DEFAULT_CLIENT_ID.into(),
            user_agent: format!("Cypas/NSOAlbum/{}", env!("CARGO_PKG_VERSION")),
        }
    }
}

#[derive(Debug, Clone)]
struct OAuthToken {
    access_token: String,
    refresh_token: Option<String>,
    expires_at: Instant,
}

#[derive(Debug, Clone)]
struct VersionCache {
    value: String,
    expires_at: Instant,
}

/// Concrete client for nxapi-znca-api.
///
/// The public service requires OAuth token reuse and serial requests. Both are
/// enforced here so Flutter callers cannot accidentally create request bursts.
#[derive(Clone)]
pub struct NxapiAttestationClient {
    transport: HttpTransport,
    config: NxapiConfig,
    token: Arc<Mutex<Option<OAuthToken>>>,
    version: Arc<Mutex<Option<VersionCache>>>,
    request_lock: Arc<Mutex<()>>,
}

impl NxapiAttestationClient {
    pub fn new(transport: HttpTransport, config: NxapiConfig) -> Self {
        Self {
            transport,
            config,
            token: Arc::new(Mutex::new(None)),
            version: Arc::new(Mutex::new(None)),
            request_lock: Arc::new(Mutex::new(())),
        }
    }

    async fn oauth_token(&self) -> CoreResult<String> {
        let now = Instant::now();
        let cached = self.token.lock().await.clone();
        if let Some(token) = cached.as_ref().filter(|token| now < token.expires_at) {
            return Ok(token.access_token.clone());
        }

        let refresh_token = cached.and_then(|token| token.refresh_token);
        let mut response = if let Some(refresh_token) = refresh_token.as_deref() {
            self.request_oauth_token("refresh_token", Some(refresh_token))
                .await?
        } else {
            self.request_oauth_token("client_credentials", None).await?
        };
        if response.status >= 400 && refresh_token.is_some() {
            response = self.request_oauth_token("client_credentials", None).await?;
        }
        if let Some(message) = oauth_client_authentication_error(&response) {
            return Err(CoreError::Authentication(message));
        }
        response.ensure_success("NXAPI OAuth token request")?;
        let value: Value = response.json()?;
        let access_token = value
            .get("access_token")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                CoreError::Authentication("NXAPI OAuth response has no access_token".into())
            })?
            .to_owned();
        let expires_in = value
            .get("expires_in")
            .and_then(Value::as_u64)
            .unwrap_or(300);
        let refresh_token = value
            .get("refresh_token")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or(refresh_token);
        *self.token.lock().await = Some(OAuthToken {
            access_token: access_token.clone(),
            refresh_token,
            expires_at: Instant::now() + Duration::from_secs(expires_in.saturating_sub(30).max(1)),
        });
        Ok(access_token)
    }

    async fn request_oauth_token(
        &self,
        grant_type: &str,
        refresh_token: Option<&str>,
    ) -> CoreResult<HttpResponseData> {
        let mut fields = vec![
            ("grant_type", grant_type.to_owned()),
            ("client_id", self.config.client_id.clone()),
            ("scope", "ca:gf ca:er ca:dr".to_owned()),
        ];
        if let Some(refresh_token) = refresh_token {
            fields.push(("refresh_token", refresh_token.to_owned()));
        }
        self.transport
            .post_form_raw(
                &self.config.oauth_url,
                &[("User-Agent", self.config.user_agent.clone())],
                &fields,
            )
            .await
    }

    async fn znca_request(
        &self,
        path: &str,
        body: &Value,
        accept: &str,
    ) -> CoreResult<HttpResponseData> {
        let _request_guard = self.request_lock.lock().await;
        let version = Some(self.nso_version_uncached().await?);
        let mut response = self
            .znca_request_once(path, body, accept, version.as_deref())
            .await?;
        if response.status == 401 {
            *self.token.lock().await = None;
            response = self
                .znca_request_once(path, body, accept, version.as_deref())
                .await?;
        }
        if response.status == 406 {
            *self.version.lock().await = None;
        }
        if is_incompatible_client(&response) {
            return Err(CoreError::Provider(
                "NXAPI client compatibility identifier is outdated; update Fresh Album".into(),
            ));
        }
        response.ensure_success(&format!("NXAPI {path}"))?;
        Ok(response)
    }

    async fn znca_request_once(
        &self,
        path: &str,
        body: &Value,
        accept: &str,
        version: Option<&str>,
    ) -> CoreResult<HttpResponseData> {
        let url = format!("{}{path}", self.config.znca_base_url.trim_end_matches('/'));
        if path == "/config" {
            return self
                .transport
                .get_raw(&url, &[("User-Agent", self.config.user_agent.clone())])
                .await;
        }

        let token = self.oauth_token().await?;
        let mut headers = vec![
            ("Accept", accept.to_owned()),
            ("User-Agent", self.config.user_agent.clone()),
            ("Authorization", format!("Bearer {token}")),
        ];
        if let Some(version) = version {
            headers.extend([
                ("X-znca-Platform", "Android".into()),
                ("X-znca-Version", version.into()),
                ("X-znca-Client-Version", ZNCA_CLIENT_VERSION.into()),
            ]);
        }
        if requires_client_id(path) {
            headers.push(("Client-Id", self.config.client_id.clone()));
        }
        self.transport.post_json_raw(&url, &headers, body).await
    }

    async fn nso_version_uncached(&self) -> CoreResult<String> {
        if let Some(cached) = self
            .version
            .lock()
            .await
            .clone()
            .filter(|cached| Instant::now() < cached.expires_at)
        {
            return Ok(cached.value);
        }
        // Do not use `znca_request` here: it also resolves the version and would recurse.
        let response = self
            .znca_request_once("/config", &Value::Null, "application/json", None)
            .await?;
        response.ensure_success("NXAPI /config")?;
        let value: Value = response.json()?;
        let version = value
            .get("nso_version")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::Provider("NXAPI /config has no nso_version".into()))?
            .to_owned();
        *self.version.lock().await = Some(VersionCache {
            value: version.clone(),
            expires_at: Instant::now() + Duration::from_secs(6 * 60 * 60),
        });
        Ok(version)
    }

    fn decode_encrypted(value: &Value, field: &str) -> CoreResult<Vec<u8>> {
        let encoded = value
            .get(field)
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::Provider(format!("NXAPI response has no {field}")))?;
        STANDARD
            .decode(encoded)
            .or_else(|_| URL_SAFE_NO_PAD.decode(encoded))
            .or_else(|_| URL_SAFE.decode(encoded))
            .map_err(|error| CoreError::Provider(format!("invalid NXAPI base64 body: {error}")))
    }

    fn parse_decrypted(response: &HttpResponseData) -> CoreResult<Value> {
        let raw: Value = serde_json::from_slice(&response.body)?;
        if let Some(data) = raw.get("data").and_then(Value::as_str) {
            return Ok(serde_json::from_str(data)?);
        }
        Ok(raw)
    }
}

#[async_trait]
impl AttestationService for NxapiAttestationClient {
    async fn encrypt_request(
        &self,
        url: &str,
        access_token: &str,
        parameter: Value,
        method: u8,
        na_id: Option<&str>,
        coral_user_id: Option<&str>,
    ) -> CoreResult<EncryptedRequest> {
        if method == 0 {
            let response = self
                .znca_request(
                    "/encrypt-request",
                    &json!({
                        "url": url,
                        "token": if access_token.is_empty() { Value::Null } else { Value::String(access_token.into()) },
                        "data": serde_json::to_string(&parameter)?,
                    }),
                    "application/json",
                )
                .await?;
            let value: Value = response.json()?;
            return Ok(EncryptedRequest {
                body: Self::decode_encrypted(&value, "data")?,
                request_id: String::new(),
                timestamp: 0,
            });
        }

        let na_id =
            na_id.ok_or_else(|| CoreError::Authentication("NXAPI /f requires na_id".into()))?;
        let body =
            build_f_request_body(url, access_token, parameter, method, na_id, coral_user_id)?;
        let response = self.znca_request("/f", &body, "application/json").await?;
        let value: Value = response.json()?;
        Ok(EncryptedRequest {
            body: Self::decode_encrypted(&value, "encrypted_token_request")?,
            request_id: value
                .get("request_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .into(),
            timestamp: value
                .get("timestamp")
                .and_then(Value::as_i64)
                .unwrap_or_default(),
        })
    }

    async fn decrypt_response(&self, encrypted: &[u8]) -> CoreResult<Value> {
        let response = self
            .znca_request(
                "/decrypt-response",
                &json!({"data": STANDARD.encode(encrypted)}),
                "text/plain",
            )
            .await?;
        Self::parse_decrypted(&response)
    }

    async fn nso_version(&self) -> CoreResult<String> {
        self.nso_version_uncached().await
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    #[test]
    fn uses_current_nxapi_client_identifiers() {
        let config = NxapiConfig::default();

        assert_eq!(config.client_id, "K25kIeO_LRjaijJlPNs8og");
        assert_eq!(
            config.user_agent,
            format!("Cypas/NSOAlbum/{}", env!("CARGO_PKG_VERSION"))
        );
        assert_eq!(ZNCA_CLIENT_VERSION, "d8fAZDPzwimzQ7c6");
    }

    #[test]
    fn detects_incompatible_client_response() {
        let response = HttpResponseData {
            status: 400,
            headers: HashMap::new(),
            body: br#"{"error":"incompatible_client","error_description":"update required"}"#
                .to_vec(),
        };

        assert!(is_incompatible_client(&response));
    }

    #[test]
    fn explains_missing_oauth_client_authentication() {
        let response = HttpResponseData {
            status: 401,
            headers: HashMap::new(),
            body:
                br#"{"error":"invalid_client","error_description":"Missing client authentication"}"#
                    .to_vec(),
        };

        let message = oauth_client_authentication_error(&response).unwrap();
        assert!(message.contains("client secret/client assertion"));
        assert!(message.contains("must not be bundled"));
    }

    #[test]
    fn ignores_other_bad_request_responses() {
        let response = HttpResponseData {
            status: 400,
            headers: HashMap::new(),
            body: br#"{"error":"invalid_request"}"#.to_vec(),
        };

        assert!(!is_incompatible_client(&response));
    }

    #[test]
    fn method_one_omits_coral_user_id() {
        let body = build_f_request_body(
            "https://example.com/login",
            "id-token",
            json!({"naIdToken": "id-token"}),
            1,
            "1234567890",
            None,
        )
        .unwrap();

        assert!(body.get("coral_user_id").is_none());
    }

    #[test]
    fn method_two_requires_numeric_coral_user_id() {
        assert!(build_f_request_body(
            "https://example.com/token",
            "access-token",
            json!({}),
            2,
            "1234567890",
            Some("not-a-number"),
        )
        .is_err());

        let body = build_f_request_body(
            "https://example.com/token",
            "access-token",
            json!({}),
            2,
            "1234567890",
            Some("9876543210"),
        )
        .unwrap();
        assert_eq!(body["coral_user_id"], "9876543210");
    }

    #[test]
    fn client_id_is_only_required_for_encrypt_and_decrypt() {
        assert!(requires_client_id("/encrypt-request"));
        assert!(requires_client_id("/decrypt-response"));
        assert!(!requires_client_id("/f"));
        assert!(!requires_client_id("/config"));
    }

    #[test]
    fn decodes_base64url_encrypted_body() {
        let expected = vec![251, 255, 239, 1, 2, 3];
        let value = json!({"data": URL_SAFE_NO_PAD.encode(&expected)});

        assert_eq!(
            NxapiAttestationClient::decode_encrypted(&value, "data").unwrap(),
            expected
        );
    }
}
