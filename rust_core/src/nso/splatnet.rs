use super::account_tools::{coral_call, ensure_response, CORAL_ORIGIN};
use super::session::AuthenticatedCoralSession;
use super::AttestationService;
use crate::error::{CoreError, CoreResult};
use crate::models::SeedExportPayload;
use crate::models::SplatNetWebSession;
use crate::transport::HttpTransport;
use base64::{
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD},
    Engine,
};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};

const ORIGIN: &str = "https://api.lp1.av5ja.srv.nintendo.net";

#[derive(Clone)]
pub(crate) struct SplatNetSession {
    web: SplatNetWebSession,
    bullet: Option<String>,
    version: Option<String>,
    bullet_expires_at: Option<DateTime<Utc>>,
}

impl From<SplatNetWebSession> for SplatNetSession {
    fn from(web: SplatNetWebSession) -> Self {
        Self {
            web,
            bullet: None,
            version: None,
            bullet_expires_at: None,
        }
    }
}

impl SplatNetSession {
    pub(crate) fn reusable_web(&self, now: DateTime<Utc>) -> bool {
        super::token_expiry::reusable(self.web.expires_at, now)
    }

    pub(crate) fn reusable_bullet(&self, now: DateTime<Utc>) -> bool {
        self.bullet.is_some()
            && self.version.is_some()
            && self
                .bullet_expires_at
                .is_some_and(|expiry| super::token_expiry::reusable(expiry, now))
    }
}

/// A rejection retires the credential used by that endpoint, not its parents.
/// Returning false leaves unrelated authentication failures to their owner.
pub(crate) fn retire_rejected_credential(
    cache: &mut Option<SplatNetSession>,
    error: &CoreError,
) -> bool {
    let CoreError::Authentication(code) = error else {
        return false;
    };
    match code.as_str() {
        "splatnet_bullet_token_invalid" => {
            if let Some(session) = cache.as_mut() {
                session.bullet = None;
                session.bullet_expires_at = None;
            }
        }
        "splatnet_game_web_token_invalid (HTTP 401)" => *cache = None,
        _ => return false,
    }
    true
}

#[derive(Clone, Copy)]
pub(crate) enum Query {
    Friends,
    Latest,
    Gear,
}
impl Query {
    fn hash(self) -> &'static str {
        match self {
            Self::Friends => "ea1297e9bb8e52404f52d89ac821e1d73b726ceef2fd9cc8d6b38ab253428fb3",
            Self::Latest => "b24d22fd6cb251c515c2b90044039698aa27bc1fab15801d83014d919cd45780",
            Self::Gear => "45a4c343d973864f7bb9e9efac404182be1d48cf2181619505e9b7cd3b56a6e8",
        }
    }
}

pub(crate) fn game_token_parameter(coral_token: &str) -> Value {
    json!({"id":4834290508791808_u64, "registrationToken":coral_token,
        "requestId":"", "f":"", "timestamp":0})
}

pub(crate) async fn web_session<A: AttestationService>(
    transport: &HttpTransport,
    attestation: &A,
    auth: &AuthenticatedCoralSession,
    cache: &mut Option<SplatNetSession>,
) -> CoreResult<SplatNetWebSession> {
    web_session_at(
        transport,
        attestation,
        auth,
        cache,
        &format!("{CORAL_ORIGIN}/v4/Game/GetWebServiceToken"),
    )
    .await
}

async fn web_session_at<A: AttestationService>(
    transport: &HttpTransport,
    attestation: &A,
    auth: &AuthenticatedCoralSession,
    cache: &mut Option<SplatNetSession>,
    url: &str,
) -> CoreResult<SplatNetWebSession> {
    if let Some(session) = cache.as_ref().filter(|v| v.reusable_web(Utc::now())) {
        return Ok(session.web.clone());
    }
    let result = coral_call(
        transport,
        attestation,
        &auth.session,
        url,
        game_token_parameter(&auth.session.access_token),
        2,
    )
    .await?;
    let token = result
        .pointer("/result/accessToken")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| CoreError::Provider("splatnet_response_invalid".into()))?;
    validate_cookie_token(token)?;
    let expires = result
        .pointer("/result/expiresIn")
        .and_then(Value::as_i64)
        .unwrap_or(10800)
        .clamp(1, 10800);
    let web = SplatNetWebSession {
        game_web_token: token.into(),
        expires_at: super::token_expiry::expires_at(token, Some(expires), Utc::now()),
        language: auth.language.clone(),
        country: auth.country.clone(),
    };
    if let Some(session) = cache.as_mut() {
        // Natural parent expiry does not revoke a separately valid child.
        session.web = web.clone();
    } else {
        *cache = Some(web.clone().into());
    }
    Ok(web)
}

