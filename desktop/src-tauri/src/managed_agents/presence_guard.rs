//! Cross-machine start guard: don't spawn a harness for an agent that is
//! already answering from another device.
//!
//! `ManagedAgentSummary.status` is a LOCAL process fact — an agent running on
//! another machine reads as `stopped` here (see `build_managed_agent_summary`),
//! so the desktop happily starts a second harness for the same identity and
//! the agent replies twice. Relay presence (kind:20001) is the only live
//! cross-machine signal available, so the start path consults it.
//!
//! Presence is an OPTIMIZATION, never a lock. It has known blind spots — a
//! duplicate shutting down clears the key without counting the other live
//! sockets, the harness publishes `online` only after AUTH+subscribe, Redis
//! can be down — so every failure mode here resolves to "unknown", which
//! allows the spawn.

use std::collections::HashMap;
use std::time::Duration;

use buzz_core_pkg::PresenceStatus;

use crate::app_state::AppState;

/// Budget for the whole presence lookup, rate-limit wait included.
///
/// This sits on the mention hot path, so it must be short. `query_relay_at`
/// carries its own 30s `QUERY_REQUEST_TIMEOUT` and additionally awaits
/// `wait_for_rate_limit()` before issuing the request; without an outer bound
/// a single mention could stall for half a minute. Blowing this budget yields
/// "unknown" and therefore allows the spawn — a duplicate reply is a far
/// better failure than a mention that hangs.
const PRESENCE_PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Ask the relay which of `pubkeys` are currently live.
///
/// Returns only what the relay positively reported. A missing entry means
/// "unknown", which is deliberately indistinguishable from offline at the call
/// site: both allow a spawn.
///
/// Deliberately NOT a `Result`. That is part of the contract — an earlier
/// revision of this guard used `?` on the query and inverted the intended
/// fail-open into fail-closed, which would have made a Redis blip unable to
/// start any agent at all.
pub(crate) async fn query_agent_presence(
    state: &AppState,
    pubkeys: &[String],
    relay_ws_url: &str,
) -> HashMap<String, PresenceStatus> {
    if pubkeys.is_empty() {
        return HashMap::new();
    }

    // `query_relay_at` speaks to the relay's HTTP bridge; handing it the
    // ws:// workspace URL would fail every request, and a failed request reads
    // as "unknown" — the guard would silently do nothing.
    let api_base = crate::relay::relay_http_base_url(relay_ws_url);

    // The relay answers presence from Redis only when the filters match
    // `synthesize_presence` exactly: EVERY filter must carry exactly one kind
    // in {20001, 40902} AND a non-empty `authors`. Anything else falls through
    // to a normal DB query, and ephemeral events are never stored there, so
    // the answer comes back `[]` — which reads as "everyone offline" and turns
    // this guard off without a single error. Do not add kinds, do not drop
    // `authors`.
    let filters = [serde_json::json!({
        "kinds": [buzz_core_pkg::kind::KIND_PRESENCE_UPDATE],
        "authors": pubkeys,
    })];

    let events = match tokio::time::timeout(
        PRESENCE_PROBE_TIMEOUT,
        crate::relay::query_relay_at(state, &api_base, &filters),
    )
    .await
    {
        Ok(Ok(events)) => events,
        Ok(Err(error)) => {
            tracing::warn!(
                error = %error,
                "presence probe failed; allowing local start (fail-open)"
            );
            return HashMap::new();
        }
        Err(_) => {
            tracing::warn!(
                timeout_secs = PRESENCE_PROBE_TIMEOUT.as_secs(),
                "presence probe timed out; allowing local start (fail-open)"
            );
            return HashMap::new();
        }
    };

    crate::commands::profile::latest_presence_by_pubkey(&events)
        .into_iter()
        .map(|(pubkey, status)| (pubkey.to_lowercase(), status))
        .collect()
}
