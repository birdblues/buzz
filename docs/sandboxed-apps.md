# Sandboxed HTML apps (fork feature)

Agents can attach a self-contained HTML file to a message and Buzz clients run
it as an **app** — a static preview card in the timeline, and on **Run** the
page executes inside a sandbox in the right-hand auxiliary drawer (desktop) or
a full-screen WebView (mobile). Upstream Buzz has no such surface and treats
HTML as an inert download everywhere; this fork keeps that behaviour on
`/media/*` and adds a second, gated door.

> **Fork note (2026-09-06).** The desktop (Tauri) side described below —
> `AppCard`, the auxiliary drawer, `app_content.rs`,
> `sandbox_frame_hardening.rs`, `navigation_policy.rs`, the
> `buzz-media://…/app/` proxy branch and the Intel-Mac desktop test — was
> **removed from `dev`**: the fork now keeps `desktop/` byte-identical to
> upstream `block/buzz` main, and the Mac mini host runs upstream desktop
> unmodified. That code is preserved at tag `fork-desktop-2026-09-06`. App
> cards on a desktop are provided by the Flutter client app (the macOS
> target of `mobile/`), which shares the mobile implementation. The relay
> door and the CLI attachment path are unchanged.

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
| App card: theme-matched preview (`Theme.of(context).brightness`), one tap surface (Run, or Resume when the app is already running — a green dot on the preview says so), sender in the chrome. Never in clamped previews (`maxLines`) | `mobile/lib/features/channels/message_content/app_card.dart`, wired from `message_content.dart` (`_buildAppCard`, for both `[…]()` and `![…]()` syntax) |
| NIP-11 `app_content_url` discovery with the desktop's validation (bare origin, relay hostname, distinct origin); re-asked on every reconnect; remembered per relay so a community switch cannot reuse another relay's door | `mobile/lib/shared/relay/relay_info.dart` — `appContentUrlProvider`, null = HTML stays a link |
| Blob-scoped token: `t=get`, `x`, `expiration = now + 300 s`, **no `server` tag**, minted fresh on every Run (never memoized) | `mobile/lib/shared/relay/media_auth.dart` `signAppContentAuth` |
| Document fetch **in Dart**, the way the desktop proxy does it: `Authorization` header (never a URL token), **no redirects** (a 3xx fails — a custom header must never follow one), `text/html` only, ≤ 8 MiB. The WebView itself never touches the network, so a LAN MITM cannot strip the policy and no ATS exception is needed | `mobile/lib/shared/relay/app_content.dart` (`fetchAppDocument`) |
| CSP stamped by the client: the relay/desktop policy minus `sandbox`, inserted as the first element (after a leading doctype) so no script can precede it; the document is then loaded with `loadHtmlString` and no base URL → `about:blank`, opaque origin, no storage | `app_content.dart` (`stampSandboxCsp`, `appSandboxCsp`) |
| Sandbox page: `CupertinoPageRoute` pushed on the **root** navigator (slides in from the right, like the desktop drawer, and takes the whole screen in the wide shell too — a push inside a pane's nested navigator aborts on the compose bar's overlay portal during the pane's layout pass, which left Run silently dead in forum threads), JS unrestricted, **one JavaScript channel at most** (the selection bridge below, only when opened from a message), `onNavigationRequest` allows exactly the first main-frame `about:blank` load and prevents everything else, generation-fenced retry, error states per relay status. The WebView is owned by the session registry, not the page — see *Sessions* below | `mobile/lib/features/channels/sandbox_session.dart` (`decideAppNavigation`, `SandboxSessionsNotifier`), `app_webview_page.dart` |
| Fail closed on the native hook: before running, Dart asks `buzz/sandbox_webview` → `isHardeningInstalled`; false (hook failed, or a platform without one — Android today) shows an error instead of the app | `sandbox_session.dart` (`sandboxHardeningProbeProvider`), `AppDelegate.swift` |
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
   posted as kind 45001 (`buzz messages send --kind 45001 …`; the CLI sends
   kind 9 by default whatever the channel type). Mobile lists no forum
   channels (`channels_page/body.dart` sections are stream and DM only, an
   upstream gap), so open the forum by deep link
   (`buzz://channel/<id>` in Safari) or from a search hit. The post list
   clips only the prose of a post, so the trailing attachment line stays
   renderable (`features/forum/forum_preview.dart`); opening the post shows
   the app card, and Run works from the thread on both layouts. Desktop
   forums host the app drawer through `ForumChannelContent`, which replaces
   `ChannelPane` for forum channels. The compose-note preview cannot be reached:
   `lib/features/pulse/` is not referenced from the rest of the mobile app,
   so that call site is covered by widget tests only.

## Selection bridge (2026-09-07, Flutter clients only)

The one deliberate app→host path. A reader picks a node, edge or path in an
app (the causal-graph template's "ask the agent" button) and the phrase the
app composed lands in the composer of the message the app was shared in —
**prefilled, never sent.** The user edits and sends; the agent that built the
app reads `[인과그래프 #1a2b3c4d] 간선 e4 …` and resolves the app from the
tag. Two things flow back into the app, both host-initiated and both
narrow (*New versions* below): the readiness probe and the view state of
the version being replaced. No agent text is pushed into an app.

| Piece | Where |
|---|---|
| App side: `window.buzzBridge.select({ kind, ref, text })` in the agent skill's shared runtime calls the host-injected `window.__buzzHost.select` when present, else shows a copy box. Apps never touch `parent.postMessage` or `webkit.messageHandlers` themselves | `~/.hermes/skills/software-development/buzz-sandbox-webapp` (`scripts/build-app.mjs`, `references/bridge.md`) |
| Native shim: a second document-start `WKUserScript` (main frame only) defines `window.__buzzHost` as a **getter** that resolves to `{ select }` only while `window.buzzHost` — the `webview_flutter` channel object — exists, so an app opened with no composer in scope sees no host. `select` copies three string fields explicitly and posts **one JSON string**; it returns nothing useful | `mobile/ios/Runner/SandboxWebViewHardening.swift` (`bridgeScript`), `mobile/macos/Runner/SandboxWebViewHardening.swift` (byte-identical) |
| Channel: `addJavaScriptChannel('buzzHost')` **before** `loadHtmlString`, and only when the page was given a `SandboxBridgeTarget` (channel id, message id, thread head) by the message row that opened it. The target is host knowledge; the payload cannot name a channel, message or thread. Honoured only while a page shows the app — a backed-out app cannot reach the composer | `sandbox_session.dart` (`_onBridgeMessage`), `message_content.dart` (`appBridge`), wired from the channel bubble, the thread row and both forum rows |
| Validation, re-applied whatever the app promised: JSON object ≤ 16 KiB; `kind` ∈ {node, edge, path, layout}; `ref` single line ≤ 200 chars; `text` ≤ 2048 chars (`layout`: ≤ 8192, never truncated — it carries the moved nodes as fenced JSON for the agent to pin), control characters stripped, non-empty; one message per 500 ms, extras dropped; generation-fenced so a stale page cannot write | `mobile/lib/features/channels/sandbox_bridge.dart` (`parseSandboxSelect`, `SandboxBridgeRateLimiter`) |
| App tag: the host stamps the first 8 characters of the app message's event id into the text's leading `[…]` (`[인과그래프] …` → `[인과그래프 #1a2b3c4d] …`), or prefixes `[앱 #…]` when there is none | `sandbox_bridge.dart` (`sandboxBridgePrefillText`) |
| Delivery: the text is appended to that composer's persisted draft (`composeDraftsProvider`, so a thread composer that is not open yet picks it up when it mounts) and published through `composerPrefillProvider`; a mounted `ComposeBar` with the matching draft key shows the merged draft, expands and takes focus. On a compact layout the sandbox page pops so the reader lands on the composer; the app stays alive behind it (*Sessions*), so returning to the card shows the selection still highlighted. On a wide layout the composer is already beside the app (*Beside the thread*) and nothing pops | `sandbox_bridge.dart` (`ComposerPrefillNotifier`), `compose_bar/draft_lifecycle.dart` (`_listenForComposerPrefill`) |
| Draft key = the message's composer: `<channelId>` for a channel bubble or a forum post/reply (forum composers are keyed by channel), `<channelId>:<threadHeadId>` for a row inside a thread — and `<channelId>:<threadRootId>` for a channel bubble opened beside its thread on a wide window, so the phrase lands in the thread composer the reader can see, not the covered channel composer | `SandboxBridgeTarget.draftKey`, `sandbox_open.dart` |
| Not a bridge: search hits, profile sheets and previews render `MessageContent` without `appBridge`, so Run from there registers no channel and the app falls back to its copy box | `message_content.dart` |

### Intel-Mac session: verify the bridge (iPad and the macOS client)

1. Build the causal-graph sample with the skill (`build-app.mjs … --graph`)
   or reuse the posted `policy-rate-50bp-causal.html`; post it in a channel.
   Run → tap an edge → "에이전트에게 묻기". Expected: the app closes, the
   channel composer opens focused with `[인과그래프 #<8 hex>] 간선 … — 이 관계를
   더 설명해줘`, the tag matching the message's event id, and **nothing was
   sent** (no new message in the channel, no typing indicator beyond the
   usual). Repeat from a thread reply (composer = that thread) and from a
   forum post (composer = the forum channel).
2. Type before tapping: an existing draft must survive, with the phrase
   appended on a new line.
3. ~~Run the same app from a search hit or a profile sheet~~ — **not
   reachable today** (Intel-Mac finding, 2026-09-07): search hits, profile
   sheets and inbox rows render `MessageContent` with `maxLines`, which
   disables app cards, and the only card surface without a bridge
   (`pulse/note_card.dart`) has no route into it. The no-bridge fallback is
   fail-closed by construction and covered by widget tests only. Re-add
   this step if a card surface without `appBridge` ever becomes reachable.
4. Upload `docs/sandbox-probe.html` again (an owner call — it posts a real
   message): rows 1–20 unchanged (all blocked, row 20
   `origin=null href=about:blank`); the new row 21 reads *present* when
   opened from a message. Repeat the Run three or four times: row 21 must
   read *present* every time (the channel is registered and awaited before
   the load, so an intermittent *absent* would be a defect).
5. Paste a hostile payload via the probe's console-free path: edit a copy of
   the sample app so `buzzBridge.select` is called ten times in a loop with a
   5 KB `text` and `kind: 'window'` — the composer must receive at most one
   line per 500 ms and nothing for the bad kind or the oversized text.

## Beside the thread — the wide layout's app split (2026-09-10, Flutter clients only)

On an iPad or the macOS client (`LayoutMode.wide`) Run no longer pushes a
full-screen page that shoves the sidebar, the channel and the thread aside.
The app opens **beside the thread of the message it was shared in**: the
thread keeps the left 40 % of the content area and the app takes the right
60 %, sliding in from the right over the sidebar (folded for the duration,
the preference untouched) and the channel. The reader instructs the agent
from the thread composer and watches the app change in place (*New
versions*). Phones keep the full-screen page.

| Piece | Where |
|---|---|
| Opening: `openSandboxApp` picks the path. Compact → root-navigator push, as before (a push inside a pane's nested navigator aborts on the compose bar's overlay portal — commit 27eefd003). Wide → the message's thread is opened first when the auxiliary pane does not show it (`onOpenAppThread` from the channel bubble), then the app pane is mounted on the next frame. Forum threads count as the thread being shown | `mobile/lib/features/channels/sandbox_open.dart`, `message_content.dart` (`onOpenAppThread`) |
| Layout: `WideShellState.appPane` (`WideAppPane`). The auxiliary drawer keeps its stack slot and only its `Positioned` parent data changes (`right: 0` → `left: 0`), so the thread's navigator, composer draft and scroll survive — no `GlobalKey`, no remount. The app column is appended after it as a fixed-width `SlideTransition`; a hidden app stays mounted while it slides out (`retainedApp`). Widths are measured on the stack's own width, so the two columns partition whatever the folding sidebar has released and never overlap | `wide_home_shell.dart`, `wide_home_shell/app_pane.dart`, `layout_mode.dart` (`kWideAppSplitThreadFraction`, `wideAppSplitThreadWidthFor`) |
| The covered channel takes no pointer, semantics or focus (`IgnorePointer` / `ExcludeSemantics` / `ExcludeFocus`, always present, flags toggled); focus moves to the shell's own node when the split opens so Escape still reaches the shell. Focus mode is unavailable while split | `wide_home_shell.dart`, `aux_pane.dart` (`focusEnabled`) |
| Bound to the thread: closing the thread hides the app; selecting another channel, Inbox or Search hides it; Escape / system back hide the app **first and alone** (the thread stays); the pane's Hide keeps the session running (green dot), its Close ends it. One `WebViewWidget` per session: the pane and the full-screen page never show the same app at once | `wide_shell_provider.dart` (`openAppPane`, `hideAppPane`, `closeAux`) |
| Geometry: 1376 (iPad Pro 13") → 550 / 826; 1194 (iPad 11") → 478 / 716; 1280 (macOS default) → 512 / 768; 1000 (macOS minimum) → 400 / 600. Below 700 the app draws its own phone layout | `wide_home_shell_test.dart` (`_appSplitTests`) |

## New versions — an edit swaps the app in place (2026-09-10, Flutter clients only)

An agent republishes an app by **editing the message that carries it**
(`buzz messages edit --event <id> --content … --file app.html --preview-light …
--preview-dark …`, kind 40003 with a fresh `text/html` imeta). The relay's
imeta validation is kind-agnostic and its edit gate is authorship (the
author must still be a member, or the channel open); the timeline folds the
edit by replacing the original's tags wholesale, so the card's blob changes
and the message keeps its id. Nothing new on the relay. Edits are
deliberately absent from push notifications, search results (which render
original tags — a card opened from search may be an old version) and forum
queries (forum apps are republished as new replies instead).

| Piece | Where |
|---|---|
| CLI: `messages edit` gained `--file` / `--preview-*`; it restates the target's `p` / `mention` tags (an edit's tags replace the original's, so mention highlights would otherwise vanish) and appends the new attachment line to the body given with `--content`, which stays mandatory | `crates/buzz-cli` (`cmd_edit_message`, `upload_attachments`), `crates/buzz-sdk` (`build_edit_with_media`) |
| Following: a session keyed to a message (`msg:<id>` — only when the message carries exactly one HTML attachment; otherwise `sha:<blob>` and no swap) subscribes to `appRevisionProvider`: the channel's live events merged with a one-shot fetch of the message's edits and deletions (deep links, the legacy history fallback and thread history query content kinds only). The winner is chosen by the timeline's own rule (`latestEditFor`: strictly newer `createdAt`, first seen on a tie, deletions honoured); a winner without an app means no revision — the session never climbs back to an older blob. Thread history now asks for `include_aux` so a reply carrying an app shows its edited blob on a cold open. Subscribed through the container, not the notifier's `ref`, because Riverpod pauses a provider's own listeners while nothing watches it — exactly the backed-out app that must still follow | `sandbox_revision.dart`, `timeline_message.dart` (`latestEditFor`, `deletedEventIds`), `thread_replies_provider.dart`, `sandbox_session.dart` (`_followRevisions`) |
| Swap, in this order: fetch the new HTML (a relay failure leaves the old document untouched and shows a strip); read the running app's view state through one host-owned script that stringifies and caps inside the page (the page can redefine its bridge object, so the host caps and validates again — `sandbox_app_state.dart`, 64 KiB, closed schema); navigate the **same** controller with a one-shot reload token (the navigation lock is back on after that single `about:blank` load; the `buzzHost` channel lives on the controller and is never registered twice); wait for page-finished, then poll `__APP_READY__ && !__APP_ERROR__` (≤ 10 s); hand the state over as base64 of canonical JSON (`jsonEncode` does not escape U+2028/2029, which end a JS string literal) — the runtime keeps it until the template registers its import handler; only then mark the session ready. A version that reports a boot error or never becomes ready is rolled back by fetching the previous blob again and loading it with the same state. Revisions arriving mid-swap coalesce to the newest. Runs whether or not a page is attached | `sandbox_session.dart` (`_swap`, `_loadInto`, `_exportState`, `_decide`), `sandbox_app_state.dart` |
| Shown: the page subtitle and the app pane header say "Updated HH:MM" from the standing edit's `created_at` (data, not a session counter — an app opened after it was edited must say so too); a spinner while updating; a strip with Try again when a version could not be shown | `app_sandbox_body.dart`, `app_webview_page.dart`, `app_pane.dart` |
| App side: `window.buzzBridge.onExport(fn)` / `onImport(fn)` / `_importB64`, `sanitizeState`, and a `layout` selection kind whose text is fenced JSON of the nodes the reader moved, for the agent to pin into `data.json`; the build refuses a graph template without both hooks. The skill's `scripts/publish.mjs` keeps a receipt (`published.json`) so the agent edits the right message | `~/.hermes/skills/software-development/buzz-sandbox-webapp` (`scripts/build-app.mjs`, `scripts/publish.mjs`, `references/bridge.md`) |
| Known: a person editing an app-bearing message from the mobile edit sheet drops its imeta (the sheet sends emoji tags only), so the card disappears — unreachable for agent-owned messages (the relay's edit gate is authorship), documented rather than fixed here | `message_actions.dart` |

### Intel-Mac session: verify the split and in-place updates (iPad and the macOS client)

1. **Split.** In a thread with an app card (built with skill 1.11.0), tap Run on the macOS client at its default window and on an iPad: the sidebar folds, the thread docks left at 40 %, the app slides in on the right at 60 %; the thread composer still works; the aux focus button is disabled; Escape (Mac) hides the app only, the thread stays and the sidebar comes back; Hide keeps the card's dot lit; Close ends it. Repeat from a channel bubble whose thread is not open: the thread opens first, then the app. Rotate the iPad both ways with the split open.
2. **Selection.** "에이전트에게 묻기" from the split lands in the thread composer beside the app with the `#id8` tag; the app does not close.
3. **In place.** Send `@<agent> 노드 하나 추가해` from that composer. When the agent's edit lands: the card's preview changes, the app updates without closing, camera, view, time and selection are kept, the header reads "Updated HH:MM", the thread has the agent's one-line log, and **no new card appeared**. Note the round-trip time.
4. **Moved nodes.** Drag two nodes (one inside a group, then collapse the group), tap 배치 반영: the fenced JSON lands in the composer; send it; the next version keeps both where they were and the 배치 반영 button is gone (the positions became build coordinates).
5. **Cold start.** After an edit, open the card on a device that had never run the app (from the channel, from a deep link, and for an app that was posted as a reply): the newest version comes up.
6. **Phone.** Full screen as before; a selection pops to the composer; reopening after the agent's edit shows the new version with the state restored.
7. **Platform view.** With the split open: pinch/scroll inside the app, fold and unfold the sidebar preference, open the keyboard on the thread composer, click inside the app then press Escape (Mac) — the app must not float above the thread's header or composer, and Escape must still reach the shell.
8. Re-run the *Sessions* checklist: keys changed (`msg:` / `sha:`).

## Sessions — Back keeps the app, Close ends it (2026-09-07, Flutter clients only)

Owner decision. The page used to own the WebView, so leaving it restarted the
app: every selected path, collapsed group and slider position was lost, and the
Back and Close affordances meant the same thing. Now `sandboxSessionsProvider`
(`mobile/lib/features/channels/sandbox_session.dart`) owns one session per app
blob per message, and the page only attaches to it while on screen.

| Rule | Where |
|---|---|
| **Back** (the bar's back button, the swipe, Escape on macOS): the page detaches, the WebView keeps its document. The next open for the same key re-attaches the same `WebViewController`; `webview_flutter` hands the same native `WKWebView` to the new platform view, so script state survives | `app_webview_page.dart` (`useEffect` attach/detach), `SandboxSessionsNotifier.attach/detach` |
| **Close** (× in the bar): the session loads a script-free document over the app — the only navigation the delegate allows once the host marks the document `terminating` — and is dropped. Native release stays with the finalizer; the blank load is what stops the app's timers now | `SandboxSessionsNotifier.terminate`, `_blank`, `_decide` |
| Expiry: a backed-out session ends **24 h** after Back (`sandboxSessionTtl`) — a `Timer`, re-checked from `AppLifecycleListener.onResume` because iOS does not run Dart timers while suspended | `detach`, `_expireOverdue` |
| Cap: at most **3** backed-out sessions (`sandboxSessionBackgroundCap`); the one backed out of longest ago is ended when a fourth arrives | `_evictBeyondCap` |
| Content process killed by the OS (`webContentProcessTerminated`): a hidden app is dropped silently (its dot goes out); a shown one gets the error state with *Try again*, which loads a fresh document in the same session | `_load` (`onWebResourceError`), `retry` |
| A failed app is dropped when its page goes away — there is nothing to come back to | `detach` |
| Bridge: selections are honoured only while a page is attached; a hidden app's script cannot reach the composer | `_onBridgeMessage` |
| Card: one tap surface (whole card, key `app-card-run`), semantics label *Run …* / *Resume …, running*; green dot (`app-card-running`) at the preview's bottom-right, or on the app icon when there is no preview. The Run and Download buttons are gone (owner decision) | `message_content/app_card.dart` |
| Key: `<sha256>:<messageId>` — the same blob shared in two messages is two sessions with two bridge targets | `sandboxSessionKey` |

Tests: `test/features/channels/sandbox_session_test.dart` (registry rules,
against a fake `WebViewPlatform` in `fake_webview_platform.dart`),
`app_webview_page_session_test.dart` (Back keeps / Close ends / bridge pop /
retry, through the real page), `message_content_app_card_test.dart` (dot and
semantics). The 24 h and cap rules are unit-tested only.

### Intel-Mac session: verify sessions (macOS client, iPad, iPhone)

1. Open the causal graph, highlight a path, collapse a group, move the
   slider. Back. The card shows a green dot at the preview's bottom-right.
   Tap the card: the same state is still there (no reload, no spinner).
2. Close (×) from the page: the dot goes out; tapping the card loads from
   scratch.
3. "에이전트에게 묻기" → the composer is prefilled as before; go back to the
   card: dot on, and the selection is still highlighted when reopened.
4. Back out of four different apps in a row: the first card's dot goes out
   and reopening it starts fresh; the other three resume.
5. Rotate the device while an app is backed out, then reopen it: the graph
   fits the new size (the app's resize handler runs on re-attach).
6. Swipe-back on iPhone/iPad and Escape on macOS keep the app running, like
   the bar's back button.
7. Leave an app backed out, put the client in the background for a while,
   resume: still there (well under 24 h). The 24 h expiry itself is not
   verified on a device.

## Sandbox probe

Upload `docs/sandbox-probe.html` as an app and Run it. Every row must read
**blocked**; if any reads *allowed*, do not ship. Row 20 also prints the
document's `location.href` and origin (`null` on both clients); rows 4–6
(fetch) are the proof that the policy is enforced, rows 12–13 that the origin
is opaque, row 9 that the native WebRTC removal ran. Row 21 is informational
(like row 3): it names the selection-bridge surface when present.

## Fonts

Pretendard (OFL) is the one fixed face:

- Container image (`~/.hermes/docker/Dockerfile.buzz-agent`): OTFs +
  fontconfig aliases (`sans-serif`, `:lang=ko`) for headless-Chrome PNGs.
- archify skill `scripts/embed-fonts.mjs`: subsets the woff2 to the
  characters used and inlines it into the HTML (the sandbox blocks font
  downloads).
- Mobile: bundled as the `Pretendard` font family (same 1.3.9 release).
