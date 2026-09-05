//! Reaper tests on a headless mock Tauri app: the production sequence
//! (classify → record → save → receipt → cache → emit) runs against real
//! child processes, a real store on a temp HOME, and the real event bus, so
//! the JSON asserted here is exactly what the frontend listener receives.
//!
//! Each test names what makes it RED.

#![cfg(unix)]

use std::{
    collections::HashMap,
    io::Write as _,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use tauri::{Listener as _, Manager as _};

use super::{
    finish_exited, liveness_tick_once, reap_managed_agent_runtimes,
    spawn_liveness_tick_with_interval, stop_liveness_tick, Notify,
};
use crate::{
    app_state::{build_app_state, AppState},
    managed_agents::{
        load_managed_agents, managed_agent_runtime_log_path, read_all_agent_runtime_receipts,
        runtime_commands::list_managed_agent_runtimes_blocking, save_managed_agents,
        write_agent_runtime_receipt, ExitCause, ExitVerdict, ExitedRuntime,
        ManagedAgentPairRuntime, ManagedAgentProcess, ManagedAgentRecord, ManagedAgentRuntimeKey,
        ManagedAgentRuntimeReceipt,
    },
};

const RELAY: &str = "wss://relay.example";
const OTHER_RELAY: &str = "wss://other.example";

fn pubkey() -> String {
    "a".repeat(64)
}

/// A mock app with its own HOME so the store, receipts and logs land in a
/// temp dir. Holds the crate-wide env lock for its lifetime (HOME swap).
struct MockApp {
    app: tauri::App<tauri::test::MockRuntime>,
    _temp: tempfile::TempDir,
    _prior_home: Option<std::ffi::OsString>,
    _prior_xdg: Option<std::ffi::OsString>,
    _env_guard: std::sync::MutexGuard<'static, ()>,
}

impl MockApp {
    fn new() -> Self {
        let env_guard = crate::managed_agents::lock_path_mutex();
        let temp = tempfile::tempdir().expect("tempdir");
        let home = temp.path().join("home");
        std::fs::create_dir_all(&home).expect("home");
        let prior_home = std::env::var_os("HOME");
        let prior_xdg = std::env::var_os("XDG_DATA_HOME");
        #[allow(deprecated)]
        // SAFETY: the crate-wide process-env lock is held for the app's life.
        unsafe {
            std::env::set_var("HOME", &home);
            std::env::set_var("XDG_DATA_HOME", &home);
        }
        let app = tauri::test::mock_builder()
            .manage(build_app_state())
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("mock app builds headless");
        Self {
            app,
            _temp: temp,
            _prior_home: prior_home,
            _prior_xdg: prior_xdg,
            _env_guard: env_guard,
        }
    }

    fn handle(&self) -> &tauri::AppHandle<tauri::test::MockRuntime> {
        self.app.handle()
    }

    fn state(&self) -> tauri::State<'_, AppState> {
        self.app.state::<AppState>()
    }

    /// Collect every `managed-agent-runtime-status` payload emitted from now on.
    fn capture_status_events(&self) -> Arc<Mutex<Vec<serde_json::Value>>> {
        let captured = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&captured);
        self.handle()
            .listen_any("managed-agent-runtime-status", move |event| {
                let value: serde_json::Value =
                    serde_json::from_str(event.payload()).expect("status payload is JSON");
                sink.lock().expect("sink").push(value);
            });
        captured
    }
}

impl Drop for MockApp {
    fn drop(&mut self) {
        #[allow(deprecated)]
        // SAFETY: still under the process-env lock held by `_env_guard`.
        unsafe {
            match &self._prior_home {
                Some(v) => std::env::set_var("HOME", v),
                None => std::env::remove_var("HOME"),
            }
            match &self._prior_xdg {
                Some(v) => std::env::set_var("XDG_DATA_HOME", v),
                None => std::env::remove_var("XDG_DATA_HOME"),
            }
        }
    }
}

fn record(pubkey: &str) -> ManagedAgentRecord {
    serde_json::from_value(serde_json::json!({
        "pubkey": pubkey,
        "name": "Reaped",
        "relay_url": "",
        "acp_command": "buzz-acp",
        "agent_command": "buzz-agent",
        "agent_args": [],
        "mcp_command": "",
        "turn_timeout_seconds": 320,
        "system_prompt": null,
        "model": null,
        "provider": null,
        "env_vars": {},
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "last_started_at": "2026-01-01T00:00:00Z",
        "last_stopped_at": null,
        "last_exit_code": null,
        "last_error": null
    }))
    .expect("record fixture")
}

