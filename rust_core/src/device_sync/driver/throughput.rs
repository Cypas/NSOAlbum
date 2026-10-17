use std::{cell::RefCell, collections::VecDeque};

#[derive(Default)]
pub(super) struct Throughput {
    samples: VecDeque<(u64, u64)>,
    started: Option<u64>,
    observed: u64,
    published: RefCell<Option<(u64, u64)>>,
}

impl Throughput {
    pub(super) fn record(&mut self, now: u64, bytes: u64) {
        let now = now.max(self.observed);
        self.observed = now;
        self.started.get_or_insert(now);
        if let Some((_, value)) = self.samples.back_mut().filter(|(at, _)| *at == now) {
            *value = value.saturating_add(bytes);
        } else {
            self.samples.push_back((now, bytes));
        }
        while self
            .samples
            .front()
            .is_some_and(|(at, _)| now.saturating_sub(*at) >= 3000)
        {
            self.samples.pop_front();
        }
    }

    pub(super) fn rate(&self, now: u64) -> u64 {
        let mut published = self.published.borrow_mut();
        let now = now
            .max(self.observed)
            .max(published.map_or(0, |(at, _)| at));
        if let Some((at, rate)) = *published {
            if now.saturating_sub(at) < 500 {
                return rate;
            }
        }
        let bytes: u64 = self
            .samples
            .iter()
            .filter(|(at, _)| now.saturating_sub(*at) < 3000)
            .map(|(_, bytes)| *bytes)
            .sum();
        let elapsed = now
            .saturating_sub(self.started.unwrap_or(now))
            .clamp(500, 3000);
        let rate =
            (u128::from(bytes) * 1000 / u128::from(elapsed)).min(u128::from(u64::MAX)) as u64;
        *published = Some((now, rate));
        rate
    }
}
