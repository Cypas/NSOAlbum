use std::collections::HashMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use reqwest::{Client, ClientBuilder, Method, Proxy, Response};
use serde::de::DeserializeOwned;
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use url::Url;

use crate::doh;
use crate::error::{CoreError, CoreResult};
use crate::sync::CancellationToken;

pub const DEFAULT_MAX_DOWNLOAD_BYTES: u64 = 256 * 1024 * 1024;
pub(crate) const NXAPI_REQUEST_TIMEOUT: Duration = Duration::from_secs(60);
const DEFAULT_USER_AGENT: &str =
    "Mozilla/5.0 (Linux; Android 14; Pixel 7a) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36";
const MAX_AVATAR_BYTES: u64 = 4 * 1024 * 1024;

pub(crate) fn nintendo_user_agent(nso_version: &str) -> String {
    format!("com.nintendo.znca/{nso_version}(Android/14)")
}

#[derive(Debug, Clone)]
pub struct HttpResponseData {
    pub status: u16,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl HttpResponseData {
    pub fn text(&self) -> CoreResult<String> {
        String::from_utf8(self.body.clone())
            .map_err(|error| CoreError::Provider(format!("response was not UTF-8: {error}")))
    }

    pub fn json<T: DeserializeOwned>(&self) -> CoreResult<T> {
        Ok(serde_json::from_slice(&self.body)?)
    }

    pub fn ensure_success(&self, operation: &str) -> CoreResult<()> {
        if (200..300).contains(&self.status) {
            return Ok(());
        }
        if self.status == 429 {
            return Err(CoreError::RateLimited {
                retry_after_seconds: 60,
            });
        }
        let detail = String::from_utf8_lossy(&self.body);
        Err(CoreError::Provider(format!(
            "{operation} failed with HTTP {}: {}",
            self.status, detail
        )))
    }

    pub(crate) fn ensure_success_redacted(&self, operation: &str) -> CoreResult<()> {
        match self.status {
            200..=299 => Ok(()),
            401 => Err(CoreError::Authentication(format!(
                "{operation} session has expired"
            ))),
            429 => Err(CoreError::RateLimited {
                retry_after_seconds: 60,
            }),
            status => Err(CoreError::Provider(format!(
                "{operation} failed (HTTP {status})"
            ))),
        }
    }
}

#[derive(Debug, Clone)]
pub struct TransportConfig {
    pub proxy_url: Option<String>,
    pub timeout: Duration,
    pub max_download_bytes: u64,
    pub doh_enabled: bool,
}

impl Default for TransportConfig {
    fn default() -> Self {
        Self {
            proxy_url: None,
            timeout: Duration::from_secs(30),
            max_download_bytes: DEFAULT_MAX_DOWNLOAD_BYTES,
            doh_enabled: false,
        }
    }
}

#[derive(Clone)]
pub struct HttpTransport {
    client: Arc<Client>,
    config: TransportConfig,
    download_user_agent: Option<String>,
    follow_redirects: bool,
}

#[derive(Clone, Copy)]
struct DohRequestContext;

#[derive(Debug)]
/// A temporary file created by this transport, never an arbitrary caller-owned path.
///
/// ```compile_fail
/// use squid_album_core::transport::DownloadedMedia;
/// let forged = DownloadedMedia {
///     path: "/someone/else/original.jpg".into(),
///     sha256: "a".repeat(64),
///     size: 1,
/// };
/// ```
///
/// ```compile_fail
/// use squid_album_core::transport::DownloadedMedia;
/// fn replace_owned_path(download: &mut DownloadedMedia) {
///     download.path = "/someone/else/original.jpg".into();
/// }
/// ```
pub struct DownloadedMedia {
    path: PathBuf,
    temporary_root: PathBuf,
    sha256: String,
    size: u64,
    owned: bool,
}

impl DownloadedMedia {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn sha256(&self) -> &str {
        &self.sha256
    }

    pub fn size(&self) -> u64 {
        self.size
    }