fn key(relay: &str) -> ManagedAgentRuntimeKey {
    ManagedAgentRuntimeKey::new(pubkey(), relay).expect("key")
}

/// A pair runtime whose child has already exited with `exit_code`. Absolute
/// paths: sibling tests swap PATH under the shared env lock (observed flake).
fn dead_runtime(log_path: std::path::PathBuf, exit_code: i32) -> ManagedAgentPairRuntime {
    let mut child = Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("exit {exit_code}"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn sh");
    let deadline = Instant::now() + Duration::from_secs(5);
    while child.try_wait().expect("try_wait").is_none() {
        assert!(Instant::now() < deadline, "child did not exit");
        std::thread::sleep(Duration::from_millis(5));
    }
    let process = ManagedAgentProcess {
        child,
        log_path,
        spawn_config: crate::managed_agents::spawn_snapshot::prospective_spawn_config_snapshot(
            &record(&pubkey()),
            &[],
            &[],
            RELAY,
            &Default::default(),
            false,
            crate::managed_agents::AcpSessionPolicy::Channel,
        ),
        setup_mode: false,
        adapter_availability: None,
        start_nonce: "test-nonce".to_string(),
        #[cfg(windows)]
        job: None,
    };
    ManagedAgentPairRuntime::starting(process)
}

fn session_cache() -> crate::managed_agents::config_bridge::SessionConfigCache {
    serde_json::from_value(serde_json::json!({
        "configOptions": [],
        "availableModes": [],
        "availableModels": [],
        "currentModel": null,
        "gooseNativeConfig": null,
        "capturedAt": "2026-01-01T00:00:00Z"
    }))
    .expect("session cache fixture")
}

/// Seed: one record, a dead pair on RELAY with a crash line in its log, a
/// receipt for it, and session caches for both this pair and the same agent
/// on OTHER_RELAY.
struct Seeded {
    key: ManagedAgentRuntimeKey,
    other_key: ManagedAgentRuntimeKey,
    runtimes: HashMap<ManagedAgentRuntimeKey, ManagedAgentPairRuntime>,
}

fn seed(mock: &MockApp, exit_code: i32, log_tail: &str) -> Seeded {
    let app = mock.handle();
    save_managed_agents(app, &[record(&pubkey())]).expect("seed record");
    let key = key(RELAY);
    let other_key = key_for(OTHER_RELAY);
    let log_path = managed_agent_runtime_log_path(app, &key).expect("log path");
    let mut log = std::fs::File::create(&log_path).expect("log file");
    write!(
        log,
        "=== starting Reaped ({}) at 2026-09-04T11:00:00Z ===\n{log_tail}",
        pubkey()
    )
    .expect("write log");
    write_agent_runtime_receipt(
        app,
        &ManagedAgentRuntimeReceipt {
            key: key.clone(),
            pid: 1,
            desktop_instance_id: "test".into(),
            started_at: "2026-01-01T00:00:00Z".into(),
        },
    )
    .expect("receipt");
    let state = mock.state();
    state.put_session_cache(key.clone(), session_cache());
    state.put_session_cache(other_key.clone(), session_cache());
    let mut runtimes = HashMap::new();
    runtimes.insert(key.clone(), dead_runtime(log_path, exit_code));
    Seeded {
        key,
        other_key,
        runtimes,
    }
}

fn key_for(relay: &str) -> ManagedAgentRuntimeKey {
    ManagedAgentRuntimeKey::new(pubkey(), relay).expect("key")
}

fn receipt_exists(
    app: &tauri::AppHandle<tauri::test::MockRuntime>,
    key: &ManagedAgentRuntimeKey,
) -> bool {
    read_all_agent_runtime_receipts(app)
        .iter()
        .any(|(_, receipt)| &receipt.key == key)
}

const CRASH_TAIL: &str = "Error: relay connect error: connection reset by peer\n";

#[test]
fn reap_records_the_verdict_then_removes_receipt_clears_pair_cache_and_emits() {
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded {
        key,
        other_key,
        mut runtimes,
    } = seed(&mock, 1, CRASH_TAIL);
    let events = mock.capture_status_events();
    let mut records = load_managed_agents(app).expect("load");

    let exited =
        reap_managed_agent_runtimes(app, &mut records, &mut runtimes, Notify::Emit).expect("reap");

    // Evidence persisted (reverting to the inline reaper loses these).
    assert_eq!(exited.len(), 1);
    assert_eq!(exited[0].verdict.cause, ExitCause::Crash);
    let saved = load_managed_agents(app).expect("reload");
    assert_eq!(saved[0].last_exit_code, Some(1));
    assert_eq!(
        saved[0].last_error.as_deref(),
        Some("Error: relay connect error: connection reset by peer")
    );
    assert!(saved[0].last_stopped_at.is_some());
    assert!(runtimes.is_empty(), "the dead pair leaves the map");

    // Side effects: receipt gone, only THIS pair's session cache cleared.
    assert!(!receipt_exists(app, &key), "receipt must be removed");
    let state = mock.state();
    assert!(state.get_session_cache(&key).is_none());
    assert!(
        state.get_session_cache(&other_key).is_some(),
        "the same agent's other-community session must survive (pubkey-wide clear regressed this)"
    );

    // The wire payload the frontend listener reads — from Rust serde, not a
    // hand-written fixture.
    let events = events.lock().expect("events");
    assert_eq!(events.len(), 1, "one status per exited pair");
    let event = &events[0];
    assert_eq!(event["pubkey"], pubkey());
    assert_eq!(event["relayUrl"], key.relay_url);
    assert_eq!(event["lifecycle"], "stopped");
    assert_eq!(event["exitCause"], "crash");
    assert_eq!(
        event["error"],
        "Error: relay connect error: connection reset by peer"
    );
}

#[test]
fn silent_reap_records_and_cleans_up_but_emits_nothing() {
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded {
        key, mut runtimes, ..
    } = seed(&mock, 1, CRASH_TAIL);
    let events = mock.capture_status_events();
    let mut records = load_managed_agents(app).expect("load");

    reap_managed_agent_runtimes(app, &mut records, &mut runtimes, Notify::Silent).expect("reap");

    assert_eq!(
        load_managed_agents(app).expect("reload")[0].last_exit_code,
        Some(1)
    );
    assert!(!receipt_exists(app, &key));
    assert!(
        events.lock().expect("events").is_empty(),
        "shutdown/restore must not toast"
    );
}

#[test]
fn intentional_exit_emits_intentional_with_no_error() {
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded { mut runtimes, .. } = seed(
        &mock,
        0,
        "2026-09-04T11:32:10Z  INFO buzz_acp: shutdown command from owner — exiting gracefully\n2026-09-04T11:32:10Z  INFO buzz_acp: buzz-acp stopped\n",
    );
    let events = mock.capture_status_events();
    let mut records = load_managed_agents(app).expect("load");

    reap_managed_agent_runtimes(app, &mut records, &mut runtimes, Notify::Emit).expect("reap");

    let saved = load_managed_agents(app).expect("reload");
    assert_eq!(saved[0].last_exit_code, Some(0));
    assert_eq!(
        saved[0].last_error, None,
        "an intentional stop is not an error"
    );
    let events = events.lock().expect("events");
    assert_eq!(events[0]["exitCause"], "intentional");
    assert!(events[0]["error"].is_null());
}

#[test]
fn save_failure_keeps_the_receipt_for_the_next_pass() {
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded {
        key, mut runtimes, ..
    } = seed(&mock, 1, CRASH_TAIL);
    let mut records = load_managed_agents(app).expect("load");
    // Make the store unwritable: a directory where the file goes.
    let store = crate::managed_agents::managed_agents_base_dir(app)
        .expect("base dir")
        .join("managed-agents.json");
    std::fs::remove_file(&store).expect("remove store file");
    std::fs::create_dir_all(&store).expect("store dir");

    let result = reap_managed_agent_runtimes(app, &mut records, &mut runtimes, Notify::Emit);

    assert!(result.is_err(), "save failure must propagate");
    assert!(
        receipt_exists(app, &key),
        "receipt must survive an unsaved verdict (save must precede receipt removal)"
    );
}

#[test]
fn inspection_failure_keeps_the_receipt_but_clears_the_cache() {
    // `try_wait` erroring is not proof the child is gone; the receipt is what
    // lets the next start terminate a still-live process instead of
    // spawning a duplicate.
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded { key, .. } = seed(&mock, 1, CRASH_TAIL);
    let records = load_managed_agents(app).expect("load");
    let exited = ExitedRuntime {
        key: key.clone(),
        verdict: ExitVerdict {
            cause: ExitCause::Unknown,
            exit_code: None,
            message: Some("failed to inspect process state: boom".into()),
            code: None,
        },
        inspect_failed: true,
    };

    finish_exited(app, &records, &[exited], Notify::Silent);

    assert!(receipt_exists(app, &key));
    assert!(mock.state().get_session_cache(&key).is_none());
}

#[test]
fn list_managed_agent_runtimes_reaps_through_the_reaper() {
    // The sidebar path used to drop the exit code and error. Running the
    // real command body proves it now records, cleans up, emits, and no
    // longer lists the dead pair.
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded { key, runtimes, .. } = seed(&mock, 1, CRASH_TAIL);
    *mock
        .state()
        .managed_agent_processes
        .lock()
        .expect("runtimes") = runtimes;
    let events = mock.capture_status_events();

    let statuses = list_managed_agent_runtimes_blocking(app).expect("list");

    assert!(statuses.is_empty(), "a reaped pair is not a live runtime");
    let saved = load_managed_agents(app).expect("reload");
    assert_eq!(saved[0].last_exit_code, Some(1));
    assert!(saved[0].last_error.is_some());
    assert!(!receipt_exists(app, &key));
    assert_eq!(events.lock().expect("events")[0]["exitCause"], "crash");
}

#[test]
fn liveness_tick_reaps_when_the_app_is_running() {
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded { key, runtimes, .. } = seed(&mock, 1, CRASH_TAIL);
    *mock
        .state()
        .managed_agent_processes
        .lock()
        .expect("runtimes") = runtimes;
    let events = mock.capture_status_events();

    assert_eq!(liveness_tick_once(app), Ok(true));

    assert!(!receipt_exists(app, &key));
    assert_eq!(
        load_managed_agents(app).expect("reload")[0].last_exit_code,
        Some(1)
    );
    assert_eq!(events.lock().expect("events").len(), 1);
}

#[test]
fn liveness_tick_skips_entirely_once_shutdown_has_started() {
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded { key, runtimes, .. } = seed(&mock, 1, CRASH_TAIL);
    *mock
        .state()
        .managed_agent_processes
        .lock()
        .expect("runtimes") = runtimes;
    mock.state()
        .shutdown_started
        .store(true, std::sync::atomic::Ordering::SeqCst);

    assert_eq!(liveness_tick_once(app), Ok(false));

    assert!(receipt_exists(app, &key), "a skipped pass touches nothing");
    assert_eq!(
        mock.state()
            .managed_agent_processes
            .lock()
            .expect("runtimes")
            .len(),
        1
    );
}

#[test]
fn stop_liveness_tick_joins_a_pass_parked_on_the_transition_lock() {
    // Scenario the shutdown ordering exists for: a pass is blocked on the
    // transition lock when shutdown begins. Shutdown must (a) join it inside
    // the timeout and (b) the pass, once it gets the lock, must see the
    // shutdown flag and do nothing — otherwise it would rewrite the store
    // after shutdown finished.
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded { key, runtimes, .. } = seed(&mock, 1, CRASH_TAIL);
    *mock
        .state()
        .managed_agent_processes
        .lock()
        .expect("runtimes") = runtimes;
    let state = mock.state();

    // Park: hold the transition lock, then start a fast tick.
    let transition = state
        .managed_agent_runtime_transition
        .lock()
        .expect("transition");
    spawn_liveness_tick_with_interval(app, Duration::from_millis(20));
    std::thread::sleep(Duration::from_millis(200));

    // Shutdown begins: flag first, then release the lock the pass waits on,
    // then join — the order `shutdown_managed_agents` uses.
    state
        .shutdown_started
        .store(true, std::sync::atomic::Ordering::SeqCst);
    drop(transition);
    let started = Instant::now();
    stop_liveness_tick(&state.liveness_tick);
    let elapsed = started.elapsed();

    assert!(
        elapsed < Duration::from_secs(4),
        "join must finish well inside the 5s timeout, took {elapsed:?}"
    );
    assert!(
        state.liveness_tick.lock().expect("slot").is_none(),
        "the handle is taken exactly once"
    );
    // The parked pass re-checked the flag after acquiring the lock and
    // skipped: nothing reaped, nothing removed.
    assert!(receipt_exists(app, &key));
    assert_eq!(
        state
            .managed_agent_processes
            .lock()
            .expect("runtimes")
            .len(),
        1
    );
    // Idempotent: a second shutdown entry point finds nothing to join.
    stop_liveness_tick(&state.liveness_tick);
}

#[test]
fn stop_on_an_already_dead_pair_records_a_crash_and_writes_no_stop_marker() {
    // A Stop click that lands after the harness died used to `wait()` the
    // corpse, store its exit code, and append a stop marker — rewriting a
    // crash as an intentional stop. Routing the dead branch through the
    // reaper makes this test RED if the marker comes back.
    let mock = MockApp::new();
    let app = mock.handle();
    let Seeded {
        key, mut runtimes, ..
    } = seed(&mock, 1, CRASH_TAIL);
    let events = mock.capture_status_events();
    let mut records = load_managed_agents(app).expect("load");

    crate::managed_agents::stop_managed_agent_process(app, &mut records[0], &mut runtimes)
        .expect("stop");

    let log = std::fs::read_to_string(managed_agent_runtime_log_path(app, &key).expect("log path"))
        .expect("read log");
    assert!(
        !log.contains("=== stopped"),
        "no stop marker over a crash: {log}"
    );
    // `stop_managed_agent_process` clears the record's error fields for a
    // stop it performed; here the reaper's verdict must already have been
    // emitted before that bookkeeping ran.
    let events = events.lock().expect("events");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["exitCause"], "crash");
    assert!(!receipt_exists(app, &key));
    assert!(runtimes.is_empty());
}

