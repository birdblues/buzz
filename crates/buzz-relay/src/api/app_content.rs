//! Sandboxed app-content door: `GET /app/{sha256}.html` on a dedicated listener.
//!
//! This is the one place the relay ever serves uploaded `text/html` inline —
//! and it does so only from a *separate origin* (its own TCP listener, see
//! `Config::app_content`), only to a **blob-scoped** kind:24242 token carried
//! in the `Authorization` header, and only under a CSP `sandbox` that gives
//! the document an opaque origin and no network. The main listener's
//! `/media/{sha}.html` keeps treating HTML as an inert download; that
//! invariant is pinned by `buzz-media` and the media e2e tests and is not
//! weakened here — it is relocated behind a door with its own gate.
//!
//! Three things make the sandbox hold even if one layer fails:
//!   1. the response CSP below (opaque origin, `connect-src 'none'`);
//!   2. the embedder's own sandbox (`<iframe sandbox>` on desktop, the
//!      navigation delegate on mobile) — survives in-frame navigation;
//!   3. the token: no query-string credential exists, so a leaked URL opens
//!      nothing, and a leaked token opens exactly one blob for ≤10 minutes.

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::Response,
};
use buzz_core::tenant::TenantContext;
use buzz_media::MediaError;

use crate::state::AppState;

/// CSP for every app-content response.
///
/// `sandbox allow-scripts` (no `allow-same-origin`) makes the document
/// opaque-origin: it cannot read anything scoped to the relay origin even if
/// the port split were ever undone. `connect-src 'none'` closes fetch/XHR/
/// WebSocket/beacon; `webrtc 'block'` closes the one channel `connect-src`
/// does not cover. `navigate-to` is not implemented by WebKit today; it is
/// harmless where unsupported and the embedder owns navigation locking.
pub const APP_CONTENT_CSP: &str = "sandbox allow-scripts; default-src 'none'; \
script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; \
font-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'; \
object-src 'none'; navigate-to 'none'; webrtc 'block'";

/// Permissions-Policy for app-content responses: no device access.
pub const APP_CONTENT_PERMISSIONS_POLICY: &str =
    "camera=(), microphone=(), geolocation=(), payment=(), usb=()";

