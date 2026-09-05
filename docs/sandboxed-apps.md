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
| Response CSP `sandbox allow-scripts; default-src 'none'; connect-src 'none'; webrtc 'block'; …` | relay app door, re-stamped by the desktop proxy, and stamped as a `<meta>` policy into the document by the mobile client (`sandbox` is not expressible in `<meta>`; the opaque origin there comes from loading the document as `about:blank`) | opaque origin, no fetch/XHR/WS/beacon, no forms, no plugins. Neither client trusts the relay's headers to survive the LAN. **WebKit ignores `webrtc 'block'`** — see the subframe script below |
| Subframe script | desktop `sandbox_frame_hardening.rs` (`initialization_script_for_all_frames`); mobile `ios/Runner/SandboxWebViewHardening.swift` (document-start `WKUserScript`, all frames of the sandbox web view; the app refuses to run when the hook is not installed) | `RTCPeerConnection` & co., `WebTransport`, `webkitGetUserMedia` are undefined and `sendBeacon` returns false before app code runs; properties are non-configurable. Observed before the fix: ICE gathering reached a public STUN server from inside the sandbox |
| Embedder sandbox | desktop `<iframe sandbox="allow-scripts">`; mobile `NavigationDelegate` | survives in-frame navigation; no top navigation, popups, downloads, forms |
| Navigation lock | desktop `navigation_policy.rs` (`WebviewWindowBuilder::on_navigation`), parent CSP `frame-src buzz-media:`; mobile: exactly one navigation is allowed — the first main-frame load of the `about:blank` document — every later request, subframe, reload or `window.open` is `prevent` | a frame cannot carry data out by navigating itself to an external URL |

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

## Intel-Mac session — desktop test (do this before the mobile work)

Requested 2026-09-05 by the owner. Run Buzz Desktop from this branch on the
Intel Mac against the mac-mini relay and repeat the desktop verification.

1. `git pull` `feat/sandbox-webapp` (≥ 2460c474). `just desktop-install`,
   then `BUZZ_RELAY_URL=ws://192.168.1.99:3000 just desktop-standalone`
   (this is `tauri dev` with the `xyz.block.buzz.app.dev` identifier). Sign in
   with the Intel Mac's existing Buzz identity and open `#test`.
2. **Cards.** `cache-miss-sequence.html` and `buzz-relay-sequence.html` show a
   preview that matches the current theme; switch the theme in Settings and
   the preview swaps (light ↔ dark PNG). `sandbox-probe.html` and
   `sandbox-net-probe.html` show plain app cards (no preview attached).
3. **Run.** Run `buzz-relay-sequence.html` → the auxiliary drawer opens on the
   right with the sender + "sandbox" bar; the diagram is interactive
   (guided views, Present, Export); closing the drawer unmounts it. Download
   saves the HTML.
4. **Probe.** Run `sandbox-probe.html` → the banner reads **all 19 blocked**.
   Any ALLOWED row is a fail; paste the row.
5. **Listener probe.** Run `sandbox-net-probe.html`; the page shows a run id
   `t=…`. Listeners are up on the mac mini (`192.168.1.99:3999` http,
   `:3478` udp); the mac-mini session checks its logs for that run id —
   zero hits is the pass. Report the run id.
6. **Navigation.** From an app, links / `window.open` / form submits do
   nothing (probe rows 14–19); the desktop log prints
   `buzz-desktop: blocked navigation to …` for external attempts.

Report back by cross-session message to the mac-mini session (it shows as
"buzz 웹앱 구현" in your ListAgents) with one line per item 2–6 and the run id
from item 5. Then continue with the mobile checklist below.

## Mobile — code on the mac mini, build and verify on the Intel Mac (real iPad)

The M-series dev Mac has no Flutter toolchain or pub cache, so the mobile
code is written there and **analyzed, built, installed and verified from the
Intel-Mac session** on a physical iPad. Test fixtures are in `#test`: an
archify sequence app with light/dark previews, `sandbox-probe.html`, and a
listener-targeted `sandbox-net-probe.html`. Relay: `ws://192.168.1.99:3000`,
app door `http://192.168.1.99:3001`.

### Implementation (2026-09-05)

