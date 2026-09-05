//! Why did a managed-agent harness exit?
//!
//! The supervisor cannot trust the exit code alone: `buzz-acp` returns `Ok(())`
//! (exit 0) from several paths that are crashes in every sense that matters
//! ("all agents dead", "relay background task is gone") — see
//! `docs/remote-agents.md` Known Defect 6. So the verdict combines the exit
//! status with the *current-generation* slice of the pair log.
//!
//! The log is append-only across restarts, and the agent subprocess's stderr
//! is inherited into the same file, so two defences are structural rather
//! than optional: the window is anchored at the last desktop-written start
//! marker, and an "intentional" phrase only counts when the exit code is 0 —
//! an agent can print the phrase, but it cannot make the harness exit clean.

use std::{
    fs::File,
    io::{Read as _, Seek, SeekFrom},
    path::Path,
    process::ExitStatus,
};

use serde::{Deserialize, Serialize};

use super::storage::{recognize_agent_error_line, AgentLogError};

/// Wire-facing classification carried on `managed-agent-runtime-status`.
/// Deliberately a unit enum: the frontend compares the string.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExitCause {
    /// The harness died. Nonzero exit, signal death, or a crash line in the
    /// current generation regardless of exit code.
    Crash,
    /// The harness chose to exit (owner `!shutdown`, inactivity bound) and
    /// exited 0.
    Intentional,
    /// Exit 0 with nothing recognizable in the log. Not an error; not proof
    /// of intent either.
    Unknown,
}

/// The full verdict for one exited pair. `message`/`code` are what land in
/// `ManagedAgentRecord::last_error{,_code}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExitVerdict {
    pub cause: ExitCause,
    pub exit_code: Option<i32>,
    pub message: Option<String>,
    pub code: Option<i64>,
}

/// Platform-neutral view of a child's exit status, so the classifier is a
/// pure function testable without spawning anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HarnessExit {
    pub code: Option<i32>,
    /// Terminating signal number on unix; always `None` elsewhere.
    pub signal: Option<i32>,
}

impl From<ExitStatus> for HarnessExit {
    fn from(status: ExitStatus) -> Self {
        #[cfg(unix)]
        let signal = {
            use std::os::unix::process::ExitStatusExt as _;
            status.signal()
        };
        #[cfg(not(unix))]
        let signal = None;
        Self {
            code: status.code(),
            signal,
        }
    }
}

impl HarnessExit {
    fn is_clean(self) -> bool {
        self.signal.is_none() && self.code == Some(0)
    }
}

/// How far back from the end of the log the classifier will read looking for
/// the current generation's start marker. Bounded so a chatty agent cannot
/// make every exit cost a full-file read (Review-Proven Rule 4); if the marker
/// is older than this the whole budget window is classified as-is.
pub const LOG_WINDOW_BUDGET_BYTES: u64 = 256 * 1024;

/// Substrings (not prefixes — the harness logs through `tracing`'s compact
/// formatter, so every line carries a timestamp and target first) that the
/// harness emits immediately before an exit that is a failure even when the
/// process returns 0.
pub const CRASH_PHRASES: &[&str] = &[
    "all agents dead — exiting",
    "relay background task is gone",
    "result channel closed — exiting main loop",
];

/// Substrings the harness emits when it exits on purpose. Only honoured
/// alongside exit 0 — see the module docs.
pub const INTENTIONAL_PHRASES: &[&str] = &[
    "shutdown command from owner — exiting gracefully",
    "inactivity bound reached — exiting gracefully",
];

const START_MARKER_PREFIX: &str = "=== starting ";

enum LogSignal {
    Crash(AgentLogError),
    Intentional,
}

fn recognize_line(line: &str) -> Option<LogSignal> {
    let trimmed = line.trim();
    if let Some(error) = recognize_agent_error_line(trimmed) {
        return Some(LogSignal::Crash(error));
    }
    // anyhow's `main` failure line. Line-start only: a mid-line "Error:" is
    // ordinary agent chatter (see the `llm auth:` guard in storage_tests).
    if trimmed.starts_with("Error:") {
        return Some(LogSignal::Crash(AgentLogError {
            message: trimmed.to_string(),
            code: None,
        }));
    }
    if CRASH_PHRASES.iter().any(|phrase| trimmed.contains(phrase)) {
        return Some(LogSignal::Crash(AgentLogError {
            message: trimmed.to_string(),
            code: None,
        }));
    }
    if INTENTIONAL_PHRASES
        .iter()
        .any(|phrase| trimmed.contains(phrase))
    {
        return Some(LogSignal::Intentional);
    }
    None
}

