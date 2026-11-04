//! Per-work test synchronization, absent from release builds. This only pauses
//! an actual progress boundary; the consumer still owns cancellation and all
//! production checks must run to stop remaining work.
use super::{BackupObservation, BackupWork, WorkControl};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{self, Receiver, SyncSender},
    Arc, Mutex,
};
use std::time::Duration;

pub(super) type Observer = Arc<dyn Fn(BackupObservation) + Send + Sync>;
const LIMIT: Duration = Duration::from_secs(30);

pub(crate) struct BackupPause {
    work: WorkControl,
    observed: Receiver<BackupObservation>,
    resume: SyncSender<()>,
    armed: Arc<AtomicBool>,
}

impl BackupPause {
    pub(crate) fn wait(&self) -> Result<BackupObservation, mpsc::RecvTimeoutError> {
        self.observed.recv_timeout(LIMIT)
    }

    pub(crate) fn release(&self) {
        self.armed.store(false, Ordering::Release);
        let _ = self.resume.try_send(());
    }
}

impl Drop for BackupPause {
    fn drop(&mut self) {
        self.release();
        self.work.counters.backup_observer.lock().unwrap().take();
    }
}

pub(crate) fn pause_backup_after(
    work: &WorkControl,
    phase: BackupWork,
    threshold: u64,
) -> BackupPause {
    let (send_observed, observed) = mpsc::sync_channel(1);
    let (resume, receive_resume) = mpsc::sync_channel(1);
    let receive_resume = Mutex::new(receive_resume);
    let armed = Arc::new(AtomicBool::new(true));
    let callback_armed = armed.clone();
    let callback = Arc::new(move |observation: BackupObservation| {
        if observation.phase == phase
            && observation.completed >= threshold
            && callback_armed.swap(false, Ordering::AcqRel)
        {
            send_observed.send(observation).unwrap();
            receive_resume.lock().unwrap().recv_timeout(LIMIT).unwrap();
        }
    });
    assert!(work
        .counters
        .backup_observer
        .lock()
        .unwrap()
        .replace(callback)
        .is_none());
    BackupPause {
        work: work.clone(),
        observed,
        resume,
        armed,
    }
}
