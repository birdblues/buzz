//! Sandboxed app-content: discovery, blob-scoped tokens, and the
//! `buzz-media://localhost/app/{sha}.html` protocol branch.
//!
//! The relay's app-content door (see `crates/buzz-relay/src/api/app_content.rs`)
//! serves uploaded HTML inline from a separate origin, to a **blob-scoped**
//! `Authorization` header only. The webview cannot set headers on an iframe
//! `src`, so the desktop keeps the token out of the URL entirely: the iframe
//! points at the custom protocol, and this module attaches the header on the
//! way out and **re-stamps the sandbox response headers on the way back** —
//! the CSP the iframe sees comes from this process, not from whatever the LAN
//! delivered, so a stripped upstream header cannot weaken the sandbox.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use nostr::{EventBuilder, JsonUtil, Keys, Kind, Tag, Timestamp};
use serde::Deserialize;
use tauri::{http, Manager, State};

use crate::app_state::AppState;
use crate::relay::relay_api_base_url_with_override;

/// Lifetime of one app-content read token. Minted per open, per blob.
pub(crate) const APP_CONTENT_AUTH_EXPIRY_SECS: u64 = 600;

/// Largest HTML body the desktop will hand to an iframe. Mirrors the relay's
/// default `BUZZ_APP_CONTENT_MAX_BYTES`; executable content must stay small.
pub(crate) const MAX_APP_CONTENT_BYTES: u64 = 8 * 1024 * 1024;

/// How long a NIP-11 `app_content_url` answer is trusted before re-asking.
const DISCOVERY_TTL: Duration = Duration::from_secs(300);

/// CSP stamped on every app-content response by this process. Must stay in
/// lockstep with the relay's `APP_CONTENT_CSP`; the desktop copy is the one
/// that actually protects the webview.
pub(crate) const APP_CONTENT_CSP: &str = "sandbox allow-scripts; default-src 'none'; \
script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; \
font-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'; \
object-src 'none'; navigate-to 'none'; webrtc 'block'";

pub(crate) const APP_CONTENT_PERMISSIONS_POLICY: &str =
    "camera=(), microphone=(), geolocation=(), payment=(), usb=()";

/// Cached NIP-11 discovery result for one relay base URL.
#[derive(Debug, Clone)]
pub(crate) struct AppContentDiscovery {
    relay_base: String,
    app_content_url: Option<String>,
    fetched_at: Instant,
}

#[derive(Default)]
pub(crate) struct AppContentCache(Mutex<Option<AppContentDiscovery>>);

#[derive(Deserialize)]
struct RelayInfoDoc {
    #[serde(default)]
    app_content_url: Option<String>,
}

/// Accept an advertised app-content origin only when it is a bare http(s)
/// origin on the **same hostname** as the relay we are talking to. A relay
/// can only ever point us at one of its own ports — never at a third party
/// that would then receive a token signed by the user's key.
pub(crate) fn validate_app_content_url(advertised: &str, relay_base: &str) -> Option<String> {
    let app = url::Url::parse(advertised.trim()).ok()?;
    let relay = url::Url::parse(relay_base).ok()?;
    let bare = matches!(app.scheme(), "http" | "https")
        && app.username().is_empty()
        && app.password().is_none()
        && app.query().is_none()
        && app.fragment().is_none()
        && matches!(app.path(), "" | "/");
    if !bare {
        return None;
    }
    let same_host = match (app.host_str(), relay.host_str()) {
        (Some(a), Some(r)) => a.eq_ignore_ascii_case(r),
        _ => false,
    };
    if !same_host {
        return None;
    }
    // Same host *and* same scheme+port would just be the relay itself, which
    // never serves the app door. Require a distinct origin.
    if app.scheme() == relay.scheme()
        && app.port_or_known_default() == relay.port_or_known_default()
    {
        return None;
    }
    Some(advertised.trim().trim_end_matches('/').to_string())
}