    pub(crate) async fn publish_to(&mut self, destination: &Path) -> CoreResult<()> {
        tokio::fs::rename(&self.path, destination).await?;
        self.owned = false;
        Ok(())
    }
}

impl Drop for DownloadedMedia {
    fn drop(&mut self) {
        if self.owned && self.path.parent() == Some(self.temporary_root.as_path()) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

struct StreamingDownloadWriter {
    file: Option<tokio::fs::File>,
    path: PathBuf,
    temporary_root: PathBuf,
    expected_size: Option<u64>,
    limit: u64,
    size: u64,
    hasher: Sha256,
    cancellation: CancellationToken,
    completed: bool,
}

fn is_allowed_android_private_alias(path: &Path, target: &Path) -> bool {
    path == Path::new("/data/user/0") && target == Path::new("/data/data")
}

impl StreamingDownloadWriter {
    async fn create(
        temporary_root: &Path,
        expected_size: Option<u64>,
        limit: u64,
        cancellation: CancellationToken,
    ) -> CoreResult<Self> {
        if let Some(expected) = expected_size {
            validate_size(expected, limit)?;
        }
        tokio::fs::create_dir_all(temporary_root).await?;
        let mut component_path = PathBuf::new();
        for component in temporary_root.components() {
            component_path.push(component);
            if !matches!(
                component,
                std::path::Component::Normal(_) | std::path::Component::CurDir
            ) {
                continue;
            }
            let metadata = std::fs::symlink_metadata(&component_path)?;
            if metadata.file_type().is_symlink() {
                let target = std::fs::canonicalize(&component_path)?;
                if !is_allowed_android_private_alias(&component_path, &target) {
                    return Err(CoreError::InvalidConfig(
                        "download temporary root is a symbolic link".into(),
                    ));
                }
            }
        }
        let temporary_root = temporary_root.canonicalize()?;
        let path = temporary_root.join(format!("{}.part", uuid::Uuid::new_v4()));
        let file = tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .await?;
        Ok(Self {
            file: Some(file),
            path,
            temporary_root,
            expected_size,
            limit,
            size: 0,
            hasher: Sha256::new(),
            cancellation,
            completed: false,
        })
    }

    async fn write_chunk(&mut self, bytes: &[u8]) -> CoreResult<()> {
        if let Err(error) = self.cancellation.check() {
            self.cleanup().await;
            return Err(error);
        }
        let next_size = self.size.saturating_add(bytes.len() as u64);
        if let Err(error) = validate_size(next_size, self.limit) {
            self.cleanup().await;
            return Err(error);
        }
        let write = self
            .file
            .as_mut()
            .expect("streaming writer is active")
            .write_all(bytes);
        tokio::select! {
            _ = self.cancellation.cancelled() => {
                self.cleanup().await;
                Err(CoreError::Cancelled)
            }
            result = write => {
                if let Err(error) = result {
                    self.cleanup().await;
                    return Err(error.into());
                }
                self.size = next_size;
                self.hasher.update(bytes);
                Ok(())
            }
        }
    }

    async fn finish(mut self) -> CoreResult<DownloadedMedia> {
        if let Err(error) = self.cancellation.check() {
            self.cleanup().await;
            return Err(error);
        }
        if let Some(expected) = self.expected_size {
            if expected != self.size {
                let actual = self.size;
                self.cleanup().await;
                return Err(CoreError::DownloadLengthMismatch { expected, actual });
            }
        }
        if let Some(mut file) = self.file.take() {
            if let Err(error) = file.flush().await {
                self.cleanup().await;
                return Err(error.into());
            }
        }
        self.completed = true;
        Ok(DownloadedMedia {
            path: self.path.clone(),
            temporary_root: self.temporary_root.clone(),
            sha256: hex::encode(self.hasher.clone().finalize()),
            size: self.size,
            owned: true,
        })
    }

    async fn cleanup(&mut self) {
        self.file.take();
        let _ = tokio::fs::remove_file(&self.path).await;
        self.completed = true;
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;

    pub async fn download_bytes(root: &Path, bytes: &[u8]) -> DownloadedMedia {
        // This helper writes into a controlled test directory, not a linked
        // input under test. Keep OS temporary aliases out of the fixture.
        std::fs::create_dir_all(root).unwrap();
        let root = root.canonicalize().unwrap();
        let mut writer = StreamingDownloadWriter::create(
            &root,
            Some(bytes.len() as u64),
            DEFAULT_MAX_DOWNLOAD_BYTES,
            CancellationToken::default(),
        )
        .await
        .unwrap();
        writer.write_chunk(bytes).await.unwrap();
        writer.finish().await.unwrap()
    }
}

impl Drop for StreamingDownloadWriter {
    fn drop(&mut self) {
        if !self.completed {
            self.file.take();
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

impl HttpTransport {
    #[cfg(test)]
    pub(crate) fn shares_client(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.client, &other.client)
    }
    pub fn new(config: TransportConfig) -> CoreResult<Self> {
        Self::configured(config, true)
    }

    pub(crate) fn without_redirects(&self) -> CoreResult<Self> {
        let mut transport = Self::configured(self.config.clone(), false)?;
        transport
            .download_user_agent
            .clone_from(&self.download_user_agent);
        Ok(transport)
    }

    pub(crate) fn with_timeout(&self, timeout: Duration) -> CoreResult<Self> {
        let mut config = self.config.clone();
        config.timeout = timeout;
        let mut transport = Self::configured(config, self.follow_redirects)?;
        transport
            .download_user_agent
            .clone_from(&self.download_user_agent);
        Ok(transport)
    }

    fn configured(config: TransportConfig, follow_redirects: bool) -> CoreResult<Self> {
        let builder = client_builder(&config, follow_redirects)?;
        Ok(Self {
            client: Arc::new(builder.build()?),
            config,
            download_user_agent: None,
            follow_redirects,
        })
    }

    fn client_with_resolved_addresses(
        &self,
        host: &str,
        addresses: &[std::net::SocketAddr],
    ) -> CoreResult<Client> {
        if addresses.is_empty() {
            return Err(CoreError::InvalidConfig(
                "resolved host has no addresses".into(),
            ));
        }
        Ok(client_builder(&self.config, self.follow_redirects)?
            .resolve_to_addrs(host, addresses)
            .build()?)
    }

    fn client_with_doh_bootstrap(&self) -> CoreResult<Client> {
        Ok(client_builder(&self.config, self.follow_redirects)?
            .resolve_to_addrs(doh::doh_host(), doh::bootstrap_addresses())
            .build()?)
    }

    /// Applies only to public media/avatar downloads on this transport clone.
    pub(crate) fn with_nso_downloads(mut self, nso_version: &str) -> Self {
        self.download_user_agent = Some(nintendo_user_agent(nso_version));
        self
    }

    fn public_download_request(&self, url: &str) -> CoreResult<reqwest::RequestBuilder> {
        validate_public_https_url(url)?;
        Ok(self.client.get(url).header(
            "User-Agent",
            self.download_user_agent
                .as_deref()
                .unwrap_or(DEFAULT_USER_AGENT),
        ))
    }

    pub async fn get_json<T: DeserializeOwned>(
        &self,
        url: &str,
        headers: &[(&str, String)],
    ) -> CoreResult<T> {
        let response = self.send(Method::GET, url, headers, None).await?;
        let response = collect_response(response).await?;
        response.ensure_success_redacted("JSON request")?;
        response.json()
    }

    pub async fn post_json<B: Serialize + ?Sized, T: DeserializeOwned>(
        &self,
        url: &str,
        headers: &[(&str, String)],
        body: &B,
    ) -> CoreResult<T> {
        let response = self.post_json_raw(url, headers, body).await?;
        response.ensure_success_redacted("JSON request")?;
        response.json()
    }

    pub async fn post_form<B: Serialize + ?Sized, T: DeserializeOwned>(
        &self,
        url: &str,
        headers: &[(&str, String)],
        body: &B,
    ) -> CoreResult<T> {
        let response = self.post_form_raw(url, headers, body).await?;
        response.ensure_success_redacted("Form request")?;
        response.json()
    }

    pub async fn post_bytes(
        &self,
        url: &str,
        headers: &[(&str, String)],
        body: Vec<u8>,
    ) -> CoreResult<Vec<u8>> {
        let response = self.post_bytes_raw(url, headers, body).await?;
        response.ensure_success_redacted("Binary request")?;
        Ok(response.body)
    }

    pub async fn post_json_raw<B: Serialize + ?Sized>(
        &self,
        url: &str,
        headers: &[(&str, String)],
        body: &B,
    ) -> CoreResult<HttpResponseData> {
        let mut request = self.client.post(url).json(body);
        for (name, value) in headers {
            request = request.header(*name, value);
        }
        collect_response(self.execute(request).await?).await
    }

    pub async fn post_form_raw<B: Serialize + ?Sized>(
        &self,
        url: &str,
        headers: &[(&str, String)],
        body: &B,
    ) -> CoreResult<HttpResponseData> {
        let mut request = self.client.post(url).form(body);
        for (name, value) in headers {
            request = request.header(*name, value);
        }
        collect_response(self.execute(request).await?).await
    }

    pub async fn post_bytes_raw(
        &self,
        url: &str,
        headers: &[(&str, String)],
        body: Vec<u8>,
    ) -> CoreResult<HttpResponseData> {
        let mut request = self.client.post(url).body(body);
        for (name, value) in headers {
            request = request.header(*name, value);
        }
        collect_response(self.execute(request).await?).await
    }

    pub async fn get_raw(
        &self,
        url: &str,
        headers: &[(&str, String)],
    ) -> CoreResult<HttpResponseData> {
        let mut request = self.client.get(url);
        for (name, value) in headers {
            request = request.header(*name, value);
        }
        collect_response(self.execute(request).await?).await
    }

    pub async fn download_media(
        &self,
        url: &str,
        expected_size: Option<u64>,
    ) -> CoreResult<Vec<u8>> {
        self.download_public_bytes(url, expected_size, self.config.max_download_bytes)
            .await
    }

    pub async fn download_media_to_file(
        &self,
        url: &str,
        expected_size: Option<u64>,
        temporary_root: &Path,
        cancellation: &CancellationToken,
    ) -> CoreResult<DownloadedMedia> {
        let request = self.public_download_request(url)?;
        let mut response = tokio::select! {
            _ = cancellation.cancelled() => return Err(CoreError::Cancelled),
            result = self.execute(request) => result?,
        };
        if response.status().as_u16() == 429 {
            return Err(CoreError::RateLimited {
                retry_after_seconds: 60,
            });
        }
        response = response.error_for_status()?;
        let response_length = response.content_length();
        if let Some(length) = response_length {
            validate_size(length, self.config.max_download_bytes)?;
        }
        let mut writer = StreamingDownloadWriter::create(
            temporary_root,
            expected_size.or(response_length),
            self.config.max_download_bytes,
            cancellation.clone(),
        )
        .await?;
        while let Some(chunk) = tokio::select! {
            _ = cancellation.cancelled() => {
                writer.cleanup().await;
                return Err(CoreError::Cancelled);
            }
            result = response.chunk() => result?,
        } {
            writer.write_chunk(&chunk).await?;
        }
        writer.finish().await
    }

    pub async fn download_avatar(&self, url: &str) -> CoreResult<Vec<u8>> {
        self.download_public_bytes(url, None, MAX_AVATAR_BYTES)
            .await
    }

    async fn download_public_bytes(
        &self,
        url: &str,
        expected_size: Option<u64>,
        limit: u64,
    ) -> CoreResult<Vec<u8>> {
        let mut response = self
            .execute(self.public_download_request(url)?)
            .await?
            .error_for_status()?;
        if let Some(length) = response.content_length() {
            validate_size(length, limit)?;
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            let next_size = bytes.len() as u64 + chunk.len() as u64;
            validate_size(next_size, limit)?;
            bytes.extend_from_slice(&chunk);
        }
        let actual = bytes.len() as u64;
        validate_size(actual, limit)?;
        if let Some(expected) = expected_size {
            if expected != actual {
                return Err(CoreError::DownloadLengthMismatch { expected, actual });
            }
        }
        Ok(bytes)
    }

    async fn send(
        &self,
        method: Method,
        url: &str,
        headers: &[(&str, String)],
        body: Option<Vec<u8>>,
    ) -> CoreResult<Response> {
        let mut request = self.client.request(method, url);
        for (name, value) in headers {
            request = request.header(*name, value);
        }
        if let Some(body) = body {
            request = request.body(body);
        }
        self.execute(request).await
    }

    async fn execute(&self, request: reqwest::RequestBuilder) -> CoreResult<Response> {
        let request = request.build()?;
        let stage = request_stage(request.url());
        let url = diagnostic_endpoint(request.url());
        let proxy = if self
            .config
            .proxy_url
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty())
        {
            "explicit"
        } else {
            "default"
        };
        let started = std::time::Instant::now();
        let request_host = request.url().host_str();
        let target_host = request_host.filter(|host| doh::is_allowed_nxapi_host(host));
        let mut doh_context = None;
        let client = if let Some(host) = target_host.filter(|_| self.config.doh_enabled) {
            let (client, used_doh) = self
                .resolve_nxapi_client(
                    host,
                    request.url().port_or_known_default().unwrap_or(443),
                    stage,
                    &url,
                    proxy,
                    started,
                )
                .await?
                .unwrap_or_else(|| (self.client.as_ref().clone(), None));
            doh_context = used_doh;
            client
        } else {
            crate::diagnostics::doh_resolution(
                self.config.doh_enabled,
                doh_log_host_class(request_host),
                "system",
                0,
                0,
                "system",
                "skipped",
                if target_host.is_some() {
                    "not_attempted"
                } else {
                    "not_applicable"
                },
            );
            self.client.as_ref().clone()
        };
        match client.execute(request).await {
            Ok(response) => {
                if !response.status().is_success() {
                    crate::diagnostics::network_failure(&CoreError::NetworkRequest {
                        stage,
                        reason: "http_error",
                        proxy,
                        elapsed_ms: started.elapsed().as_millis().min(u64::MAX as u128) as u64,
                        url,
                        code_kind: "http",
                        code: response.status().as_u16().to_string(),
                    });
                }
                Ok(response)
            }
            Err(error) => {
                let reason = network_failure_reason(&error, doh_context.is_some());
                let elapsed_ms = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
                // Never serialize reqwest's remote URL, nested connector text,
                // headers or payload. Both the log and Bridge retain only
                // fixed classifications and bounded numeric timing.
                let (code_kind, code) = network_failure_code(&error);
                let failure = CoreError::NetworkRequest {
                    stage,
                    reason,
                    proxy,
                    elapsed_ms,
                    url,
                    code_kind,
                    code,
                };
                crate::diagnostics::network_failure(&failure);
                Err(failure)
            }
        }
    }

    async fn resolve_nxapi_client(
        &self,
        host: &str,
        port: u16,
        stage: &'static str,
        url: &str,
        proxy: &'static str,
        started: std::time::Instant,
    ) -> CoreResult<Option<(Client, Option<DohRequestContext>)>> {
        let Some(_) = doh::nxapi_host_class(host) else {
            return Ok(None);
        };
        let system_started = std::time::Instant::now();
        let system = doh::system_lookup(host, port).await;
        let system_duration = system_started.elapsed().as_millis().min(u64::MAX as u128) as u64;
        match system {
            Ok(addresses) => {
                crate::diagnostics::doh_resolution(
                    self.config.doh_enabled,
                    "nxapi",
                    "system",
                    1,
                    system_duration,
                    "system",
                    "success",
                    "none",
                );
                Ok(Some((
                    self.client_with_resolved_addresses(host, &addresses)?,
                    None,
                )))
            }
            Err(system_error) if !system_error.allows_doh_fallback() => {
                crate::diagnostics::doh_resolution(
                    self.config.doh_enabled,
                    "nxapi",
                    "system",
                    1,
                    system_duration,
                    "system",
                    "failure",
                    system_error.as_str(),
                );
                let failure = doh::combined_dns_error(
                    stage,
                    url,
                    proxy,
                    started.elapsed().as_millis().min(u64::MAX as u128) as u64,
                    system_error,
                    doh::DnsFailureClass::NotAttempted,
                );
                crate::diagnostics::network_failure(&failure);
                Err(failure)
            }
            Err(system_error) => {
                crate::diagnostics::doh_resolution(
                    self.config.doh_enabled,
                    "nxapi",
                    "system",
                    1,
                    system_duration,
                    "system",
                    "failure",
                    system_error.as_str(),
                );
                let doh_started = std::time::Instant::now();
                let (doh_client, bootstrap) = self.doh_client().await?;
                let doh_result =
                    doh::resolve_via_doh(&doh_client, doh::DOH_ENDPOINT, host, port).await;
                let doh_duration = doh_started.elapsed().as_millis().min(u64::MAX as u128) as u64;
                match doh_result {
                    Ok(addresses) => {
                        crate::diagnostics::doh_resolution(
                            self.config.doh_enabled,
                            "nxapi",
                            "cloudflare_doh",
                            2,
                            doh_duration,
                            if bootstrap { "bootstrap_ip" } else { "system" },
                            "success",
                            "none",
                        );
                        Ok(Some((
                            self.client_with_resolved_addresses(host, &addresses)?,
                            Some(DohRequestContext),
                        )))
                    }
                    Err(doh_error) => {
                        crate::diagnostics::doh_resolution(
                            self.config.doh_enabled,
                            "nxapi",
                            "cloudflare_doh",
                            2,
                            doh_duration,
                            if bootstrap { "bootstrap_ip" } else { "system" },
                            "failure",
                            doh_error.as_str(),
                        );
                        let failure = doh::combined_dns_error(
                            stage,
                            url,
                            proxy,
                            started.elapsed().as_millis().min(u64::MAX as u128) as u64,
                            system_error,
                            doh_error,
                        );
                        crate::diagnostics::network_failure(&failure);
                        Err(failure)
                    }
                }
            }
        }
    }

    async fn doh_client(&self) -> CoreResult<(Client, bool)> {
        if self
            .config
            .proxy_url
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty())
        {
            return Ok((self.client.as_ref().clone(), false));
        }
        match doh::system_lookup(doh::doh_host(), 443).await {
            Ok(addresses) => Ok((
                client_builder(&self.config, self.follow_redirects)?
                    .resolve_to_addrs(doh::doh_host(), &addresses)
                    .build()?,
                false,
            )),
            Err(_) => Ok((self.client_with_doh_bootstrap()?, true)),
        }
    }
}

fn doh_log_host_class(host: Option<&str>) -> &'static str {
    if host.is_some_and(doh::is_allowed_nxapi_host) {
        "nxapi"
    } else {
        "other"
    }
}

fn network_failure_reason(error: &reqwest::Error, doh_used: bool) -> &'static str {
    if doh_used {
        "doh_request_failed"
    } else if error.is_timeout() {
        "timeout"
    } else if error.is_connect() {
        "connect_failed"
    } else if error.is_body() {
        "body_failed"
    } else if error.is_request() {
        "request_failed"
    } else {
        "transport_failed"
    }
}

fn client_builder(config: &TransportConfig, follow_redirects: bool) -> CoreResult<ClientBuilder> {
    let mut builder = Client::builder()
        .timeout(config.timeout)
        .redirect(if follow_redirects {
            reqwest::redirect::Policy::limited(10)
        } else {
            reqwest::redirect::Policy::none()
        })
        .user_agent(DEFAULT_USER_AGENT);
    if let Some(proxy_url) = config.proxy_url.as_deref().filter(|v| !v.trim().is_empty()) {
        let parsed = Url::parse(proxy_url)?;
        if !matches!(parsed.scheme(), "http" | "https") {
            return Err(CoreError::InvalidConfig(
                "proxy URL must use http or https".into(),
            ));
        }
        builder = builder.proxy(Proxy::all(proxy_url)?);
    }
    Ok(builder)
}

fn network_failure_code(error: &reqwest::Error) -> (&'static str, String) {
    if let Some(status) = error.status() {
        return ("http", status.as_u16().to_string());
    }
    let mut source: Option<&(dyn std::error::Error + 'static)> = Some(error);
    while let Some(cause) = source {
        if let Some(code) = cause
            .downcast_ref::<std::io::Error>()
            .and_then(std::io::Error::raw_os_error)
        {
            return ("os", code.to_string());
        }
        source = cause.source();
    }
    ("none", "none".into())
}

fn diagnostic_endpoint(url: &Url) -> String {
    // Endpoint names are useful; arbitrary media/account path segments, query
    // strings, fragments and URL userinfo must never enter runtime logs.
    let path = match (url.host_str(), url.path()) {
        (Some("nxapi-auth.fancy.org.uk"), "/api/oauth/token") => url.path(),
        (
            Some("nxapi-znca-api.fancy.org.uk"),
            "/api/znca/config"
            | "/api/znca/f"
            | "/api/znca/encrypt-request"
            | "/api/znca/decrypt-response",
        ) => url.path(),
        (
            Some("accounts.nintendo.com"),
            "/connect/1.0.0/api/token" | "/connect/1.0.0/api/session_token",
        ) => url.path(),
        (Some("api.accounts.nintendo.com"), "/2.0.0/users/me") => url.path(),
        (
            Some("api-lp1.znc.srv.nintendo.net"),
            "/v4/Account/Login"
            | "/v4/Friend/List"
            | "/v3/Friend/CreateFriendCodeUrl"
            | "/v3/Friend/GetUserByFriendCode"
            | "/v4/FriendRequest/Create"
            | "/v4/Friend/Note/Update"
            | "/v4/User/PlayLog/Show"
            | "/v4/Game/GetWebServiceToken"
            | "/v4/Media/List",
        ) => url.path(),
        (Some("api.lp1.av5ja.srv.nintendo.net"), "/api/bullet_tokens" | "/api/graphql") => {
            url.path()
        }
        _ => "/<redacted-path>",
    };
    format!("{}{path}", url.origin().ascii_serialization())
}

fn request_stage(url: &Url) -> &'static str {
    match (url.host_str(), url.path()) {
        (Some("nxapi-auth.fancy.org.uk"), _) => "nxapi_oauth",
        (Some("nxapi-znca-api.fancy.org.uk"), "/api/znca/config") => "nxapi_config",
        (Some("nxapi-znca-api.fancy.org.uk"), "/api/znca/f") => "nxapi_attestation",
        (Some("nxapi-znca-api.fancy.org.uk"), "/api/znca/encrypt-request") => "nxapi_encrypt",
        (Some("nxapi-znca-api.fancy.org.uk"), "/api/znca/decrypt-response") => "nxapi_decrypt",
        (Some("nxapi-znca-api.fancy.org.uk"), _) => "nxapi",
        (Some("accounts.nintendo.com"), _) => "nintendo_oauth",
        (Some("api.accounts.nintendo.com"), _) => "nintendo_profile",
        (Some("api-lp1.znc.srv.nintendo.net"), _) => "coral",
        (Some("api.lp1.av5ja.srv.nintendo.net"), _) => "splatnet",
        _ => "http_request",
    }
}

fn validate_size(size: u64, limit: u64) -> CoreResult<()> {
    if size > limit {
        return Err(CoreError::DownloadTooLarge {
            actual: size,
            limit,
        });
    }
    Ok(())
}

async fn collect_response(response: Response) -> CoreResult<HttpResponseData> {
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|value| (name.as_str().to_ascii_lowercase(), value.to_owned()))
        })
        .collect();
    let body = response.bytes().await?.to_vec();
    Ok(HttpResponseData {
        status,
        headers,
        body,
    })
}

