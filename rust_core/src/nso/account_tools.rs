use super::game_images::PublicGameImages;
use super::session::{AuthenticatedCoralSession, CachedNintendoIdentity};
use super::splatnet::{self, SplatNetSession};
use super::{
    AttestationService, CoralSession, CoralSessionClient, NxapiAttestationClient, NxapiConfig,
};
use crate::error::{CoreError, CoreResult};
use crate::models::{
    NintendoFriend, NintendoFriendCodeSnapshot, NintendoFriendCodeUser, NintendoFriendGame,
    NintendoFriendRequestResult, NintendoFriendsSnapshot, SeedExportPayload, SplatNetWebSession,
};
use crate::sync::CancellationToken;
use crate::transport::{nintendo_user_agent, HttpResponseData, HttpTransport};
use async_trait::async_trait;
use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{TimeZone, Utc};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::future::Future;
use std::sync::{Arc, Mutex};

pub(crate) const CORAL_ORIGIN: &str = "https://api-lp1.znc.srv.nintendo.net";
const MAX_RETIRED_OPERATIONS: usize = 512;

fn parse_friends(value: &Value) -> CoreResult<(Vec<NintendoFriend>, HashMap<String, String>)> {
    let nodes = value
        .pointer("/result/friends")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::Provider("Nintendo friend list is unavailable".into()))?;
    let mut friends = Vec::with_capacity(nodes.len());
    let mut avatars = HashMap::new();
    for node in nodes {
        let id = node
            .get("nsaId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .ok_or_else(|| {
                CoreError::Provider("Nintendo friend is missing its stable ID".into())
            })?;
        if let Some(url) = node.get("imageUri").and_then(Value::as_str) {
            avatars.insert(id.to_owned(), url.to_owned());
        }
        let presence = node.get("presence").unwrap_or(&Value::Null);
        let game = presence.get("game").unwrap_or(&Value::Null);
        let state = match presence.get("state").and_then(Value::as_str) {
            Some("ONLINE") => "ONLINE",
            Some("OFFLINE") => "OFFLINE",
            _ => "UNKNOWN",
        };
        friends.push(NintendoFriend {
            friend_id: id.into(),
            nickname: node
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .into(),
            avatar_url: node
                .get("imageUri")
                .and_then(Value::as_str)
                .filter(|url| !url.is_empty())
                .map(str::to_owned),
            note: node
                .get("note")
                .and_then(Value::as_str)
                .unwrap_or("")
                .into(),
            is_favorite: node
                .get("isFavoriteFriend")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            presence: state.into(),
            game_name: game.get("name").and_then(Value::as_str).map(str::to_owned),
            game_image_url: game
                .get("imageUri")
                .and_then(Value::as_str)
                .filter(|url| !url.is_empty())
                .map(str::to_owned),
            total_play_time_minutes: game
                .get("totalPlayTime")
                .and_then(Value::as_u64)
                .and_then(|v| u32::try_from(v).ok()),
            first_played_at: game
                .get("firstPlayedAt")
                .and_then(Value::as_i64)
                .filter(|v| *v > 0)
                .and_then(|v| Utc.timestamp_opt(v, 0).single()),
            logout_at: presence
                .get("logoutAt")
                .and_then(Value::as_i64)
                .filter(|v| *v > 0)
                .and_then(|v| Utc.timestamp_opt(v, 0).single()),
            activity: None,
            in_game_name: node
                .pointer("/route/userName")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .map(str::to_owned),
            friendship_source: node
                .pointer("/route/channel")
                .and_then(Value::as_str)
                .filter(|channel| !channel.is_empty())
                .map(str::to_owned),
            friendship_game_name: node
                .pointer("/route/appName")
                .and_then(Value::as_str)
                .filter(|name| !name.trim().is_empty())
                .map(str::to_owned),
            friend_created_at: node
                .get("friendCreatedAt")
                .and_then(Value::as_i64)
                .filter(|v| *v > 0)
                .and_then(|v| Utc.timestamp_opt(v, 0).single()),
        });
    }
    Ok((friends, avatars))
}

fn parse_friend_play_log(value: &Value) -> CoreResult<Vec<NintendoFriendGame>> {
    let games = value
        .get("result")
        .and_then(Value::as_array)
        .or_else(|| value.as_array())
        .ok_or_else(|| CoreError::Provider("Nintendo friend game history is unavailable".into()))?;
    Ok(games
        .iter()
        .filter_map(|game| {
            let name = game
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.trim().is_empty())?
                .to_owned();
            Some(NintendoFriendGame {
                name,
                image_url: game
                    .get("imageUri")
                    .and_then(Value::as_str)
                    .filter(|url| !url.is_empty())
                    .map(str::to_owned),
                total_play_time_minutes: game
                    .get("totalPlayTime")
                    .and_then(Value::as_u64)
                    .and_then(|minutes| u32::try_from(minutes).ok()),
                first_played_at: game
                    .get("firstPlayedAt")
                    .and_then(Value::as_i64)
                    .filter(|timestamp| *timestamp > 0)
                    .and_then(|timestamp| Utc.timestamp_opt(timestamp, 0).single()),
            })
        })
        .collect())
}

fn supplement_friends(friends: &mut [NintendoFriend], value: &Value) -> CoreResult<()> {
    let nodes = value
        .pointer("/data/friends/nodes")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::Provider("SplatNet friend activity is unavailable".into()))?;
    for node in nodes {
        let decoded = node
            .get("id")
            .and_then(Value::as_str)
            .and_then(|id| STANDARD.decode(id).ok())
            .and_then(|id| String::from_utf8(id).ok());
        let id = node
            .get("nsaId")
            .and_then(Value::as_str)
            .or_else(|| decoded.as_deref().and_then(|id| id.strip_prefix("Friend-")));
        if let Some(friend) = friends
            .iter_mut()
            .find(|f| Some(f.friend_id.as_str()) == id)
        {
            friend.activity = friend_activity(node).map(str::to_owned);
        }
    }
    Ok(())
}

fn friend_activity(node: &Value) -> Option<&'static str> {
    match node.get("onlineState").and_then(Value::as_str)? {
        "VS_MODE_MATCHING" | "COOP_MODE_MATCHING" => Some("MATCHING"),
        "COOP_MODE_FIGHTING" => Some("COOP"),
        "VS_MODE_FIGHTING" => {
            let mode_id = node
                .pointer("/vsMode/id")
                .and_then(Value::as_str)
                .and_then(|value| STANDARD.decode(value).ok())
                .and_then(|bytes| String::from_utf8(bytes).ok());
            Some(
                match (
                    node.pointer("/vsMode/mode").and_then(Value::as_str),
                    mode_id.as_deref(),
                ) {
                    (Some("REGULAR"), _) => "REGULAR",
                    (Some("BANKARA"), Some("VsMode-51")) => "BANKARA_OPEN",
                    (Some("BANKARA"), Some("VsMode-2")) => "BANKARA_CHALLENGE",
                    (Some("X_MATCH"), _) => "X_MATCH",
                    (Some("PRIVATE"), _) => "PRIVATE",
                    (Some("LEAGUE"), _) => "EVENT",
                    (Some("FEST"), Some("VsMode-6")) => "FEST_OPEN",
                    (Some("FEST"), Some("VsMode-7")) => "FEST_CHALLENGE",
                    (Some("FEST"), Some("VsMode-8")) => "FEST_TRICOLOR",
                    _ => "VS_FIGHTING",
                },
            )
        }
        _ => None,
    }
}

#[async_trait]
pub(crate) trait AccountAuthenticator: Send + Sync {
    async fn login_cached(
        &self,
        transport: HttpTransport,
        attestation: NxapiAttestationClient,
        token: &str,
        _cache: &mut Option<CachedNintendoIdentity>,
    ) -> CoreResult<AuthenticatedCoralSession> {
        self.login(transport, attestation, token).await
    }
    async fn login(
        &self,
        transport: HttpTransport,
        attestation: NxapiAttestationClient,
        token: &str,
    ) -> CoreResult<AuthenticatedCoralSession>;
}
struct ProtocolAuthenticator;
#[async_trait]
impl AccountAuthenticator for ProtocolAuthenticator {
    async fn login_cached(
        &self,
        transport: HttpTransport,
        attestation: NxapiAttestationClient,
        token: &str,
        cache: &mut Option<CachedNintendoIdentity>,
    ) -> CoreResult<AuthenticatedCoralSession> {
        CoralSessionClient::new(transport, attestation)
            .login_with_identity_cache(token, cache)
            .await
    }
    async fn login(
        &self,
        transport: HttpTransport,
        attestation: NxapiAttestationClient,
        token: &str,
    ) -> CoreResult<AuthenticatedCoralSession> {
        CoralSessionClient::new(transport, attestation)
            .login_with_account_info(token)
            .await
    }
}

#[derive(Default)]
struct AccountCache {
    nintendo: Option<CachedNintendoIdentity>,
    auth: Option<AuthenticatedCoralSession>,
    splatnet: Option<SplatNetSession>,
    avatars: HashMap<String, String>,
    avatar_bytes: HashMap<String, (String, Vec<u8>)>,
    lookup_avatar: Option<(String, String)>,
    game_urls: HashMap<String, String>,
    game_images: Arc<tokio::sync::Mutex<PublicGameImages>>,
}

impl AccountCache {
    fn remember_game(&mut self, name: &str, url: Option<&str>) {
        if let Some(url) = url.filter(|url| !url.is_empty()) {
            if self.game_urls.len() >= 512 && !self.game_urls.contains_key(name) {
                self.game_urls.clear();
            }
            self.game_urls.insert(name.to_owned(), url.to_owned());
        }
    }

    fn lookup_preview(&mut self, result: &Value) -> CoreResult<NintendoFriendCodeUser> {
        let friend_id = result
            .get("nsaId")
            .and_then(Value::as_str)
            .filter(|value| {
                !value.is_empty()
                    && value.len() <= 128
                    && value
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
            })
            .ok_or_else(|| CoreError::Provider("friend lookup has no stable ID".into()))?;
        let avatar_url = result
            .get("imageUri")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        self.lookup_avatar = avatar_url
            .as_ref()
            .map(|url| (friend_id.to_owned(), url.to_owned()));
        Ok(NintendoFriendCodeUser {
            friend_id: friend_id.to_owned(),
            nickname: result
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
            avatar_url,
        })
    }

    fn cached_avatar(&self, id: &str, url: &str) -> Option<Vec<u8>> {
        self.avatar_bytes
            .get(id)
            .filter(|(cached, _)| cached == url)
            .map(|(_, bytes)| bytes.clone())
    }
    fn remember_avatar(&mut self, id: &str, url: &str, bytes: &[u8]) {
        const MAX_BYTES: usize = 16 * 1024 * 1024;
        if self.avatar_bytes.len() >= 128
            || self
                .avatar_bytes
                .values()
                .map(|(_, data)| data.len())
                .sum::<usize>()
                + bytes.len()
                > MAX_BYTES
        {
            self.avatar_bytes.clear();
        }
        if !bytes.is_empty() && bytes.len() <= 4 * 1024 * 1024 {
            self.avatar_bytes
                .insert(id.into(), (url.into(), bytes.to_vec()));
        }
    }
}
struct AuthenticationInput<'a> {
    token: &'a str,
    account: Option<&'a str>,
    transport: &'a HttpTransport,
    client: &'a NxapiAttestationClient,
    proxy: Option<&'a str>,
    generation: u64,
}
struct AccountEntry {
    client: NxapiAttestationClient,
    identities: Mutex<BTreeSet<String>>,
    removed: CancellationToken,
    cache: tokio::sync::Mutex<AccountCache>,
}
impl AccountEntry {
    fn new(
        client: NxapiAttestationClient,
        game_images: Arc<tokio::sync::Mutex<PublicGameImages>>,
    ) -> Self {
        Self {
            client,
            identities: Default::default(),
            removed: Default::default(),
            cache: tokio::sync::Mutex::new(AccountCache {
                game_images,
                ..Default::default()
            }),
        }
    }
}
struct RegisteredOperation {
    account: Option<String>,
    token: CancellationToken,
    started: bool,
}
#[derive(Default)]
struct Registry {
    generation: u64,
    cleared_accounts: HashMap<String, u64>,
    entries: HashMap<String, Arc<AccountEntry>>,
    clients: HashMap<String, NxapiAttestationClient>,
    client_accounts: HashMap<String, BTreeSet<String>>,
    operations: HashMap<String, RegisteredOperation>,
    retired: VecDeque<String>,
}