/// Resolve the app-content origin for the active relay, via NIP-11, cached.
pub(crate) async fn resolve_app_content_url(app: &tauri::AppHandle) -> Option<String> {
    let state = app.state::<AppState>();
    let cache = app.state::<AppContentCache>();
    let relay_base = relay_api_base_url_with_override(&state);

    if let Ok(guard) = cache.0.lock() {
        if let Some(entry) = guard.as_ref() {
            if entry.relay_base == relay_base && entry.fetched_at.elapsed() < DISCOVERY_TTL {
                return entry.app_content_url.clone();
            }
        }
    }

    let url = format!("{}/info", relay_base.trim_end_matches('/'));
    let fetched = async {
        let response = state
            .http_client
            .get(url)
            .header("Accept", "application/nostr+json")
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        let doc: RelayInfoDoc = response.json().await.ok()?;
        doc.app_content_url
            .as_deref()
            .and_then(|advertised| validate_app_content_url(advertised, &relay_base))
    }
    .await;

    if let Ok(mut guard) = cache.0.lock() {
        *guard = Some(AppContentDiscovery {
            relay_base,
            app_content_url: fetched.clone(),
            fetched_at: Instant::now(),
        });
    }
    fetched
}

/// Whether the active relay advertises an app-content door. Drives the
/// "Run" affordance on `text/html` attachments; false keeps them downloads.
#[tauri::command]
pub async fn app_content_available(app: tauri::AppHandle) -> bool {
    resolve_app_content_url(&app).await.is_some()
}

/// Forget the cached discovery (community switch).
#[tauri::command]
pub fn reset_app_content_discovery(cache: State<'_, AppContentCache>) {
    if let Ok(mut guard) = cache.0.lock() {
        *guard = None;
    }
}

/// Sign a blob-scoped kind:24242 `t=get` token for the app door.
///
/// Deliberately **no `server` tag**: the relay's app verifier rejects any
/// token that carries one, and the existing server-scoped media signer
/// (`sign_blossom_get_auth_header`) must never be reused here.
pub(crate) fn sign_app_content_auth_header(keys: &Keys, sha256: &str) -> Result<String, String> {
    let now = Timestamp::now().as_secs();
    let tags = vec![
        Tag::parse(vec!["t", "get"]).map_err(|e| e.to_string())?,
        Tag::parse(vec!["x", sha256]).map_err(|e| e.to_string())?,
        Tag::parse(vec![
            "expiration",
            &(now + APP_CONTENT_AUTH_EXPIRY_SECS).to_string(),
        ])
        .map_err(|e| e.to_string())?,
    ];
    let event = EventBuilder::new(Kind::from(24242), "Get buzz-app")
        .tags(tags)
        .sign_with_keys(keys)
        .map_err(|e| e.to_string())?;
    Ok(format!(
        "Nostr {}",
        URL_SAFE_NO_PAD.encode(event.as_json().as_bytes())
    ))
}

/// `/app/{64-hex}.html` → the hash, or `None` for anything else.
pub(crate) fn parse_app_path(path: &str) -> Option<&str> {
    let rest = path.strip_prefix("/app/")?;
    let sha = rest.strip_suffix(".html")?;
    if sha.len() == 64 && sha.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
        Some(sha)
    } else {
        None
    }
}

fn plain(status: u16, msg: &str) -> http::Response<Vec<u8>> {
    http::Response::builder()
        .status(status)
        .header("content-type", "text/plain")
        .header("cache-control", "no-store")
        .body(msg.as_bytes().to_vec())
        .unwrap_or_else(|_| {
            http::Response::builder()
                .status(500)
                .body(Vec::new())
                .unwrap()
        })
}

/// Handle `buzz-media://localhost/app/{sha}.html` for the sandbox iframe.
pub(crate) async fn handle_app_content(
    app: &tauri::AppHandle,
    request: &http::Request<Vec<u8>>,
) -> http::Response<Vec<u8>> {
    // Path only — a query string on this route is not a credential and is
    // dropped rather than forwarded.
    let Some(sha256) = parse_app_path(request.uri().path()) else {
        return plain(404, "not found");
    };
    let Some(app_url) = resolve_app_content_url(app).await else {
        return plain(404, "app content not available on this relay");
    };

    let state = app.state::<AppState>();
    let keys = match state.signing_keys() {
        Ok(k) => k,
        Err(_) => return plain(403, "identity unavailable"),
    };
    let auth = match sign_app_content_auth_header(&keys, sha256) {
        Ok(h) => h,
        Err(_) => return plain(500, "token signing failed"),
    };

    // No-redirect client: a 3xx must never carry the token to another origin.
    let upstream = state
        .media_fetch_client
        .get(format!("{app_url}/app/{sha256}.html"))
        .header("authorization", auth)
        .timeout(Duration::from_secs(30))
        .send()
        .await;
    let resp = match upstream {
        Ok(r) => r,
        Err(_) => return plain(502, "upstream request failed"),
    };
    let status = resp.status().as_u16();
    if !(200..300).contains(&status) {
        return plain(status, "app content unavailable");
    }
    if let Some(len) = resp.content_length() {
        if len > MAX_APP_CONTENT_BYTES {
            return plain(413, "app too large");
        }
    }
    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(_) => return plain(502, "failed to read upstream body"),
    };
    if bytes.len() as u64 > MAX_APP_CONTENT_BYTES {
        return plain(413, "app too large");
    }

    sandbox_response(bytes.to_vec())
}

