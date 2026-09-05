//! The one place a tracked harness runtime is reaped.
//!
//! Before this module there were four reapers — the sync helper, an inline
//! loop in `list_managed_agent_runtimes`, and the dead-child branches of
//! `start_pair` and the stop paths — and three of them dropped the exit
//! evidence or wrote a stop marker over a crash. Every path now funnels
//! through [`reap_managed_agent_runtimes`] (bulk) or [`finish_dead_pair`]
//! (one known-dead pair), which own the sequence:
//!
//!   classify → record → **save** → remove receipt → clear pair cache → emit
//!
//! Save comes before the receipt goes: if the store write fails the receipt
//! survives and the next pass retries, so a crash is never both untracked and
//! unrecorded. Emission is the default; only shutdown and launch restore ask
//! for [`Notify::Silent`], because a death observed while the app is going
//! down or coming up is not news.
//!
//! The 30-second liveness tick lives here too. It is the only reaper that
//! runs when nothing else does — app in the background, every agent already
//! believed stopped so the frontend poll is off.

use std::{collections::HashMap, process::ExitStatus, sync::Mutex, time::Duration};

use tauri::{AppHandle, Manager};
use tokio_util::sync::CancellationToken;

use super::{
    apply_exit_verdict,
    exit_verdict::classify_harness_exit_from_log,
    load_global_agent_config, load_managed_agents, load_personas, remove_agent_runtime_receipt,
    runtime_commands::{emit_status, exited_status_for},
    save_managed_agents, sync_managed_agent_processes, ExitVerdict, ExitedRuntime, HarnessExit,
    ManagedAgentPairRuntime, ManagedAgentRecord, ManagedAgentRuntimeKey,
};
use crate::app_state::AppState;

/// Whether a reap emits `managed-agent-runtime-status` for each exited pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Notify {
    Emit,
    Silent,
}

/// Reap every exited runtime in `runtimes`, persisting verdicts and running
/// the per-pair side effects. Callers hold at least the store and process
/// locks; this function takes none itself.
pub(crate) fn reap_managed_agent_runtimes<R: tauri::Runtime>(
    app: &AppHandle<R>,
    records: &mut [ManagedAgentRecord],
    runtimes: &mut HashMap<ManagedAgentRuntimeKey, ManagedAgentPairRuntime>,
    notify: Notify,
) -> Result<Vec<ExitedRuntime>, String> {
    let (changed, exited) = sync_managed_agent_processes(records, runtimes);
    if changed {
        save_managed_agents(app, records)?;
    }
    finish_exited(app, records, &exited, notify);
    Ok(exited)
}

/// Finish one pair whose child is already known to have exited (`status`),
/// on a path that has removed it from the map itself. Does not save — the
/// caller is mid-transaction and saves the record it holds.
pub(crate) fn finish_dead_pair<R: tauri::Runtime>(
    app: &AppHandle<R>,
    record: &mut ManagedAgentRecord,
    key: &ManagedAgentRuntimeKey,
    runtime: &ManagedAgentPairRuntime,
    status: ExitStatus,
    notify: Notify,
) -> ExitVerdict {
    let verdict =
        classify_harness_exit_from_log(HarnessExit::from(status), &runtime.log_path, &key.pubkey);
    apply_exit_verdict(record, &verdict);
    let exited = ExitedRuntime {
        key: key.clone(),
        verdict: verdict.clone(),
        inspect_failed: false,
    };
    finish_exited(app, std::slice::from_ref(record), &[exited], notify);
    verdict
}

pub(crate) fn finish_exited<R: tauri::Runtime>(
    app: &AppHandle<R>,
    records: &[ManagedAgentRecord],
    exited: &[ExitedRuntime],
    notify: Notify,
) {
    if exited.is_empty() {
        return;
    }
    let state = app.state::<AppState>();
    for exited_runtime in exited {
        if !exited_runtime.inspect_failed {
            remove_agent_runtime_receipt(app, &exited_runtime.key);
        }
        // Pair-scoped on purpose: the pubkey-wide clear would drop the live
        // session of the same agent in another community.
        state.clear_agent_session_cache(&exited_runtime.key);
    }
    if notify == Notify::Silent {
        return;
    }
    let personas = load_personas(app).unwrap_or_default();
    let global = load_global_agent_config(app).unwrap_or_default();
    for exited_runtime in exited {
        let Some(record) = records.iter().find(|record| {
            record
                .pubkey
                .eq_ignore_ascii_case(&exited_runtime.key.pubkey)
        }) else {
            continue;
        };
        let status = exited_status_for(app, record, exited_runtime, &personas, &global);
        emit_status(app, &status);
    }
}

// ── liveness tick ──────────────────────────────────────────────────────────