pub(crate) async fn session<A: AttestationService>(
    transport: &HttpTransport,
    attestation: &A,
    auth: &AuthenticatedCoralSession,
    cache: &mut Option<SplatNetSession>,
) -> CoreResult<SplatNetSession> {
    if let Some(session) = cache.as_ref().filter(|v| v.reusable_bullet(Utc::now())) {
        return Ok(session.clone());
    }
    web_session(transport, attestation, auth, cache).await?;
    let session = cache.as_mut().expect("web session populated cache");
    if session.reusable_bullet(Utc::now()) {
        return Ok(session.clone());
    }
    let headers = web_headers(&session.web);
    let home = transport.get_raw(&format!("{ORIGIN}/"), &headers).await?;
    ensure_response(&home, "SplatNet page")?;
    let home_text = home.text()?;
    let script_pattern =
        regex::Regex::new(r#"<script\b[^>]*\bsrc\s*=\s*["']([^"']*static[^"']*)["']"#)
            .expect("static script pattern");
    let src = script_pattern
        .captures(&home_text)
        .and_then(|captures| captures.get(1))
        .ok_or_else(|| {
            CoreError::Provider("SplatNet page version could not be determined".into())
        })?;
    let script = transport
        .get_raw(&official_script(src.as_str())?, &headers)
        .await?;
    ensure_response(&script, "SplatNet version")?;
    let version = parse_web_version(&script.text()?)?;
    session.bullet = Some(
        bullet_at(
            transport,
            &session.web,
            &version,
            &format!("{ORIGIN}/api/bullet_tokens"),
        )
        .await?,
    );
    session.bullet_expires_at = session
        .bullet
        .as_deref()
        .map(|token| super::token_expiry::expires_at(token, Some(7200), Utc::now()));
    session.version = Some(version);
    Ok(session.clone())
}

fn web_headers(web: &SplatNetWebSession) -> Vec<(&'static str, String)> {
    let mut referer = url::Url::parse(ORIGIN).expect("official SplatNet URL");
    referer
        .query_pairs_mut()
        .append_pair("lang", &web.language)
        .append_pair("na_country", &web.country)
        .append_pair("na_lang", &web.language);
    vec![
        ("Accept-Language", web.language.clone()),
        ("Accept", "*/*".into()),
        ("Origin", ORIGIN.into()),
        ("Referer", referer.to_string()),
        ("X-Requested-With", "com.nintendo.znca".into()),
        ("Cookie", format!("_gtoken={}; _dnt=1", web.game_web_token)),
    ]
}
fn validate_cookie_token(token: &str) -> CoreResult<()> {
    if token
        .bytes()
        .any(|b| !b.is_ascii_graphic() || matches!(b, b';' | b',' | b'"' | b'\\'))
    {
        return Err(CoreError::Provider("splatnet_response_invalid".into()));
    }
    Ok(())
}

pub(crate) async fn query(
    transport: &HttpTransport,
    session: &SplatNetSession,
    query: Query,
) -> CoreResult<Value> {
    query_at(transport, session, query, &format!("{ORIGIN}/api/graphql")).await
}
async fn query_at(
    transport: &HttpTransport,
    session: &SplatNetSession,
    query: Query,
    url: &str,
) -> CoreResult<Value> {
    let mut headers = web_headers(&session.web);
    headers.extend([
        (
            "Authorization",
            format!(
                "Bearer {}",
                session
                    .bullet
                    .as_deref()
                    .ok_or_else(|| CoreError::Authentication(
                        "SplatNet session is missing".into()
                    ))?
            ),
        ),
        (
            "X-Web-View-Ver",
            session
                .version
                .clone()
                .ok_or_else(|| CoreError::Provider("SplatNet version is unavailable".into()))?,
        ),
    ]);
    let response = transport.post_json_raw(url, &headers,
        &json!({"variables":{}, "extensions":{"persistedQuery":{"version":1,"sha256Hash":query.hash()}}})).await?;
    if response.status == 401 {
        return Err(CoreError::Authentication(
            "splatnet_bullet_token_invalid".into(),
        ));
    }
    ensure_response(&response, "SplatNet query")?;
    let value: Value = response.json()?;
    if value
        .get("errors")
        .and_then(Value::as_array)
        .is_some_and(|v| !v.is_empty())
        || !value.get("data").is_some_and(Value::is_object)
    {
        return Err(CoreError::Provider(
            "SplatNet could not provide the requested data".into(),
        ));
    }
    Ok(value)
}

fn murmur3(bytes: &[u8]) -> u32 {
    let mut h = 0_u32;
    let (chunks, remainder) = bytes.as_chunks::<4>();
    for chunk in chunks {
        let k = u32::from_le_bytes(*chunk)
            .wrapping_mul(0xcc9e2d51)
            .rotate_left(15)
            .wrapping_mul(0x1b873593);
        h = (h ^ k)
            .rotate_left(13)
            .wrapping_mul(5)
            .wrapping_add(0xe6546b64);
    }
    let tail = remainder
        .iter()
        .enumerate()
        .fold(0_u32, |value, (i, byte)| {
            value | ((*byte as u32) << (8 * i))
        });
    if !remainder.is_empty() {
        h ^= tail
            .wrapping_mul(0xcc9e2d51)
            .rotate_left(15)
            .wrapping_mul(0x1b873593);
    }
    h ^= bytes.len() as u32;
    h ^= h >> 16;
    h = h.wrapping_mul(0x85ebca6b);
    h ^= h >> 13;
    h = h.wrapping_mul(0xc2b2ae35);
    h ^ (h >> 16)
}

pub(crate) fn seed_export(id: &str, gear: Value, timestamp: i64) -> CoreResult<SeedExportPayload> {
    if id.is_empty() || id.len() > 128 || !id.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(CoreError::Provider(
            "SplatNet player identity is unavailable".into(),
        ));
    }
    let mut has_equipment = false;
    for collection in ["headGears", "clothingGears", "shoesGears"] {
        let nodes = gear
            .get("data")
            .and_then(|data| data.get(collection))
            .and_then(|collection| collection.get("nodes"))
            .and_then(Value::as_array)
            .ok_or_else(|| {
                CoreError::Provider(
                    "SplatNet equipment response is incomplete; refresh and try again".into(),
                )
            })?;
        has_equipment |= !nodes.is_empty();
    }
    if !has_equipment {
        return Err(CoreError::Provider(
            "No equipment is available to export; refresh SplatNet after obtaining equipment"
                .into(),
        ));
    }
    let user = format!("u-{id}");
    let h = murmur3(user.as_bytes());
    let key = STANDARD.encode(user.bytes().map(|byte| byte ^ h as u8).collect::<Vec<_>>());
    Ok(SeedExportPayload {
        file_name: format!("gear_{id}_{timestamp}.json"),
        bytes: serde_json::to_vec(&json!({"key":key, "h":h, "timestamp":timestamp, "gear":gear}))?,
    })
}

