use crate::error::CoreResult;
use std::collections::VecDeque;
use std::future::Future;

/// Public presentation bytes shared across accounts. URLs come from Coral data.
/// No identities, credentials or authenticated responses are stored here.
#[derive(Default)]
pub(super) struct PublicGameImages {
    entries: VecDeque<(String, String, Vec<u8>)>,
    bytes: usize,
}

impl PublicGameImages {
    pub(super) async fn load(
        &mut self,
        name: &str,
        url: &str,
        download: impl Future<Output = CoreResult<Vec<u8>>>,
    ) -> CoreResult<Vec<u8>> {
        if let Some(index) = self
            .entries
            .iter()
            .position(|(game, source, _)| game == name && source == url)
        {
            let entry = self.entries.remove(index).expect("matching image");
            let bytes = entry.2.clone();
            self.entries.push_back(entry);
            return Ok(bytes);
        }
        let bytes = download.await?;
        if !bytes.is_empty() && bytes.len() <= 4 * 1024 * 1024 {
            if let Some(index) = self.entries.iter().position(|(game, _, _)| game == name) {
                self.bytes -= self.entries.remove(index).expect("matching game").2.len();
            }
            while self.entries.len() >= 128 || self.bytes + bytes.len() > 16 * 1024 * 1024 {
                if let Some((_, _, removed)) = self.entries.pop_front() {
                    self.bytes -= removed.len();
                } else {
                    break;
                }
            }
            self.bytes += bytes.len();
            self.entries
                .push_back((name.to_owned(), url.to_owned(), bytes.clone()));
        }
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::CoreError;

    #[tokio::test]
    async fn game_name_reuses_public_bytes_and_changed_url_replaces_them() {
        let mut images = PublicGameImages::default();
        assert_eq!(
            images
                .load("Game", "https://example.com/a", async { Ok(vec![1]) })
                .await
                .unwrap(),
            vec![1]
        );
        assert_eq!(
            images
                .load("Game", "https://example.com/a", async {
                    panic!("cache hit must not download")
                })
                .await
                .unwrap(),
            vec![1]
        );
        assert_eq!(
            images
                .load("Game", "https://example.com/b", async { Ok(vec![2]) })
                .await
                .unwrap(),
            vec![2]
        );
        assert_eq!(images.entries.len(), 1);
        assert_eq!(images.bytes, 1);
    }

    #[tokio::test]
    async fn failed_and_empty_downloads_do_not_poison_game_cache() {
        let mut images = PublicGameImages::default();
        assert!(images
            .load("Game", "url", async { Err(CoreError::Cancelled) })
            .await
            .is_err());
        assert!(images
            .load("Game", "url", async { Ok(Vec::new()) })
            .await
            .unwrap()
            .is_empty());
        assert_eq!(
            images
                .load("Game", "url", async { Ok(vec![3]) })
                .await
                .unwrap(),
            vec![3]
        );
    }

    #[tokio::test]
    async fn memory_and_entry_budgets_evict_least_recently_used_images() {
        let mut images = PublicGameImages::default();
        for i in 0..6 {
            images
                .load(&i.to_string(), "url", async {
                    Ok(vec![0; 4 * 1024 * 1024])
                })
                .await
                .unwrap();
        }
        assert_eq!(images.bytes, 16 * 1024 * 1024);
        assert_eq!(images.entries.len(), 4);
        assert_eq!(images.entries.front().unwrap().0, "2");
        for i in 6..140 {
            images
                .load(&i.to_string(), "url", async { Ok(vec![0]) })
                .await
                .unwrap();
        }
        assert_eq!(images.entries.len(), 128);
        assert!(images.bytes <= 16 * 1024 * 1024);
        assert_eq!(images.entries.front().unwrap().0, "12");
    }

    #[tokio::test]
    async fn simultaneous_readers_share_one_download_under_the_shared_lock() {
        let images = tokio::sync::Mutex::new(PublicGameImages::default());
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let load = || async {
            images
                .lock()
                .await
                .load("Game", "url", async {
                    calls.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    tokio::task::yield_now().await;
                    Ok(vec![4])
                })
                .await
                .unwrap()
        };
        let (first, second) = tokio::join!(load(), load());
        assert_eq!(first, vec![4]);
        assert_eq!(second, vec![4]);
        assert_eq!(calls.load(std::sync::atomic::Ordering::Relaxed), 1);
    }
}