pub(crate) struct AccountTools {
    registry: Mutex<Registry>,
    authenticator: Arc<dyn AccountAuthenticator>,
    protocol: Arc<dyn ToolProtocol>,
    game_images: Arc<tokio::sync::Mutex<PublicGameImages>>,
}
impl Default for AccountTools {
    fn default() -> Self {
        Self {
            registry: Mutex::new(Registry::default()),
            authenticator: Arc::new(ProtocolAuthenticator),
            protocol: Arc::new(NetworkProtocol),
            game_images: Default::default(),
        }
    }
}
pub(crate) struct Operation<'a> {
    service: &'a AccountTools,
    id: String,
    token: CancellationToken,
}
impl Operation<'_> {
    fn check(&self) -> CoreResult<()> {
        self.token.check()
    }
    async fn run<T>(&self, future: impl Future<Output = CoreResult<T>>) -> CoreResult<T> {
        self.check()?;
        let result = tokio::select! {
            biased;
            _ = self.token.cancelled() => Err(CoreError::Cancelled),
            result = future => result,
        };
        self.check()?;
        result
    }
}
impl Drop for Operation<'_> {
    fn drop(&mut self) {
        if let Ok(mut registry) = self.service.registry.lock() {
            registry.operations.remove(&self.id);
            registry.retired.push_back(self.id.clone());
            while registry.retired.len() > MAX_RETIRED_OPERATIONS {
                registry.retired.pop_front();
            }
        }
    }
}
pub(crate) enum ToolRequest {
    Friends,
    Avatar(String),
    GameImage(String),
    FriendPlayLog(String),
    FriendCode,
    FriendLookup(String),
    FriendRequest(String),
    FriendNote { friend_id: String, note: String },
    Web { force_refresh: bool },
    Seed,
}
pub(crate) enum ToolResponse {
    Friends(NintendoFriendsSnapshot),
    // Internal protocol result: AccountTools owns the single recovery budget
    // before converting this into the public friends snapshot.
    FriendsWithActivity(Vec<NintendoFriend>, CoreResult<Value>),
    Avatar(Vec<u8>),
    GameImage(Vec<u8>),
    FriendPlayLog(Vec<NintendoFriendGame>),
    FriendCode(NintendoFriendCodeSnapshot),
    FriendLookup(NintendoFriendCodeUser),
    FriendRequest(NintendoFriendRequestResult),
    FriendNote,
    Web(SplatNetWebSession),
    Seed(SeedExportPayload),
}

#[async_trait]
trait ToolProtocol: Send + Sync {
    async fn execute(
        &self,
        transport: &HttpTransport,
        client: &NxapiAttestationClient,
        auth: &AuthenticatedCoralSession,
        cache: &mut AccountCache,
        request: &ToolRequest,
    ) -> CoreResult<ToolResponse>;
}
struct NetworkProtocol;
#[async_trait]
impl ToolProtocol for NetworkProtocol {
    async fn execute(
        &self,
        transport: &HttpTransport,
        client: &NxapiAttestationClient,
        auth: &AuthenticatedCoralSession,
        cache: &mut AccountCache,
        request: &ToolRequest,
    ) -> CoreResult<ToolResponse> {
        execute_tool(transport, client, auth, cache, request).await
    }
}

impl AccountTools {
    fn begin(&self, account: &str, id: &str) -> CoreResult<Operation<'_>> {
        if account.trim().is_empty() || id.trim().is_empty() || id.len() > 256 {
            return Err(CoreError::InvalidConfig(
                "Account and operation IDs are required".into(),
            ));
        }
        let mut registry = self.registry.lock().map_err(|_| poisoned())?;
        if registry.retired.iter().any(|v| v == id)
            || registry.operations.get(id).is_some_and(|op| op.started)
        {
            return Err(CoreError::InvalidConfig(
                "Operation ID has already been used".into(),
            ));
        }
        let op = registry
            .operations
            .entry(id.into())
            .or_insert_with(|| RegisteredOperation {
                account: None,
                token: CancellationToken::default(),
                started: false,
            });
        op.account = Some(account.into());
        op.started = true;
        Ok(Operation {
            service: self,
            id: id.into(),
            token: op.token.clone(),
        })
    }

    pub(crate) fn cancel(&self, id: &str) -> CoreResult<bool> {
        if id.trim().is_empty() || id.len() > 256 {
            return Err(CoreError::InvalidConfig("Operation ID is required".into()));
        }
        let mut registry = self.registry.lock().map_err(|_| poisoned())?;
        if let Some(op) = registry.operations.get(id) {
            op.token.cancel();
            return Ok(op.started);
        }
        if !registry.retired.iter().any(|v| v == id) {
            // Retain pre-registration cancellation so crossing bridge calls cannot lose it.
            if registry
                .operations
                .values()
                .filter(|op| !op.started)
                .count()
                >= MAX_RETIRED_OPERATIONS
            {
                return Err(CoreError::InvalidConfig(
                    "Too many pending cancellations".into(),
                ));
            }
            let token = CancellationToken::default();
            token.cancel();
            registry.operations.insert(
                id.into(),
                RegisteredOperation {
                    account: None,
                    token,
                    started: false,
                },
            );
        }
        Ok(false)
    }

    pub(crate) fn clear(&self, account: &str) -> CoreResult<()> {
        let mut registry = self.registry.lock().map_err(|_| poisoned())?;
        registry.generation = registry.generation.wrapping_add(1);
        let generation = registry.generation;
        registry.cleared_accounts.insert(account.into(), generation);
        for op in registry
            .operations
            .values()
            .filter(|op| op.account.as_deref() == Some(account))
        {
            op.token.cancel();
        }
        let mut removed_identities = BTreeSet::from([account.to_owned()]);
        registry.entries.retain(|_, entry| {
            let identities = entry
                .identities
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            if identities.contains(account) {
                removed_identities.extend(identities.iter().cloned());
                entry.removed.cancel();
                false
            } else {
                true
            }
        });
        let removed_keys: Vec<_> = registry
            .client_accounts
            .iter()
            .filter(|(_, identities)| !identities.is_disjoint(&removed_identities))
            .map(|(key, _)| key.clone())
            .collect();
        for key in removed_keys {
            registry.clients.remove(&key);
            registry.client_accounts.remove(&key);
        }
        Ok(())
    }

    pub(crate) fn invalidate_network_context(&self) -> CoreResult<()> {
        let mut registry = self.registry.lock().map_err(|_| poisoned())?;
        // In-flight operations keep their Arc and finish on the transport they
        // started with; new operations must establish fresh proxy-scoped state.
        registry.entries.clear();
        registry.clients.clear();
        registry.client_accounts.clear();
        Ok(())
    }

    fn context(
        &self,
        token: &str,
        account: Option<&str>,
        proxy: Option<&str>,
        transport: &HttpTransport,
    ) -> CoreResult<(Arc<AccountEntry>, NxapiAttestationClient, u64)> {
        if token.trim().is_empty() {
            return Err(CoreError::Authentication(
                "Nintendo session is missing".into(),
            ));
        }
        let proxy_key = hex::encode(Sha256::digest(proxy.unwrap_or("").as_bytes()));
        let key = format!(
            "{}:{proxy_key}",
            hex::encode(Sha256::digest(token.as_bytes()))
        );
        let mut registry = self.registry.lock().map_err(|_| poisoned())?;
        registry
            .entries
            .retain(|_, entry| entry.removed.check().is_ok());
        let generation = registry.generation;
        let template =
            shared_attestation(&mut registry, proxy_key, transport, NxapiConfig::default())?;
        let client = account
            .and_then(|id| {
                registry
                    .clients
                    .get(&account_attestation_key(id, &template.service_key(), proxy))
                    .cloned()
            })
            .unwrap_or_else(|| template.isolated_credentials());
        let entry =
            Arc::clone(registry.entries.entry(key).or_insert_with(|| {
                Arc::new(AccountEntry::new(client, Arc::clone(&self.game_images)))
            }));
        if let Some(account) = account {
            let identities = entry.identities.lock().map_err(|_| poisoned())?;
            if !identities.is_empty() && !identities.contains(account) {
                return Err(CoreError::Authentication(
                    "Nintendo session does not belong to this account".into(),
                ));
            }
        }
        let client = entry.client.clone();
        Ok((entry, client, generation))
    }

    async fn authenticate_locked(
        &self,
        cache: &mut AccountCache,
        entry: &AccountEntry,
        input: AuthenticationInput<'_>,
        force: bool,
    ) -> CoreResult<AuthenticatedCoralSession> {
        entry.removed.check()?;
        if force {
            // Only the Coral credential was rejected by the caller's request.
            // Its Nintendo parent and separately valid children remain reusable.
            cache.auth = None;
        }
        let valid = cache.auth.as_ref().is_some_and(|auth| {
            auth.session
                .expires_at
                .is_some_and(|expiry| super::token_expiry::reusable(expiry, Utc::now()))
        });
        if !valid {
            let auth = self
                .authenticator
                .login_cached(
                    input.transport.clone(),
                    input.client.clone(),
                    input.token,
                    &mut cache.nintendo,
                )
                .await?;
            entry.removed.check()?;
            verify_identity(&auth.session, input.account)?;
            let actual_ids = session_identities(&auth.session);
            if actual_ids.is_empty() {
                return Err(CoreError::Authentication(
                    "Nintendo account identity is missing".into(),
                ));
            }
            // Serialize the identity/cache commit with account removal, including
            // authentication that started before its Nintendo identity was known.
            let mut registry = self.registry.lock().map_err(|_| poisoned())?;
            if actual_ids.iter().any(|id| {
                registry
                    .cleared_accounts
                    .get(id)
                    .is_some_and(|generation| *generation > input.generation)
            }) {
                entry.removed.cancel();
                return Err(CoreError::Cancelled);
            }
            let mut identities = entry.identities.lock().map_err(|_| poisoned())?;
            entry.removed.check()?;
            if !identities.is_subset(&actual_ids) {
                entry.removed.cancel();
                return Err(CoreError::Authentication(
                    "Nintendo session does not belong to this account".into(),
                ));
            }
            let service = input.client.service_key();
            if registry
                .entries
                .values()
                .any(|current| std::ptr::eq(current.as_ref(), entry))
            {
                for id in &actual_ids {
                    let key = account_attestation_key(id, &service, input.proxy);
                    registry.clients.insert(key.clone(), input.client.clone());
                    registry.client_accounts.insert(key, actual_ids.clone());
                }
            }
            *identities = actual_ids;
            cache.auth = Some(auth);
            // Normal renewal of a verified parent does not revoke a separately
            // valid child. Rejections retire only the stage that used it.
        }
        let auth = cache
            .auth
            .as_ref()
            .expect("authentication populated cache")
            .clone();
        verify_identity(&auth.session, input.account)?;
        Ok(auth)
    }

    pub(crate) fn attestation(
        &self,
        session: &CoralSession,
        proxy: Option<&str>,
        transport: &HttpTransport,
    ) -> CoreResult<NxapiAttestationClient> {
        let identities = session_identities(session);
        if identities.is_empty() {
            return Err(CoreError::Authentication(
                "Nintendo account identity is missing".into(),
            ));
        }
        let mut registry = self.registry.lock().map_err(|_| poisoned())?;
        let proxy_key = hex::encode(Sha256::digest(proxy.unwrap_or("").as_bytes()));
        let template =
            shared_attestation(&mut registry, proxy_key, transport, NxapiConfig::default())?;
        let service = template.service_key();
        for id in &identities {
            if let Some(client) = registry
                .clients
                .get(&account_attestation_key(id, &service, proxy))
            {
                return Ok(client.clone());
            }
        }
        let client = template.isolated_credentials();
        for id in &identities {
            let key = account_attestation_key(id, &service, proxy);
            registry.clients.insert(key.clone(), client.clone());
            registry.client_accounts.insert(key, identities.clone());
        }
        Ok(client)
    }

    pub(crate) async fn authenticate(
        &self,
        token: &str,
        account: Option<&str>,
        proxy: Option<&str>,
        transport: HttpTransport,
        cancellation: &CancellationToken,
    ) -> CoreResult<CoralSession> {
        self.authenticate_with_refresh(token, account, proxy, transport, cancellation, false)
            .await
    }

    pub(crate) async fn authenticate_with_refresh(
        &self,
        token: &str,
        account: Option<&str>,
        proxy: Option<&str>,
        transport: HttpTransport,
        cancellation: &CancellationToken,
        force_refresh: bool,
    ) -> CoreResult<CoralSession> {
        cancellation.check()?;
        let (entry, client, generation) = self.context(token, account, proxy, &transport)?;
        tokio::select! {
            biased;
            _ = cancellation.cancelled() => Err(CoreError::Cancelled),
            _ = entry.removed.cancelled() => Err(CoreError::Cancelled),
            result = async {
                let mut cache = entry.cache.lock().await;
                self.authenticate_locked(&mut cache, &entry, AuthenticationInput {
                    token, account, transport: &transport, client: &client, proxy, generation,
                }, force_refresh)
                    .await.map(|auth| auth.session)
            } => result,
        }
    }

    pub(crate) async fn execute(
        &self,
        account: &str,
        token: &str,
        id: &str,
        proxy: Option<&str>,
        transport: HttpTransport,
        request: ToolRequest,
    ) -> CoreResult<ToolResponse> {
        let operation = self.begin(account, id)?;
        operation.run(async {
            let (entry, client, generation) = self.context(token, Some(account), proxy, &transport)?;
            tokio::select! {
                biased;
                _ = entry.removed.cancelled() => Err(CoreError::Cancelled),
                result = async {
                    let mut cache = entry.cache.lock().await;
                    if matches!(request, ToolRequest::Web { force_refresh: true }) {
                        // A web refresh retires its own descendants, not valid
                        // Nintendo/Coral credentials used by friends and albums.
                        cache.splatnet = None;
                    }
                    let mut force_authentication = false;
                    let mut friends_fallback = None;
                    for attempt in 0..2 {
                        let child_usable = !force_authentication
                            && cache.splatnet.as_ref().is_some_and(|session| match request {
                                ToolRequest::Web { .. } => session.reusable_web(Utc::now()),
                                ToolRequest::Seed => session.reusable_bullet(Utc::now())
                                    || session.reusable_web(Utc::now()),
                                _ => false,
                            });
                        let cached_auth = child_usable.then(|| cache.auth.clone()).flatten();
                        let auth = if let Some(auth) = cached_auth {
                            // A valid child is independent of its parent's TTL.
                            // The parent is only sent when a new child is needed.
                            verify_identity(&auth.session, Some(account))?;
                            auth
                        } else {
                            let authentication = self.authenticate_locked(&mut cache, &entry, AuthenticationInput {
                                token, account: Some(account), transport: &transport, client: &client, proxy, generation,
                            }, force_authentication).await;
                            match authentication {
                                Ok(auth) => auth,
                                Err(error) => {
                                    entry.removed.check()?;
                                    operation.check()?;
                                    return match friends_fallback {
                                        Some(friends) => finish_friends(friends, Err(error)).map(ToolResponse::Friends),
                                        None => Err(error),
                                    };
                                }
                            }
                        };
                        let result = self.protocol.execute(&transport, &client, &auth, &mut cache, &request).await;
                        entry.removed.check()?;
                        operation.check()?;
                        match result {
                            Ok(ToolResponse::FriendsWithActivity(friends, activity)) => {
                                if let Err(ref error @ CoreError::Authentication(_)) = activity {
                                    let child_rejected = splatnet::retire_rejected_credential(
                                        &mut cache.splatnet, error,
                                    );
                                    if !child_rejected {
                                        cache.auth = None;
                                    }
                                    if attempt == 0 {
                                        friends_fallback = Some(friends);
                                        force_authentication = !child_rejected;
                                        continue;
                                    }
                                }
                                return finish_friends(friends, activity).map(ToolResponse::Friends);
                            },
                            Err(error) if friends_fallback.is_some() => {
                                if matches!(error, CoreError::Authentication(_))
                                    && !splatnet::retire_rejected_credential(&mut cache.splatnet, &error)
                                {
                                    cache.auth = None;
                                }
                                return finish_friends(friends_fallback.take().expect("checked fallback"), Err(error))
                                    .map(ToolResponse::Friends);
                            },
                            Err(ref error @ CoreError::Authentication(_)) => {
                                let child_rejected = splatnet::retire_rejected_credential(
                                    &mut cache.splatnet, error,
                                );
                                if !child_rejected {
                                    cache.auth = None;
                                }
                                if attempt == 0 {
                                    force_authentication = !child_rejected;
                                    continue;
                                }
                                return result;
                            },
                            other => return other,
                        }
                    }
                    unreachable!("bounded authentication retry")
                } => result,
            }
        }).await
    }
}

