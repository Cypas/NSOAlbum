use std::collections::HashMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use reqwest::{Client, Method, Proxy, Response};
use serde::de::DeserializeOwned;
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use url::Url;

use crate::error::{CoreError, CoreResult};
use crate::sync::CancellationToken;

pub const DEFAULT_MAX_DOWNLOAD_BYTES: u64 = 256 * 1024 * 1024;
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
}

impl Default for TransportConfig {
    fn default() -> Self {
        Self {
            proxy_url: None,
            timeout: Duration::from_secs(30),
            max_download_bytes: DEFAULT_MAX_DOWNLOAD_BYTES,
        }
    }
}

#[derive(Clone)]
pub struct HttpTransport {
    client: Client,
    config: TransportConfig,
    download_user_agent: Option<String>,
}

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
            if std::fs::symlink_metadata(&component_path)?
                .file_type()
                .is_symlink()
            {
                return Err(CoreError::InvalidConfig(
                    "download temporary root is a symbolic link".into(),
                ));
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
        let mut writer = StreamingDownloadWriter::create(
            root,
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
    pub fn new(config: TransportConfig) -> CoreResult<Self> {
        Self::configured(config, reqwest::redirect::Policy::limited(10))
    }

    pub(crate) fn without_redirects(&self) -> CoreResult<Self> {
        let mut transport =
            Self::configured(self.config.clone(), reqwest::redirect::Policy::none())?;
        transport
            .download_user_agent
            .clone_from(&self.download_user_agent);
        Ok(transport)
    }

    fn configured(
        config: TransportConfig,
        redirects: reqwest::redirect::Policy,
    ) -> CoreResult<Self> {
        let mut builder = Client::builder()
            .timeout(config.timeout)
            .redirect(redirects)
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
        Ok(Self {
            client: builder.build()?,
            config,
            download_user_agent: None,
        })
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
        collect_response(request.send().await?).await
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
        collect_response(request.send().await?).await
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
        collect_response(request.send().await?).await
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
        collect_response(request.send().await?).await
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
            result = request.send() => result?,
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
            .public_download_request(url)?
            .send()
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
        Ok(request.send().await?)
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
    use crate::sync::CancellationToken;

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
        let directory = tempfile::tempdir().unwrap();
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
        let directory = tempfile::tempdir().unwrap();
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
        let directory = tempfile::tempdir().unwrap();
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
        let directory = tempfile::tempdir().unwrap();
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
        let parent = tempfile::tempdir().unwrap();
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
