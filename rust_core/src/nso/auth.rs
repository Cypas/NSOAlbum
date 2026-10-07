use std::collections::HashMap;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;

use crate::error::{CoreError, CoreResult};
use crate::models::LoginChallenge;
use crate::transport::HttpTransport;

const CLIENT_ID: &str = "71b963c1b7b6d119";
const REDIRECT_URI: &str = "npf71b963c1b7b6d119://auth";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NintendoTokens {
    pub access_token: String,
    pub id_token: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NintendoProfile {
    pub id: String,
    pub nickname: String,
    pub language: String,
    pub country: String,
    pub birthday: String,
    #[serde(default, rename = "imageUri")]
    pub image_uri: Option<String>,
    #[serde(default)]
    pub mii: Option<NintendoMii>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NintendoMii {
    #[serde(default, rename = "imageOrigin")]
    pub image_origin: Option<String>,
}

impl NintendoProfile {
    pub fn avatar_url(&self) -> Option<&str> {
        self.image_uri.as_deref().or_else(|| {
            self.mii
                .as_ref()
                .and_then(|mii| mii.image_origin.as_deref())
        })
    }
}

#[derive(Clone)]
pub struct NintendoAuthClient {
    transport: HttpTransport,
}

impl NintendoAuthClient {
    pub fn new(transport: HttpTransport) -> Self {
        Self { transport }
    }

    pub fn create_login_challenge(&self) -> CoreResult<LoginChallenge> {
        let mut state_bytes = [0_u8; 36];
        let mut verifier_bytes = [0_u8; 32];
        rand::thread_rng().fill_bytes(&mut state_bytes);
        rand::thread_rng().fill_bytes(&mut verifier_bytes);
        let state = URL_SAFE_NO_PAD.encode(state_bytes);
        let verifier = URL_SAFE_NO_PAD.encode(verifier_bytes);
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let mut url = Url::parse("https://accounts.nintendo.com/connect/1.0.0/authorize")?;
        url.query_pairs_mut()
            .append_pair("state", &state)
            .append_pair("redirect_uri", REDIRECT_URI)
            .append_pair("client_id", CLIENT_ID)
            .append_pair(
                "scope",
                "openid user user.birthday user.mii user.screenName",
            )
            .append_pair("response_type", "session_token_code")
            .append_pair("session_token_code_challenge", &challenge)
            .append_pair("session_token_code_challenge_method", "S256")
            .append_pair("theme", "login_form");
        Ok(LoginChallenge {
            authorization_url: url.to_string(),
            state,
            verifier,
        })
    }

    pub fn parse_callback(&self, callback: &str, expected_state: &str) -> CoreResult<String> {
        let url = Url::parse(callback)?;
        let mut parameters: HashMap<String, String> = url.query_pairs().into_owned().collect();
        if let Some(fragment) = url.fragment() {
            parameters.extend(url::form_urlencoded::parse(fragment.as_bytes()).into_owned());
        }
        if parameters.get("state").map(String::as_str) != Some(expected_state) {
            return Err(CoreError::Authentication("OAuth state mismatch".into()));
        }
        parameters
            .get("session_token_code")
            .cloned()
            .ok_or_else(|| CoreError::Authentication("callback has no session_token_code".into()))
    }

    pub async fn exchange_session_token_code(
        &self,
        session_token_code: &str,
        verifier: &str,
        nso_version: &str,
    ) -> CoreResult<String> {
        let body = [
            ("client_id", CLIENT_ID),
            ("session_token_code", session_token_code),
            ("session_token_code_verifier", verifier),
        ];
        let response: serde_json::Value = self
            .transport
            .post_form(
                "https://accounts.nintendo.com/connect/1.0.0/api/session_token",
                &[(
                    "User-Agent",
                    format!("OnlineLounge/{nso_version} NASDKAPI Android"),
                )],
                &body,
            )
            .await?;
        response
            .get("session_token")
            .and_then(|value| value.as_str())
            .map(str::to_owned)
            .ok_or_else(|| CoreError::Authentication("session token exchange failed".into()))
    }

    pub async fn exchange_session_token(&self, session_token: &str) -> CoreResult<NintendoTokens> {
        let response: serde_json::Value = self
            .transport
            .post_json(
                "https://accounts.nintendo.com/connect/1.0.0/api/token",
                &[("User-Agent", "Dalvik/2.1.0 (Linux; U; Android 14)".into())],
                &serde_json::json!({
                    "client_id": CLIENT_ID,
                    "session_token": session_token,
                    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer-session-token"
                }),
            )
            .await?;
        let access_token = response
            .get("access_token")
            .and_then(|value| value.as_str())
            .ok_or_else(|| CoreError::Authentication("missing Nintendo access token".into()))?;
        let id_token = response
            .get("id_token")
            .and_then(|value| value.as_str())
            .ok_or_else(|| CoreError::Authentication("missing Nintendo id token".into()))?;
        Ok(NintendoTokens {
            access_token: access_token.into(),
            id_token: id_token.into(),
        })
    }

    pub async fn fetch_profile(&self, access_token: &str) -> CoreResult<NintendoProfile> {
        self.transport
            .get_json(
                "https://api.accounts.nintendo.com/2.0.0/users/me",
                &[
                    ("Authorization", format!("Bearer {access_token}")),
                    ("Accept-Language", "en-GB".into()),
                    ("Accept", "application/json".into()),
                    ("Content-Type", "application/json".into()),
                    ("User-Agent", "NASDKAPI; Android".into()),
                ],
            )
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_nintendo_fragment_callback() {
        let transport = HttpTransport::new(Default::default()).unwrap();
        let client = NintendoAuthClient::new(transport);
        let code = client
            .parse_callback(
                "npf71b963c1b7b6d119://auth#session_token_code=abc123&state=expected",
                "expected",
            )
            .unwrap();
        assert_eq!(code, "abc123");
    }
}
