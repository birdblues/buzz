# Sandboxed HTML apps (fork feature)

Agents can attach a self-contained HTML file to a message and Buzz clients run
it as an **app** — a static preview card in the timeline, and on **Run** the
page executes inside a sandbox in the right-hand auxiliary drawer (desktop) or
a full-screen WebView (mobile). Upstream Buzz has no such surface and treats
HTML as an inert download everywhere; this fork keeps that behaviour on
`/media/*` and adds a second, gated door.

## Threat model in one line

The boundary is the **rendering layer, not the uploader**. Even agent-only
uploads can carry hostile script via indirect prompt injection, so every app —
whoever posted it — runs with an opaque origin, no network, and no way to
navigate anywhere.

Three independent layers; any one failing leaves the other two:

| Layer | Where | What it guarantees |
|---|---|---|
| Response CSP `sandbox allow-scripts; default-src 'none'; connect-src 'none'; webrtc 'block'; …` | relay app door **and** re-stamped by the desktop proxy | opaque origin, no fetch/XHR/WS/beacon, no forms, no plugins. **WebKit ignores `webrtc 'block'`** — see the subframe script below |
| Subframe script | desktop `sandbox_frame_hardening.rs` (`initialization_script_for_all_frames`) | in every non-main frame, `RTCPeerConnection` & co. are undefined and `sendBeacon` returns false before app code runs; properties are non-configurable. Observed before the fix: ICE gathering reached a public STUN server from inside the sandbox |
| Embedder sandbox | desktop `<iframe sandbox="allow-scripts">`; mobile `NavigationDelegate` | survives in-frame navigation; no top navigation, popups, downloads, forms |
| Navigation lock | desktop `navigation_policy.rs` (`WebviewWindowBuilder::on_navigation`), parent CSP `frame-src buzz-media:`; mobile: every request after the first is `prevent` | a frame cannot carry data out by navigating itself to an external URL |

Tokens never appear in a URL. The app door authenticates by
`Authorization` header only, with a **blob-scoped** kind:24242 event (`x`
tag = the blob hash, `t=get`, ≤10 min, **no `server` tag**). A leaked URL
opens nothing; a leaked token opens one blob briefly.

## Relay

- Config: `BUZZ_APP_CONTENT_BIND_ADDR` + `BUZZ_APP_CONTENT_URL` (both or
  neither), optional `BUZZ_APP_CONTENT_MAX_BYTES` (default 8 MiB). See
  `.env.example`.
- A third TCP listener with a one-route router: `GET /app/{sha256}.html`
  (`crates/buzz-relay/src/api/app_content.rs`). Everything else is 404.
- Community binding: the request `Host` keeps its hostname and takes the
  relay's port (`192.168.1.99:3001` → lookup `192.168.1.99:3000`). "Same
  host, different port" is the only supported layout.
- Verifier: `buzz_media::auth::verify_app_content_auth` — rejects any
  `server` tag (403), requires matching `x`, caps lifetime.
- Advertised in NIP-11 as `app_content_url`. Clients that don't see it keep
  HTML as a download card.
- `/media/{sha}.html` is unchanged: `Content-Disposition: attachment`,
  `nosniff`, `CSP: default-src 'none'`. Pinned by
  `crates/buzz-media/src/validation.rs` and `e2e_media_extended.rs`.

## CLI

```bash
buzz messages send --channel <UUID> --content "…" \
  --file diagram.html --preview-light light.png --preview-dark dark.png
```

- `text/html` is accepted (magic-byte sniff: the file must start with
  `<!DOCTYPE html` or `<html`; a UTF-8 BOM defeats detection).
- HTML goes to `PUT /upload` only (the legacy `/media/upload` is media-only).
- The body gets a `[filename](url)` link (not `![image]`), the imeta tag gets
  `filename`, and — when previews are given — fork-local `preview-light` /
  `preview-dark` keys with the uploaded PNG URLs.

## Desktop

- `buzz-media://localhost/app/{sha}.html` is the iframe `src`; the custom
  protocol handler (`desktop/src-tauri/src/app_content.rs`) mints the token,
  fetches from the app origin with the no-redirect client, and **stamps the
  sandbox headers itself** — a LAN MITM cannot strip them.
- The app origin is discovered from NIP-11 natively and accepted only if it
  is a bare http(s) origin on the relay's hostname and a distinct port.