/// Wrap HTML bytes in the sandbox response contract. The headers are set
/// here unconditionally — upstream values are ignored on purpose.
pub(crate) fn sandbox_response(body: Vec<u8>) -> http::Response<Vec<u8>> {
    http::Response::builder()
        .status(200)
        .header("content-type", "text/html; charset=utf-8")
        .header("content-length", body.len().to_string())
        .header("content-security-policy", APP_CONTENT_CSP)
        .header("x-content-type-options", "nosniff")
        .header("referrer-policy", "no-referrer")
        .header("permissions-policy", APP_CONTENT_PERMISSIONS_POLICY)
        .header("cache-control", "private, no-store")
        .body(body)
        .unwrap_or_else(|_| plain(500, "response build failed"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_url_must_be_bare_same_host_distinct_origin() {
        let relay = "http://192.168.1.99:3000";
        assert_eq!(
            validate_app_content_url("http://192.168.1.99:3001/", relay).as_deref(),
            Some("http://192.168.1.99:3001")
        );
        assert_eq!(
            validate_app_content_url("HTTP://192.168.1.99:3001", relay).as_deref(),
            Some("HTTP://192.168.1.99:3001")
        );
        for bad in [
            "http://evil.example:3001",     // other host
            "http://192.168.1.99:3000",     // the relay itself
            "http://192.168.1.99:3001/x",   // path
            "http://192.168.1.99:3001/?q",  // query
            "http://u:p@192.168.1.99:3001", // credentials
            "ws://192.168.1.99:3001",       // scheme
            "192.168.1.99:3001",            // not a URL
        ] {
            assert!(validate_app_content_url(bad, relay).is_none(), "{bad}");
        }
    }

    #[test]
    fn app_path_is_strict() {
        let sha = "a".repeat(64);
        assert_eq!(
            parse_app_path(&format!("/app/{sha}.html")),
            Some(sha.as_str())
        );
        assert!(parse_app_path(&format!("/app/{sha}")).is_none());
        assert!(parse_app_path(&format!("/media/{sha}.html")).is_none());
        assert!(parse_app_path(&format!("/app/{}.html", "A".repeat(64))).is_none());
        assert!(parse_app_path("/app/../x.html").is_none());
    }

    #[test]
    fn token_is_blob_scoped_without_server_tag() {
        let keys = Keys::generate();
        let sha = "b".repeat(64);
        let header = sign_app_content_auth_header(&keys, &sha).unwrap();
        let json = URL_SAFE_NO_PAD
            .decode(header.strip_prefix("Nostr ").unwrap())
            .unwrap();
        let event = nostr::Event::from_json(json).unwrap();
        assert!(event.verify().is_ok());
        let tags: Vec<(String, String)> = event
            .tags
            .iter()
            .map(|t| {
                (
                    t.kind().to_string(),
                    t.content().unwrap_or_default().to_string(),
                )
            })
            .collect();
        assert!(tags.contains(&("t".into(), "get".into())));
        assert!(tags.contains(&("x".into(), sha.clone())));
        assert!(!tags.iter().any(|(k, _)| k == "server"));
    }

    #[test]
    fn sandbox_response_pins_headers() {
        let resp = sandbox_response(b"<!DOCTYPE html>".to_vec());
        let h = |n: &str| resp.headers().get(n).unwrap().to_str().unwrap().to_string();
        assert_eq!(h("content-type"), "text/html; charset=utf-8");
        assert_eq!(h("x-content-type-options"), "nosniff");
        assert_eq!(h("referrer-policy"), "no-referrer");
        assert_eq!(h("cache-control"), "private, no-store");
        assert!(h("content-security-policy").contains("sandbox allow-scripts"));
        assert!(h("content-security-policy").contains("connect-src 'none'"));
        assert!(!h("content-security-policy").contains("allow-same-origin"));
    }
}
