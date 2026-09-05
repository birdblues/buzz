//! Truth table for `classify_harness_exit` plus the generation-anchor reader.
//!
//! Every case names what it pins: deleting the corresponding recognizer, the
//! exit-0 coupling, or the anchor makes exactly that case RED.

use std::io::Write as _;

use tempfile::NamedTempFile;

use super::{
    classify_harness_exit, classify_harness_exit_from_log, current_generation_window,
    read_log_since_last_start, ExitCause, HarnessExit, LOG_WINDOW_BUDGET_BYTES,
};

const PK: &str = "aa";

fn clean() -> HarnessExit {
    HarnessExit {
        code: Some(0),
        signal: None,
    }
}

fn failed(code: i32) -> HarnessExit {
    HarnessExit {
        code: Some(code),
        signal: None,
    }
}

fn killed(signal: i32) -> HarnessExit {
    HarnessExit {
        code: None,
        signal: Some(signal),
    }
}

fn start_marker() -> String {
    format!("=== starting test ({PK}) at 2026-09-04T11:00:00Z ===\n")
}

fn tracing(level: &str, msg: &str) -> String {
    // The harness's `tracing_subscriber::fmt().compact()` shape.
    format!("2026-09-04T11:32:10.123456Z {level:>5} buzz_acp: {msg}\n")
}

// ── the incident ──────────────────────────────────────────────────────────

#[test]
fn yesterday_relay_connect_error_becomes_the_recorded_cause() {
    // Deleting the line-start `Error:` recognizer reverts this to the
    // "harness exited with status 1" fallback — RED.
    let window = format!(
        "{}{}Error: relay connect error: connection reset by peer\n",
        tracing("INFO", "connecting"),
        tracing("WARN", "relay event stream ended — requesting reconnect")
    );
    let verdict = classify_harness_exit(failed(1), &window);
    assert_eq!(verdict.cause, ExitCause::Crash);
    assert_eq!(
        verdict.message.as_deref(),
        Some("Error: relay connect error: connection reset by peer")
    );
    assert_eq!(verdict.exit_code, Some(1));
}

// ── exit-0 crashes (the contract violations the plan cites) ───────────────

#[test]
fn all_agents_dead_is_a_crash_even_at_exit_zero() {
    let window =
        tracing("ERROR", "all agents dead — exiting") + &tracing("INFO", "buzz-acp stopped");
    let verdict = classify_harness_exit(clean(), &window);
    assert_eq!(verdict.cause, ExitCause::Crash);
    assert!(verdict
        .message
        .as_deref()
        .is_some_and(|m| m.contains("all agents dead")));
}

#[test]
fn relay_background_task_gone_is_a_crash_in_both_main_and_setup_mode() {
    for msg in [
        "relay background task is gone: closed — exiting",
        "setup-mode: relay background task is gone: closed — exiting",
    ] {
        let verdict = classify_harness_exit(clean(), &tracing("ERROR", msg));
        assert_eq!(verdict.cause, ExitCause::Crash, "{msg}");
    }
}

#[test]
fn result_channel_closed_is_a_crash_at_exit_zero() {
    let verdict = classify_harness_exit(
        clean(),
        &tracing("INFO", "result channel closed — exiting main loop"),
    );
    assert_eq!(verdict.cause, ExitCause::Crash);
}

// ── intentional ───────────────────────────────────────────────────────────

#[test]
fn owner_shutdown_and_inactivity_are_intentional_at_exit_zero() {
    for msg in [
        "shutdown command from owner — exiting gracefully",
        "inactivity bound reached — exiting gracefully",
    ] {
        let window = tracing("INFO", msg) + &tracing("INFO", "buzz-acp stopped");
        let verdict = classify_harness_exit(clean(), &window);
        assert_eq!(verdict.cause, ExitCause::Intentional, "{msg}");
        assert_eq!(verdict.message, None);
        assert_eq!(verdict.code, None);
    }
}

#[test]
fn intentional_phrase_with_nonzero_exit_is_a_crash_not_a_spoofed_stop() {
    // Agent stderr is inherited into the same log: an agent can print the
    // graceful phrase, but it cannot make the harness exit 0. Dropping the
    // exit-0 coupling turns this into Intentional — RED.
    let window = tracing("INFO", "shutdown command from owner — exiting gracefully");
    let verdict = classify_harness_exit(failed(1), &window);
    assert_eq!(verdict.cause, ExitCause::Crash);
    assert_eq!(
        verdict.message.as_deref(),
        Some("harness exited with status 1")
    );
}

#[test]
fn buzz_acp_stopped_alone_is_not_intentional() {
    // The tail line follows crashes too; it must never be a signal.
    let verdict = classify_harness_exit(clean(), &tracing("INFO", "buzz-acp stopped"));
    assert_eq!(verdict.cause, ExitCause::Unknown);
}

// ── signal / fallback ─────────────────────────────────────────────────────

#[test]
fn signal_death_is_a_crash_with_the_signal_named() {
    // `kill -9` leaves nothing in the log. The runtime verification depends
    // on this being Crash (toast), not Unknown (badge only).
    let verdict = classify_harness_exit(killed(9), "");
    assert_eq!(verdict.cause, ExitCause::Crash);
    assert_eq!(
        verdict.message.as_deref(),
        Some("harness killed by signal 9")
    );
    assert_eq!(verdict.exit_code, None);
}

#[test]
fn nonzero_exit_without_a_recognized_line_is_a_crash_with_fallback() {
    let verdict = classify_harness_exit(failed(137), &tracing("INFO", "noise"));
    assert_eq!(verdict.cause, ExitCause::Crash);
    assert_eq!(
        verdict.message.as_deref(),
        Some("harness exited with status 137")
    );
}