fn account_attestation_key(account: &str, service: &str, proxy: Option<&str>) -> String {
    format!(
        "account:{}:service:{}:proxy:{}",
        hex::encode(Sha256::digest(account.as_bytes())),
        service,
        hex::encode(Sha256::digest(proxy.unwrap_or("").as_bytes()))
    )
}

fn shared_attestation(
    registry: &mut Registry,
    key: String,
    transport: &HttpTransport,
    config: NxapiConfig,
) -> CoreResult<NxapiAttestationClient> {
    if let Some(client) = registry.clients.get(&key) {
        return Ok(client.clone());
    }
    let strict = transport.without_redirects()?;
    let client = NxapiAttestationClient::new(
        strict.with_timeout(crate::transport::NXAPI_REQUEST_TIMEOUT)?,
        config,
    );
    registry.clients.insert(key, client.clone());
    Ok(client)
}

fn poisoned() -> CoreError {
    CoreError::Provider("Account tools state is unavailable".into())
}
fn verify_identity(session: &CoralSession, account: Option<&str>) -> CoreResult<()> {
    if account.is_some_and(|id| !session_identities(session).contains(id)) {
        Err(CoreError::Authentication(
            "Nintendo session does not belong to this account".into(),
        ))
    } else {
        Ok(())
    }
}

fn session_identities(session: &CoralSession) -> BTreeSet<String> {
    session
        .na_id
        .iter()
        .chain(session.coral_user_id.iter())
        .filter(|id| !id.is_empty())
        .cloned()
        .collect()
}

pub(crate) fn ensure_response(response: &HttpResponseData, operation: &str) -> CoreResult<()> {
    response.ensure_success_redacted(operation)
}

pub(crate) async fn coral_call<A: AttestationService>(
    transport: &HttpTransport,
    attestation: &A,
    session: &CoralSession,
    url: &str,
    parameter: Value,
    method: u8,
) -> CoreResult<Value> {
    // /encrypt-request takes a complete Coral JSON body. /f instead takes
    // token-operation fields, and CreateFriendCodeUrl explicitly has no parameter.
    let parameter = if method == 0
        && parameter.get("parameter").is_none()
        && !url::Url::parse(url)
            .ok()
            .is_some_and(|url| url.path() == "/v3/Friend/CreateFriendCodeUrl")
    {
        json!({"parameter": parameter})
    } else {
        parameter
    };
    let encrypted = attestation
        .encrypt_request(
            url,
            &session.access_token,
            parameter,
            method,
            session.na_id.as_deref(),
            session.coral_user_id.as_deref(),
        )
        .await?;
    let version = attestation.nso_version().await?;
    let response = transport
        .post_bytes_raw(
            url,
            &[
                ("Authorization", format!("Bearer {}", session.access_token)),
                ("User-Agent", nintendo_user_agent(&version)),
                ("X-Platform", "Android".into()),
                ("X-ProductVersion", version),
                ("Content-Type", "application/octet-stream".into()),
                ("Accept", "application/octet-stream,application/json".into()),
            ],
            encrypted.body,
        )
        .await?;
    ensure_response(&response, "Nintendo account request")?;
    let value = attestation.decrypt_response(&response.body).await?;
    let status = value.get("status").and_then(Value::as_i64).unwrap_or(0);
    if matches!(status, 429 | 9437) {
        return Err(CoreError::RateLimited {
            retry_after_seconds: 60,
        });
    }
    if method == 2
        && url::Url::parse(url)
            .ok()
            .is_some_and(|url| url.path() == "/v4/Game/GetWebServiceToken")
        && value.get("errorMessage").and_then(Value::as_str) == Some("Membership required error.")
    {
        return Err(CoreError::Provider("nso_membership_required".into()));
    }
    let endpoint = url::Url::parse(url).ok().map(|url| url.path().to_owned());
    super::conditions::ensure_coral_success_for_endpoint(&value, endpoint.as_deref())?;
    Ok(value)
}

async fn execute_tool(
    transport: &HttpTransport,
    client: &NxapiAttestationClient,
    auth: &AuthenticatedCoralSession,
    cache: &mut AccountCache,
    request: &ToolRequest,
) -> CoreResult<ToolResponse> {
    match request {
        ToolRequest::Friends => {
            let raw = coral_call(
                transport,
                client,
                &auth.session,
                &format!("{CORAL_ORIGIN}/v4/Friend/List"),
                json!({"parameter":{}}),
                0,
            )
            .await?;
            let (friends, avatars) = parse_friends(&raw)?;
            for friend in &friends {
                if let Some(name) = friend.game_name.as_deref() {
                    cache.remember_game(name, friend.game_image_url.as_deref());
                }
            }
            cache
                .avatar_bytes
                .retain(|id, (url, _)| avatars.get(id) == Some(url));
            cache.avatars = avatars;
            let activity = async {
                let session =
                    splatnet::session(transport, client, auth, &mut cache.splatnet).await?;
                splatnet::query(transport, &session, splatnet::Query::Friends).await
            }
            .await;
            Ok(ToolResponse::FriendsWithActivity(friends, activity))
        }
        ToolRequest::Avatar(id) => {
            let url = cache
                .lookup_avatar
                .as_ref()
                .filter(|(lookup_id, _)| lookup_id == id)
                .map(|(_, url)| url)
                .or_else(|| cache.avatars.get(id))
                .ok_or_else(|| {
                    CoreError::InvalidConfig(
                        "Load a friend list or lookup preview before opening this avatar".into(),
                    )
                })?
                .clone();
            if let Some(bytes) = cache.cached_avatar(id, &url) {
                return Ok(ToolResponse::Avatar(bytes));
            }
            let version = client.nso_version().await?;
            let bytes = transport
                .clone()
                .with_nso_downloads(&version)
                .download_avatar(&url)
                .await?;
            cache.remember_avatar(id, &url, &bytes);
            Ok(ToolResponse::Avatar(bytes))
        }
        ToolRequest::FriendPlayLog(friend_id) => {
            if friend_id.trim().is_empty() || friend_id.len() > 128 {
                return Err(CoreError::InvalidConfig("invalid friend identity".into()));
            }
            let raw = coral_call(
                transport,
                client,
                &auth.session,
                &format!("{CORAL_ORIGIN}/v4/User/PlayLog/Show"),
                json!({"nsaId": friend_id}),
                0,
            )
            .await?;
            let games = parse_friend_play_log(&raw)?;
            for game in &games {
                cache.remember_game(&game.name, game.image_url.as_deref());
            }
            Ok(ToolResponse::FriendPlayLog(games))
        }
        ToolRequest::GameImage(name) => {
            let url = cache.game_urls.get(name).ok_or_else(|| {
                CoreError::InvalidConfig("Load game information before opening its image".into())
            })?;
            let mut images = cache.game_images.lock().await;
            let bytes = images
                .load(name, url, async {
                    let version = client.nso_version().await?;
                    transport
                        .clone()
                        .with_nso_downloads(&version)
                        .download_avatar(url)
                        .await
                })
                .await?;
            Ok(ToolResponse::GameImage(bytes))
        }
        ToolRequest::FriendCode => {
            let raw = coral_call(
                transport,
                client,
                &auth.session,
                &format!("{CORAL_ORIGIN}/v3/Friend/CreateFriendCodeUrl"),
                json!({}),
                0,
            )
            .await?;
            let result = raw.get("result").unwrap_or(&raw);
            let friend_code = result
                .get("friendCode")
                .and_then(Value::as_str)
                .filter(|value| value.len() == 14)
                .ok_or_else(|| CoreError::Provider("Nintendo friend code is unavailable".into()))?;
            let url = result
                .get("url")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            Ok(ToolResponse::FriendCode(NintendoFriendCodeSnapshot {
                friend_code: friend_code.to_owned(),
                url,
            }))
        }
        ToolRequest::FriendLookup(code) => {
            if !is_friend_code(code) {
                return Err(CoreError::InvalidConfig("invalid friend code".into()));
            }
            let raw = coral_call(
                transport,
                client,
                &auth.session,
                &format!("{CORAL_ORIGIN}/v3/Friend/GetUserByFriendCode"),
                json!({"friendCode": format!("{}-{}-{}", &code[..4], &code[4..8], &code[8..])}),
                0,
            )
            .await?;
            let result = raw.get("result").unwrap_or(&raw);
            Ok(ToolResponse::FriendLookup(cache.lookup_preview(result)?))
        }
        ToolRequest::FriendRequest(friend_id) => {
            if friend_id.trim().is_empty() || friend_id.len() > 128 {
                return Err(CoreError::InvalidConfig("invalid friend identity".into()));
            }
            coral_call(
                transport,
                client,
                &auth.session,
                &format!("{CORAL_ORIGIN}/v4/FriendRequest/Create"),
                json!({"nsaId": friend_id, "channel": "FRIEND_CODE"}),
                0,
            )
            .await?;
            Ok(ToolResponse::FriendRequest(NintendoFriendRequestResult {
                friend_id: friend_id.clone(),
                accepted: true,
            }))
        }
        ToolRequest::FriendNote { friend_id, note } => {
            if friend_id.trim().is_empty() || friend_id.len() > 128 {
                return Err(CoreError::InvalidConfig("invalid friend identity".into()));
            }
            if note.chars().count() > 20 {
                return Err(CoreError::InvalidConfig(
                    "friend note cannot be longer than 20 characters".into(),
                ));
            }
            coral_call(
                transport,
                client,
                &auth.session,
                &format!("{CORAL_ORIGIN}/v4/Friend/Note/Update"),
                json!({"friendNsaId": friend_id, "note": note}),
                0,
            )
            .await?;
            Ok(ToolResponse::FriendNote)
        }
        ToolRequest::Web { .. } => {
            let session =
                splatnet::web_session(transport, client, auth, &mut cache.splatnet).await?;
            Ok(ToolResponse::Web(session))
        }
        ToolRequest::Seed => {
            let session = splatnet::session(transport, client, auth, &mut cache.splatnet).await?;
            let latest = splatnet::query(transport, &session, splatnet::Query::Latest).await?;
            let player = splatnet::player_id(&latest)?;
            let gear = splatnet::query(transport, &session, splatnet::Query::Gear).await?;
            Ok(ToolResponse::Seed(splatnet::seed_export(
                &player,
                gear,
                Utc::now().timestamp(),
            )?))
        }
    }
}

fn is_friend_code(value: &str) -> bool {
    value.len() == 12 && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn safe_activity_error(error: &CoreError) -> &'static str {
    if let Some(condition) = super::conditions::safe_activity_condition(error) {
        return condition;
    }
    match error {
        CoreError::RateLimited { .. } => "splatnet_rate_limited",
        CoreError::Authentication(_) => "splatnet_authentication_failed",
        _ => "splatnet_activity_unavailable",
    }
}