pub(crate) const LIVENESS_TICK_INTERVAL: Duration = Duration::from_secs(30);
const LIVENESS_TICK_JOIN_TIMEOUT: Duration = Duration::from_secs(5);

/// Handle to the running tick, held in `AppState` so shutdown can stop it.
pub struct LivenessTick {
    cancel: CancellationToken,
    handle: tauri::async_runtime::JoinHandle<()>,
}

/// Start the periodic reaper. Idempotent per `AppState`: a second call while
/// one is running is a no-op.
pub(crate) fn spawn_liveness_tick<R: tauri::Runtime>(app: &AppHandle<R>) {
    spawn_liveness_tick_with_interval(app, LIVENESS_TICK_INTERVAL);
}

pub(crate) fn spawn_liveness_tick_with_interval<R: tauri::Runtime>(
    app: &AppHandle<R>,
    interval: Duration,
) {
    let state = app.state::<AppState>();
    let Ok(mut slot) = state.liveness_tick.lock() else {
        return;
    };
    if slot.is_some() {
        return;
    }
    let cancel = CancellationToken::new();
    let handle =
        tauri::async_runtime::spawn(run_liveness_tick(app.clone(), cancel.clone(), interval));
    *slot = Some(LivenessTick { cancel, handle });
}

async fn run_liveness_tick<R: tauri::Runtime>(
    app: AppHandle<R>,
    cancel: CancellationToken,
    interval: Duration,
) {
    loop {
        tokio::select! {
            _ = cancel.cancelled() => break,
            _ = tokio::time::sleep(interval) => {}
        }
        let app_for_tick = app.clone();
        // `spawn_blocking` is not cancellable: cancellation only stops the
        // *next* tick, and shutdown joins this one. Never abort the handle —
        // that would orphan a blocking body that may hold the store lock.
        let _ = tauri::async_runtime::spawn_blocking(move || {
            if let Err(error) = liveness_tick_once(&app_for_tick) {
                eprintln!("buzz-desktop: liveness tick failed: {error}");
            }
        })
        .await;
    }
}

/// One reaper pass. Returns `Ok(false)` when shutdown has started and the
/// pass was skipped without touching any state.
pub(crate) fn liveness_tick_once<R: tauri::Runtime>(app: &AppHandle<R>) -> Result<bool, String> {
    use std::sync::atomic::Ordering;
    let state = app.state::<AppState>();
    if state.shutdown_started.load(Ordering::Acquire) {
        return Ok(false);
    }
    // Reaping mutates the protected PID set, so it is a runtime transition
    // (see `AppState::managed_agent_runtime_transition`). Re-check the
    // shutdown flag once the lock is ours: a tick parked on this lock while
    // shutdown ran must not wake up afterwards and rewrite the store.
    let _transition = state
        .managed_agent_runtime_transition
        .lock()
        .map_err(|error| error.to_string())?;
    if state.shutdown_started.load(Ordering::Acquire) {
        return Ok(false);
    }
    let _store = state
        .managed_agents_store_lock
        .lock()
        .map_err(|error| error.to_string())?;
    let mut records = load_managed_agents(app)?;
    let mut runtimes = state
        .managed_agent_processes
        .lock()
        .map_err(|error| error.to_string())?;
    reap_managed_agent_runtimes(app, &mut records, &mut runtimes, Notify::Emit)?;
    Ok(true)
}

/// Cancel the tick and wait (bounded) for an in-flight pass to finish.
/// Called from `shutdown_managed_agents` *before* it takes the transition
/// lock, so a pass that is mid-reap can complete instead of deadlocking
/// against shutdown. Safe to call repeatedly: only the first call finds a
/// handle. Synchronous because every shutdown entry point is synchronous
/// (`shut_down_app`, the ctrlc handler thread, `sign_out`).
pub(crate) fn stop_liveness_tick(tick: &Mutex<Option<LivenessTick>>) {
    let Some(LivenessTick { cancel, handle }) = tick.lock().ok().and_then(|mut slot| slot.take())
    else {
        return;
    };
    cancel.cancel();
    let (done_tx, done_rx) = std::sync::mpsc::channel::<()>();
    tauri::async_runtime::spawn(async move {
        let _ = handle.await;
        let _ = done_tx.send(());
    });
    if done_rx.recv_timeout(LIVENESS_TICK_JOIN_TIMEOUT).is_err() {
        // A pass stuck inside keyring or log I/O. Shutdown proceeds; the
        // transition-lock re-check above keeps a late wake-up from writing.
        eprintln!("buzz-desktop: liveness tick did not finish before shutdown; continuing");
    }
}

#[cfg(test)]
#[path = "reaper_tests.rs"]
mod tests;