/// Browser-facing headers every app-content response carries, in one place so
/// the handler and its tests cannot drift apart.
pub fn app_content_headers() -> [(header::HeaderName, &'static str); 6] {
    [
        (header::CONTENT_TYPE, "text/html; charset=utf-8"),
        (header::CONTENT_SECURITY_POLICY, APP_CONTENT_CSP),
        (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
        (header::REFERRER_POLICY, "no-referrer"),
        // Not a `header::` constant in this http version; literal is fine.
        (
            header::HeaderName::from_static("permissions-policy"),
            APP_CONTENT_PERMISSIONS_POLICY,
        ),
        // Tokens travel in headers, but the body is still member-only content.
        (header::CACHE_CONTROL, "private, no-store"),
    ]
}

/// Map the app-content request `Host` onto the community lookup key.
///
/// Communities are keyed by the relay's own authority (`relay_url` host plus
/// its explicit port, e.g. `192.168.1.99:3000`), and `normalize_host` keeps
/// non-default ports on purpose. A request on the app-content listener
/// arrives as `Host: 192.168.1.99:3001`, so we keep its *hostname* and
/// substitute the *relay's* port — "same host, different port" is the one
/// convention this door supports. Anything that then fails to resolve is a
/// generic 404, exactly like every other unmapped host.
pub(crate) fn app_content_lookup_host(raw_host: &str, relay_url: &str) -> String {
    let hostname = split_authority(raw_host.trim()).0;
    if hostname.is_empty() {
        return String::new();
    }
    let relay_authority = buzz_core::tenant::relay_url_authority(relay_url);
    match split_authority(&relay_authority).1 {
        Some(port) => format!("{hostname}:{port}"),
        None => hostname.to_string(),
    }
}

/// Split `host[:port]` into (`host`, `port`), keeping IPv6 brackets intact.
fn split_authority(authority: &str) -> (&str, Option<&str>) {
    if let Some(rest) = authority.strip_prefix('[') {
        // `[v6]` or `[v6]:port`
        return match rest.find(']') {
            Some(end) => {
                let host = &authority[..end + 2];
                let port = authority[end + 2..].strip_prefix(':');
                (host, port)
            }
            None => (authority, None),
        };
    }
    match authority.rsplit_once(':') {
        // A bare IPv6 literal without brackets has more than one colon — treat
        // the whole thing as the host rather than guessing.
        Some((host, port)) if !host.contains(':') => (host, Some(port)),
        _ => (authority, None),
    }
}

fn parse_sha256_html(sha256_ext: &str) -> Result<&str, MediaError> {
    let sha256 = sha256_ext
        .strip_suffix(".html")
        .ok_or(MediaError::NotFound)?;
    if sha256.len() != 64 || !sha256.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
        return Err(MediaError::NotFound);
    }
    Ok(sha256)
}

async fn bind_app_content_tenant(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<TenantContext, MediaError> {
    let raw_host = headers
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let lookup_host = app_content_lookup_host(raw_host, &state.config.relay_url);
    crate::tenant::bind_community(&state.db, &lookup_host)
        .await
        .map_err(|_| MediaError::NotFound)
}

/// `GET /app/{sha256}.html` — serve one uploaded HTML blob inside the sandbox.
pub async fn get_app_content(
    State(state): State<Arc<AppState>>,
    Path(sha256_ext): Path<String>,
    headers: HeaderMap,
) -> Result<Response, MediaError> {
    let result = serve_app_content(state, &sha256_ext, &headers).await;
    if let Err(error) = &result {
        // The door answers with a bare status; clients render "app content
        // unavailable". Keep the reason server-side so a 401/403/404 can be
        // diagnosed without instrumenting the client.
        let host = headers
            .get(header::HOST)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        tracing::warn!(
            sha256 = %sha256_ext.chars().take(12).collect::<String>(),
            host,
            reason = %error,
            "app-content door rejected request"
        );
    }
    result
}

async fn serve_app_content(
    state: Arc<AppState>,
    sha256_ext: &str,
    headers: &HeaderMap,
) -> Result<Response, MediaError> {
    // The router only exists when the door is configured, but stay fail-closed.
    let app = state
        .config
        .app_content
        .as_ref()
        .ok_or(MediaError::NotFound)?;
    let sha256 = parse_sha256_html(sha256_ext)?;

    let tenant = bind_app_content_tenant(&state, headers).await?;

    // Header-only credential. There is deliberately no query-string form.
    let auth_event = super::media::extract_blossom_auth(headers)?;
    buzz_media::auth::verify_app_content_auth(&auth_event, sha256)?;

    let auth_tag = super::relay_members::extract_auth_tag_header(headers);
    super::relay_members::enforce_relay_membership(
        &state,
        tenant.community(),
        auth_event.pubkey.as_bytes(),
        auth_tag,
        Some(auth_event.created_at.as_secs()),
    )
    .await
    .map_err(|_| MediaError::RelayMembershipRequired)?;

    // Sidecar gate: tenant-scoped, and only canonical HTML is eligible.
    let sidecar = state
        .media_storage
        .get_sidecar(&tenant, sha256)
        .await
        .map_err(|_| MediaError::NotFound)?;
    if sidecar.mime_type != "text/html" || sidecar.ext != "html" {
        return Err(MediaError::NotFound);
    }
    if sidecar.size > app.max_bytes {
        return Err(MediaError::FileTooLarge {
            size: sidecar.size,
            max: app.max_bytes,
        });
    }

    let key = super::media::resolve_s3_key(&state.media_storage, &tenant, sha256_ext).await?;
    let total = state
        .media_storage
        .head_with_metadata(&key)
        .await?
        .ok_or(MediaError::NotFound)?
        .size;
    if total > app.max_bytes {
        return Err(MediaError::FileTooLarge {
            size: total,
            max: app.max_bytes,
        });
    }
    let stream = state.media_storage.get_stream(&key).await?;

    let mut builder = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_LENGTH, total.to_string());
    for (name, value) in app_content_headers() {
        builder = builder.header(name, value);
    }
    builder
        .body(axum::body::Body::from_stream(stream))
        .map_err(|_| MediaError::Internal)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_host_swaps_in_relay_port() {
        let relay = "ws://192.168.1.99:3000";
        assert_eq!(
            app_content_lookup_host("192.168.1.99:3001", relay),
            "192.168.1.99:3000"
        );
        assert_eq!(
            app_content_lookup_host("192.168.1.99", relay),
            "192.168.1.99:3000"
        );
        assert_eq!(
            app_content_lookup_host("Relay.Example:3001", relay),
            "Relay.Example:3000"
        );
    }

    #[test]
    fn lookup_host_without_relay_port_keeps_bare_hostname() {
        assert_eq!(
            app_content_lookup_host("relay.example:3001", "wss://relay.example"),
            "relay.example"
        );
    }

    #[test]
    fn lookup_host_handles_ipv6_and_empty() {
        assert_eq!(
            app_content_lookup_host("[::1]:3001", "ws://[::1]:3000"),
            "[::1]:3000"
        );
        assert_eq!(app_content_lookup_host("", "ws://h:3000"), "");
        assert_eq!(app_content_lookup_host("   ", "ws://h:3000"), "");
    }

    #[test]
    fn sha_path_must_be_hex_html() {
        let ok = format!("{}.html", "a".repeat(64));
        assert!(parse_sha256_html(&ok).is_ok());
        assert!(parse_sha256_html(&"a".repeat(64)).is_err());
        assert!(parse_sha256_html(&format!("{}.htm", "a".repeat(64))).is_err());
        assert!(parse_sha256_html(&format!("{}.html", "A".repeat(64))).is_err());
        assert!(parse_sha256_html(&format!("{}.html", "a".repeat(63))).is_err());
        assert!(parse_sha256_html("../x.html").is_err());
    }

    #[test]
    fn headers_pin_the_sandbox_contract() {
        let headers = app_content_headers();
        let get = |name: &str| {
            headers
                .iter()
                .find(|(n, _)| n.as_str() == name)
                .map(|(_, v)| *v)
                .unwrap_or("")
        };
        assert_eq!(get("content-type"), "text/html; charset=utf-8");
        assert_eq!(get("x-content-type-options"), "nosniff");
        assert_eq!(get("referrer-policy"), "no-referrer");
        assert_eq!(get("cache-control"), "private, no-store");
        let csp = get("content-security-policy");
        for directive in [
            "sandbox allow-scripts",
            "default-src 'none'",
            "connect-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "webrtc 'block'",
        ] {
            assert!(
                csp.contains(directive),
                "CSP must contain `{directive}`: {csp}"
            );
        }
        assert!(
            !csp.contains("allow-same-origin"),
            "allow-same-origin would give the app the relay origin"
        );
    }
}
