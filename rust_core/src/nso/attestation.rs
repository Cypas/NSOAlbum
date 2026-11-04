use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::engine::general_purpose::{STANDARD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Digest;
use tokio::sync::Mutex;

use crate::error::{CoreError, CoreResult};
use crate::transport::{HttpResponseData, HttpTransport};

const DEFAULT_ZNCA_BASE_URL: &str = "https://nxapi-znca-api.fancy.org.uk/api/znca";
const DEFAULT_OAUTH_URL: &str = "https://nxapi-auth.fancy.org.uk/api/oauth/token";
const DEFAULT_CLIENT_ID: &str = "OhFZ3YmNeYnls5Fo-z3BkA";
// This is a compatibility identifier, not the Coral app version. It must be
// updated deliberately when nxapi changes its Coral request implementation.
const ZNCA_CLIENT_VERSION: &str = "d8fAZDPzwimzQ7c6";

async fn nxapi_transport_request<F, Fut>(mut send: F) -> CoreResult<HttpResponseData>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = CoreResult<HttpResponseData>>,
{
    let first = send().await;
    let retry = match first.as_ref() {
        Err(CoreError::NetworkRequest { reason, .. }) => {
            matches!(*reason, "timeout" | "connect_failed")
        }
        Err(CoreError::Network(error)) => error.is_timeout() || error.is_connect(),
        _ => false,
    };
    if !retry {
        return first;
    }
    // Only the NXAPI service's stateless exchanges use this wrapper. Never
    // retry Coral account writes here, and never change the selected proxy.
    tokio::time::sleep(Duration::from_millis(250)).await;
    send().await
}

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
    Some(format!(
        "NXAPI OAuth client authentication is required for client id {}. Configure the matching nxapi-auth client secret/client assertion; it must not be bundled in the app. NXAPI code: invalid_client",
        DEFAULT_CLIENT_ID
    ))
}

fn ensure_nxapi_success(response: &HttpResponseData, operation: &str) -> CoreResult<()> {
    // Never echo remote descriptions, unknown error strings, IDs or bodies.
    let value = response.json::<Value>().ok();
    let code = value
        .as_ref()
        .and_then(|value| value.get("error"))
        .and_then(Value::as_str);
    let safe_code = match code {
        Some("invalid_request") => "invalid_request",
        Some("request_parameter_not_set") => "request_parameter_not_set",
        Some("unsupported_platform") => "unsupported_platform",
        Some("unsupported_version") => "unsupported_version",
        Some("incompatible_client") => "incompatible_client",
        Some("unauthorised") => "unauthorised",
        Some("invalid_token") => "invalid_token",
        Some("insufficient_scope") => "insufficient_scope",
        Some("rate_limit") => "rate_limit",
        Some("unknown_error") => "unknown_error",
        Some("service_unavailable") => "service_unavailable",
        Some("invalid_client") => "invalid_client",
        Some("invalid_grant") => "invalid_grant",
        Some("invalid_scope") => "invalid_scope",
        Some("unauthorized_client") => "unauthorized_client",
        Some("unsupported_grant_type") => "unsupported_grant_type",
        _ => return response.ensure_success_redacted(operation),
    };
    response
        .ensure_success_redacted(operation)
        .map_err(|error| match error {
            CoreError::Provider(message) => {
                CoreError::Provider(format!("{message}; NXAPI code: {safe_code}"))
            }
            CoreError::Authentication(message) => {
                CoreError::Authentication(format!("{message}; NXAPI code: {safe_code}"))
            }
            other => other,
        })
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
            user_agent: format!("Cypas-NSOAlbum/{}", env!("CARGO_PKG_VERSION")),
        }
    }
}