pub(crate) fn player_id(value: &Value) -> CoreResult<String> {
    let encoded = value
        .pointer(
            "/data/latestBattleHistories/historyGroups/nodes/0/historyDetails/nodes/0/player/id",
        )
        .and_then(Value::as_str)
        .ok_or_else(|| {
            CoreError::Provider(
                "No recent battle is available; play an online battle before exporting".into(),
            )
        })?;
    let decoded = STANDARD
        .decode(encoded)
        .or_else(|_| STANDARD_NO_PAD.decode(encoded))
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .ok_or_else(|| CoreError::Provider("SplatNet player identity could not be read".into()))?;
    let id = decoded
        .rsplit_once(":u-")
        .filter(|(prefix, _)| prefix.starts_with("VsPlayer"))
        .map(|(_, id)| id)
        .filter(|id| {
            !id.is_empty() && id.len() <= 128 && id.bytes().all(|b| b.is_ascii_alphanumeric())
        })
        .ok_or_else(|| CoreError::Provider("SplatNet player identity could not be read".into()))?;
    Ok(id.into())
}
fn parse_web_version(value: &str) -> CoreResult<String> {
    let pattern = regex::Regex::new(
        r#"(?s)\b([0-9a-f]{40})\b.{0,2048}?revision_info_not_set.{0,1024}?`(\d+\.\d+\.\d+)-"#,
    )
    .expect("SplatNet version pattern");
    let matched = pattern.captures(value).ok_or_else(|| {
        CoreError::Provider("SplatNet page version could not be determined".into())
    })?;
    Ok(format!("{}-{}", &matched[2], &matched[1][..8]))
}
fn official_script(value: &str) -> CoreResult<String> {
    let origin = url::Url::parse(ORIGIN)?;
    let url = origin.join(value)?;
    if url.origin() != origin.origin() || !url.username().is_empty() || url.password().is_some() {
        return Err(CoreError::Provider(
            "SplatNet script origin is not trusted".into(),
        ));
    }
    Ok(url.into())
}

