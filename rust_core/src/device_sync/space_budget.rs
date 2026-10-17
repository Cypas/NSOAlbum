//! Receiver-local peak estimates, not a disk reservation or filesystem guarantee.
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::staging::{paths::HeldDirectory, StagingError, StagingOperation, StagingResult};
use super::work::WorkControl;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StorageRole {
    Staging,
    Originals,
    Database,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeBudgetView {
    pub roles: Vec<StorageRole>,
    pub additional_bytes: u64,
    pub safety_margin_bytes: u64,
    pub required_bytes: u64,
    pub available_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReceiverBudgetView {
    pub volumes: Vec<VolumeBudgetView>,
    pub includes_metadata: bool,
    pub includes_allocation_estimate: bool,
}

pub(crate) struct MetadataCost {
    pub database_bytes: u64,
    pub backup_bytes: u64,
    pub plan_bytes: u64,
    pub database_parent: PathBuf,
}

fn allocation(length: u64) -> StagingResult<u64> {
    (length / 65_536)
        .checked_add(u64::from(!length.is_multiple_of(65_536)))
        .and_then(|n| n.checked_mul(65_536))
        .and_then(|n| n.checked_add(16_384))
        .ok_or(StagingError::Overflow)
}

fn costs(missing: &[u64], publishing: &[u64], d: u64, b: u64, p: u64) -> StagingResult<[u64; 3]> {
    fn sum(lengths: &[u64]) -> StagingResult<u64> {
        lengths.iter().try_fold(0_u64, |sum, length| {
            sum.checked_add(allocation(*length)?)
                .ok_or(StagingError::Overflow)
        })
    }
    let metadata = d
        .checked_add(b)
        .and_then(|n| n.checked_add(p))
        .and_then(|n| n.checked_mul(4))
        .and_then(|n| n.checked_add(16 * 1024 * 1024))
        .ok_or(StagingError::Overflow)?;
    Ok([sum(missing)?, sum(publishing)?, metadata])
}

fn calculate(costs: [u64; 3], samples: [(u64, u64); 3]) -> StagingResult<ReceiverBudgetView> {
    let mut groups: Vec<(u64, VolumeBudgetView)> = Vec::new();
    for ((role, additional), (volume, available)) in [
        StorageRole::Staging,
        StorageRole::Originals,
        StorageRole::Database,
    ]
    .into_iter()
    .zip(costs)
    .zip(samples)
    {
        if let Some((_, group)) = groups.iter_mut().find(|(id, _)| *id == volume) {
            group.roles.push(role);
            group.additional_bytes = group
                .additional_bytes
                .checked_add(additional)
                .ok_or(StagingError::Overflow)?;
            group.available_bytes = group.available_bytes.min(available);
        } else {
            groups.push((
                volume,
                VolumeBudgetView {
                    roles: vec![role],
                    additional_bytes: additional,
                    safety_margin_bytes: 0,
                    required_bytes: 0,
                    available_bytes: available,
                },
            ));
        }
    }
    let mut volumes = Vec::new();
    for (_, mut group) in groups {
        let base = group.additional_bytes;
        if base == 0 {
            continue;
        }
        group.safety_margin_bytes =
            (base / 20 + u64::from(!base.is_multiple_of(20))).max(64 * 1024 * 1024);
        group.required_bytes = base
            .checked_add(group.safety_margin_bytes)
            .ok_or(StagingError::Overflow)?;
        if group.available_bytes < group.required_bytes {
            return Err(StagingError::InsufficientSpace);
        }
        volumes.push(group);
    }
    Ok(ReceiverBudgetView {
        volumes,
        includes_metadata: true,
        includes_allocation_estimate: true,
    })
}

struct DirectorySample {
    directory: HeldDirectory,
    volume: u64,
}

impl DirectorySample {
    fn open(path: &Path) -> StagingResult<Self> {
        let directory = HeldDirectory::open(path)?;
        let volume = directory.volume_id()?;
        Ok(Self { directory, volume })
    }
    fn available(&self) -> StagingResult<u64> {
        self.directory.inspect()?;
        let result = fs2::available_space(self.directory.path()).map_err(|_| StagingError::Read)?;
        self.directory.inspect()?;
        Ok(result)
    }
}

fn measure_paths(
    staging: &Path,
    originals: &Path,
    database: &Path,
    costs: [u64; 3],
    mut sample: impl FnMut(&mut DirectorySample) -> StagingResult<u64>,
) -> StagingResult<ReceiverBudgetView> {
    let mut directories = [
        DirectorySample::open(staging)?,
        DirectorySample::open(originals)?,
        DirectorySample::open(database)?,
    ];
    let mut samples = [(0, 0); 3];
    for (directory, output) in directories.iter_mut().zip(&mut samples) {
        let free = sample(directory)?;
        directory.directory.inspect()?;
        *output = (directory.volume, free);
    }
    calculate(costs, samples)
}

pub(crate) fn measure(
    staging: &StagingOperation,
    metadata: MetadataCost,
    work: &WorkControl,
) -> StagingResult<ReceiverBudgetView> {
    let input = staging.budget_inputs(work)?;
    let costs = costs(
        &input.missing,
        &input.publishing,
        metadata.database_bytes,
        metadata.backup_bytes,
        metadata.plan_bytes,
    )?;
    measure_paths(
        input.staging,
        input.originals,
        &metadata.database_parent,
        costs,
        |directory| {
            work.check().map_err(|_| StagingError::Cancelled)?;
            #[cfg(test)]
            if let Some(free) = tests_support::sample_override() {
                return free;
            }
            directory.available()
        },
    )
}

#[cfg(test)]
pub(crate) mod tests_support {
    use super::*;
    thread_local! {
        static FREE: std::cell::Cell<Option<u64>> = const { std::cell::Cell::new(None) };
    }
    pub(crate) struct Override;
    impl Override {
        pub(crate) fn free(bytes: u64) -> Self {
            FREE.set(Some(bytes));
            Self
        }
    }
    impl Drop for Override {
        fn drop(&mut self) {
            FREE.set(None);
        }
    }
    pub(super) fn sample_override() -> Option<StagingResult<u64>> {
        FREE.get().map(Ok)
    }
}

#[cfg(test)]
mod tests;