#[test]
fn sync_seam_marks_inspection_failures_and_uses_the_injected_classifier() {
    // Binds the `_with` seam: an erroring `try_wait` yields
    // `inspect_failed` with no `last_stopped_at`; a normal exit is classified
    // by the injected function, whose verdict lands on the record verbatim.
    let mock = MockApp::new();
    let Seeded { key, runtimes, .. } = seed(&mock, 3, "");
    let mut records = vec![record(&pubkey())];

    let mut failing = runtimes;
    let (changed, exited) = crate::managed_agents::sync_managed_agent_processes_with(
        &mut records,
        &mut failing,
        |_child| Err(std::io::Error::other("boom")),
        |_key, _log, _exit| unreachable!("classifier must not run on inspection failure"),
    );
    assert!(changed);
    assert_eq!(exited.len(), 1);
    assert!(exited[0].inspect_failed);
    assert_eq!(exited[0].verdict.cause, ExitCause::Unknown);
    assert_eq!(
        records[0].last_stopped_at, None,
        "not a stop: the child may be live"
    );
    assert!(records[0]
        .last_error
        .as_deref()
        .is_some_and(|m| m.starts_with("failed to inspect process state:")));
    assert!(failing.is_empty());

    let mut normal = HashMap::new();
    normal.insert(
        key.clone(),
        dead_runtime(std::path::PathBuf::from("/nonexistent"), 3),
    );
    let mut records = vec![record(&pubkey())];
    let (_, exited) = crate::managed_agents::sync_managed_agent_processes_with(
        &mut records,
        &mut normal,
        |child| child.try_wait(),
        |key, _log, exit| {
            assert_eq!(exit.code, Some(3));
            assert_eq!(key.relay_url, "wss://relay.example");
            ExitVerdict {
                cause: ExitCause::Crash,
                exit_code: exit.code,
                message: Some("injected verdict".into()),
                code: Some(-1),
            }
        },
    );
    assert!(!exited[0].inspect_failed);
    assert_eq!(records[0].last_exit_code, Some(3));
    assert_eq!(records[0].last_error.as_deref(), Some("injected verdict"));
    assert_eq!(records[0].last_error_code, Some(-1));
    assert!(records[0].last_stopped_at.is_some());
}