| Piece | Where |
|---|---|
| imeta `x`, `preview-light`, `preview-dark`; `MessageMediaKind.app` (= `text/html` + a lowercase 64-hex `x`) | `mobile/lib/features/channels/message_media.dart` |
| App card: theme-matched preview (`Theme.of(context).brightness`), Run, Download, sender in the chrome. Never in clamped previews (`maxLines`) | `mobile/lib/features/channels/message_content/app_card.dart`, wired from `message_content.dart` (`_buildAppCard`, for both `[…]()` and `![…]()` syntax) |
| NIP-11 `app_content_url` discovery with the desktop's validation (bare origin, relay hostname, distinct origin); re-asked on every reconnect; remembered per relay so a community switch cannot reuse another relay's door | `mobile/lib/shared/relay/relay_info.dart` — `appContentUrlProvider`, null = HTML stays a link |
| Blob-scoped token: `t=get`, `x`, `expiration = now + 300 s`, **no `server` tag**, minted fresh on every Run (never memoized) | `mobile/lib/shared/relay/media_auth.dart` `signAppContentAuth` |
| Document fetch **in Dart**, the way the desktop proxy does it: `Authorization` header (never a URL token), **no redirects** (a 3xx fails — a custom header must never follow one), `text/html` only, ≤ 8 MiB. The WebView itself never touches the network, so a LAN MITM cannot strip the policy and no ATS exception is needed | `mobile/lib/shared/relay/app_content.dart` (`fetchAppDocument`) |
| CSP stamped by the client: the relay/desktop policy minus `sandbox`, inserted as the first element (after a leading doctype) so no script can precede it; the document is then loaded with `loadHtmlString` and no base URL → `about:blank`, opaque origin, no storage | `app_content.dart` (`stampSandboxCsp`, `appSandboxCsp`) |
| Sandbox page: `CupertinoPageRoute` (slides in from the right, like the desktop drawer; stacks inside the pane in the wide shell), JS unrestricted, **no JavaScript channels**, `onNavigationRequest` allows exactly the first main-frame `about:blank` load and prevents everything else, generation-fenced retry, error states per relay status | `mobile/lib/features/channels/app_webview_page.dart` (`decideAppNavigation`) |
| Fail closed on the native hook: before running, Dart asks `buzz/sandbox_webview` → `isHardeningInstalled`; false (hook failed, or a platform without one — Android today) shows an error instead of the app | `app_webview_page.dart` (`sandboxHardeningProbeProvider`), `AppDelegate.swift` |
| WebRTC + `sendBeacon` removal. `webview_flutter` has no user-script API, so `WKWebView.loadHTMLString(_:baseURL:)` — the sandbox page's only entry point — is swizzled to register the document-start script (all frames) on that web view before the load. `WKUserContentController` is shared by reference with the live page; `webview_flutter` adds its own channel scripts the same way after creation | `mobile/ios/Runner/SandboxWebViewHardening.swift`, installed from `AppDelegate` |
| Pretendard 1.3.9 (OFL) as a Flutter font family | `mobile/pubspec.yaml`, `mobile/assets/fonts/Pretendard-*.otf` |
| NIP-11 allowlist widened with `app_content_url`, `admin_api`, `gif`. The push descriptor parser rejects any unknown top-level NIP-11 field, so advertising the door would otherwise have silently disabled push on mobile | `mobile/lib/shared/push/dev_push_lease.dart` |

### Intel-Mac session: build and verify

1. `flutter pub get` → `flutter analyze` → `dart format --set-exit-if-changed` →
   `flutter test`. Send the `pubspec.lock` / `Podfile.lock` hunks back to the
   mac-mini session (or commit them) — it cannot resolve packages.
2. Release build → `xcrun devicectl device install app` (`Buzz.app`) → launch
   `dev.birdblues.buzz.mobile`.
3. The built `Info.plist` needs **no** `NSAppTransportSecurity` entry: the
   document is fetched by the Dart `http` client (not subject to ATS) and the
   WebView only ever loads `about:blank`. A blank page therefore points at
   the fetch (check the relay's door log) or at the stamped policy, not ATS.
4. On the iPad: (a) an archify app renders and is interactive; (b) the probe
   page below shows every escape as blocked — row 9 (`RTCPeerConnection`) is
   the native script, and row 20 must read `origin=null href=about:blank`;
   (c) link taps, `window.open`, form submits do nothing;
   (d) no blank page; (e) reopening after 10 minutes mints a fresh token;
   (f) the listener-targeted net probe with the `3999`/`3478` listeners up on
   the mac mini reports zero hits (send the run id and time); (g) light/dark
   preview follows the app theme; (h) a forum post card shows the inert
   pill, not a cropped card — needs a forum channel with an HTML attachment
   (none existed on 2026-09-05). The compose-note preview cannot be reached:
   `lib/features/pulse/` is not referenced from the rest of the mobile app,
   so that call site is covered by widget tests only.

## Sandbox probe

Upload `docs/sandbox-probe.html` as an app and Run it. Every row must read
**blocked**; if any reads *allowed*, do not ship. Row 20 also prints the
document's `location.href` and origin (`null` on both clients); rows 4–6
(fetch) are the proof that the policy is enforced, rows 12–13 that the origin
is opaque, row 9 that the native WebRTC removal ran.

## Fonts

Pretendard (OFL) is the one fixed face:

- Container image (`~/.hermes/docker/Dockerfile.buzz-agent`): OTFs +
  fontconfig aliases (`sans-serif`, `:lang=ko`) for headless-Chrome PNGs.
- archify skill `scripts/embed-fonts.mjs`: subsets the woff2 to the
  characters used and inlines it into the HTML (the sandbox blocks font
  downloads).
- Mobile: bundled as the `Pretendard` font family (same 1.3.9 release).
