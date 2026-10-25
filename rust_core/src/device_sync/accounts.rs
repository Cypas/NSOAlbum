//! Transient, explicitly authorized account projection. Never persisted by Rust.
use std::fmt;

use serde::de::{self, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

pub const MAX_ACCOUNTS: usize = 32;
pub const MAX_ACCOUNT_BYTES: usize = 262_144;
const MAX_DISPLAY_NAMES: usize = 1024;

#[derive(Debug, thiserror::Error)]
#[error("device-sync account payload is invalid or exceeds its resource boundary")]
pub struct AccountError;
type Result<T> = std::result::Result<T, AccountError>;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Account {
    #[serde(deserialize_with = "account_id")]
    account_id: String,
    #[serde(deserialize_with = "nickname")]
    nickname: String,
    #[serde(deserialize_with = "session_token")]
    session_token: String,
}
impl Drop for Account {
    fn drop(&mut self) {
        self.session_token.zeroize();
    }
}
impl fmt::Debug for Account {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Account([REDACTED])")
    }
}

fn bounded_string<'de, D: Deserializer<'de>, const N: usize>(
    deserializer: D,
    allow_empty: bool,
) -> std::result::Result<String, D::Error> {
    struct Bounded<const N: usize>(bool);
    impl<const N: usize> Visitor<'_> for Bounded<N> {
        type Value = String;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("a bounded account field")
        }
        fn visit_str<E: de::Error>(self, value: &str) -> std::result::Result<String, E> {
            if value.len() > N
                || (!self.0 && value.trim().is_empty())
                || value.chars().any(char::is_control)
            {
                return Err(E::custom("invalid account field"));
            }
            Ok(value.to_owned())
        }
    }
    deserializer.deserialize_str(Bounded::<N>(allow_empty))
}
fn account_id<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<String, D::Error> {
    bounded_string::<D, 128>(d, false)
}
fn nickname<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<String, D::Error> {
    bounded_string::<D, 256>(d, true)
}
fn session_token<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<String, D::Error> {
    bounded_string::<D, 8192>(d, false)
}
fn account_list<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Vec<Account>, D::Error> {
    struct Accounts;
    impl<'de> Visitor<'de> for Accounts {
        type Value = Vec<Account>;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("a bounded account list")
        }
        fn visit_seq<A: SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut result = Vec::new();
            while result.len() < MAX_ACCOUNTS {
                let Some(account) = seq.next_element::<Account>()? else {
                    return Ok(result);
                };
                result.push(account);
            }
            if seq.next_element::<de::IgnoredAny>()?.is_some() {
                return Err(de::Error::custom("account count exceeded"));
            }
            Ok(result)
        }
    }
    d.deserialize_seq(Accounts)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DisplayName {
    #[serde(deserialize_with = "account_id")]
    account_id: String,
    #[serde(deserialize_with = "nickname")]
    nickname: String,
    #[serde(deserialize_with = "updated_at")]
    updated_at: Option<String>,
}

fn updated_at<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Option<String>, D::Error> {
    let value = Option::<String>::deserialize(d)?;
    if let Some(text) = &value {
        if text.len() > 64 || chrono::DateTime::parse_from_rfc3339(text).is_err() {
            return Err(de::Error::custom("invalid display name timestamp"));
        }
    }
    Ok(value)
}

#[derive(Serialize)]
#[serde(transparent)]
struct DisplayNames(Vec<DisplayName>);

impl<'de> Deserialize<'de> for DisplayNames {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        struct Names;
        impl<'de> Visitor<'de> for Names {
            type Value = DisplayNames;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("a bounded display-name history")
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut records: Vec<DisplayName> = Vec::new();
                while records.len() < MAX_DISPLAY_NAMES {
                    let Some(record) = seq.next_element::<DisplayName>()? else {
                        return Ok(DisplayNames(records));
                    };
                    if records
                        .last()
                        .is_some_and(|old| old.account_id >= record.account_id)
                    {
                        return Err(de::Error::custom("display name order invalid"));
                    }
                    records.push(record);
                }
                if seq.next_element::<de::IgnoredAny>()?.is_some() {
                    return Err(de::Error::custom("display name count exceeded"));
                }
                Ok(DisplayNames(records))
            }
        }
        d.deserialize_seq(Names)
    }
}

fn present_display_names<'de, D: Deserializer<'de>>(
    d: D,
) -> std::result::Result<Option<DisplayNames>, D::Error> {
    DisplayNames::deserialize(d).map(Some)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccountSet {
    version: u8,
    #[serde(deserialize_with = "account_list")]
    accounts: Vec<Account>,
    #[serde(
        default,
        deserialize_with = "present_display_names",
        skip_serializing_if = "Option::is_none"
    )]
    display_names: Option<DisplayNames>,
}
impl fmt::Debug for AccountSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AccountSet")
            .field("count", &self.accounts.len())
            .finish_non_exhaustive()
    }
}
impl AccountSet {
    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        if bytes.is_empty() || bytes.len() > MAX_ACCOUNT_BYTES {
            return Err(AccountError);
        }
        let result: Self = serde_json::from_slice(bytes).map_err(|_| AccountError)?;
        if !matches!(
            (result.version, result.display_names.is_some()),
            (1, false) | (2, true)
        ) || result
            .accounts
            .windows(2)
            .any(|a| a[0].account_id >= a[1].account_id)
        {
            return Err(AccountError);
        }
        Ok(result)
    }
    pub fn len(&self) -> usize {
        self.accounts.len()
    }
    pub fn is_empty(&self) -> bool {
        self.accounts.is_empty()
    }
    pub fn to_json(&self) -> Result<Zeroizing<Vec<u8>>> {
        struct BoundedWriter(Zeroizing<Vec<u8>>);
        impl std::io::Write for BoundedWriter {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if self.0.len().saturating_add(bytes.len()) > MAX_ACCOUNT_BYTES {
                    return Err(std::io::ErrorKind::InvalidData.into());
                }
                self.0.extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut output = BoundedWriter(Zeroizing::new(Vec::new()));
        serde_json::to_writer(&mut output, self).map_err(|_| AccountError)?;
        Ok(output.0)
    }
    pub fn digest(&self) -> Result<String> {
        Ok(hex::encode(Sha256::digest(&*self.to_json()?)))
    }
}

#[derive(Default)]
pub struct AccountCollector {
    bytes: Zeroizing<Vec<u8>>,
    total: Option<usize>,
}
impl AccountCollector {
    pub fn part(&mut self, offset: usize, total: usize, bytes: &[u8]) -> Result<()> {
        if total == 0
            || total > MAX_ACCOUNT_BYTES
            || bytes.is_empty()
            || bytes.len() > super::wire::RAW_CHUNK
            || offset != self.bytes.len()
            || offset
                .checked_add(bytes.len())
                .is_none_or(|end| end > total)
            || self.total.is_some_and(|previous| previous != total)
        {
            return Err(AccountError);
        }
        self.total = Some(total);
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }
    pub fn finish(self, digest: &str) -> Result<AccountSet> {
        if self.total != Some(self.bytes.len()) {
            return Err(AccountError);
        }
        let accounts = AccountSet::from_json(&self.bytes)?;
        if accounts.digest()? != digest {
            return Err(AccountError);
        }
        Ok(accounts)
    }
}
