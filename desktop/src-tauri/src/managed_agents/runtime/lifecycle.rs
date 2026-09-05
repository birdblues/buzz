use super::*;

use crate::managed_agents::{ExitCause, ExitVerdict, HarnessExit};

/// Kill stale agent processes from a previous session whose PID is still alive
/// but not tracked in the current `runtimes` map. Updates the record fields and
/// returns `true` if any records were modified.
pub fn kill_stale_tracked_processes(
    records: &mut [ManagedAgentRecord],
    runtimes: &HashMap<ManagedAgentRuntimeKey, ManagedAgentPairRuntime>,
    instance_id: &str,
) -> bool {
    kill_stale_tracked_processes_with(
        records,
        runtimes,
        |pid| process_has_buzz_marker(pid, instance_id),
        terminate_process,
    )
}

/// Injectable version of `kill_stale_tracked_processes` for testing.
/// `has_marker(pid)` returns true when the process carries this instance's
/// `BUZZ_MANAGED_AGENT` marker; `kill(pid)` performs the termination.
pub(crate) fn kill_stale_tracked_processes_with(
    records: &mut [ManagedAgentRecord],
    runtimes: &HashMap<ManagedAgentRuntimeKey, ManagedAgentPairRuntime>,
    has_marker: impl Fn(u32) -> bool,
    mut kill: impl FnMut(u32) -> Result<(), String>,
) -> bool {
    use crate::managed_agents::BackendKind;

    let mut changed = false;
    for record in records.iter_mut() {
        if record.backend != BackendKind::Local {
            continue;
        }
        let Some(pid) = record.runtime_pid else {
            continue;
        };
        if !runtimes.keys().any(|key| key.pubkey == record.pubkey) {
            // Name-gate is omitted intentionally: custom harnesses use arbitrary
            // binary names not in KNOWN_AGENT_BINARIES. BUZZ_MANAGED_AGENT is the
            // authoritative ownership proof; terminate only if it matches.
            if has_marker(pid) {
                let _ = kill(pid);
            }
            record.runtime_pid = None;
            record.last_stopped_at = Some(crate::util::now_iso());
            record.updated_at = crate::util::now_iso();
            changed = true;
        }
    }
    changed
}

/// One runtime the reaper removed from the map this pass, with the verdict
/// that was written to its record. Pair-keyed, unlike the record's own
/// error fields, so callers can act on exactly the pair that died.
#[derive(Debug, Clone)]
pub struct ExitedRuntime {
    pub key: ManagedAgentRuntimeKey,
    pub verdict: ExitVerdict,
    /// `try_wait` itself failed: we do not actually know the child is gone.
    /// The receipt must survive so a later start can find and terminate a
    /// still-live process instead of spawning a duplicate.
    pub inspect_failed: bool,
}

/// Write an exit verdict onto the pubkey-wide record fields.
pub(crate) fn apply_exit_verdict(record: &mut ManagedAgentRecord, verdict: &ExitVerdict) {
    let now = now_iso();
    record.updated_at = now.clone();
    record.last_stopped_at = Some(now);
    record.last_exit_code = verdict.exit_code;
    record.last_error = verdict.message.clone();
    record.last_error_code = verdict.code;
}

/// Reap every tracked runtime whose child has exited, recording the verdict
/// on its record. Returns whether any record changed plus the reaped pairs.
///
/// Callers must go through `reaper::reap_managed_agent_runtimes`, which owns
/// the save → receipt → cache → emit sequence; this function only touches
/// memory. Restricted to the parent module so nothing else can reap without
/// those side effects.
pub(in crate::managed_agents) fn sync_managed_agent_processes(
    records: &mut [ManagedAgentRecord],
    runtimes: &mut HashMap<ManagedAgentRuntimeKey, ManagedAgentPairRuntime>,
) -> (bool, Vec<ExitedRuntime>) {
    sync_managed_agent_processes_with(
        records,
        runtimes,
        |child| child.try_wait(),
        |key, log_path, exit| {
            super::super::exit_verdict::classify_harness_exit_from_log(exit, log_path, &key.pubkey)
        },
    )
}

/// Injectable version of [`sync_managed_agent_processes`]: `try_wait` stands
/// in for `Child::try_wait` and `classify` for the log-backed classifier.
pub(crate) fn sync_managed_agent_processes_with(
    records: &mut [ManagedAgentRecord],
    runtimes: &mut HashMap<ManagedAgentRuntimeKey, ManagedAgentPairRuntime>,
    mut try_wait: impl FnMut(
        &mut std::process::Child,
    ) -> std::io::Result<Option<std::process::ExitStatus>>,
    classify: impl Fn(&ManagedAgentRuntimeKey, &std::path::Path, HarnessExit) -> ExitVerdict,
) -> (bool, Vec<ExitedRuntime>) {
    let mut changed = false;
    let mut exited = Vec::new();

    for (key, runtime) in runtimes.iter_mut() {
        let record = records
            .iter_mut()
            .find(|record| record.pubkey.eq_ignore_ascii_case(&key.pubkey));
        match try_wait(&mut runtime.child) {
            Ok(None) => continue,
            Ok(Some(status)) => {
                let verdict = classify(key, &runtime.log_path, HarnessExit::from(status));
                if let Some(record) = record {
                    apply_exit_verdict(record, &verdict);
                }
                exited.push(ExitedRuntime {
                    key: key.clone(),
                    verdict,
                    inspect_failed: false,
                });
            }
            Err(error) => {
                let verdict = ExitVerdict {
                    cause: ExitCause::Unknown,
                    exit_code: None,
                    message: Some(format!("failed to inspect process state: {error}")),
                    code: None,
                };
                if let Some(record) = record {
                    // Not a stop: no `last_stopped_at`, the child may be live.
                    record.updated_at = now_iso();
                    record.last_error = verdict.message.clone();
                    record.last_error_code = None;
                }
                exited.push(ExitedRuntime {
                    key: key.clone(),
                    verdict,
                    inspect_failed: true,
                });
            }
        }
        changed = true;
    }

    for exited_runtime in &exited {
        runtimes.remove(&exited_runtime.key);
    }

    // `runtime_pid` is legacy bookkeeping. Pair runtimes and receipts are the
    // authoritative lifecycle source; migration cleanup is handled separately.
    for record in records.iter_mut() {
        if record.runtime_pid.take().is_some() {
            record.updated_at = now_iso();
            changed = true;
        }
    }

    (changed, exited)
}