fn finish_friends(
    mut friends: Vec<NintendoFriend>,
    activity: CoreResult<Value>,
) -> CoreResult<NintendoFriendsSnapshot> {
    let activity_error = match activity.and_then(|data| supplement_friends(&mut friends, &data)) {
        Ok(()) => None,
        Err(CoreError::Cancelled) => return Err(CoreError::Cancelled),
        Err(error) => Some(safe_activity_error(&error).into()),
    };
    Ok(NintendoFriendsSnapshot {
        friends,
        updated_at: Utc::now(),
        activity_error,
    })
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;

    pub(crate) fn service_with_clients(
        authenticator: Arc<dyn AccountAuthenticator>,
        clients: Vec<(Option<String>, NxapiAttestationClient)>,
    ) -> AccountTools {
        let mut registry = Registry::default();
        for (proxy, client) in clients {
            let key = hex::encode(Sha256::digest(proxy.as_deref().unwrap_or("").as_bytes()));
            registry.clients.insert(key, client);
        }
        AccountTools {
            registry: Mutex::new(registry),
            authenticator,
            protocol: Arc::new(NetworkProtocol),
            game_images: Default::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    use serde_json::json;

    #[test]
    fn avatar_cache_matches_download_url_and_is_account_owned_and_bounded() {
        let mut first = AccountCache::default();
        let second = AccountCache::default();
        first.remember_avatar("friend", "https://example.com/a.png", &[1, 2]);
        assert_eq!(
            first.cached_avatar("friend", "https://example.com/a.png"),
            Some(vec![1, 2])
        );
        assert_eq!(
            first.cached_avatar("friend", "https://example.com/b.png"),
            None
        );
        assert_eq!(
            second.cached_avatar("friend", "https://example.com/a.png"),
            None
        );
        for id in 0..256 {
            first.remember_avatar(&id.to_string(), "https://example.com/a.png", &[1]);
        }
        assert!(first.avatar_bytes.len() <= 128);
    }

    #[tokio::test]
    async fn game_art_is_public_but_each_account_must_register_its_source() {
        let transport = HttpTransport::new(Default::default()).unwrap();
        let client = NxapiAttestationClient::new(transport.clone(), Default::default());
        let images = Arc::new(tokio::sync::Mutex::new(PublicGameImages::default()));
        images
            .lock()
            .await
            .load("Game", "https://example.com/game", async {
                Ok(vec![1, 2, 3])
            })
            .await
            .unwrap();
        let mut account = AccountCache {
            game_images: Arc::clone(&images),
            ..Default::default()
        };
        let request = ToolRequest::GameImage("Game".into());
        assert!(matches!(
            execute_tool(&transport, &client, &test_auth(), &mut account, &request).await,
            Err(CoreError::InvalidConfig(_))
        ));
        account.remember_game("Game", Some("https://example.com/game"));
        let result = execute_tool(&transport, &client, &test_auth(), &mut account, &request)
            .await
            .unwrap();
        assert!(matches!(result, ToolResponse::GameImage(bytes) if bytes == vec![1, 2, 3]));
        let mut second = AccountCache {
            game_images: images,
            ..Default::default()
        };
        second.remember_game("Game", Some("https://example.com/game"));
        let result = execute_tool(&transport, &client, &test_auth(), &mut second, &request)
            .await
            .unwrap();
        assert!(matches!(result, ToolResponse::GameImage(bytes) if bytes == vec![1, 2, 3]));
    }

    #[test]
    fn lookup_preview_requires_a_valid_stable_id() {
        for invalid in ["", " ", &"x".repeat(129), "https://example.com/a.png"] {
            let mut cache = AccountCache::default();
            let result = cache.lookup_preview(&json!({
                "nsaId": invalid, "name": "Synthetic lookup"
            }));
            assert!(matches!(result, Err(CoreError::Provider(_))), "{invalid}");
            assert!(cache.lookup_avatar.is_none());
        }
    }

    #[tokio::test]
    async fn lookup_avatar_uses_the_latest_query_url_and_keeps_accounts_isolated() {
        let transport = HttpTransport::new(Default::default()).unwrap();
        let client = NxapiAttestationClient::new(
            transport.clone(),
            NxapiConfig {
                znca_base_url: "http://127.0.0.1:1".into(),
                ..Default::default()
            },
        );
        let mut cache = AccountCache::default();
        cache.avatars.insert(
            "synthetic-lookup".into(),
            "https://example.com/old.png".into(),
        );
        cache.remember_avatar("synthetic-lookup", "https://example.com/old.png", &[1]);
        let preview = cache
            .lookup_preview(&json!({
                "nsaId": "synthetic-lookup", "name": "Synthetic lookup",
                "imageUri": "https://example.com/new.png"
            }))
            .unwrap();
        assert_eq!(preview.nickname, "Synthetic lookup");
        assert_eq!(
            preview.avatar_url.as_deref(),
            Some("https://example.com/new.png")
        );
        cache.remember_avatar("synthetic-lookup", "https://example.com/new.png", &[2]);
        let request = ToolRequest::Avatar(preview.friend_id);
        let response = execute_tool(&transport, &client, &test_auth(), &mut cache, &request)
            .await
            .unwrap();
        assert!(matches!(response, ToolResponse::Avatar(bytes) if bytes == vec![2]));
        let mut other_account = AccountCache::default();
        assert!(matches!(
            execute_tool(
                &transport,
                &client,
                &test_auth(),
                &mut other_account,
                &request
            )
            .await,
            Err(CoreError::InvalidConfig(_))
        ));
    }

    #[tokio::test]
    async fn only_the_latest_lookup_registers_an_unknown_users_avatar() {
        let transport = HttpTransport::new(Default::default()).unwrap();
        let client = NxapiAttestationClient::new(transport.clone(), Default::default());
        let mut cache = AccountCache::default();
        cache
            .lookup_preview(&json!({
                "nsaId": "first", "name": "First", "imageUri": "https://example.com/first.png"
            }))
            .unwrap();
        cache
            .lookup_preview(&json!({
                "nsaId": "second", "name": "Second", "imageUri": "https://example.com/second.png"
            }))
            .unwrap();
        assert!(matches!(
            execute_tool(
                &transport,
                &client,
                &test_auth(),
                &mut cache,
                &ToolRequest::Avatar("first".into())
            )
            .await,
            Err(CoreError::InvalidConfig(_))
        ));
        cache
            .lookup_preview(&json!({"nsaId": "third", "name": "Third"}))
            .unwrap();
        assert!(matches!(
            execute_tool(
                &transport,
                &client,
                &test_auth(),
                &mut cache,
                &ToolRequest::Avatar("second".into())
            )
            .await,
            Err(CoreError::InvalidConfig(_))
        ));
    }

    #[tokio::test]
    async fn shared_nxapi_client_uses_sixty_second_timeout_without_retrying_slow_config() {
        use std::io::{Read, Write};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                .unwrap();
            let mut request = [0; 2048];
            let length = socket.read(&mut request).unwrap();
            assert!(std::str::from_utf8(&request[..length])
                .unwrap()
                .starts_with("GET /config "));
            std::thread::sleep(std::time::Duration::from_millis(350));
            let body = r#"{"nso_version":"3.9.9"}"#;
            write!(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
            1
        });
        let transport = HttpTransport::new(crate::transport::TransportConfig {
            timeout: std::time::Duration::from_millis(80),
            ..Default::default()
        })
        .unwrap();
        let client = shared_attestation(
            &mut Registry::default(),
            "synthetic-proxy".into(),
            &transport,
            NxapiConfig {
                znca_base_url: base,
                ..Default::default()
            },
        )
        .unwrap();
        let result = client.nso_version().await;
        let requests = server.join().unwrap();

        assert_eq!(result.unwrap(), "3.9.9");
        assert_eq!(
            requests, 1,
            "the NXAPI-scoped timeout must avoid the transient-timeout retry"
        );
    }

    struct OAuthProbe {
        url: String,
        issued: Arc<std::sync::atomic::AtomicUsize>,
        encryptions: Arc<Mutex<Vec<Value>>>,
        stop: Arc<std::sync::atomic::AtomicBool>,
        worker: Option<std::thread::JoinHandle<()>>,
    }

    impl OAuthProbe {
        fn new() -> Self {
            use std::io::{Read, Write};
            use std::sync::atomic::Ordering;
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            let issued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let encryptions = Arc::new(Mutex::new(Vec::new()));
            let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let thread_issued = Arc::clone(&issued);
            let thread_encryptions = Arc::clone(&encryptions);
            let thread_stop = Arc::clone(&stop);
            let worker = std::thread::spawn(move || {
                let mut bindings = HashMap::<String, String>::new();
                while !thread_stop.load(Ordering::SeqCst) {
                    let mut connection = match listener.accept() {
                        Ok((connection, _)) => connection,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(std::time::Duration::from_millis(5));
                            continue;
                        }
                        Err(error) => panic!("test listener failed: {error}"),
                    };
                    connection.set_nonblocking(false).unwrap();
                    connection
                        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                        .unwrap();
                    let mut request = Vec::new();
                    let mut buffer = [0; 1024];
                    let header_end = loop {
                        let count = connection.read(&mut buffer).unwrap();
                        assert!(count > 0);
                        request.extend_from_slice(&buffer[..count]);
                        assert!(request.len() <= 64 * 1024);
                        if let Some(end) = request.windows(4).position(|v| v == b"\r\n\r\n") {
                            break end + 4;
                        }
                    };
                    let headers = String::from_utf8(request[..header_end].to_vec()).unwrap();
                    let length = headers
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    while request.len() < header_end + length {
                        let count = connection.read(&mut buffer).unwrap();
                        assert!(count > 0);
                        request.extend_from_slice(&buffer[..count]);
                    }
                    let path = headers.split_whitespace().nth(1).unwrap();
                    let (status, body) = match path {
                        "/config" => (200, json!({"nso_version": "3.9.9"})),
                        "/oauth" => {
                            let number = thread_issued.fetch_add(1, Ordering::SeqCst) + 1;
                            (
                                200,
                                json!({"access_token": format!("synthetic-oauth-{number}"), "expires_in": 3600}),
                            )
                        }
                        "/f" => {
                            let parameter: Value =
                                serde_json::from_slice(&request[header_end..header_end + length])
                                    .unwrap();
                            if parameter["hash_method"] == 2 {
                                thread_encryptions.lock().unwrap().push(parameter);
                                (400, json!({"error": "invalid_request"}))
                            } else {
                                let account = parameter["na_id"].as_str().unwrap();
                                let bearer = headers
                                    .lines()
                                    .find_map(|line| {
                                        let (name, value) = line.split_once(':')?;
                                        name.eq_ignore_ascii_case("authorization")
                                            .then(|| value.trim().to_owned())
                                    })
                                    .unwrap();
                                let owner =
                                    bindings.entry(bearer).or_insert_with(|| account.into());
                                if owner == account {
                                    (200, json!({"encrypted_token_request": "dGVzdA=="}))
                                } else {
                                    (
                                        400,
                                        json!({"error": "invalid_request", "error_description": "synthetic token belongs to another user"}),
                                    )
                                }
                            }
                        }
                        "/encrypt-request" => {
                            thread_encryptions.lock().unwrap().push(
                                serde_json::from_slice(&request[header_end..header_end + length])
                                    .unwrap(),
                            );
                            // Stop at the synthetic encryption service. No request may
                            // continue to Nintendo or mutate a real account.
                            (400, json!({"error": "invalid_request"}))
                        }
                        _ => panic!("unexpected synthetic request: {path}"),
                    };
                    let body = body.to_string();
                    write!(
                        connection,
                        "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .unwrap();
                }
            });
            Self {
                url,
                issued,
                encryptions,
                stop,
                worker: Some(worker),
            }
        }
    }

    impl Drop for OAuthProbe {
        fn drop(&mut self) {
            self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
            self.worker.take().unwrap().join().unwrap();
        }
    }

    #[tokio::test]
    async fn coral_tools_send_complete_request_bodies_to_nxapi_before_encryption() {
        let probe = OAuthProbe::new();
        let transport = HttpTransport::new(Default::default()).unwrap();
        let client = NxapiAttestationClient::new(
            transport.clone(),
            NxapiConfig {
                znca_base_url: probe.url.clone(),
                oauth_url: format!("{}/oauth", probe.url),
                ..Default::default()
            },
        );
        let auth = test_auth();
        let mut cache = AccountCache::default();
        let cases = [
            (
                ToolRequest::FriendPlayLog("synthetic-friend".into()),
                "/v4/User/PlayLog/Show",
                json!({"parameter": {"nsaId": "synthetic-friend"}}),
            ),
            (
                ToolRequest::FriendLookup("123456789012".into()),
                "/v3/Friend/GetUserByFriendCode",
                json!({"parameter": {"friendCode": "1234-5678-9012"}}),
            ),
            (
                ToolRequest::FriendRequest("synthetic-friend".into()),
                "/v4/FriendRequest/Create",
                json!({"parameter": {"nsaId": "synthetic-friend", "channel": "FRIEND_CODE"}}),
            ),
            (
                ToolRequest::FriendNote {
                    friend_id: "synthetic-friend".into(),
                    note: "synthetic note".into(),
                },
                "/v4/Friend/Note/Update",
                json!({"parameter": {"friendNsaId": "synthetic-friend", "note": "synthetic note"}}),
            ),
            (
                ToolRequest::Friends,
                "/v4/Friend/List",
                json!({"parameter": {}}),
            ),
            (
                ToolRequest::FriendCode,
                "/v3/Friend/CreateFriendCodeUrl",
                json!({}),
            ),
        ];
        for (request, path, expected) in cases {
            let result = execute_tool(&transport, &client, &auth, &mut cache, &request).await;
            assert!(
                matches!(result, Err(CoreError::Provider(_))),
                "the synthetic NXAPI service must stop the request before Nintendo"
            );
            let captured = probe.encryptions.lock().unwrap().pop().unwrap();
            assert_eq!(captured["url"], format!("{CORAL_ORIGIN}{path}"));
            assert_eq!(captured["token"], "coral-only");
            let plaintext: Value =
                serde_json::from_str(captured["data"].as_str().unwrap()).unwrap();
            assert_eq!(plaintext, expected, "{path}");
        }

        use super::super::provider::{CoralAlbumProvider, MediaProvider};
        let album = CoralAlbumProvider::new(transport, client, auth.session);
        assert!(matches!(
            album.list_recent(None).await,
            Err(CoreError::Provider(_))
        ));
        let captured = probe.encryptions.lock().unwrap().pop().unwrap();
        assert_eq!(captured["url"], format!("{CORAL_ORIGIN}/v4/Media/List"));
        assert_eq!(captured["token"], "coral-only");
        let plaintext: Value = serde_json::from_str(captured["data"].as_str().unwrap()).unwrap();
        assert_eq!(plaintext, json!({"parameter": {}}));
    }

    #[tokio::test]
    async fn second_account_gets_its_own_nxapi_oauth_token_and_first_keeps_reusing_its_token() {
        let probe = OAuthProbe::new();
        let transport = HttpTransport::new(Default::default()).unwrap();
        let client = NxapiAttestationClient::new(
            transport.clone(),
            NxapiConfig {
                znca_base_url: probe.url.clone(),
                oauth_url: format!("{}/oauth", probe.url),
                ..Default::default()
            },
        );
        let (mut service, _) = test_service(None);
        service
            .registry
            .get_mut()
            .unwrap()
            .clients
            .insert(hex::encode(Sha256::digest(b"")), client);
        for (token, account) in [
            ("session-a", "account-a"),
            ("session-b", "account-b"),
            ("session-a", "account-a"),
        ] {
            let (_, client, _) = service.context(token, None, None, &transport).unwrap();
            client
                .encrypt_request(
                    "https://example.invalid/login",
                    "synthetic-id-token",
                    json!({}),
                    1,
                    Some(account),
                    None,
                )
                .await
                .expect("NXAPI credentials must never be reused for a different account");
        }
        assert_eq!(probe.issued.load(std::sync::atomic::Ordering::SeqCst), 2);
        // Authentication and later album sync must use the same account scope.
        let session = service
            .authenticate(
                "session-a",
                Some("account-a"),
                None,
                transport.clone(),
                &CancellationToken::default(),
            )
            .await
            .unwrap();
        service
            .attestation(&session, None, &transport)
            .unwrap()
            .encrypt_request(
                "https://example.invalid/login",
                "synthetic-id-token",
                json!({}),
                1,
                Some("account-a"),
                None,
            )
            .await
            .unwrap();
        assert_eq!(probe.issued.load(std::sync::atomic::Ordering::SeqCst), 2);

        // Removing A invalidates its aliases/credential without clearing B.
        service.clear("account-a").unwrap();
        for (token, account) in [("session-b", "account-b"), ("session-a", "account-a")] {
            let (_, client, _) = service.context(token, None, None, &transport).unwrap();
            client
                .encrypt_request(
                    "https://example.invalid/login",
                    "synthetic-id-token",
                    json!({}),
                    1,
                    Some(account),
                    None,
                )
                .await
                .unwrap();
        }
        assert_eq!(probe.issued.load(std::sync::atomic::Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn same_account_reuses_nxapi_oauth_token_across_session_credentials() {
        let probe = OAuthProbe::new();
        let transport = HttpTransport::new(Default::default()).unwrap();
        let client = NxapiAttestationClient::new(
            transport.clone(),
            NxapiConfig {
                znca_base_url: probe.url.clone(),
                oauth_url: format!("{}/oauth", probe.url),
                ..Default::default()
            },
        );
        let (mut service, _) = test_service(None);
        service
            .registry
            .get_mut()
            .unwrap()
            .clients
            .insert(hex::encode(Sha256::digest(b"")), client);
        let cancellation = CancellationToken::default();
        for token in ["session-a", "session-c"] {
            service
                .authenticate(
                    token,
                    Some("account-a"),
                    None,
                    transport.clone(),
                    &cancellation,
                )
                .await
                .unwrap();
            let (_, client, _) = service
                .context(token, Some("account-a"), None, &transport)
                .unwrap();
            client
                .encrypt_request(
                    "https://example.invalid/login",
                    "synthetic-id-token",
                    json!({}),
                    1,
                    Some("account-a"),
                    None,
                )
                .await
                .unwrap();
        }
        assert_eq!(
            probe.issued.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "same account/service/proxy must share one OAuth token cache"
        );
    }

    #[tokio::test]
    async fn legacy_sync_scopes_tokens_and_account_removal_revokes_all_identity_aliases() {
        let probe = OAuthProbe::new();
        let transport = HttpTransport::new(Default::default()).unwrap();
        let client = NxapiAttestationClient::new(
            transport.clone(),
            NxapiConfig {
                znca_base_url: probe.url.clone(),
                oauth_url: format!("{}/oauth", probe.url),
                ..Default::default()
            },
        );
        let (mut service, _) = test_service(None);
        service
            .registry
            .get_mut()
            .unwrap()
            .clients
            .insert(hex::encode(Sha256::digest(b"")), client);
        let first = test_auth().session;
        let mut second = first.clone();
        second.na_id = Some("account-b".into());
        second.coral_user_id = Some("999999".into());
        for session in [&first, &second, &first] {
            service
                .attestation(session, None, &transport)
                .unwrap()
                .encrypt_request(
                    "https://example.invalid/login",
                    "synthetic-id-token",
                    json!({}),
                    1,
                    session.na_id.as_deref(),
                    None,
                )
                .await
                .unwrap();
        }
        assert_eq!(probe.issued.load(std::sync::atomic::Ordering::SeqCst), 2);
        service.clear("account-a").unwrap();
        service
            .attestation(&first, None, &transport)
            .unwrap()
            .encrypt_request(
                "https://example.invalid/login",
                "synthetic-id-token",
                json!({}),
                1,
                first.na_id.as_deref(),
                None,
            )
            .await
            .unwrap();
        assert_eq!(probe.issued.load(std::sync::atomic::Ordering::SeqCst), 3);
    }

    #[test]
    fn friend_mapping_keeps_unknown_presence_and_does_not_match_names() {
        let (mut friends, avatars) = parse_friends(&json!({"result":{"friends":[
            {"nsaId":"a","name":"same","note":"one","isFavoriteFriend":true,
             "imageUri":"https://example.com/a.png","friendCreatedAt":1700000000,
             "route":{"channel":"FRIEND_CODE","userName":"inkling","appName":"Source game"},
             "presence":{"state":"ONLINE","game":{"name":"Splatoon 3","imageUri":"https://example.com/game.png",
             "shopUri":"https://example.com/shop","firstPlayedAt":1690000000,"totalPlayTime":123}}},
            {"nsaId":"b","name":"same","presence":{"state":"NEW_STATE"}}
        ]}})).unwrap();
        supplement_friends(
            &mut friends,
            &json!({"data":{"friends":{"nodes":[
                {"id":"RnJpZW5kLWE=","nickname":"same","onlineState":"VS_MODE_MATCHING"},
                {"nsaId":"unrelated","nickname":"same","onlineState":"COOP_MODE_FIGHTING"}
            ]}}}),
        )
        .unwrap();
        assert_eq!(friends[0].activity.as_deref(), Some("MATCHING"));
        assert_eq!(friends[1].activity, None);
        assert_eq!(friends[1].presence, "UNKNOWN");
        assert_eq!(friends[0].total_play_time_minutes, Some(123));
        assert_eq!(friends[0].in_game_name.as_deref(), Some("inkling"));
        assert_eq!(friends[0].friendship_source.as_deref(), Some("FRIEND_CODE"));
        assert_eq!(
            serde_json::to_value(&friends[0]).unwrap()["friendship_game_name"],
            "Source game"
        );
        assert_eq!(
            friends[0].game_image_url.as_deref(),
            Some("https://example.com/game.png")
        );
        assert_eq!(
            friends[0].friend_created_at,
            Some(Utc.timestamp_opt(1_700_000_000, 0).single().unwrap())
        );
        assert_eq!(
            friends[0].first_played_at,
            Some(Utc.timestamp_opt(1_690_000_000, 0).single().unwrap())
        );
        assert_eq!(avatars["a"], "https://example.com/a.png");
        assert_eq!(
            friends[0].avatar_url.as_deref(),
            Some("https://example.com/a.png")
        );
        assert_eq!(friends[1].avatar_url, None);
    }

    #[test]
    fn friend_play_log_maps_only_service_returned_games_and_times() {
        let games = parse_friend_play_log(&json!({"result":[
            {
                "name":"Splatoon 3",
                "imageUri":"https://example.com/splatoon3.png",
                "totalPlayTime":123,
                "firstPlayedAt":1690000000
            },
            {
                "name":"Game without optional metadata",
                "totalPlayTime":0,
                "firstPlayedAt":0
            }
        ]}))
        .unwrap();

        assert_eq!(games.len(), 2);
        assert_eq!(games[0].name, "Splatoon 3");
        assert_eq!(
            games[0].image_url.as_deref(),
            Some("https://example.com/splatoon3.png")
        );
        assert_eq!(games[0].total_play_time_minutes, Some(123));
        assert_eq!(
            games[0].first_played_at,
            Some(Utc.timestamp_opt(1_690_000_000, 0).single().unwrap())
        );
        assert_eq!(games[1].image_url, None);
        assert_eq!(games[1].first_played_at, None);
    }

    #[test]
    fn friend_code_validation_accepts_only_twelve_ascii_digits() {
        assert!(is_friend_code("123456789012"));
        assert!(!is_friend_code("1234-5678-9012"));
        assert!(!is_friend_code("SW-1234-5678-9012"));
        assert!(!is_friend_code("12345678901"));
        assert!(!is_friend_code("1234567890123"));
        assert!(!is_friend_code("12345678901a"));
        assert!(!is_friend_code("１２３４５６７８９０１２"));
        assert!(!is_friend_code(""));
    }

    #[test]
    fn account_attestation_cache_key_separates_account_service_and_proxy() {
        let base = account_attestation_key("account-a", "service-a", None);
        assert_ne!(
            base,
            account_attestation_key("account-b", "service-a", None)
        );
        assert_ne!(
            base,
            account_attestation_key("account-a", "service-b", None)
        );
        assert_ne!(
            base,
            account_attestation_key("account-a", "service-a", Some("http://proxy"))
        );
    }

    #[tokio::test]
    async fn cancel_before_registration_is_not_lost_and_ids_are_independent() {
        let service = AccountTools::default();
        assert!(!service.cancel("early").unwrap());
        let early = service.begin("a", "early").unwrap();
        assert!(matches!(early.check(), Err(CoreError::Cancelled)));
        let other = service.begin("a", "other").unwrap();
        assert!(other.check().is_ok());
        service.clear("a").unwrap();
        assert!(matches!(other.check(), Err(CoreError::Cancelled)));
        assert!(service.begin("a", "new-operation").unwrap().check().is_ok());
    }

    struct RecordingAttestation {
        method: u8,
    }
    #[async_trait]
    impl AttestationService for RecordingAttestation {
        async fn encrypt_request(
            &self,
            url: &str,
            token: &str,
            parameter: Value,
            method: u8,
            na_id: Option<&str>,
            coral_user_id: Option<&str>,
        ) -> CoreResult<super::super::EncryptedRequest> {
            assert!(url.starts_with("http://127.0.0.1:"));
            assert_eq!(token, "coral-only");
            assert_eq!(method, self.method);
            assert_eq!(na_id, Some("account-a"));
            assert_eq!(coral_user_id, Some("123456"));
            match self.method {
                0 => assert_eq!(parameter, json!({"parameter":{}})),
                2 => assert_eq!(
                    parameter,
                    json!({"id":4834290508791808_u64,
                    "registrationToken":"coral-only","requestId":"","f":"","timestamp":0})
                ),
                _ => panic!("unexpected attestation method"),
            }
            Ok(super::super::EncryptedRequest {
                body: b"encrypted-body".to_vec(),
                request_id: "".into(),
                timestamp: 0,
            })
        }
        async fn decrypt_response(&self, _: &[u8]) -> CoreResult<Value> {
            Ok(json!({"status":0,"result":{"accessToken":"game-token","expiresIn":10800}}))
        }
        async fn nso_version(&self) -> CoreResult<String> {
            Ok("3.9.9".into())
        }
    }

    struct CoralResponseAttestation {
        method: u8,
        response: Value,
    }
    #[async_trait]
    impl AttestationService for CoralResponseAttestation {
        async fn encrypt_request(
            &self,
            url: &str,
            token: &str,
            parameter: Value,
            method: u8,
            na_id: Option<&str>,
            coral_user_id: Option<&str>,
        ) -> CoreResult<super::super::EncryptedRequest> {
            RecordingAttestation {
                method: self.method,
            }
            .encrypt_request(url, token, parameter, method, na_id, coral_user_id)
            .await
        }
        async fn decrypt_response(&self, _: &[u8]) -> CoreResult<Value> {
            Ok(self.response.clone())
        }
        async fn nso_version(&self) -> CoreResult<String> {
            Ok("3.9.9".into())
        }
    }

    async fn coral_error_response(path: &str, http_status: u16, decoded: Value) -> CoreError {
        let (url, server) = crate::transport::tests::capture_response(http_status, "{}", &[]);
        let method = if path == "/v4/Game/GetWebServiceToken" {
            2
        } else {
            0
        };
        let parameter = if method == 2 {
            splatnet::game_token_parameter("coral-only")
        } else {
            json!({"parameter":{}})
        };
        let result = coral_call(
            &HttpTransport::new(Default::default()).unwrap(),
            &CoralResponseAttestation {
                method,
                response: decoded,
            },
            &test_auth().session,
            &format!("{url}{path}"),
            parameter,
            method,
        )
        .await;
        server.join().unwrap();
        result.unwrap_err()
    }

    #[tokio::test]
    async fn coral_known_account_and_service_states_are_not_expired_tokens() {
        for (status, code) in [
            (9407, "nintendo_account_not_linked"),
            (9424, "nintendo_user_not_activated"),
            (9428, "nintendo_account_disabled"),
            (9450, "nso_membership_required"),
            (9427, "nintendo_client_update_required"),
            (9499, "nintendo_service_closed"),
            (9501, "nintendo_service_unavailable"),
            (9511, "nintendo_service_maintenance"),
        ] {
            let error = coral_error_response(
                "/v4/Friend/List",
                200,
                json!({"status":status, "errorMessage":"must-not-echo", "token":"private"}),
            )
            .await;
            assert!(matches!(error, CoreError::Provider(_)), "{status}");
            assert!(error.to_string().contains(code), "{status}: {error}");
            assert!(!error.to_string().contains("must-not-echo"));
            assert!(!error.to_string().contains("private"));
        }
        let error = coral_error_response(
            "/v4/Friend/List",
            200,
            json!({"status":9437, "errorMessage":"private"}),
        )
        .await;
        assert!(matches!(error, CoreError::RateLimited { .. }));
    }

    #[tokio::test]
    async fn friend_lookup_9408_is_mapped_to_endpoint_specific_not_found() {
        let error = coral_error_response(
            "/v3/Friend/GetUserByFriendCode",
            200,
            json!({"status":9408, "errorMessage":"private"}),
        )
        .await;
        assert!(matches!(error, CoreError::Provider(_)));
        assert!(error.to_string().contains("nintendo_friend_code_not_found"));
        assert!(!error.to_string().contains("private"));
    }

    #[tokio::test]
    async fn coral_9408_on_other_endpoints_remains_generic() {
        let error = coral_error_response(
            "/v4/Friend/List",
            200,
            json!({"status":9408, "errorMessage":"private"}),
        )
        .await;
        assert!(matches!(error, CoreError::Provider(_)));
        assert!(error.to_string().contains("nintendo_request_failed"));
        assert!(!error.to_string().contains("nintendo_friend_code_not_found"));
        assert!(!error.to_string().contains("private"));
    }

    #[tokio::test]
    async fn coral_membership_unavailable_is_a_safe_provider_error_not_expired_authentication() {
        let error = coral_error_response("/v4/Game/GetWebServiceToken", 200,
            json!({"status":9403,"errorMessage":"Membership required error.","secret":"must-not-echo"})).await;
        assert!(
            matches!(error, CoreError::Provider(_)),
            "membership is unavailable, not a retryable expired session"
        );
        assert!(error.to_string().contains("membership"));
        assert!(!error.to_string().contains("must-not-echo"));
        assert!(!error.to_string().contains("Membership required error."));
        assert_eq!(safe_activity_error(&error), "nso_membership_required");
    }

    #[tokio::test]
    async fn coral_membership_message_never_overrides_429_or_matches_freeform_remote_errors() {
        for (http_status, status) in [(200, 429), (429, 9403)] {
            let error = coral_error_response(
                "/v4/Game/GetWebServiceToken",
                http_status,
                json!({"status":status,"errorMessage":"Membership required error."}),
            )
            .await;
            assert!(matches!(
                error,
                CoreError::RateLimited {
                    retry_after_seconds: 60
                }
            ));
        }
        for (path, message) in [
            ("/v4/Friend/List", "Membership required error."),
            (
                "/v4/Game/GetWebServiceToken",
                "Membership required error. must-not-echo",
            ),
        ] {
            let error =
                coral_error_response(path, 200, json!({"status":9403,"errorMessage":message}))
                    .await;
            assert!(matches!(error, CoreError::Authentication(_)));
            assert!(!error.to_string().contains("must-not-echo"));
            assert!(!error.to_string().contains("membership"));
        }
    }

    #[tokio::test]
    async fn game_token_uses_method_two_with_coral_registration_not_session_token() {
        let transport = HttpTransport::new(Default::default()).unwrap();
        let (url, server) = crate::transport::tests::capture_request("{}");
        let value = coral_call(
            &transport,
            &RecordingAttestation { method: 2 },
            &test_auth().session,
            &url,
            splatnet::game_token_parameter("coral-only"),
            2,
        )
        .await
        .unwrap();
        assert_eq!(value["result"]["accessToken"], "game-token");
        let request = server.join().unwrap();
        assert!(request.contains("authorization: Bearer coral-only"));
        assert!(request.contains("user-agent: com.nintendo.znca/3.9.9(Android/14)"));
        assert!(request.ends_with("encrypted-body"));
    }

    #[tokio::test]
    async fn friend_list_uses_method_zero_encrypted_body_and_dynamic_nso_headers() {
        let (url, server) = crate::transport::tests::capture_request("{}");
        coral_call(
            &HttpTransport::new(Default::default()).unwrap(),
            &RecordingAttestation { method: 0 },
            &test_auth().session,
            &format!("{url}/v4/Friend/List"),
            json!({"parameter":{}}),
            0,
        )
        .await
        .unwrap();
        let request = server.join().unwrap();
        assert!(request.starts_with("POST /v4/Friend/List HTTP/1.1"));
        assert!(request.contains("x-productversion: 3.9.9"));
        assert!(request.ends_with("encrypted-body"));
    }

    fn test_auth() -> AuthenticatedCoralSession {
        AuthenticatedCoralSession {
            session: CoralSession {
                access_token: "coral-only".into(),
                na_id: Some("account-a".into()),
                coral_user_id: Some("123456".into()),
                expires_at: Some(Utc::now() + Duration::hours(1)),
                nickname: "test".into(),
                avatar_url: None,
                avatar_bytes: None,
            },
            language: "ja-JP".into(),
            country: "JP".into(),
        }
    }

    struct TestAuthenticator {
        calls: Arc<std::sync::atomic::AtomicUsize>,
        pause: Option<Arc<tokio::sync::Notify>>,
    }
    #[async_trait]
    impl AccountAuthenticator for TestAuthenticator {
        async fn login(
            &self,
            _: HttpTransport,
            _: NxapiAttestationClient,
            _: &str,
        ) -> CoreResult<AuthenticatedCoralSession> {
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if let Some(pause) = &self.pause {
                pause.notified().await;
            }
            Ok(test_auth())
        }
    }
    fn test_service(
        pause: Option<Arc<tokio::sync::Notify>>,
    ) -> (AccountTools, Arc<std::sync::atomic::AtomicUsize>) {
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        (
            AccountTools {
                registry: Mutex::new(Registry::default()),
                protocol: Arc::new(NetworkProtocol),
                game_images: Default::default(),
                authenticator: Arc::new(TestAuthenticator {
                    calls: Arc::clone(&calls),
                    pause,
                }),
            },
            calls,
        )
    }

    #[tokio::test]
    async fn proxy_change_drops_reusable_sessions_without_cancelling_inflight_entries() {
        let (service, _) = test_service(None);
        let transport = HttpTransport::new(Default::default()).unwrap();
        let (old, _, _) = service
            .context(
                "same-session",
                Some("account-a"),
                Some("http://proxy.example:8080"),
                &transport,
            )
            .unwrap();
        old.cache.lock().await.auth = Some(test_auth());

        service.invalidate_network_context().unwrap();

        assert!(old.removed.check().is_ok());
        assert!(
            old.cache.lock().await.auth.is_some(),
            "an in-flight operation may finish with its original cache and transport"
        );
        let (fresh, _, _) = service
            .context(
                "same-session",
                Some("account-a"),
                Some("http://proxy.example:8080"),
                &transport,
            )
            .unwrap();
        assert!(!Arc::ptr_eq(&old, &fresh));
        assert!(fresh.cache.lock().await.auth.is_none());
    }

    #[tokio::test]
    async fn late_authentication_does_not_republish_clients_after_proxy_cache_invalidation() {
        let pause = Arc::new(tokio::sync::Notify::new());
        let (service, calls) = test_service(Some(Arc::clone(&pause)));
        let transport = HttpTransport::new(Default::default()).unwrap();
        let cancellation = CancellationToken::default();
        let login = service.authenticate(
            "same-session",
            Some("account-a"),
            None,
            transport,
            &cancellation,
        );
        let invalidate = async {
            while calls.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
            service.invalidate_network_context().unwrap();
            pause.notify_one();
        };
        let (result, ()) = tokio::join!(login, invalidate);

        assert!(
            result.is_ok(),
            "the in-flight request keeps its original route"
        );
        assert!(
            service.registry.lock().unwrap().clients.is_empty(),
            "late old-proxy authentication must not repopulate shared OAuth caches"
        );
    }

    #[tokio::test]
    async fn simultaneous_sync_and_account_authentication_reuse_one_login_but_not_other_proxies() {
        let (service, calls) = test_service(None);
        let transport = HttpTransport::new(Default::default()).unwrap();
        let cancellation = CancellationToken::default();
        let (one, two) = tokio::join!(
            service.authenticate(
                "same-credential",
                None,
                None,
                transport.clone(),
                &cancellation
            ),
            service.authenticate(
                "same-credential",
                Some("account-a"),
                None,
                transport.clone(),
                &cancellation
            )
        );
        assert_eq!(one.unwrap().na_id.as_deref(), Some("account-a"));
        assert_eq!(two.unwrap().na_id.as_deref(), Some("account-a"));
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        service
            .authenticate(
                "same-credential",
                Some("account-a"),
                Some("http://proxy.example:8080"),
                transport.clone(),
                &cancellation,
            )
            .await
            .unwrap();
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 2);
        assert!(matches!(
            service
                .authenticate(
                    "same-credential",
                    Some("account-b"),
                    None,
                    transport,
                    &cancellation
                )
                .await,
            Err(CoreError::Authentication(_))
        ));
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn near_expiry_sync_and_friend_requests_share_one_refresh_and_send_the_current_token() {
        use super::super::provider::{CoralAlbumProvider, MediaProvider};
        use std::sync::atomic::Ordering;

        // The listener rejects encryption before any Nintendo request can run.
        // Assert actual plaintext token/route submissions, not just a mock's
        // refresh count. A cached session inside the safety window must never
        // escape to FriendCode, Play Log or the album provider.
        for (seconds_left, wanted_token, wanted_logins) in [
            (600, "previous-coral", 1),
            (300, "coral-only", 2),
            (299, "coral-only", 2),
        ] {
            let probe = OAuthProbe::new();
            let transport = HttpTransport::new(Default::default()).unwrap();
            let client = NxapiAttestationClient::new(
                transport.clone(),
                NxapiConfig {
                    znca_base_url: probe.url.clone(),
                    oauth_url: format!("{}/oauth", probe.url),
                    ..Default::default()
                },
            );
            let (mut service, calls) = test_service(None);
            service
                .registry
                .get_mut()
                .unwrap()
                .clients
                .insert(hex::encode(Sha256::digest(b"")), client);
            let cancel = CancellationToken::default();
            service
                .authenticate(
                    "session-a",
                    Some("account-a"),
                    None,
                    transport.clone(),
                    &cancel,
                )
                .await
                .unwrap();
            let (entry, _, _) = service
                .context("session-a", Some("account-a"), None, &transport)
                .unwrap();
            {
                let mut cache = entry.cache.lock().await;
                let auth = cache.auth.as_mut().unwrap();
                auth.session.access_token = "previous-coral".into();
                auth.session.expires_at = Some(Utc::now() + Duration::seconds(seconds_left));
            }
            let (sync, code, play_log) = tokio::join!(
                service.authenticate("session-a", None, None, transport.clone(), &cancel),
                service.execute(
                    "account-a",
                    "session-a",
                    "friend-code",
                    None,
                    transport.clone(),
                    ToolRequest::FriendCode
                ),
                service.execute(
                    "account-a",
                    "session-a",
                    "play-log",
                    None,
                    transport.clone(),
                    ToolRequest::FriendPlayLog("synthetic-friend".into())
                ),
            );
            assert!(matches!(code, Err(CoreError::Provider(_))));
            assert!(matches!(play_log, Err(CoreError::Provider(_))));
            let session = sync.unwrap();
            assert_eq!(session.access_token, wanted_token);
            let attestation = service.attestation(&session, None, &transport).unwrap();
            let provider = CoralAlbumProvider::new(transport, attestation, session);
            assert!(matches!(
                provider.list_recent(None).await,
                Err(CoreError::Provider(_))
            ));
            assert_eq!(calls.load(Ordering::SeqCst), wanted_logins);
            assert_eq!(probe.issued.load(Ordering::SeqCst), 1);
            let captured = probe.encryptions.lock().unwrap();
            assert_eq!(captured.len(), 3);
            for request in captured.iter() {
                assert_eq!(request["token"], wanted_token);
            }
            let mut routes: Vec<_> = captured
                .iter()
                .map(|request| request["url"].as_str().unwrap().to_owned())
                .collect();
            routes.sort();
            assert_eq!(
                routes,
                [
                    format!("{CORAL_ORIGIN}/v3/Friend/CreateFriendCodeUrl"),
                    format!("{CORAL_ORIGIN}/v4/Media/List"),
                    format!("{CORAL_ORIGIN}/v4/User/PlayLog/Show"),
                ]
            );
        }
    }

    #[tokio::test]
    async fn usable_web_session_survives_parent_expiry_and_normal_renewal() {
        use std::sync::atomic::Ordering;
        for renew_parent in [false, true] {
            let probe = OAuthProbe::new();
            let (mut service, logins) = test_service(None);
            let transport = HttpTransport::new(Default::default()).unwrap();
            let client = NxapiAttestationClient::new(
                transport.clone(),
                NxapiConfig {
                    znca_base_url: probe.url.clone(),
                    oauth_url: format!("{}/oauth", probe.url),
                    ..Default::default()
                },
            );
            service
                .registry
                .get_mut()
                .unwrap()
                .clients
                .insert(hex::encode(Sha256::digest(b"")), client);
            let cancellation = CancellationToken::default();
            service
                .authenticate(
                    "session-a",
                    Some("account-a"),
                    None,
                    transport.clone(),
                    &cancellation,
                )
                .await
                .unwrap();
            let (entry, _, _) = service
                .context("session-a", Some("account-a"), None, &transport)
                .unwrap();
            {
                let mut cache = entry.cache.lock().await;
                let auth = cache.auth.as_mut().unwrap();
                auth.session.expires_at = Some(Utc::now() - Duration::seconds(1));
                cache.splatnet = Some(
                    SplatNetWebSession {
                        game_web_token: "still-valid-child".into(),
                        expires_at: Utc::now() + Duration::minutes(10),
                        language: "ja-JP".into(),
                        country: "JP".into(),
                    }
                    .into(),
                );
            }
            if renew_parent {
                service
                    .authenticate(
                        "session-a",
                        Some("account-a"),
                        None,
                        transport.clone(),
                        &cancellation,
                    )
                    .await
                    .unwrap();
            }
            let result = service
                .execute(
                    "account-a",
                    "session-a",
                    "cached-web",
                    None,
                    transport,
                    ToolRequest::Web {
                        force_refresh: false,
                    },
                )
                .await
                .unwrap();
            assert!(matches!(
                result,
                ToolResponse::Web(web) if web.game_web_token == "still-valid-child"
            ));
            assert_eq!(
                logins.load(Ordering::SeqCst),
                if renew_parent { 2 } else { 1 }
            );
            assert!(probe.encryptions.lock().unwrap().is_empty());
        }
    }

    #[tokio::test]
    async fn web_refresh_keeps_valid_coral_credentials_for_friends_and_sync() {
        use std::sync::atomic::Ordering;

        for (seconds_left, wanted_token, wanted_logins) in [
            (600, "previous-coral", 1),
            (300, "coral-only", 2),
            (299, "coral-only", 2),
        ] {
            let probe = OAuthProbe::new();
            let transport = HttpTransport::new(Default::default()).unwrap();
            let client = NxapiAttestationClient::new(
                transport.clone(),
                NxapiConfig {
                    znca_base_url: probe.url.clone(),
                    oauth_url: format!("{}/oauth", probe.url),
                    ..Default::default()
                },
            );
            let (mut service, logins) = test_service(None);
            service
                .registry
                .get_mut()
                .unwrap()
                .clients
                .insert(hex::encode(Sha256::digest(b"")), client);
            let cancellation = CancellationToken::default();
            service
                .authenticate(
                    "session-a",
                    Some("account-a"),
                    None,
                    transport.clone(),
                    &cancellation,
                )
                .await
                .unwrap();
            let (entry, _, _) = service
                .context("session-a", Some("account-a"), None, &transport)
                .unwrap();
            {
                let mut cache = entry.cache.lock().await;
                let auth = cache.auth.as_mut().unwrap();
                auth.session.access_token = "previous-coral".into();
                auth.session.expires_at = Some(Utc::now() + Duration::seconds(seconds_left));
            }
            for (id, request) in [
                (
                    "refresh-web",
                    ToolRequest::Web {
                        force_refresh: true,
                    },
                ),
                ("next-friend-code", ToolRequest::FriendCode),
            ] {
                assert!(matches!(
                    service
                        .execute(
                            "account-a",
                            "session-a",
                            id,
                            None,
                            transport.clone(),
                            request,
                        )
                        .await,
                    Err(CoreError::Provider(_))
                ));
            }
            let session = service
                .authenticate(
                    "session-a",
                    Some("account-a"),
                    None,
                    transport,
                    &cancellation,
                )
                .await
                .unwrap();
            assert_eq!(session.access_token, wanted_token);
            assert_eq!(logins.load(Ordering::SeqCst), wanted_logins);
            let requests = probe.encryptions.lock().unwrap();
            assert_eq!(requests.len(), 2);
            let web = &requests[0];
            assert_eq!(web["hash_method"], 2);
            assert_eq!(web["token"], wanted_token);
            assert_eq!(
                web["encrypt_token_request"]["url"],
                format!("{CORAL_ORIGIN}/v4/Game/GetWebServiceToken"),
            );
            assert_eq!(
                web["encrypt_token_request"]["parameter"]["registrationToken"],
                wanted_token,
            );
            assert_eq!(requests[1]["token"], wanted_token);
        }
    }

    #[tokio::test]
    async fn cancelling_authentication_while_waiting_for_the_shared_lock_returns_promptly() {
        let (service, _) = test_service(None);
        let transport = HttpTransport::new(Default::default()).unwrap();
        let (entry, _, _) = service
            .context("same", Some("account-a"), None, &transport)
            .unwrap();
        let _guard = entry.cache.lock().await;
        let cancellation = CancellationToken::default();
        let work = service.authenticate("same", Some("account-a"), None, transport, &cancellation);
        let cancel = async {
            tokio::task::yield_now().await;
            cancellation.cancel();
        };
        let (result, ()) = tokio::join!(work, cancel);
        assert!(matches!(result, Err(CoreError::Cancelled)));
    }

    #[tokio::test]
    async fn account_clear_cancels_inflight_auth_and_rejects_late_unknown_owner_results() {
        let pause = Arc::new(tokio::sync::Notify::new());
        let (service, calls) = test_service(Some(Arc::clone(&pause)));
        let transport = HttpTransport::new(Default::default()).unwrap();
        let cancellation = CancellationToken::default();
        let work = service.authenticate("unknown-owner", None, None, transport, &cancellation);
        let clear = async {
            while calls.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
            service.clear("account-a").unwrap();
            pause.notify_one();
        };
        let (result, ()) = tokio::join!(work, clear);
        assert!(matches!(result, Err(CoreError::Cancelled)));
        let (fresh, _, _) = service
            .context(
                "unknown-owner",
                Some("account-a"),
                None,
                &HttpTransport::new(Default::default()).unwrap(),
            )
            .unwrap();
        assert!(
            fresh.removed.check().is_ok(),
            "re-adding the account must not reuse a removed entry"
        );
    }

    #[test]
    fn rate_limit_is_not_authentication_and_error_summaries_do_not_echo_sensitive_responses() {
        let limited = ensure_response(
            &HttpResponseData {
                status: 429,
                headers: HashMap::new(),
                body: br#"{"token":"do-not-echo"}"#.to_vec(),
            },
            "SplatNet",
        )
        .unwrap_err();
        assert!(matches!(
            limited,
            CoreError::RateLimited {
                retry_after_seconds: 60
            }
        ));
        assert_eq!(safe_activity_error(&limited), "splatnet_rate_limited");
        let failed = ensure_response(
            &HttpResponseData {
                status: 500,
                headers: HashMap::new(),
                body: br#"{"token":"do-not-echo"}"#.to_vec(),
            },
            "SplatNet",
        )
        .unwrap_err();
        assert!(!failed.to_string().contains("do-not-echo"));
    }

    struct FailingProtocol {
        calls: Arc<std::sync::atomic::AtomicUsize>,
        rate_limited: bool,
        always_expired: bool,
    }

    struct RejectedSplatNetProtocol {
        rejection: &'static str,
        calls: Arc<std::sync::atomic::AtomicUsize>,
        always_rejected: bool,
    }

    struct CachedIdentityAuthenticator;

    struct FriendActivityProtocol {
        rejection: &'static str,
        calls: Arc<std::sync::atomic::AtomicUsize>,
        always_rejected: bool,
    }

    #[async_trait]
    impl ToolProtocol for FriendActivityProtocol {
        async fn execute(
            &self,
            _: &HttpTransport,
            _: &NxapiAttestationClient,
            _: &AuthenticatedCoralSession,
            _: &mut AccountCache,
            _: &ToolRequest,
        ) -> CoreResult<ToolResponse> {
            let (friends, _) = parse_friends(&json!({"result":{"friends":[{
                "nsaId":"synthetic-friend", "name":"Retained friend",
                "presence":{"state":"OFFLINE"}
            }]}}))?;
            let activity = if self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0
                || self.always_rejected
            {
                Err(CoreError::Authentication(self.rejection.into()))
            } else {
                Ok(json!({"data":{"friends":{"nodes":[]}}}))
            };
            Ok(ToolResponse::FriendsWithActivity(friends, activity))
        }
    }

    #[tokio::test]
    async fn friend_activity_shares_one_stage_recovery_and_keeps_basic_friends_on_failure() {
        use std::sync::atomic::Ordering;
        for (rejection, wanted_logins, always_rejected) in [
            ("splatnet_bullet_token_invalid", 1, false),
            ("splatnet_bullet_token_invalid", 1, true),
            ("splatnet_game_web_token_invalid (HTTP 401)", 1, false),
            ("Nintendo account session rejected (status 9403)", 2, false),
            ("Nintendo account session rejected (status 9403)", 2, true),
        ] {
            let (mut service, logins) = test_service(None);
            let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            service.protocol = Arc::new(FriendActivityProtocol {
                rejection,
                calls: Arc::clone(&calls),
                always_rejected,
            });
            let response = service
                .execute(
                    "account-a",
                    "session-a",
                    "friends",
                    None,
                    HttpTransport::new(Default::default()).unwrap(),
                    ToolRequest::Friends,
                )
                .await
                .unwrap();
            let ToolResponse::Friends(snapshot) = response else {
                panic!("internal activity result must become a safe public snapshot");
            };
            assert_eq!(snapshot.friends.len(), 1);
            assert_eq!(snapshot.friends[0].nickname, "Retained friend");
            assert_eq!(
                snapshot.activity_error.as_deref(),
                always_rejected.then_some("splatnet_authentication_failed")
            );
            assert_eq!(calls.load(Ordering::SeqCst), 2);
            assert_eq!(logins.load(Ordering::SeqCst), wanted_logins);
        }
    }

    #[async_trait]
    impl AccountAuthenticator for CachedIdentityAuthenticator {
        async fn login_cached(
            &self,
            _: HttpTransport,
            _: NxapiAttestationClient,
            _: &str,
            cache: &mut Option<CachedNintendoIdentity>,
        ) -> CoreResult<AuthenticatedCoralSession> {
            if cache.is_none() {
                return Err(CoreError::Provider("unexpected Nintendo renewal".into()));
            }
            Ok(test_auth())
        }

        async fn login(
            &self,
            _: HttpTransport,
            _: NxapiAttestationClient,
            _: &str,
        ) -> CoreResult<AuthenticatedCoralSession> {
            panic!("cached authentication must use its identity parent")
        }
    }

    #[tokio::test]
    async fn rejected_coral_reuses_nintendo_identity_and_preserves_valid_splatnet_child() {
        let (mut service, _) = test_service(None);
        let transport = HttpTransport::new(Default::default()).unwrap();
        let cancellation = CancellationToken::default();
        service
            .authenticate(
                "session-a",
                Some("account-a"),
                None,
                transport.clone(),
                &cancellation,
            )
            .await
            .unwrap();
        let (entry, _, _) = service
            .context("session-a", Some("account-a"), None, &transport)
            .unwrap();
        {
            let mut cache = entry.cache.lock().await;
            cache.nintendo = Some(super::super::session::tests::synthetic_identity());
            cache.auth.as_mut().unwrap().session.access_token = "rejected-coral".into();
            cache.splatnet = Some(
                SplatNetWebSession {
                    game_web_token: "valid-descendant".into(),
                    expires_at: Utc::now() + Duration::hours(1),
                    language: "ja-JP".into(),
                    country: "JP".into(),
                }
                .into(),
            );
        }
        service.authenticator = Arc::new(CachedIdentityAuthenticator);
        let renewed = service
            .authenticate_with_refresh(
                "session-a",
                Some("account-a"),
                None,
                transport.clone(),
                &cancellation,
                true,
            )
            .await
            .expect("a Coral rejection does not reject its Nintendo parent");
        assert_eq!(renewed.access_token, "coral-only");
        let child = service
            .execute(
                "account-a",
                "session-a",
                "cached-descendant",
                None,
                transport,
                ToolRequest::Web {
                    force_refresh: false,
                },
            )
            .await
            .expect("a separately valid descendant survives parent recovery");
        assert!(matches!(
            child,
            ToolResponse::Web(web) if web.game_web_token == "valid-descendant"
        ));
    }

    #[async_trait]
    impl ToolProtocol for RejectedSplatNetProtocol {
        async fn execute(
            &self,
            transport: &HttpTransport,
            client: &NxapiAttestationClient,
            auth: &AuthenticatedCoralSession,
            cache: &mut AccountCache,
            _: &ToolRequest,
        ) -> CoreResult<ToolResponse> {
            if self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0
                || self.always_rejected
            {
                return Err(CoreError::Authentication(self.rejection.into()));
            }
            splatnet::web_session(transport, client, auth, &mut cache.splatnet)
                .await
                .map(ToolResponse::Web)
        }
    }

    #[tokio::test]
    async fn rejected_splatnet_child_retains_valid_parent_for_bounded_recovery() {
        use std::sync::atomic::Ordering;
        for (rejection, expect_cached_web, always_rejected) in [
            ("splatnet_bullet_token_invalid", true, false),
            ("splatnet_game_web_token_invalid (HTTP 401)", false, false),
            ("splatnet_bullet_token_invalid", true, true),
            ("splatnet_game_web_token_invalid (HTTP 401)", false, true),
        ] {
            let probe = OAuthProbe::new();
            let (mut service, authentications) = test_service(None);
            let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            service.protocol = Arc::new(RejectedSplatNetProtocol {
                rejection,
                calls: Arc::clone(&calls),
                always_rejected,
            });
            let transport = HttpTransport::new(Default::default()).unwrap();
            let client = NxapiAttestationClient::new(
                transport.clone(),
                NxapiConfig {
                    znca_base_url: probe.url.clone(),
                    oauth_url: format!("{}/oauth", probe.url),
                    ..Default::default()
                },
            );
            service
                .registry
                .get_mut()
                .unwrap()
                .clients
                .insert(hex::encode(Sha256::digest(b"")), client);
            service
                .authenticate(
                    "session-a",
                    Some("account-a"),
                    None,
                    transport.clone(),
                    &CancellationToken::default(),
                )
                .await
                .unwrap();
            let (entry, _, _) = service
                .context("session-a", Some("account-a"), None, &transport)
                .unwrap();
            {
                let mut cache = entry.cache.lock().await;
                cache.auth.as_mut().unwrap().session.access_token = "valid-coral".into();
                cache.splatnet = Some(
                    SplatNetWebSession {
                        game_web_token: "valid-game-web".into(),
                        expires_at: Utc::now() + Duration::hours(1),
                        language: "ja-JP".into(),
                        country: "JP".into(),
                    }
                    .into(),
                );
            }
            let result = service
                .execute(
                    "account-a",
                    "session-a",
                    "recover-child",
                    None,
                    transport,
                    ToolRequest::Seed,
                )
                .await;
            assert_eq!(
                authentications.load(Ordering::SeqCst),
                1,
                "a rejected SplatNet child must not force Coral login: {rejection}"
            );
            assert_eq!(calls.load(Ordering::SeqCst), 2);
            if always_rejected {
                assert!(matches!(result, Err(CoreError::Authentication(_))));
                assert!(probe.encryptions.lock().unwrap().is_empty());
            } else if expect_cached_web {
                assert!(matches!(
                    result,
                    Ok(ToolResponse::Web(web)) if web.game_web_token == "valid-game-web"
                ));
                assert!(probe.encryptions.lock().unwrap().is_empty());
            } else {
                // The synthetic NXAPI service stops the gtoken exchange before
                // any Nintendo request. It must receive the existing Coral token.
                assert!(matches!(result, Err(CoreError::Provider(_))));
                let requests = probe.encryptions.lock().unwrap();
                assert_eq!(requests.len(), 1);
                assert_eq!(requests[0]["token"], "valid-coral");
            }
        }
    }

    #[async_trait]
    impl ToolProtocol for FailingProtocol {
        async fn execute(
            &self,
            _: &HttpTransport,
            _: &NxapiAttestationClient,
            _: &AuthenticatedCoralSession,
            _: &mut AccountCache,
            _: &ToolRequest,
        ) -> CoreResult<ToolResponse> {
            let attempt = self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if self.rate_limited {
                return Err(CoreError::RateLimited {
                    retry_after_seconds: 60,
                });
            }
            if attempt == 0 || self.always_expired {
                return Err(CoreError::Authentication("expired".into()));
            }
            Ok(ToolResponse::Avatar(vec![42]))
        }
    }

    #[tokio::test]
    async fn expired_tool_session_refreshes_at_most_once_and_429_never_retries() {
        for (limited, always_expired, want_calls, success) in [
            (false, false, 2, true),
            (false, true, 2, false),
            (true, false, 1, false),
        ] {
            let (mut service, authentications) = test_service(None);
            let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            service.protocol = Arc::new(FailingProtocol {
                calls: Arc::clone(&calls),
                rate_limited: limited,
                always_expired,
            });
            let result = service
                .execute(
                    "account-a",
                    "test-session",
                    "op",
                    None,
                    HttpTransport::new(Default::default()).unwrap(),
                    ToolRequest::Avatar("friend".into()),
                )
                .await;
            assert_eq!(result.is_ok(), success);
            assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), want_calls);
            assert_eq!(
                authentications.load(std::sync::atomic::Ordering::SeqCst),
                want_calls
            );
        }
    }

    #[tokio::test]
    async fn freshly_authenticated_mismatched_account_is_rejected_before_any_tool_request() {
        let (mut service, _) = test_service(None);
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        service.protocol = Arc::new(FailingProtocol {
            calls: Arc::clone(&calls),
            rate_limited: false,
            always_expired: false,
        });
        let result = service
            .execute(
                "account-b",
                "belongs-to-a",
                "mismatch",
                None,
                HttpTransport::new(Default::default()).unwrap(),
                ToolRequest::Friends,
            )
            .await;
        assert!(matches!(result, Err(CoreError::Authentication(_))));
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 0);
        let result = service
            .authenticate(
                "belongs-to-a",
                Some("account-a"),
                None,
                HttpTransport::new(Default::default()).unwrap(),
                &CancellationToken::default(),
            )
            .await;
        assert!(
            result.is_ok(),
            "a rejected wrong-account call must not poison the real account"
        );
    }

    #[tokio::test]
    async fn legacy_coral_account_identity_shares_verified_cache_and_clears_all_aliases() {
        let (service, calls) = test_service(None);
        let transport = HttpTransport::new(Default::default()).unwrap();
        let cancellation = CancellationToken::default();
        assert!(service
            .authenticate(
                "legacy-token",
                Some("123456"),
                None,
                transport.clone(),
                &cancellation
            )
            .await
            .is_ok());
        assert!(service
            .authenticate(
                "legacy-token",
                Some("account-a"),
                None,
                transport.clone(),
                &cancellation
            )
            .await
            .is_ok());
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        service.clear("123456").unwrap();
        assert!(service
            .authenticate(
                "legacy-token",
                Some("account-a"),
                None,
                transport,
                &cancellation
            )
            .await
            .is_ok());
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn cancelled_unverified_account_does_not_block_the_rightful_account() {
        let pause = Arc::new(tokio::sync::Notify::new());
        let (service, calls) = test_service(Some(Arc::clone(&pause)));
        let transport = HttpTransport::new(Default::default()).unwrap();
        let cancellation = CancellationToken::default();
        let work = service.authenticate(
            "recover-cancel",
            Some("account-b"),
            None,
            transport.clone(),
            &cancellation,
        );
        let cancel = async {
            while calls.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
            cancellation.cancel();
        };
        let (result, ()) = tokio::time::timeout(std::time::Duration::from_secs(1), async {
            tokio::join!(work, cancel)
        })
        .await
        .unwrap();
        assert!(matches!(result, Err(CoreError::Cancelled)));
        pause.notify_one();
        service.clear("account-a").unwrap();
        let result = service
            .authenticate(
                "recover-cancel",
                Some("account-a"),
                None,
                transport,
                &CancellationToken::default(),
            )
            .await;
        assert!(
            result.is_ok(),
            "unverified cancelled identities must never become cache owners"
        );
    }

    struct FailFirstAuthenticator(std::sync::atomic::AtomicUsize);
    #[async_trait]
    impl AccountAuthenticator for FailFirstAuthenticator {
        async fn login(
            &self,
            _: HttpTransport,
            _: NxapiAttestationClient,
            _: &str,
        ) -> CoreResult<AuthenticatedCoralSession> {
            if self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
                return Err(CoreError::Io(std::io::Error::new(
                    std::io::ErrorKind::ConnectionReset,
                    "synthetic authentication connection reset",
                )));
            }
            Ok(test_auth())
        }
    }

    #[tokio::test]
    async fn failed_unverified_account_does_not_block_the_rightful_account() {
        let service = AccountTools {
            registry: Mutex::new(Registry::default()),
            protocol: Arc::new(NetworkProtocol),
            game_images: Default::default(),
            authenticator: Arc::new(FailFirstAuthenticator(std::sync::atomic::AtomicUsize::new(
                0,
            ))),
        };
        let transport = HttpTransport::new(Default::default()).unwrap();
        let cancellation = CancellationToken::default();
        let first = service
            .authenticate(
                "recover-failure",
                Some("account-b"),
                None,
                transport.clone(),
                &cancellation,
            )
            .await;
        assert!(matches!(first, Err(CoreError::Io(_))));
        service.clear("account-a").unwrap();
        let rightful = service
            .authenticate(
                "recover-failure",
                Some("account-a"),
                None,
                transport,
                &cancellation,
            )
            .await;
        assert!(
            rightful.is_ok(),
            "failed authentication cannot establish account ownership"
        );
    }

    #[tokio::test]
    async fn arbitrary_avatar_ids_are_rejected_without_a_download() {
        let (service, _) = test_service(None);
        let result = service
            .execute(
                "account-a",
                "test-session",
                "avatar",
                None,
                HttpTransport::new(Default::default()).unwrap(),
                ToolRequest::Avatar("https://evil.example/avatar.png".into()),
            )
            .await;
        assert!(matches!(result, Err(CoreError::InvalidConfig(_))));
    }

    #[tokio::test]
    async fn operation_cancel_interrupts_authentication_and_does_not_fill_the_cache() {
        let pause = Arc::new(tokio::sync::Notify::new());
        let (service, calls) = test_service(Some(pause));
        let transport = HttpTransport::new(Default::default()).unwrap();
        let work = service.execute(
            "account-a",
            "token",
            "op-auth",
            None,
            transport.clone(),
            ToolRequest::Avatar("friend".into()),
        );
        let cancel = async {
            while calls.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
            assert!(service.cancel("op-auth").unwrap());
        };
        let (result, ()) = tokio::time::timeout(std::time::Duration::from_secs(1), async {
            tokio::join!(work, cancel)
        })
        .await
        .unwrap();
        assert!(matches!(result, Err(CoreError::Cancelled)));
        let (entry, _, _) = service
            .context("token", Some("account-a"), None, &transport)
            .unwrap();
        assert!(entry.cache.lock().await.auth.is_none());
    }

    #[test]
    fn supplement_failure_keeps_the_entire_basic_snapshot_and_reports_only_a_safe_code() {
        let (friends, _) = parse_friends(&json!({"result":{"friends":[
            {"nsaId":"friend-a","name":"same","presence":{"state":"ONLINE"}},
            {"nsaId":"friend-b","name":"same","presence":{"state":"OFFLINE"}}
        ]}}))
        .unwrap();
        let snapshot = finish_friends(
            friends.clone(),
            Err(CoreError::Provider("body may contain token=SECRET".into())),
        )
        .unwrap();
        assert_eq!(snapshot.friends, friends);
        assert_eq!(
            snapshot.activity_error.as_deref(),
            Some("splatnet_activity_unavailable")
        );
        assert!(matches!(
            finish_friends(friends, Err(CoreError::Cancelled)),
            Err(CoreError::Cancelled)
        ));
    }

    #[test]
    fn friend_activity_normalizes_match_modes_and_coop_without_guessing_unknown_modes() {
        let cases = [
            (json!({"onlineState":"VS_MODE_MATCHING"}), Some("MATCHING")),
            (
                json!({"onlineState":"COOP_MODE_MATCHING","coopRule":"REGULAR"}),
                Some("MATCHING"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"REGULAR","id":"VnNNb2RlLTE="}}),
                Some("REGULAR"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"BANKARA","id":"VnNNb2RlLTUx"}}),
                Some("BANKARA_OPEN"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"BANKARA","id":"VnNNb2RlLTI="}}),
                Some("BANKARA_CHALLENGE"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"X_MATCH"}}),
                Some("X_MATCH"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"PRIVATE"}}),
                Some("PRIVATE"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"FEST","id":"VnNNb2RlLTY="}}),
                Some("FEST_OPEN"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"FEST","id":"VnNNb2RlLTc="}}),
                Some("FEST_CHALLENGE"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"FEST","id":"VnNNb2RlLTg="}}),
                Some("FEST_TRICOLOR"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"LEAGUE"}}),
                Some("EVENT"),
            ),
            (
                json!({"onlineState":"COOP_MODE_FIGHTING","coopRule":"REGULAR"}),
                Some("COOP"),
            ),
            (
                json!({"onlineState":"COOP_MODE_FIGHTING","coopRule":"BIG_RUN"}),
                Some("COOP"),
            ),
            (
                json!({"onlineState":"COOP_MODE_FIGHTING","coopRule":"TEAM_CONTEST"}),
                Some("COOP"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"BANKARA","id":"unknown"}}),
                Some("VS_FIGHTING"),
            ),
            (
                json!({"onlineState":"VS_MODE_FIGHTING","vsMode":{"mode":"FUTURE_MODE"}}),
                Some("VS_FIGHTING"),
            ),
            (json!({"onlineState":"ONLINE"}), None),
            (json!({"onlineState":"OFFLINE"}), None),
            (json!({"onlineState":"FUTURE_STATE"}), None),
        ];
        for (mut activity, want) in cases {
            activity["id"] = json!("RnJpZW5kLWE=");
            let (mut friends, _) = parse_friends(&json!({"result":{"friends":[
                {"nsaId":"a","name":"same","presence":{"state":"ONLINE"}},
                {"nsaId":"b","name":"same","presence":{"state":"ONLINE"}}
            ]}}))
            .unwrap();
            supplement_friends(
                &mut friends,
                &json!({"data":{"friends":{"nodes":[activity]}}}),
            )
            .unwrap();
            assert_eq!(friends[0].activity.as_deref(), want);
            assert!(friends[1].activity.is_none());
        }
    }
}