async fn bullet_at(
    transport: &HttpTransport,
    web: &SplatNetWebSession,
    version: &str,
    url: &str,
) -> CoreResult<String> {
    let mut headers = web_headers(web);
    headers.extend([
        ("X-Web-View-Ver", version.into()),
        ("X-NACOUNTRY", web.country.clone()),
        ("Content-Type", "application/json".into()),
    ]);
    let response = transport.post_bytes_raw(url, &headers, Vec::new()).await?;
    if let Some(error) = super::conditions::bullet_status_error(response.status) {
        return Err(error);
    }
    ensure_response(&response, "SplatNet game session")?;
    let value: Value = response
        .json()
        .map_err(|_| CoreError::Provider("splatnet_response_invalid".into()))?;
    value
        .get("bulletToken")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| CoreError::Provider("splatnet_response_invalid".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    use serde_json::json;

    struct NoExchange;

    struct SyntheticWebExchange(Value);

    #[async_trait::async_trait]
    impl AttestationService for SyntheticWebExchange {
        async fn encrypt_request(
            &self,
            _: &str,
            token: &str,
            parameter: Value,
            method: u8,
            _: Option<&str>,
            _: Option<&str>,
        ) -> CoreResult<super::super::attestation::EncryptedRequest> {
            assert_eq!(token, "synthetic-coral");
            assert_eq!(method, 2);
            assert_eq!(parameter["registrationToken"], "synthetic-coral");
            Ok(super::super::attestation::EncryptedRequest {
                body: b"synthetic-request".to_vec(),
                request_id: String::new(),
                timestamp: 0,
            })
        }

        async fn decrypt_response(&self, _: &[u8]) -> CoreResult<Value> {
            Ok(self.0.clone())
        }

        async fn nso_version(&self) -> CoreResult<String> {
            Ok("3.9.9".into())
        }
    }

    #[tokio::test]
    async fn natural_web_renewal_preserves_separately_valid_bullet() {
        let (url, server) = crate::transport::tests::capture_request("{}");
        let mut cache = Some(SplatNetSession {
            web: SplatNetWebSession {
                game_web_token: "expired-game-web".into(),
                expires_at: Utc::now() - Duration::seconds(1),
                language: "ja-JP".into(),
                country: "JP".into(),
            },
            bullet: Some("valid-bullet".into()),
            version: Some("11.2.4-abc12345".into()),
            bullet_expires_at: Some(Utc::now() + Duration::hours(1)),
        });
        let auth = AuthenticatedCoralSession {
            session: super::super::CoralSession {
                access_token: "synthetic-coral".into(),
                na_id: Some("synthetic-account".into()),
                coral_user_id: Some("123456".into()),
                expires_at: Some(Utc::now() + Duration::hours(1)),
                nickname: String::new(),
                avatar_url: None,
                avatar_bytes: None,
            },
            language: "ja-JP".into(),
            country: "JP".into(),
        };
        let result = web_session_at(
            &HttpTransport::new(Default::default()).unwrap(),
            &SyntheticWebExchange(json!({"status":0,"result":{
                "accessToken":"renewed-game-web", "expiresIn":10800
            }})),
            &auth,
            &mut cache,
            &url,
        )
        .await
        .unwrap();
        let request = server.join().unwrap();
        assert!(request.ends_with("synthetic-request"));
        assert_eq!(result.game_web_token, "renewed-game-web");
        let retained = cache.as_ref().unwrap();
        assert!(retained.reusable_bullet(Utc::now()));
        assert_eq!(retained.bullet.as_deref(), Some("valid-bullet"));
    }

    #[tokio::test]
    async fn malformed_web_credentials_are_safe_non_retryable_provider_failures() {
        for result in [
            json!({}),
            json!({"accessToken":""}),
            json!({"accessToken":7}),
            json!({"accessToken":"PRIVATE;other=value"}),
            json!({"accessToken":"PRIVATE\r\nHeader: value"}),
        ] {
            let (url, server) = crate::transport::tests::capture_request("{}");
            let auth = AuthenticatedCoralSession {
                session: super::super::CoralSession {
                    access_token: "synthetic-coral".into(),
                    na_id: Some("synthetic-account".into()),
                    coral_user_id: Some("123456".into()),
                    expires_at: Some(Utc::now() + Duration::hours(1)),
                    nickname: String::new(),
                    avatar_url: None,
                    avatar_bytes: None,
                },
                language: "ja-JP".into(),
                country: "JP".into(),
            };
            let mut cache = None;
            let error = web_session_at(
                &HttpTransport::new(Default::default()).unwrap(),
                &SyntheticWebExchange(json!({"status":0,"result":result})),
                &auth,
                &mut cache,
                &url,
            )
            .await
            .err()
            .expect("invalid credential must not be accepted");
            server.join().unwrap();
            assert!(matches!(
                error,
                CoreError::Provider(ref code) if code == "splatnet_response_invalid"
            ));
            assert!(cache.is_none());
            assert!(!error.to_string().contains("PRIVATE"));
        }
    }

    #[async_trait::async_trait]
    impl AttestationService for NoExchange {
        async fn encrypt_request(
            &self,
            _: &str,
            _: &str,
            _: Value,
            _: u8,
            _: Option<&str>,
            _: Option<&str>,
        ) -> CoreResult<super::super::attestation::EncryptedRequest> {
            Err(CoreError::Provider("unexpected parent exchange".into()))
        }

        async fn decrypt_response(&self, _: &[u8]) -> CoreResult<Value> {
            panic!("cached child must not decrypt a parent exchange")
        }

        async fn nso_version(&self) -> CoreResult<String> {
            panic!("cached child must not prepare a parent exchange")
        }
    }

    #[tokio::test]
    async fn valid_bullet_is_reused_without_renewing_expired_game_web_token() {
        let mut cache = Some(SplatNetSession {
            web: SplatNetWebSession {
                game_web_token: "expired-parent".into(),
                expires_at: Utc::now() - Duration::seconds(1),
                language: "ja-JP".into(),
                country: "JP".into(),
            },
            bullet: Some("valid-child".into()),
            version: Some("11.2.4-abc12345".into()),
            bullet_expires_at: Some(Utc::now() + Duration::hours(1)),
        });
        let auth = AuthenticatedCoralSession {
            session: super::super::CoralSession {
                access_token: "expired-coral".into(),
                na_id: Some("synthetic-account".into()),
                coral_user_id: Some("123456".into()),
                expires_at: Some(Utc::now() - Duration::seconds(1)),
                nickname: String::new(),
                avatar_url: None,
                avatar_bytes: None,
            },
            language: "ja-JP".into(),
            country: "JP".into(),
        };
        let result = session(
            &HttpTransport::new(Default::default()).unwrap(),
            &NoExchange,
            &auth,
            &mut cache,
        )
        .await
        .expect("valid bullet does not depend on parent TTL");
        assert_eq!(result.bullet.as_deref(), Some("valid-child"));
    }

    #[tokio::test]
    async fn graphql_401_identifies_bullet_rejection_without_echoing_body() {
        let (url, server) =
            crate::transport::tests::capture_response(401, r#"{"private":"PRIVATE"}"#, &[]);
        let session = SplatNetSession {
            web: SplatNetWebSession {
                game_web_token: "valid-parent".into(),
                expires_at: Utc::now() + Duration::hours(1),
                language: "en-GB".into(),
                country: "GB".into(),
            },
            bullet: Some("rejected-child".into()),
            version: Some("11.2.4-abc12345".into()),
            bullet_expires_at: Some(Utc::now() + Duration::hours(1)),
        };
        let error = query_at(
            &HttpTransport::new(Default::default()).unwrap(),
            &session,
            Query::Friends,
            &url,
        )
        .await
        .unwrap_err();
        server.join().unwrap();
        assert!(matches!(
            error,
            CoreError::Authentication(ref code) if code == "splatnet_bullet_token_invalid"
        ));
        assert!(!error.to_string().contains("PRIVATE"));
        let mut cache = Some(session);
        assert!(retire_rejected_credential(&mut cache, &error));
        let retained = cache.as_ref().unwrap();
        assert!(retained.reusable_web(Utc::now()));
        assert!(!retained.reusable_bullet(Utc::now()));
        assert!(retained.bullet.is_none());
        assert!(retained.bullet_expires_at.is_none());
        assert_eq!(retained.web.game_web_token, "valid-parent");
        assert_eq!(retained.version.as_deref(), Some("11.2.4-abc12345"));
    }

    #[test]
    fn web_and_bullet_credentials_require_strictly_more_than_five_minutes() {
        use chrono::TimeZone;
        let now = Utc.timestamp_opt(1_000, 0).unwrap();
        let mut session = SplatNetSession::from(SplatNetWebSession {
            game_web_token: "synthetic-game".into(),
            expires_at: now + Duration::seconds(301),
            language: "en-GB".into(),
            country: "GB".into(),
        });
        session.bullet = Some("synthetic-bullet".into());
        session.version = Some("synthetic-version".into());
        session.bullet_expires_at = Some(now + Duration::seconds(301));
        assert!(session.reusable_web(now));
        assert!(session.reusable_bullet(now));
        for remaining in [300, 299, 0, -1] {
            session.web.expires_at = now + Duration::seconds(remaining);
            session.bullet_expires_at = Some(now + Duration::seconds(remaining));
            assert!(!session.reusable_web(now), "web: {remaining}");
            assert!(!session.reusable_bullet(now), "bullet: {remaining}");
        }
    }

    fn complete_gear() -> Value {
        json!({
            "data": {
                "headGears": {"nodes": [{"id": "original-head", "headGearId": "10000", "name": "Test headgear",
                    "primaryGearPower": {"gearPowerId": 1}, "additionalGearPowers": [{"gearPowerId": 2}],
                    "extra": {"preserved": true}}]},
                "clothingGears": {"nodes": [{"id": "original-clothing", "clothingGearId": "10000", "name": "Test clothing",
                    "primaryGearPower": {"gearPowerId": 1}, "additionalGearPowers": [{"gearPowerId": 2}]}]},
                "shoesGears": {"nodes": [{"id": "original-shoes", "shoesGearId": "10000", "name": "Test shoes",
                    "primaryGearPower": {"gearPowerId": 1}, "additionalGearPowers": [{"gearPowerId": 2}]}]}
            },
            "extensions": {"x": 1}
        })
    }

    #[test]
    fn seed_export_preserves_raw_gear_and_has_unsigned_murmur_golden_hash() {
        assert_eq!(murmur3(b""), 0);
        assert_eq!(murmur3(b"foo"), 0xf6a5c420);
        let gear = complete_gear();
        let export = seed_export("abc123", gear.clone(), 1_700_000_000).unwrap();
        assert_eq!(export.file_name, "gear_abc123_1700000000.json");
        let value: serde_json::Value = serde_json::from_slice(&export.bytes).unwrap();
        assert_eq!(value["gear"], gear);
        assert_eq!(value["h"], 3_966_740_424_u32);
        assert_eq!(value["key"], "veWpqqv5+vs=");
        assert_eq!(value["timestamp"], 1_700_000_000);
        assert_eq!(value.as_object().unwrap().len(), 4);
        assert!(seed_export("../bad", json!({}), 1).is_err());
        assert!(seed_export("valid", json!({"data":{}}), 1).is_err());
    }

    #[test]
    fn seed_export_rejects_missing_required_gear_collections() {
        for collection in ["headGears", "clothingGears", "shoesGears"] {
            let mut gear = complete_gear();
            gear["data"].as_object_mut().unwrap().remove(collection);
            assert!(
                seed_export("abc123", gear, 1_700_000_000).is_err(),
                "seed-checker imports require {collection}"
            );
        }
    }

    #[test]
    fn seed_export_rejects_malformed_collection_nodes() {
        for collection in ["headGears", "clothingGears", "shoesGears"] {
            for malformed in [
                json!(null),
                json!([]),
                json!({}),
                json!({"nodes":null}),
                json!({"nodes":{}}),
                json!({"nodes":"not-an-array"}),
                json!({"nodes":42}),
            ] {
                let mut gear = complete_gear();
                gear["data"][collection] = malformed;
                assert!(
                    seed_export("abc123", gear, 1_700_000_000).is_err(),
                    "{collection}.nodes must be an array"
                );
            }
        }
    }

    #[test]
    fn seed_export_rejects_an_account_with_no_equipment() {
        let gear = json!({"data": {
            "headGears":{"nodes":[]}, "clothingGears":{"nodes":[]}, "shoesGears":{"nodes":[]}
        }});
        let result = seed_export("abc123", gear, 1_700_000_000);
        assert!(
            result.is_err(),
            "do not create an empty seed-checker equipment file"
        );
        assert!(result.unwrap_err().to_string().contains("No equipment"));
    }

    #[test]
    fn seed_export_preserves_empty_categories_when_other_equipment_exists() {
        for collection in ["headGears", "clothingGears", "shoesGears"] {
            let mut gear = complete_gear();
            gear["data"][collection]["nodes"] = json!([]);
            let export = seed_export("abc123", gear.clone(), 1_700_000_000).unwrap();
            let parsed: Value = serde_json::from_slice(&export.bytes).unwrap();
            assert_eq!(parsed["gear"], gear);
        }
    }

    #[test]
    fn real_player_id_is_extracted_from_latest_battle_not_fabricated() {
        use base64::Engine;
        let id = base64::engine::general_purpose::STANDARD
            .encode("VsPlayer-latest-battle:u-0123456789abcdef");
        let data = json!({"data":{"latestBattleHistories":{"historyGroups":{"nodes":[
            {"historyDetails":{"nodes":[{"player":{"id":id}}]}}
        ]}}}});
        assert_eq!(player_id(&data).unwrap(), "0123456789abcdef");
        assert!(player_id(
            &json!({"data":{"latestBattleHistories":{"historyGroups":{"nodes":[]}}}})
        )
        .is_err());
    }

    #[test]
    fn web_version_is_dynamic_and_scripts_cannot_leave_official_origin() {
        assert_eq!(parse_web_version(r#"a="0123456789abcdef0123456789abcdef01234567";x=void 0?"revision_info_not_set"}`,v=`10.2.3-${x}`"#).unwrap(), "10.2.3-01234567");
        assert!(official_script("https://evil.example/static/main.js").is_err());
        assert!(official_script("//evil.example/static/main.js").is_err());
        assert_eq!(
            official_script("/static/main.js").unwrap(),
            "https://api.lp1.av5ja.srv.nintendo.net/static/main.js"
        );
    }

    #[tokio::test]
    async fn graphql_sends_account_locale_cookie_and_query_hash() {
        let (url, server) =
            crate::transport::tests::capture_request(r#"{"data":{"friends":{"nodes":[]}}}"#);
        let session = SplatNetSession {
            web: crate::models::SplatNetWebSession {
                game_web_token: "test-game".into(),
                expires_at: chrono::Utc::now() + chrono::Duration::hours(1),
                language: "ja-JP".into(),
                country: "JP".into(),
            },
            bullet: Some("test-bullet".into()),
            version: Some("10.2.3-01234567".into()),
            bullet_expires_at: Some(chrono::Utc::now() + chrono::Duration::hours(1)),
        };
        query_at(
            &crate::transport::HttpTransport::new(Default::default()).unwrap(),
            &session,
            Query::Friends,
            &url,
        )
        .await
        .unwrap();
        let request = server.join().unwrap();
        assert!(request.contains("authorization: Bearer test-bullet"));
        assert!(request.contains("accept-language: ja-JP"));
        assert!(request.contains("cookie: _gtoken=test-game; _dnt=1"));
        assert!(request.contains("x-web-view-ver: 10.2.3-01234567"));
        let body: Value = serde_json::from_str(request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(
            body,
            json!({"variables":{}, "extensions":{"persistedQuery":{"version":1,
            "sha256Hash":"ea1297e9bb8e52404f52d89ac821e1d73b726ceef2fd9cc8d6b38ab253428fb3"}}})
        );
    }

    #[tokio::test]
    async fn graphql_http_429_is_not_retried_or_exposed_as_a_credential_error() {
        let (url, server) =
            crate::transport::tests::capture_response(429, r#"{"token":"secret"}"#, &[]);
        let session = SplatNetSession {
            web: SplatNetWebSession {
                game_web_token: "game".into(),
                expires_at: Utc::now() + Duration::hours(1),
                language: "en-US".into(),
                country: "US".into(),
            },
            bullet: Some("bullet".into()),
            version: Some("10.2.3-01234567".into()),
            bullet_expires_at: Some(Utc::now() + Duration::hours(1)),
        };
        let result = query_at(
            &HttpTransport::new(Default::default()).unwrap(),
            &session,
            Query::Latest,
            &url,
        )
        .await;
        server.join().unwrap();
        assert!(matches!(
            result,
            Err(CoreError::RateLimited {
                retry_after_seconds: 60
            })
        ));
    }

    #[tokio::test]
    async fn bullet_exchange_sends_dynamic_version_and_real_profile_locale() {
        let (url, server) =
            crate::transport::tests::capture_request(r#"{"bulletToken":"test-bullet"}"#);
        let web = SplatNetWebSession {
            game_web_token: "game-cookie".into(),
            expires_at: Utc::now() + Duration::hours(1),
            language: "zh-Hans".into(),
            country: "HK".into(),
        };
        let bullet = bullet_at(
            &HttpTransport::new(Default::default()).unwrap(),
            &web,
            "11.2.4-abc12345",
            &url,
        )
        .await
        .unwrap();
        assert_eq!(bullet, "test-bullet");
        let request = server.join().unwrap();
        assert!(request.contains("x-web-view-ver: 11.2.4-abc12345"));
        assert!(request.contains("accept-language: zh-Hans"));
        assert!(request.contains("x-nacountry: HK"));
        assert!(request.contains("cookie: _gtoken=game-cookie; _dnt=1"));
        assert!(!request.contains("authorization:"));
    }

    #[tokio::test]
    async fn bullet_special_statuses_are_actionable_non_authentication_failures() {
        for (status, code) in [
            (204, "splatnet_user_not_registered"),
            (400, "splatnet_request_invalid"),
            (403, "splatnet_version_outdated"),
            (499, "splatnet_access_restricted"),
            (500, "splatnet_service_unavailable"),
            (503, "splatnet_service_maintenance"),
        ] {
            let (url, server) = crate::transport::tests::capture_response(
                status,
                r#"{"private":"do-not-echo"}"#,
                &[],
            );
            let web = SplatNetWebSession {
                game_web_token: "synthetic-game".into(),
                expires_at: Utc::now() + Duration::hours(1),
                language: "en-GB".into(),
                country: "GB".into(),
            };
            let error = bullet_at(
                &HttpTransport::new(Default::default()).unwrap(),
                &web,
                "11.2.4-abc12345",
                &url,
            )
            .await
            .unwrap_err();
            server.join().unwrap();
            assert!(matches!(error, CoreError::Provider(_)), "{status}");
            assert!(error.to_string().contains(code), "{status}: {error}");
            assert!(!error.to_string().contains("do-not-echo"));
        }
    }

    #[tokio::test]
    async fn malformed_bullet_responses_are_safe_provider_failures() {
        for body in ["", "<html>PRIVATE</html>", r#"{"private":"PRIVATE"}"#] {
            let (url, server) = crate::transport::tests::capture_response(200, body, &[]);
            let web = SplatNetWebSession {
                game_web_token: "synthetic-game".into(),
                expires_at: Utc::now() + Duration::hours(1),
                language: "en-GB".into(),
                country: "GB".into(),
            };
            let error = bullet_at(
                &HttpTransport::new(Default::default()).unwrap(),
                &web,
                "11.2.4-abc12345",
                &url,
            )
            .await
            .unwrap_err();
            server.join().unwrap();
            assert!(matches!(error, CoreError::Provider(_)));
            assert!(error.to_string().contains("splatnet_response_invalid"));
            assert!(!error.to_string().contains("PRIVATE"));
        }
    }

    #[tokio::test]
    async fn bullet_forbidden_is_not_reported_as_missing_membership() {
        let (url, server) = crate::transport::tests::capture_response(
            403,
            r#"{"error":"ERROR_OBSOLETE_VERSION"}"#,
            &[],
        );
        let web = SplatNetWebSession {
            game_web_token: "test-game".into(),
            expires_at: Utc::now() + Duration::hours(1),
            language: "en-US".into(),
            country: "US".into(),
        };
        let error = bullet_at(
            &HttpTransport::new(Default::default()).unwrap(),
            &web,
            "11.2.4-abc12345",
            &url,
        )
        .await
        .unwrap_err();
        server.join().unwrap();
        assert!(matches!(error, CoreError::Provider(_)));
        assert!(!error.to_string().contains("membership"));
    }
}