#[derive(Clone)]
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

    /// Keep public version metadata and serialization, but never another user's
    /// OAuth credentials. Clones of this account client still reuse its token.
    pub(crate) fn isolated_credentials(&self) -> Self {
        Self {
            token: Arc::new(Mutex::new(None)),
            ..self.clone()
        }
    }

    pub(crate) fn service_key(&self) -> String {
        let mut hasher = sha2::Sha256::new();
        hasher.update(self.config.znca_base_url.as_bytes());
        hasher.update([0]);
        hasher.update(self.config.oauth_url.as_bytes());
        hasher.update([0]);
        hasher.update(self.config.client_id.as_bytes());
        hex::encode(hasher.finalize())
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
        if matches!(response.status, 400 | 401) && refresh_token.is_some() {
            response = self.request_oauth_token("client_credentials", None).await?;
        }
        if let Some(message) = oauth_client_authentication_error(&response) {
            return Err(CoreError::Authentication(message));
        }
        ensure_nxapi_success(&response, "NXAPI OAuth token request")?;
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
            expires_at: Instant::now()
                + super::token_expiry::expires_at(
                    &access_token,
                    Some(expires_in.min(i64::MAX as u64) as i64),
                    chrono::Utc::now(),
                )
                .signed_duration_since(chrono::Utc::now())
                .to_std()
                .unwrap_or_default(),
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
        nxapi_transport_request(|| async {
            self.transport
                .post_form_raw(
                    &self.config.oauth_url,
                    &[("User-Agent", self.config.user_agent.clone())],
                    &fields,
                )
                .await
        })
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
                "NXAPI client compatibility identifier is outdated; update NSOAlbum".into(),
            ));
        }
        ensure_nxapi_success(&response, &format!("NXAPI {path}"))?;
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
            return nxapi_transport_request(|| async {
                self.transport
                    .get_raw(&url, &[("User-Agent", self.config.user_agent.clone())])
                    .await
            })
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
        nxapi_transport_request(|| self.transport.post_json_raw(&url, &headers, body)).await
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
        ensure_nxapi_success(&response, "NXAPI /config")?;
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

    #[tokio::test]
    async fn transient_transport_recovery_stops_after_one_extra_attempt() {
        let mut calls = 0;
        let error = nxapi_transport_request(|| {
            calls += 1;
            std::future::ready(Err(CoreError::NetworkRequest {
                stage: "nxapi_encrypt",
                reason: "timeout",
                proxy: "explicit",
                elapsed_ms: 30000,
                url: "https://nxapi-znca-api.fancy.org.uk/api/znca/encrypt-request".into(),
                code_kind: "none",
                code: "none".into(),
            }))
        })
        .await
        .unwrap_err();
        assert_eq!(calls, 2);
        assert!(matches!(
            error,
            CoreError::NetworkRequest {
                reason: "timeout",
                proxy: "explicit",
                ..
            }
        ));
    }

    #[tokio::test]
    async fn a_failed_request_after_doh_fallback_is_not_replayed_by_nxapi_retry() {
        let mut calls = 0;
        let result = nxapi_transport_request(|| {
            calls += 1;
            std::future::ready(Err(CoreError::NetworkRequest {
                stage: "nxapi_encrypt",
                reason: "doh_request_failed",
                proxy: "default",
                elapsed_ms: 12,
                url: "https://nxapi-znca-api.fancy.org.uk/api/znca/encrypt-request".into(),
                code_kind: "none",
                code: "none".into(),
            }))
        })
        .await;

        assert!(result.is_err());
        assert_eq!(calls, 1);
    }

    #[tokio::test]
    async fn transport_recovery_does_not_retry_http_rate_limits_or_business_errors() {
        for status in [400, 429, 503] {
            let (base, server) = crate::transport::tests::capture_response(
                status,
                r#"{"error":"service_unavailable"}"#,
                &[],
            );
            let client = NxapiAttestationClient::new(
                HttpTransport::new(Default::default()).unwrap(),
                NxapiConfig {
                    znca_base_url: base,
                    ..Default::default()
                },
            );
            let error = client.nso_version().await.unwrap_err();
            server.join().unwrap();
            if status == 429 {
                assert!(matches!(
                    error,
                    CoreError::RateLimited {
                        retry_after_seconds: 60
                    }
                ));
            } else {
                assert!(error.to_string().contains(&format!("HTTP {status}")));
            }
        }
    }

    #[tokio::test]
    async fn nxapi_config_recovers_one_transport_timeout_then_caches_the_success() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(3);
            let mut requests = 0;
            while requests < 2 && Instant::now() < deadline {
                let (mut socket, _) = match listener.accept() {
                    Ok(connection) => connection,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    Err(error) => panic!("synthetic listener failed: {error}"),
                };
                // Accepted sockets can inherit the listener's nonblocking
                // mode on Windows. The request may arrive after accept().
                socket.set_nonblocking(false).unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(1)))
                    .unwrap();
                let mut request = [0; 2048];
                let length = socket.read(&mut request).unwrap();
                assert!(std::str::from_utf8(&request[..length])
                    .unwrap()
                    .starts_with("GET /config "));
                requests += 1;
                if requests == 1 {
                    std::thread::sleep(Duration::from_millis(400));
                    continue;
                }
                let body = r#"{"nso_version":"3.9.9"}"#;
                write!(
                    socket,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
            requests
        });
        let client = NxapiAttestationClient::new(
            HttpTransport::new(crate::transport::TransportConfig {
                timeout: Duration::from_millis(200),
                ..Default::default()
            })
            .unwrap(),
            NxapiConfig {
                znca_base_url: base,
                ..Default::default()
            },
        );
        let result = client.nso_version().await;
        let requests = server.join().unwrap();
        assert!(
            result.is_ok(),
            "A single transient timeout must be recoverable: {result:?}"
        );
        assert_eq!(result.unwrap(), "3.9.9");
        assert_eq!(requests, 2);
        assert_eq!(client.nso_version().await.unwrap(), "3.9.9");
    }

    #[tokio::test]
    async fn nxapi_error_keeps_only_a_known_code_and_not_remote_response_details() {
        let (base, server) = crate::transport::tests::capture_response(
            400,
            r#"{"error":"invalid_request","error_description":"session_token=PRIVATE","debug_id":"PRIVATE-ID","token":"PRIVATE-TOKEN"}"#,
            &[],
        );
        let client = NxapiAttestationClient::new(
            HttpTransport::new(Default::default()).unwrap(),
            NxapiConfig {
                znca_base_url: base,
                ..Default::default()
            },
        );
        let error = client.nso_version().await.unwrap_err().to_string();
        server.join().unwrap();
        assert!(error.contains("HTTP 400"));
        assert!(error.contains("NXAPI code: invalid_request"));
        assert!(!error.contains("PRIVATE"));
    }

    #[test]
    fn oauth_client_error_does_not_echo_untrusted_description() {
        let response = HttpResponseData {
            status: 401,
            headers: HashMap::new(),
            body: br#"{"error":"invalid_client","error_description":"access_token=PRIVATE"}"#
                .to_vec(),
        };
        let message = oauth_client_authentication_error(&response).unwrap();
        assert!(!message.contains("PRIVATE"));
        assert!(message.contains("invalid_client"));
    }

    #[test]
    fn safe_error_codes_keep_error_categories_and_never_echo_unknown_values() {
        for body in [
            br#"{"error":"session_token_PRIVATE","error_description":"PRIVATE"}"#.to_vec(),
            b"PRIVATE HTML response".to_vec(),
            br#"{"error":{"token":"PRIVATE"}}"#.to_vec(),
        ] {
            let response = HttpResponseData {
                status: 400,
                headers: HashMap::new(),
                body,
            };
            let error = ensure_nxapi_success(&response, "NXAPI /f")
                .unwrap_err()
                .to_string();
            assert!(error.contains("HTTP 400"));
            assert!(!error.contains("PRIVATE"));
            assert!(!error.contains("NXAPI code:"));
        }
        let mut response = HttpResponseData {
            status: 401,
            headers: HashMap::new(),
            body: br#"{"error":"invalid_token","token":"PRIVATE"}"#.to_vec(),
        };
        let error = ensure_nxapi_success(&response, "NXAPI /f").unwrap_err();
        assert!(matches!(error, CoreError::Authentication(_)));
        assert!(error.to_string().contains("NXAPI code: invalid_token"));
        assert!(!error.to_string().contains("PRIVATE"));
        response.status = 429;
        assert!(matches!(
            ensure_nxapi_success(&response, "NXAPI /f"),
            Err(CoreError::RateLimited {
                retry_after_seconds: 60
            })
        ));
    }

    #[tokio::test]
    async fn oauth_and_znca_config_send_the_application_user_agent() {
        let expected = format!("user-agent: Cypas-NSOAlbum/{}", env!("CARGO_PKG_VERSION"));
        let (oauth_url, oauth_server) = crate::transport::tests::capture_request(
            r#"{"access_token":"test-only-token","expires_in":300}"#,
        );
        let (znca_base_url, config_server) =
            crate::transport::tests::capture_request(r#"{"nso_version":"3.8.0"}"#);
        let client = NxapiAttestationClient::new(
            HttpTransport::new(Default::default()).unwrap(),
            NxapiConfig {
                oauth_url,
                znca_base_url,
                ..Default::default()
            },
        );
        client.oauth_token().await.unwrap();
        assert_eq!(client.nso_version().await.unwrap(), "3.8.0");
        for request in [oauth_server.join().unwrap(), config_server.join().unwrap()] {
            assert!(request
                .lines()
                .any(|line| line.eq_ignore_ascii_case(&expected)));
        }
    }

    #[tokio::test]
    async fn short_lived_nxapi_oauth_is_reused_until_expiry_not_a_five_minute_margin() {
        let (url, server) = crate::transport::tests::capture_request(
            r#"{"access_token":"synthetic-short-oauth","expires_in":15}"#,
        );
        let client = NxapiAttestationClient::new(
            HttpTransport::new(Default::default()).unwrap(),
            NxapiConfig {
                oauth_url: url,
                ..Default::default()
            },
        );
        assert_eq!(client.oauth_token().await.unwrap(), "synthetic-short-oauth");
        server.join().unwrap();
        assert_eq!(
            client.oauth_token().await.unwrap(),
            "synthetic-short-oauth",
            "a still-valid short NXAPI OAuth token must not request a second grant",
        );
    }

    #[tokio::test]
    async fn expired_nxapi_oauth_renews_its_own_grant_then_reuses_the_replacement() {
        let (url, server) = crate::transport::tests::capture_request(
            r#"{"access_token":"synthetic-renewed-oauth","expires_in":15}"#,
        );
        let client = NxapiAttestationClient::new(
            HttpTransport::new(Default::default()).unwrap(),
            NxapiConfig {
                oauth_url: url,
                ..Default::default()
            },
        );
        *client.token.lock().await = Some(OAuthToken {
            access_token: "synthetic-expired-oauth".into(),
            refresh_token: Some("synthetic-refresh-grant".into()),
            expires_at: Instant::now() - Duration::from_secs(1),
        });
        assert_eq!(
            client.oauth_token().await.unwrap(),
            "synthetic-renewed-oauth"
        );
        let request = server.join().unwrap();
        let fields: std::collections::HashMap<_, _> =
            url::form_urlencoded::parse(request.split("\r\n\r\n").nth(1).unwrap().as_bytes())
                .into_owned()
                .collect();
        assert_eq!(fields["grant_type"], "refresh_token");
        assert_eq!(fields["refresh_token"], "synthetic-refresh-grant");
        assert_eq!(
            client.oauth_token().await.unwrap(),
            "synthetic-renewed-oauth"
        );
    }

    #[tokio::test]
    async fn rate_limited_oauth_refresh_does_not_fall_back_to_another_grant() {
        let (oauth_url, server) = crate::transport::tests::capture_response(429, "{}", &[]);
        let client = NxapiAttestationClient::new(
            HttpTransport::new(Default::default()).unwrap(),
            NxapiConfig {
                oauth_url,
                ..Default::default()
            },
        );
        *client.token.lock().await = Some(OAuthToken {
            access_token: "expired-test-token".into(),
            refresh_token: Some("test-refresh".into()),
            expires_at: Instant::now() - Duration::from_secs(1),
        });
        let result = client.oauth_token().await;
        server.join().unwrap();
        assert!(matches!(
            result,
            Err(CoreError::RateLimited {
                retry_after_seconds: 60
            })
        ));
    }

    #[test]
    fn uses_current_nxapi_client_identifiers() {
        let config = NxapiConfig::default();

        assert_eq!(config.client_id, "OhFZ3YmNeYnls5Fo-z3BkA");
        assert_eq!(
            config.user_agent,
            format!("Cypas-NSOAlbum/{}", env!("CARGO_PKG_VERSION"))
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

        assert_eq!(
            body,
            json!({
                "token": "id-token",
                "hash_method": 1,
                "na_id": "1234567890",
                "encrypt_token_request": {
                    "url": "https://example.com/login",
                    "parameter": {"naIdToken": "id-token"},
                },
            })
        );
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
        assert_eq!(
            body,
            json!({
                "token": "access-token",
                "hash_method": 2,
                "na_id": "1234567890",
                "coral_user_id": "9876543210",
                "encrypt_token_request": {
                    "url": "https://example.com/token",
                    "parameter": {},
                },
            })
        );
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
