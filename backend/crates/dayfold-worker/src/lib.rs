//! Durable reminder scheduling and APNs outbox dispatch.

use chrono::{TimeDelta, Utc};
use dayfold_apns::{ApnsClient, Outcome, PushRequest};
use dayfold_store::{Store, StoreError};
use std::time::Duration;
use tokio::sync::watch;

const MAX_ATTEMPTS: i32 = 12;
const LEASE_SECONDS: i64 = 120;

/// Each process can run a worker. PostgreSQL row locks and expiring leases
/// coordinate them; a process crash never removes an uncompleted delivery.
pub async fn run(store: Store, apns: Option<ApnsClient>, mut shutdown: watch::Receiver<bool>) {
    let dispatch_store = store.clone();
    let dispatch_shutdown = shutdown.clone();
    let dispatcher = tokio::spawn(async move {
        dispatch_loop(dispatch_store, apns, dispatch_shutdown).await;
    });
    let mut tick = tokio::time::interval(Duration::from_millis(500));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut cleanup = tokio::time::interval(Duration::from_secs(60));
    loop {
        tokio::select! {
            _ = shutdown.changed() => break,
            _ = cleanup.tick() => {
                if store.cleanup(200).await.is_err() { tracing::error!("retention cleanup failed"); }
            },
            _ = tick.tick() => {
                if let Err(error) = store.materialize_due(100).await {
                    let _ = error;
                    tracing::error!("notification worker iteration failed");
                }
            }
        }
    }
    let _ = dispatcher.await;
}

async fn dispatch_loop(
    store: Store,
    apns: Option<ApnsClient>,
    mut shutdown: watch::Receiver<bool>,
) {
    let Some(client) = apns else {
        return;
    };
    let mut tick = tokio::time::interval(Duration::from_millis(500));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = shutdown.changed() => break,
            _ = tick.tick() => {
                if dispatch_once(&store, &client).await.is_err() { tracing::error!("push dispatch iteration failed"); }
            }
        }
    }
}

/// Exposed for deterministic integration checks; uses the same path as serving.
pub async fn tick_once(store: &Store, apns: Option<&ApnsClient>) -> Result<(), StoreError> {
    store.materialize_due(100).await?;
    let Some(client) = apns else {
        return Ok(());
    };
    dispatch_once(store, client).await
}

async fn dispatch_once(store: &Store, client: &ApnsClient) -> Result<(), StoreError> {
    // A small concurrent batch stays well inside the lease even when APNs times out.
    let jobs = store.claim_pushes(8, LEASE_SECONDS, MAX_ATTEMPTS).await?;
    let mut tasks = tokio::task::JoinSet::new();
    for job in jobs {
        let store = store.clone();
        let client = client.clone();
        tasks.spawn(async move {
            // Recheck after claim to observe acknowledgements/cancellation. A remote
            // delivery already in flight cannot be recalled; clients deduplicate IDs.
            if !store.push_is_current(job.id, job.lease_id).await? {
                return Ok::<_, StoreError>(());
            }
            let request = PushRequest {
                token: job.token,
                environment: job.environment,
                notification_id: job.notification.id,
                kind: job.notification.kind,
                subject_id: job.notification.subject_id,
                revision: job.notification.revision,
                expires_at: job.notification.expires_at,
            };
            match client.send(&request).await {
                Outcome::Delivered => {
                    store.complete_push(job.id, job.lease_id).await?;
                }
                Outcome::InvalidToken { invalidated_at } => {
                    store
                        .invalidate_push_token(job.id, job.lease_id, invalidated_at)
                        .await?;
                }
                Outcome::Permanent { reason } => {
                    tracing::warn!(reason, "APNs permanently rejected a notification");
                    store.dead_push(job.id, job.lease_id).await?;
                }
                Outcome::Retry { after } => {
                    let delay = retry_delay(job.attempt, after, job.id.as_u128() as u64);
                    let retry_at = Utc::now() + TimeDelta::seconds(delay.as_secs() as i64);
                    store
                        .retry_push(job.id, job.lease_id, retry_at, MAX_ATTEMPTS)
                        .await?;
                }
            }
            Ok(())
        });
    }
    let mut first_error = None;
    while let Some(result) = tasks.join_next().await {
        match result {
            Ok(Err(error)) if first_error.is_none() => first_error = Some(error),
            Ok(_) => {}
            Err(_) => tracing::error!("push dispatch task failed; lease will expire"),
        }
    }
    match first_error {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

fn retry_delay(attempt: i32, provider_minimum: Duration, jitter_seed: u64) -> Duration {
    let exponent = u32::try_from(attempt.clamp(1, 10)).unwrap_or(1);
    let backoff = (5 * 2_u64.pow(exponent)).min(3600);
    let jitter = jitter_seed % (backoff / 4 + 1);
    Duration::from_secs(
        (backoff + jitter)
            .max(provider_minimum.as_secs())
            .min(86_400),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retries_back_off_and_respect_provider_delay_with_a_bound() {
        assert!(retry_delay(4, Duration::ZERO, 1) > retry_delay(1, Duration::ZERO, 1));
        assert!(retry_delay(1, Duration::from_secs(300), 1) >= Duration::from_secs(300));
        assert_eq!(
            retry_delay(i32::MAX, Duration::from_secs(u64::MAX), 1),
            Duration::from_secs(86_400)
        );
    }
}
