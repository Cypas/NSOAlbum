use thiserror::Error;

pub type CoreResult<T> = Result<T, CoreError>;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("invalid configuration: {0}")]
    InvalidConfig(String),
    #[error("authentication failed: {0}")]
    Authentication(String),
    #[error("provider failed: {0}")]
    Provider(String),
    #[error("rate limited: retry after {retry_after_seconds} seconds")]
    RateLimited { retry_after_seconds: u64 },
    #[error("unsafe media URL: {0}")]
    UnsafeMediaUrl(String),
    #[error("download is too large: {actual} bytes (limit {limit})")]
    DownloadTooLarge { actual: u64, limit: u64 },
    #[error("download length mismatch: expected {expected}, got {actual}")]
    DownloadLengthMismatch { expected: u64, actual: u64 },
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("network error: {0}")]
    Network(#[from] reqwest::Error),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("URL error: {0}")]
    Url(#[from] url::ParseError),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("task cancelled")]
    Cancelled,
}