#[test]
fn clean_exit_without_a_recognized_line_is_unknown_and_not_an_error() {
    let verdict = classify_harness_exit(clean(), &tracing("INFO", "noise"));
    assert_eq!(verdict.cause, ExitCause::Unknown);
    assert_eq!(verdict.message, None);
}

// ── ordering and existing recognizers ─────────────────────────────────────

#[test]
fn last_signal_from_the_end_wins() {
    // A reconnect `Error:` earlier in the generation followed by a graceful
    // exit is intentional; the same lines in the other order are a crash.
    let graceful_last = format!(
        "Error: relay connect error: reset\n{}",
        tracing("INFO", "shutdown command from owner — exiting gracefully")
    );
    assert_eq!(
        classify_harness_exit(clean(), &graceful_last).cause,
        ExitCause::Intentional
    );
    let crash_last = format!(
        "{}Error: relay connect error: reset\n",
        tracing("INFO", "shutdown command from owner — exiting gracefully")
    );
    assert_eq!(
        classify_harness_exit(clean(), &crash_last).cause,
        ExitCause::Crash
    );
}

#[test]
fn structured_agent_errors_keep_their_code() {
    let verdict = classify_harness_exit(
        failed(1),
        "Agent reported error (code -32001): llm auth: 401\n",
    );
    assert_eq!(verdict.cause, ExitCause::Crash);
    assert_eq!(verdict.code, Some(-32001));
}

#[test]
fn midline_error_text_is_not_promoted() {
    let verdict = classify_harness_exit(failed(1), "agent said Error: something odd\n");
    assert_eq!(
        verdict.message.as_deref(),
        Some("harness exited with status 1"),
        "a mid-line Error: is chatter, not the fatal line"
    );
}

// ── generation anchoring ──────────────────────────────────────────────────

#[test]
fn window_starts_after_the_last_start_marker_for_this_pubkey() {
    let text = format!(
        "old noise\nError: previous generation crashed\n=== stopped test ({PK}) at t ===\n{}new noise\n",
        start_marker()
    );
    assert_eq!(current_generation_window(&text, PK), "new noise\n");
}

#[test]
fn previous_generation_crash_does_not_leak_into_a_clean_current_generation() {
    // Removing the anchor makes the old `Error:` line classify this exit as
    // a crash — RED.
    let text = format!(
        "Error: previous generation crashed\n{}{}",
        start_marker(),
        tracing("INFO", "inactivity bound reached — exiting gracefully")
    );
    let window = current_generation_window(&text, PK);
    assert_eq!(
        classify_harness_exit(clean(), window).cause,
        ExitCause::Intentional
    );
}

#[test]
fn previous_generation_stop_marker_is_ignored_inside_the_window() {
    // Desktop stop markers are never a current-generation signal — the stop
    // paths remove the runtime before the reaper sees it — so one that
    // happens to sit after the anchor changes nothing.
    let text = format!(
        "{}=== stopped test ({PK}) at t ===\nError: boom\n",
        start_marker()
    );
    let window = current_generation_window(&text, PK);
    assert_eq!(
        classify_harness_exit(failed(1), window).cause,
        ExitCause::Crash
    );
    assert_eq!(
        classify_harness_exit(failed(1), window).message.as_deref(),
        Some("Error: boom")
    );
}

#[test]
fn another_pubkeys_start_marker_does_not_anchor() {
    let text = "Error: mine\n=== starting other (bb) at t ===\nnoise\n";
    assert_eq!(current_generation_window(text, PK), text);
}

#[test]
fn agent_spoofed_start_marker_needs_the_exact_pubkey_shape() {
    // An agent printing "=== starting" without the desktop's " (pk) at "
    // shape cannot move the anchor.
    let text = "Error: real\n=== starting fake ===\nnoise\n";
    assert_eq!(current_generation_window(text, PK), text);
}

#[test]
fn no_marker_means_the_whole_window_is_classified() {
    let text = "Error: fatal\n";
    assert_eq!(current_generation_window(text, PK), text);
}

#[test]
fn reader_strips_ansi_and_honours_the_byte_budget() {
    let mut file = NamedTempFile::new().expect("temp log");
    // Old generation with a crash, then the anchor, then a lot of chatter so
    // the anchor falls outside a small budget.
    write!(file, "\x1b[31mError: old\x1b[0m\n{}", start_marker()).expect("write");
    for i in 0..200 {
        writeln!(file, "chatter line {i}").expect("write");
    }
    writeln!(file, "\x1b[2mError: new\x1b[0m").expect("write");

    // Full budget: anchored, old crash excluded, ANSI gone.
    let window = read_log_since_last_start(file.path(), PK, LOG_WINDOW_BUDGET_BYTES).expect("read");
    assert!(!window.contains("Error: old"));
    assert!(window.contains("Error: new"));
    assert!(!window.contains('\x1b'));

    // Tiny budget: the anchor is out of reach, so the window is just the
    // tail — the current crash is still found rather than always Unknown.
    let window = read_log_since_last_start(file.path(), PK, 64).expect("read");
    assert!(window.contains("Error: new"));
    assert!(!window.contains("chatter line 0\n"));
    assert_eq!(
        classify_harness_exit_from_log(failed(1), file.path(), PK).cause,
        ExitCause::Crash
    );
}

#[test]
fn missing_log_classifies_from_exit_status_alone() {
    let path = std::env::temp_dir().join("buzz-exit-verdict-missing.log");
    let _ = std::fs::remove_file(&path);
    assert_eq!(
        classify_harness_exit_from_log(failed(1), &path, PK).cause,
        ExitCause::Crash
    );
    assert_eq!(
        classify_harness_exit_from_log(clean(), &path, PK).cause,
        ExitCause::Unknown
    );
}
