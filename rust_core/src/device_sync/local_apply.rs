//! One-use in-memory handoff. No persisted trust and no transport lease.
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

use uuid::Uuid;

use super::clock::Clock;
use super::receiver::CommitGuard;
use super::staging::{Phase, Progress};
use crate::error::{CoreError, CoreResult};
use crate::sync::CancellationToken;

const SQL_LIMIT: u64 = 512_000_000;
const SQL_MS: u64 = 300_000;

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Identity {
    pub binding: String,
    pub operation: Uuid,
    pub external: Option<Uuid>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum PhaseState {
    Network,
    ReadyPending,
    SourceChecking,
    LocalInstalled,
    GrantIssued,
    CancelRequested,
    Cancelled,
    Settled,
}

struct Life {
    phase: PhaseState,
    pending: Option<Identity>,
    installed: Option<Identity>,
    issued: Option<Identity>,
}

/// Signal callers take only this short lock, never the Driver/database lock.
pub(crate) struct LifecycleControl {
    life: Mutex<Life>,
    cancel: CancellationToken,
}

impl LifecycleControl {
    pub(super) fn new(cancel: CancellationToken) -> Arc<Self> {
        Arc::new(Self {
            life: Mutex::new(Life {
                phase: PhaseState::Network,
                pending: None,
                installed: None,
                issued: None,
            }),
            cancel,
        })
    }
    pub(super) fn ready(&self, identity: Identity) -> CoreResult<()> {
        let mut life = self.life.lock().map_err(|_| CoreError::Cancelled)?;
        self.cancel.check()?;
        if life.phase != PhaseState::Network {
            return Err(CoreError::Cancelled);
        }
        life.pending = Some(identity);
        life.phase = PhaseState::ReadyPending;
        Ok(())
    }
    pub(super) fn source_checking(&self, identity: Identity) -> CoreResult<()> {
        let mut life = self.life.lock().map_err(|_| CoreError::Cancelled)?;
        self.cancel.check()?;
        if life.phase != PhaseState::Network {
            return Err(CoreError::Cancelled);
        }
        life.pending = Some(identity);
        life.phase = PhaseState::SourceChecking;
        Ok(())
    }
    pub(super) fn issue(
        &self,
        identity: &Identity,
        enqueue: impl FnOnce() -> CoreResult<u64>,
    ) -> CoreResult<u64> {
        let mut life = self.life.lock().map_err(|_| CoreError::Cancelled)?;
        self.cancel.check()?;
        if life.phase != PhaseState::SourceChecking || life.pending.as_ref() != Some(identity) {
            return Err(CoreError::Cancelled);
        }
        let enqueued_at = enqueue()?;
        life.issued = Some(identity.clone());
        life.phase = PhaseState::GrantIssued;
        Ok(enqueued_at)
    }
    pub(super) fn install(
        self: &Arc<Self>,
        identity: &Identity,
        receiver_binding: String,
        publications: BTreeMap<String, u64>,
        clock: Arc<dyn Clock>,
    ) -> CoreResult<Arc<LocalApplyAuthority>> {
        let publication_length = publications.values().try_fold(0u64, |sum, length| {
            if *length == 0 {
                return Err(CoreError::Cancelled);
            }
            sum.checked_add(*length).ok_or(CoreError::Cancelled)
        })?;
        let budget = publication_length
            .checked_mul(8)
            .ok_or(CoreError::Cancelled)?;
        let mut life = self.life.lock().map_err(|_| CoreError::Cancelled)?;
        self.cancel.check()?;
        if life.phase != PhaseState::ReadyPending || life.pending.as_ref() != Some(identity) {
            return Err(CoreError::Cancelled);
        }
        let authority = Arc::new(LocalApplyAuthority {
            identity: identity.clone(),
            receiver_binding,
            lifecycle: self.clone(),
            clock,
            budget,
            publications,
            work: Mutex::new(Work::default()),
        });
        life.installed = Some(identity.clone());
        life.phase = PhaseState::LocalInstalled;
        Ok(authority)
    }
    pub(crate) fn cancel(&self) {
        let mut life = self.life.lock().unwrap_or_else(|error| error.into_inner());
        if life.phase != PhaseState::Settled {
            life.phase = if life.installed.is_some() {
                PhaseState::CancelRequested
            } else {
                PhaseState::Cancelled
            };
            self.cancel.cancel();
        }
    }
    pub(super) fn installed(&self) -> bool {
        self.life
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .installed
            .is_some()
    }
    pub(super) fn issued(&self) -> bool {
        self.life
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .issued
            .is_some()
    }
    pub(super) fn settle(&self) {
        self.life.lock().unwrap_or_else(|e| e.into_inner()).phase = PhaseState::Settled;
    }
}

#[derive(Default)]
struct Work {
    invalid: bool,
    publication: u64,
    seen: BTreeSet<String>,
    current: Option<(u64, Option<(Phase, u64)>)>,
    sql: u64,
    sql_until: Option<u64>,
    accounts: u16,
}

/// Constructed only at successful lifecycle installation. Deliberately no Clone/serde.
pub(super) struct LocalApplyAuthority {
    identity: Identity,
    receiver_binding: String,
    lifecycle: Arc<LifecycleControl>,
    clock: Arc<dyn Clock>,
    budget: u64,
    publications: BTreeMap<String, u64>,
    work: Mutex<Work>,
}

impl LocalApplyAuthority {
    pub(super) fn matches(&self, identity: &Identity, receiver_binding: &str) -> bool {
        self.identity == *identity && self.receiver_binding == receiver_binding
    }
    pub(super) fn account_step(&self) -> CoreResult<()> {
        self.check()?;
        let mut work = self.work.lock().map_err(|_| CoreError::Cancelled)?;
        if work.sql_until.is_none() {
            work.invalid = true;
            return Err(CoreError::Cancelled);
        }
        match work.accounts.checked_add(1).filter(|n| *n <= 64) {
            Some(value) => work.accounts = value,
            None => {
                work.invalid = true;
                return Err(CoreError::Cancelled);
            }
        }
        Ok(())
    }
    pub(super) fn sql_work(&self) -> u64 {
        self.work.lock().unwrap_or_else(|e| e.into_inner()).sql
    }
}

impl CommitGuard for LocalApplyAuthority {
    fn check(&self) -> CoreResult<()> {
        self.lifecycle.cancel.check()?;
        let life = self
            .lifecycle
            .life
            .lock()
            .map_err(|_| CoreError::Cancelled)?;
        if life.phase != PhaseState::LocalInstalled {
            return Err(CoreError::Cancelled);
        }
        let work = self.work.lock().map_err(|_| CoreError::Cancelled)?;
        if work.invalid
            || work.publication > self.budget
            || work.sql > SQL_LIMIT
            || work
                .sql_until
                .is_some_and(|until| self.clock.monotonic_ms() >= until)
        {
            return Err(CoreError::Cancelled);
        }
        Ok(())
    }
    fn sql_started(&self) {
        let mut work = self.work.lock().unwrap_or_else(|e| e.into_inner());
        if work.sql_until.is_none() {
            match self.clock.monotonic_ms().checked_add(SQL_MS) {
                Some(until) => work.sql_until = Some(until),
                None => work.invalid = true,
            }
        }
    }
    fn sql_progress(&self) {
        let mut work = self.work.lock().unwrap_or_else(|e| e.into_inner());
        if work.sql_until.is_none() {
            work.invalid = true;
            return;
        }
        match work.sql.checked_add(2048) {
            Some(value) if value <= SQL_LIMIT => work.sql = value,
            _ => work.invalid = true,
        }
    }
    fn publication_started(&self, sha: &str, length: u64) -> CoreResult<()> {
        self.check()?;
        let mut work = self.work.lock().map_err(|_| CoreError::Cancelled)?;
        if self.publications.get(sha) != Some(&length)
            || !work.seen.insert(sha.into())
            || length == 0
            || work.current.is_some_and(|(_, previous)| {
                previous.is_none_or(|(phase, _)| phase != Phase::Published)
            })
        {
            work.invalid = true;
            return Err(CoreError::Cancelled);
        }
        work.current = Some((length, None));
        Ok(())
    }
    fn publication_progress(&self, progress: &Progress) {
        let mut work = self.work.lock().unwrap_or_else(|e| e.into_inner());
        let Some((length, previous)) = work.current else {
            work.invalid = true;
            return;
        };
        let delta = match previous {
            // The real publisher verifies each pre-existing CAS extension and
            // may verify the no-clobber winner. Each full verification starts
            // explicitly at zero; its bytes still consume the immutable budget.
            Some((Phase::Verifying, completed))
                if progress.phase == Phase::Verifying
                    && completed == length
                    && progress.completed_bytes == 0 =>
            {
                Some(0)
            }
            Some((phase, completed)) if phase == progress.phase => {
                progress.completed_bytes.checked_sub(completed)
            }
            _ => Some(progress.completed_bytes),
        };
        if progress.completed_bytes > length
            || progress.total_bytes.is_some_and(|total| total != length)
            || !matches!(
                progress.phase,
                Phase::Copying | Phase::Verifying | Phase::Publishing | Phase::Published
            )
            || previous.is_some_and(|(phase, _)| {
                phase == Phase::Published
                    || (progress.phase == Phase::Copying && phase != Phase::Copying)
            })
        {
            work.invalid = true;
        }
        match delta.and_then(|delta| work.publication.checked_add(delta)) {
            Some(value) if value <= self.budget => work.publication = value,
            _ => work.invalid = true,
        }
        work.current = Some((length, Some((progress.phase, progress.completed_bytes))));
    }
}

#[cfg(test)]
mod tests;