fn is_start_marker(line: &str, pubkey: &str) -> bool {
    let trimmed = line.trim_start();
    trimmed.starts_with(START_MARKER_PREFIX) && trimmed.contains(&format!(" ({pubkey}) at "))
}

/// The slice of `text` after the last start marker for `pubkey`, or all of
/// `text` when no marker is present.
pub fn current_generation_window<'a>(text: &'a str, pubkey: &str) -> &'a str {
    let mut window_start = 0;
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        if is_start_marker(line, pubkey) {
            window_start = offset + line.len();
        }
        offset += line.len();
    }
    &text[window_start..]
}

/// Read the tail of `path` (at most `budget` bytes), strip ANSI, and return
/// the current-generation window for `pubkey`.
pub fn read_log_since_last_start(path: &Path, pubkey: &str, budget: u64) -> Result<String, String> {
    if !path.exists() {
        return Ok(String::new());
    }
    let mut file = File::open(path)
        .map_err(|error| format!("failed to read log file {}: {error}", path.display()))?;
    let len = file
        .seek(SeekFrom::End(0))
        .map_err(|error| format!("failed to seek log file: {error}"))?;
    let take = len.min(budget);
    file.seek(SeekFrom::Start(len - take))
        .map_err(|error| format!("failed to seek log file: {error}"))?;
    let mut buf = Vec::with_capacity(take as usize);
    file.read_to_end(&mut buf)
        .map_err(|error| format!("failed to read log tail: {error}"))?;
    let cleaned = strip_ansi_escapes::strip_str(String::from_utf8_lossy(&buf));
    Ok(current_generation_window(&cleaned, pubkey).to_string())
}

/// Pure classification of one exit from its status and the current-generation
/// log window. Scans the window backwards: a crash exits right after its fatal
/// line and a graceful exit is followed only by a couple of tail lines, so the
/// first recognized signal from the end is the one that describes this exit.
pub fn classify_harness_exit(exit: HarnessExit, window: &str) -> ExitVerdict {
    let signal = window.lines().rev().find_map(recognize_line);
    match signal {
        Some(LogSignal::Crash(error)) => ExitVerdict {
            cause: ExitCause::Crash,
            exit_code: exit.code,
            message: Some(error.message),
            code: error.code,
        },
        Some(LogSignal::Intentional) if exit.is_clean() => ExitVerdict {
            cause: ExitCause::Intentional,
            exit_code: exit.code,
            message: None,
            code: None,
        },
        // An intentional phrase paired with a failure exit is either a spoof
        // from inherited agent stderr or a harness that could not finish its
        // graceful path — both are failures.
        _ => {
            if let Some(signal) = exit.signal {
                ExitVerdict {
                    cause: ExitCause::Crash,
                    exit_code: exit.code,
                    message: Some(format!("harness killed by signal {signal}")),
                    code: None,
                }
            } else if exit.is_clean() {
                ExitVerdict {
                    cause: ExitCause::Unknown,
                    exit_code: exit.code,
                    message: None,
                    code: None,
                }
            } else {
                ExitVerdict {
                    cause: ExitCause::Crash,
                    exit_code: exit.code,
                    message: Some(match exit.code {
                        Some(code) => format!("harness exited with status {code}"),
                        None => "harness exited with an unknown status".to_string(),
                    }),
                    code: None,
                }
            }
        }
    }
}

/// Production entry: read the window from `log_path` and classify. A log
/// that cannot be read classifies as if it were empty — the exit status still
/// decides crash vs. unknown.
pub fn classify_harness_exit_from_log(
    exit: HarnessExit,
    log_path: &Path,
    pubkey: &str,
) -> ExitVerdict {
    let window =
        read_log_since_last_start(log_path, pubkey, LOG_WINDOW_BUDGET_BYTES).unwrap_or_default();
    classify_harness_exit(exit, &window)
}

#[cfg(test)]
#[path = "exit_verdict_tests.rs"]
mod tests;