- The main window is created in `setup()` from `tauri.conf.json`
  (`create: false`) so `on_navigation` and the all-frames hardening script
  can be attached. The script skips the main frame (huddles use WebRTC there).
- Timeline: `resolveAppCard` (`markdownFileCard.ts`) → `AppCard` (preview +
  Run + Download). Run opens the app as an idle auxiliary panel
  (`features/apps`), i.e. the same drawer as threads, above an open thread.
  Closing the drawer unmounts the iframe.

## Mobile — checklist for the Intel-Mac session (real iPad)

Do not build or run the Flutter app on the M-series dev Mac; verify on a
physical iPad from the Intel Mac session.

**Assignment (2026-09-05):** items 1–8 below are the Intel-Mac session's work
— `mobile/` has no changes on this branch yet, so implementation comes first.
Test fixtures are already in `#test`: an archify sequence app with light/dark
previews, `sandbox-probe.html`, and a listener-targeted `sandbox-net-probe.html`.
Relay: `ws://192.168.1.99:3000`, app door `http://192.168.1.99:3001`.

1. `pubspec.yaml`: add `webview_flutter`. `ios/Runner/Info.plist`: add
   `NSAppTransportSecurity` → `NSAllowsLocalNetworking = true` (WKWebView
   obeys ATS; the Dart `http` client does not).
2. `lib/features/channels/message_media.dart`: parse imeta `x`,
   `preview-light`, `preview-dark`; add `MessageMediaKind.app` for
   `m == text/html && x`.
3. `lib/features/channels/message_content.dart` `_buildLink`: when the link's
   imeta resolves to an app → `AppCard` (preview chosen by
   `Theme.of(context).brightness`, Run, Download). Widget test.
4. `lib/shared/relay/relay_info.dart`: read NIP-11 `app_content_url`, same
   validation as desktop (bare origin, relay hostname, distinct port).
5. `lib/shared/relay/media_auth.dart`: `signAppContentAuth(sha256)` — `t=get`,
   `x`, `expiration` ≤ 600 s, **no `server` tag**. Leave the existing
   server-scoped signer untouched.
6. `AppWebViewPage` (pushed with `CupertinoPageRoute` — slides in from the
   right): `loadRequest(uri, headers: {'Authorization': …})`,
   `javaScriptMode: unrestricted`, **no JavaScript channels**,
   `NavigationDelegate.onNavigationRequest` returns `prevent` for anything
   but the initial URL, top bar with sender + "sandbox" + close.
7. Bundle Pretendard (same release as the desktop/skill assets) as a Flutter
   font family for future SVG previews.
7b. **WebKit ignores the CSP `webrtc 'block'` directive** — on the desktop
   the probe reached a public STUN server over UDP from inside the sandbox
   until a user script removed WebRTC. Add a document-start `WKUserScript`
   (webview_flutter: `runJavaScript` is too late; use the platform
   `WKUserScript` injection) that defines `RTCPeerConnection`,
   `webkitRTCPeerConnection`, `RTCDataChannel` & co. as non-configurable
   `undefined` and makes `navigator.sendBeacon` return `false`. Mirror
   `desktop/src-tauri/src/sandbox_frame_hardening.rs`; the mobile page is the
   top frame, so apply it unconditionally (no `window.top === window` guard).
   Probe row 9 (`RTCPeerConnection + ICE gather`) is the check.
8. On the iPad: (a) an archify app renders and is interactive; (b) the probe
   page below shows every escape as blocked; (c) link taps, `window.open`,
   form submits do nothing; (d) no ATS error/blank page over
   `http://<lan-ip>:3001`; (e) reopening after 10 minutes mints a fresh token.

## Sandbox probe

Upload `docs/sandbox-probe.html` as an app and Run it. Every row must read
**blocked**; if any reads *allowed*, do not ship.

## Fonts

Pretendard (OFL) is the one fixed face:

- Container image (`~/.hermes/docker/Dockerfile.buzz-agent`): OTFs +
  fontconfig aliases (`sans-serif`, `:lang=ko`) for headless-Chrome PNGs.
- archify skill `scripts/embed-fonts.mjs`: subsets the woff2 to the
  characters used and inlines it into the HTML (the sandbox blocks font
  downloads).
- Mobile: bundle the same release.