pub fn validate_public_https_url(raw: &str) -> CoreResult<Url> {
    let url = Url::parse(raw)?;
    if url.scheme() != "https" || !url.username().is_empty() || url.password().is_some() {
        return Err(CoreError::UnsafeMediaUrl(raw.into()));
    }
    if url.port_or_known_default() != Some(443) {
        return Err(CoreError::UnsafeMediaUrl(raw.into()));
    }
    let host = url
        .host_str()
        .ok_or_else(|| CoreError::UnsafeMediaUrl(raw.into()))?
        .trim_end_matches('.')
        .to_ascii_lowercase();
    if host.parse::<IpAddr>().is_ok()
        || host == "localhost"
        || !host.contains('.')
        || [
            ".localhost",
            ".local",
            ".localdomain",
            ".internal",
            ".lan",
            ".home",
        ]
        .iter()
        .any(|suffix| host.ends_with(suffix))
    {
        return Err(CoreError::UnsafeMediaUrl(raw.into()));
    }
    Ok(url)
}

#[cfg(test)]
pub(crate) mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;

    use super::*;

    #[test]
    fn logged_endpoints_retain_known_api_routes_but_never_url_credentials_or_private_paths() {
        for (raw, expected) in [
            (
                "https://user:password@nxapi-znca-api.fancy.org.uk/api/znca/encrypt-request?token=secret#private",
                "https://nxapi-znca-api.fancy.org.uk/api/znca/encrypt-request",
            ),
            (
                "https://api-lp1.znc.srv.nintendo.net/v4/User/PlayLog/Show?user=private",
                "https://api-lp1.znc.srv.nintendo.net/v4/User/PlayLog/Show",
            ),
            (
                "https://media.example.invalid/private-account/private-media.jpg?signature=secret",
                "https://media.example.invalid/<redacted-path>",
            ),
            (
                "https://nxapi-auth.fancy.org.uk/unrecognised/private-account?token=secret",
                "https://nxapi-auth.fancy.org.uk/<redacted-path>",
            ),
        ] {
            assert_eq!(diagnostic_endpoint(&Url::parse(raw).unwrap()), expected);
        }
    }
    use crate::sync::CancellationToken;

    #[test]
    fn transport_clones_reuse_the_same_http_client_lifetime() {
        let transport = HttpTransport::new(Default::default()).unwrap();
        let clone = transport.clone();
        assert!(Arc::ptr_eq(&transport.client, &clone.client));
    }

    #[test]
    fn doh_is_default_off_and_preserved_by_transport_clones() {
        let config = TransportConfig::default();
        assert!(!config.doh_enabled);
        let transport = HttpTransport::new(TransportConfig {
            doh_enabled: true,
            ..config
        })
        .unwrap();
        assert!(transport.config.doh_enabled);
        assert!(
            transport
                .with_timeout(Duration::from_secs(1))
                .unwrap()
                .config
                .doh_enabled
        );
        assert!(transport.without_redirects().unwrap().config.doh_enabled);
    }

    #[test]
    fn failures_after_doh_resolution_are_marked_to_stop_the_nxapi_retry_wrapper() {
        let error = Client::new().get("not a URL").build().unwrap_err();
        assert_eq!(network_failure_reason(&error, false), "transport_failed");
        assert_eq!(network_failure_reason(&error, true), "doh_request_failed");
    }

    #[test]
    fn doh_log_host_class_is_other_for_non_nxapi_hosts() {
        assert_eq!(doh_log_host_class(None), "other");
        assert_eq!(doh_log_host_class(Some("example.com")), "other");
        assert_eq!(doh_log_host_class(Some("nxapi-auth.fancy.org.uk")), "nxapi");
    }

    pub(crate) fn capture_request(body: &'static str) -> (String, std::thread::JoinHandle<String>) {
        capture_response(200, body, &[])
    }

    pub(crate) fn capture_response(
        status: u16,
        body: &'static str,
        response_headers: &'static [(&str, &str)],
    ) -> (String, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let deadline = std::time::Instant::now() + Duration::from_secs(10);
            let mut connection = loop {
                match listener.accept() {
                    Ok((connection, _)) => break connection,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(
                            std::time::Instant::now() < deadline,
                            "request was never sent"
                        );
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("failed to accept request: {error}"),
                }
            };
            connection.set_nonblocking(false).unwrap();
            connection
                .set_read_timeout(Some(Duration::from_secs(10)))
                .unwrap();
            let mut request = Vec::new();
            let mut buffer = [0_u8; 1024];
            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                let length = connection.read(&mut buffer).unwrap();
                assert!(length > 0, "connection closed before request headers");
                request.extend_from_slice(&buffer[..length]);
                assert!(
                    request.len() <= 64 * 1024,
                    "request headers exceeded test limit"
                );
            }
            let header_end = request
                .windows(4)
                .position(|bytes| bytes == b"\r\n\r\n")
                .unwrap()
                + 4;
            let headers = String::from_utf8(request[..header_end].to_vec()).unwrap();
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            while request.len() < header_end + content_length {
                let length = connection.read(&mut buffer).unwrap();
                assert!(length > 0, "connection closed before request body");
                request.extend_from_slice(&buffer[..length]);
            }
            write!(
                connection,
                "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{}Connection: close\r\n\r\n{}",
                body.len(),
                response_headers.iter().map(|(key, value)| format!("{key}: {value}\r\n")).collect::<String>(),
                body
            )
            .unwrap();
            String::from_utf8(request).unwrap()
        });
        (url, server)
    }

    #[tokio::test]
    async fn timed_out_nxapi_request_keeps_stage_and_safe_cause_without_url_or_credentials() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut bytes = [0; 1024];
            let _ = stream.read(&mut bytes);
            std::thread::sleep(Duration::from_millis(250));
        });
        let transport = HttpTransport {
            client: Arc::new(
                Client::builder()
                    .no_proxy()
                    .resolve("nxapi-auth.fancy.org.uk", address)
                    .timeout(Duration::from_millis(100))
                    .build()
                    .unwrap(),
            ),
            config: TransportConfig::default(),
            download_user_agent: None,
            follow_redirects: true,
        };
        let error = transport
            .post_form_raw(
                &format!(
                    "http://nxapi-auth.fancy.org.uk:{}/api/oauth/token?private=query",
                    address.port()
                ),
                &[("Authorization", "Bearer private-bearer".into())],
                &[("refresh_token", "private-token")],
            )
            .await
            .unwrap_err();
        server.join().unwrap();
        let message = error.to_string();
        assert!(message.contains("stage=nxapi_oauth"), "{message}");
        assert!(message.contains("reason=timeout"), "{message}");
        assert!(message.contains("proxy=default"), "{message}");
        assert!(
            message.contains(&format!(
                "url=http://nxapi-auth.fancy.org.uk:{}/api/oauth/token",
                address.port()
            )),
            "{message}"
        );
        assert!(message.contains("code_kind=none code=none"), "{message}");
        for private in ["private", "Bearer", "refresh_token", "?"] {
            assert!(!message.contains(private), "{message}");
            assert!(!format!("{error:?}").contains(private));
        }
    }

    #[tokio::test]
    async fn authentication_json_preserves_rate_limits_without_echoing_remote_secrets() {
        let (url, server) = capture_response(429, r#"{"secret":"not-for-errors"}"#, &[]);
        let transport = HttpTransport::new(Default::default()).unwrap();
        let result = transport
            .post_json::<_, serde_json::Value>(&url, &[], &serde_json::json!({}))
            .await;
        server.join().unwrap();
        assert!(matches!(
            result,
            Err(CoreError::RateLimited {
                retry_after_seconds: 60
            })
        ));
        let (url, server) = capture_response(500, r#"{"secret":"not-for-errors"}"#, &[]);
        let result = transport
            .post_json::<_, serde_json::Value>(&url, &[], &serde_json::json!({}))
            .await;
        server.join().unwrap();
        assert!(!result.unwrap_err().to_string().contains("not-for-errors"));
    }

    #[tokio::test]
    async fn account_transport_never_follows_cookie_bearing_redirects() {
        let (url, server) =
            capture_response(302, "", &[("Location", "https://evil.example/collect")]);
        let transport = HttpTransport::new(Default::default())
            .unwrap()
            .without_redirects()
            .unwrap();
        let response = transport
            .get_raw(&url, &[("Cookie", "_gtoken=test-only".into())])
            .await
            .unwrap();
        assert_eq!(response.status, 302);
        assert!(server.join().unwrap().contains("cookie: _gtoken=test-only"));
    }

    #[tokio::test]
    async fn streaming_writer_hashes_chunks_without_buffering_the_whole_media() {
        let directory = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let token = CancellationToken::default();
        let mut writer = StreamingDownloadWriter::create(directory.path(), Some(6), 8, token)
            .await
            .unwrap();

        writer.write_chunk(b"abc").await.unwrap();
        writer.write_chunk(b"def").await.unwrap();
        let download = writer.finish().await.unwrap();

        assert_eq!(download.size(), 6);
        assert_eq!(
            download.sha256(),
            "bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721"
        );
        assert_eq!(tokio::fs::read(download.path()).await.unwrap(), b"abcdef");
    }

    #[tokio::test]
    async fn streaming_writer_removes_part_on_limit_error_or_cancellation() {
        let directory = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let token = CancellationToken::default();
        let mut too_large =
            StreamingDownloadWriter::create(directory.path(), None, 4, token.clone())
                .await
                .unwrap();
        let oversized_path = too_large.path.clone();

        assert!(matches!(
            too_large.write_chunk(b"12345").await,
            Err(CoreError::DownloadTooLarge {
                actual: 5,
                limit: 4
            })
        ));
        assert!(!oversized_path.exists());

        let mut cancelled =
            StreamingDownloadWriter::create(directory.path(), None, 8, token.clone())
                .await
                .unwrap();
        let cancelled_path = cancelled.path.clone();
        token.cancel();
        assert!(matches!(
            cancelled.write_chunk(b"1").await,
            Err(CoreError::Cancelled)
        ));
        assert!(!cancelled_path.exists());
    }

    #[tokio::test]
    async fn streaming_writer_rejects_length_mismatch_and_removes_part() {
        let directory = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let mut writer = StreamingDownloadWriter::create(
            directory.path(),
            Some(5),
            8,
            CancellationToken::default(),
        )
        .await
        .unwrap();
        let path = writer.path.clone();
        writer.write_chunk(b"1234").await.unwrap();

        assert!(matches!(
            writer.finish().await,
            Err(CoreError::DownloadLengthMismatch {
                expected: 5,
                actual: 4
            })
        ));
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn completed_part_is_removed_when_download_result_is_dropped() {
        let directory = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let mut writer = StreamingDownloadWriter::create(
            directory.path(),
            Some(4),
            8,
            CancellationToken::default(),
        )
        .await
        .unwrap();
        writer.write_chunk(b"data").await.unwrap();
        let download = writer.finish().await.unwrap();
        let path = download.path().to_path_buf();

        drop(download);

        assert!(!path.exists());
    }

    #[tokio::test]
    async fn review_fix1_r2_symbolic_temporary_root_is_rejected_without_deleting_other_files() {
        let parent = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let target = parent.path().join("target");
        std::fs::create_dir_all(&target).unwrap();
        let sentinel = target.join("unowned.jpg");
        std::fs::write(&sentinel, b"not a transport temporary").unwrap();
        let linked = parent.path().join("linked");
        #[cfg(windows)]
        std::os::windows::fs::symlink_dir(&target, &linked).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &linked).unwrap();
        assert!(
            StreamingDownloadWriter::create(&linked, Some(1), 4, CancellationToken::default())
                .await
                .is_err()
        );
        assert_eq!(
            std::fs::read(&sentinel).unwrap(),
            b"not a transport temporary"
        );
        assert_eq!(std::fs::read_dir(&target).unwrap().count(), 1);
    }

    #[test]
    fn android_private_storage_alias_is_allowed_only_for_the_known_package_root() {
        assert!(is_allowed_android_private_alias(
            Path::new("/data/user/0"),
            Path::new("/data/data"),
        ));
        assert!(!is_allowed_android_private_alias(
            Path::new("/data/user/0"),
            Path::new("/storage/emulated/0"),
        ));
        assert!(!is_allowed_android_private_alias(
            Path::new("/tmp/link"),
            Path::new("/tmp/target"),
        ));
    }

    #[tokio::test]
    async fn unspecified_requests_send_browser_fallback_without_overriding_protocol_headers() {
        let transport = HttpTransport::new(Default::default())
            .unwrap()
            .with_nso_downloads("3.8.0");
        for (headers, expected) in [
            (
                vec![],
                "Mozilla/5.0 (Linux; Android 14; Pixel 7a) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36",
            ),
            (
                vec![("User-Agent", "NASDKAPI; Android".into())],
                "NASDKAPI; Android",
            ),
        ] {
            let (url, server) = capture_request("{}");
            transport.get_raw(&url, &headers).await.unwrap();
            let request = server.join().unwrap();
            assert!(
                request
                    .lines()
                    .any(|line| line.eq_ignore_ascii_case(&format!("user-agent: {expected}"))),
                "unexpected request headers: {request}"
            );
        }
    }

    #[test]
    fn nintendo_download_requests_use_nso_version_without_changing_other_clones() {
        let transport = HttpTransport::new(Default::default()).unwrap();
        let first_account = transport.clone().with_nso_downloads("3.8.0");
        let second_account = transport.clone().with_nso_downloads("3.9.1");
        for (scoped, expected) in [
            (&first_account, "com.nintendo.znca/3.8.0(Android/14)"),
            (&second_account, "com.nintendo.znca/3.9.1(Android/14)"),
            (
                &transport,
                "Mozilla/5.0 (Linux; Android 14; Pixel 7a) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36",
            ),
        ] {
            for url in [
                "https://example.com/video.mp4",
                "https://example.com/avatar.png",
            ] {
                let request = scoped.public_download_request(url).unwrap().build().unwrap();
                assert_eq!(request.headers()["user-agent"], expected);
                assert!(!request.headers().contains_key("authorization"));
                assert!(!request.headers().contains_key("cookie"));
            }
            assert!(scoped.public_download_request("http://127.0.0.1/private").is_err());
        }
    }

    #[test]
    fn rejects_local_media_urls() {
        assert!(validate_public_https_url("http://example.com/a.jpg").is_err());
        assert!(validate_public_https_url("https://localhost/a.jpg").is_err());
        assert!(validate_public_https_url("https://192.168.1.2/a.jpg").is_err());
    }

    #[test]
    fn accepts_public_https_urls() {
        assert!(validate_public_https_url("https://example.com/a.jpg").is_ok());
    }

    #[test]
    fn preserves_complete_error_response() {
        let detail = format!("start-{}-end", "x".repeat(1_000));
        let response = HttpResponseData {
            status: 400,
            headers: HashMap::new(),
            body: detail.as_bytes().to_vec(),
        };

        let error = response.ensure_success("test request").unwrap_err();
        let message = error.to_string();
        assert!(message.contains(&detail));
        assert!(message.ends_with("-end"));
    }

    #[test]
    fn normalizes_rate_limit_retry_to_one_minute() {
        let response = HttpResponseData {
            status: 429,
            headers: HashMap::from([("retry-after".into(), "900".into())]),
            body: Vec::new(),
        };

        let error = response.ensure_success("test request").unwrap_err();
        assert!(matches!(
            error,
            CoreError::RateLimited {
                retry_after_seconds: 60
            }
        ));
    }
}
