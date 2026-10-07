use std::collections::HashMap;
use std::net::IpAddr;
use std::time::Duration;

use reqwest::{Client, Method, Proxy, Response};
use serde::de::DeserializeOwned;
use serde::Serialize;
use url::Url;

use crate::error::{CoreError, CoreResult};

pub const DEFAULT_MAX_DOWNLOAD_BYTES: u64 = 256 * 1024 * 1024;
const MAX_AVATAR_BYTES: u64 = 4 * 1024 * 1024;

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
}

impl HttpTransport {
    pub fn new(config: TransportConfig) -> CoreResult<Self> {
        let mut builder = Client::builder()
            .timeout(config.timeout)
            .user_agent("SquidAlbum/0.1.12");
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
        })
    }

    pub async fn get_json<T: DeserializeOwned>(
        &self,
        url: &str,
        headers: &[(&str, String)],
    ) -> CoreResult<T> {
        let response = self.send(Method::GET, url, headers, None).await?;
        Ok(response.error_for_status()?.json().await?)
    }

    pub async fn post_json<B: Serialize + ?Sized, T: DeserializeOwned>(
        &self,
        url: &str,
        headers: &[(&str, String)],
        body: &B,
    ) -> CoreResult<T> {
        let mut request = self.client.post(url).json(body);
        for (name, value) in headers {
            request = request.header(*name, value);
        }
        Ok(request.send().await?.error_for_status()?.json().await?)
    }

    pub async fn post_form<B: Serialize + ?Sized, T: DeserializeOwned>(
        &self,
        url: &str,
        headers: &[(&str, String)],
        body: &B,
    ) -> CoreResult<T> {
        let mut request = self.client.post(url).form(body);
        for (name, value) in headers {
            request = request.header(*name, value);
        }
        Ok(request.send().await?.error_for_status()?.json().await?)
    }

    pub async fn post_bytes(
        &self,
        url: &str,
        headers: &[(&str, String)],
        body: Vec<u8>,
    ) -> CoreResult<Vec<u8>> {
        let mut request = self.client.post(url).body(body);
        for (name, value) in headers {
            request = request.header(*name, value);
        }
        Ok(request
            .send()
            .await?
            .error_for_status()?
            .bytes()
            .await?
            .to_vec())
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
        validate_public_https_url(url)?;
        let mut response = self.client.get(url).send().await?.error_for_status()?;
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
mod tests {
    use super::*;

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
