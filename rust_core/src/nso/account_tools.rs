use super::session::{AuthenticatedCoralSession, CachedNintendoIdentity};
use super::splatnet::{self, SplatNetSession};
use super::{
    AttestationService, CoralSession, CoralSessionClient, NxapiAttestationClient, NxapiConfig,
};
use crate::error::{CoreError, CoreResult};
use crate::models::{
    NintendoFriend, NintendoFriendsSnapshot, SeedExportPayload, SplatNetWebSession,
};
use crate::sync::CancellationToken;
use crate::transport::{nintendo_user_agent, HttpResponseData, HttpTransport};
use async_trait::async_trait;
use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{Duration, TimeZone, Utc};
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
            total_play_time_minutes: game
                .get("totalPlayTime")
                .and_then(Value::as_u64)
                .and_then(|v| u32::try_from(v).ok()),
            logout_at: presence
                .get("logoutAt")
                .and_then(Value::as_i64)
                .filter(|v| *v > 0)
                .and_then(|v| Utc.timestamp_opt(v, 0).single()),
            activity: None,
        });
    }
    Ok((friends, avatars))
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
}

impl AccountCache {
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
    fn new(client: NxapiAttestationClient) -> Self {
        Self {
            client,
            identities: Default::default(),
            removed: Default::default(),
            cache: Default::default(),
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
}
impl Default for AccountTools {
    fn default() -> Self {
        Self {
            registry: Mutex::new(Registry::default()),
            authenticator: Arc::new(ProtocolAuthenticator),
            protocol: Arc::new(NetworkProtocol),
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
    Web { force_refresh: bool },
    Seed,
}
pub(crate) enum ToolResponse {
    Friends(NintendoFriendsSnapshot),
    Avatar(Vec<u8>),
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
        let template = shared_attestation(&mut registry, proxy_key, transport)?;
        let client = account
            .and_then(|id| {
                registry
                    .clients
                    .get(&account_attestation_key(id, &template.service_key(), proxy))
                    .cloned()
            })
            .unwrap_or_else(|| template.isolated_credentials());
        let entry = Arc::clone(
            registry
                .entries
                .entry(key)
                .or_insert_with(|| Arc::new(AccountEntry::new(client))),
        );
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
            cache.auth = None;
            cache.splatnet = None;
            cache.nintendo = None;
        }
        let valid = cache.auth.as_ref().is_some_and(|auth| {
            auth.session
                .expires_at
                .is_some_and(|expiry| expiry > Utc::now() + Duration::seconds(60))
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
            for id in &actual_ids {
                let key = account_attestation_key(id, &service, input.proxy);
                registry.clients.insert(key.clone(), input.client.clone());
                registry.client_accounts.insert(key, actual_ids.clone());
            }
            *identities = actual_ids;
            cache.auth = Some(auth);
            cache.splatnet = None;
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
        let template = shared_attestation(&mut registry, proxy_key, transport)?;
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
                    let force = matches!(request, ToolRequest::Web { force_refresh: true });
                    for attempt in 0..2 {
                        let auth = self.authenticate_locked(&mut cache, &entry, AuthenticationInput {
                            token, account: Some(account), transport: &transport, client: &client, proxy, generation,
                        }, force || attempt > 0).await?;
                        let result = self.protocol.execute(&transport, &client, &auth, &mut cache, &request).await;
                        entry.removed.check()?;
                        operation.check()?;
                        match result {
                            Err(CoreError::Authentication(_)) if attempt == 0 => continue,
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
) -> CoreResult<NxapiAttestationClient> {
    if let Some(client) = registry.clients.get(&key) {
        return Ok(client.clone());
    }
    let client =
        NxapiAttestationClient::new(transport.without_redirects()?, NxapiConfig::default());
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
    if status == 429 {
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
        return Err(CoreError::Provider(
            "Nintendo Switch Online membership is required for SplatNet 3".into(),
        ));
    }
    match status {
        0 => Ok(value),
        9403 | 9404 | 9599 => Err(CoreError::Authentication(
            "Nintendo account session has expired".into(),
        )),
        status => Err(CoreError::Provider(format!(
            "Nintendo account request failed (status {status})"
        ))),
    }
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
            cache
                .avatar_bytes
                .retain(|id, (url, _)| avatars.get(id) == Some(url));
            cache.avatars = avatars;
            let activity = async {
                for attempt in 0..2 {
                    let result = async {
                        let session =
                            splatnet::session(transport, client, auth, &mut cache.splatnet).await?;
                        splatnet::query(transport, &session, splatnet::Query::Friends).await
                    }
                    .await;
                    match result {
                        Err(CoreError::Authentication(_)) if attempt == 0 => cache.splatnet = None,
                        other => return other,
                    }
                }
                unreachable!("bounded SplatNet activity refresh")
            }
            .await;
            Ok(ToolResponse::Friends(finish_friends(friends, activity)?))
        }
        ToolRequest::Avatar(id) => {
            let url = cache
                .avatars
                .get(id)
                .ok_or_else(|| {
                    CoreError::InvalidConfig(
                        "Load the friend list before opening this avatar".into(),
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

fn safe_activity_error(error: &CoreError) -> &'static str {
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
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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

    struct OAuthProbe {
        url: String,
        issued: Arc<std::sync::atomic::AtomicUsize>,
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
            let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let thread_issued = Arc::clone(&issued);
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
                            let account = parameter["na_id"].as_str().unwrap();
                            let bearer = headers
                                .lines()
                                .find_map(|line| {
                                    let (name, value) = line.split_once(':')?;
                                    name.eq_ignore_ascii_case("authorization")
                                        .then(|| value.trim().to_owned())
                                })
                                .unwrap();
                            let owner = bindings.entry(bearer).or_insert_with(|| account.into());
                            if owner == account {
                                (200, json!({"encrypted_token_request": "dGVzdA=="}))
                            } else {
                                (
                                    400,
                                    json!({"error": "invalid_request", "error_description": "synthetic token belongs to another user"}),
                                )
                            }
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
             "imageUri":"https://example.com/a.png","presence":{"state":"ONLINE","game":{"name":"Splatoon 3","totalPlayTime":123}}},
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
        assert_eq!(avatars["a"], "https://example.com/a.png");
        assert_eq!(
            friends[0].avatar_url.as_deref(),
            Some("https://example.com/a.png")
        );
        assert_eq!(friends[1].avatar_url, None);
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
                authenticator: Arc::new(TestAuthenticator {
                    calls: Arc::clone(&calls),
                    pause,
                }),
            },
            calls,
        )
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
