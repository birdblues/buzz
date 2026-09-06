# Buzz Client — the client-only desktop app (fork feature)

The fork ships two desktop programs:

| | Host desktop | **Buzz Client** |
|---|---|---|
| Source | upstream `desktop/` (Tauri), byte-identical to `block/buzz` main | `mobile/` (Flutter) built for macOS |
| Runs where | the Mac mini that hosts the agents | any Mac you work from |
| Hosts agent harnesses, keeps agent keys, is the pairing source | yes | **no** |
| Role | the one machine per identity that runs `buzz-acp` children | a client, exactly like the iPhone/iPad app |

The split exists because the fork could not keep up with upstream's desktop
churn: from 2026-09-06 the fork changes only `crates/`, `mobile/` and `docs/`,
and `desktop/` is pinned to upstream (a `lefthook-local.yml` pre-push guard
refuses a push whose `desktop/` differs from `upstream/main`). The fork's
earlier desktop work is preserved at tag `fork-desktop-2026-09-06`.

## What the Mac client is

`flutter build macos` of the mobile app: the same three-column shell the
iPad uses (`lib/shared/layout/layout_mode.dart` — wide when the content is
at least 1000×600), the same relay client, link previews, sandboxed HTML
apps, forum, pulse, search, invites and pairing. The wide shell's sidebar
ends in a profile card like the desktop's (`SidebarProfileCard` in
`channels_page/profile_card.dart`): your avatar with presence dot and your
display name; the card opens Settings, and the channel list header drops
its Settings avatar there. The community is named only in the header at
the top of the sidebar, which opens the switcher; that name comes from the
relay when one is set (`docs/community-name.md`). The sidebar's sections,
their `+` buttons and the open channels listed for joining are described in
`docs/mobile-sidebar.md`. Nothing here talks to the
host desktop except pairing (NIP-AB over the relay); everything else is read
from the relay.

Platform gates live in `lib/shared/platform/apple_platform.dart`:

| Getter | macOS | What it changes |
|---|---|---|
| `supportsSandboxApps` | true | `AppWebViewPage` asks the runner for the WebRTC-removal hook (`macos/Runner/SandboxWebViewHardening.swift`, a verbatim copy of the iOS file, installed in `MainFlutterWindow.awakeFromNib` before the Flutter engine starts) |
| `hasCamera` | false | no Camera entry in the composer, no camera avatar capture, no Animated avatar mode |
| `hasNativeMediaPipeline` | false | no Video and Voice note entries (transcoding/packaging exist only in the iOS/Android runners) |
| `isDesktopHost` | true | Photos opens the system open panel; "Save image" uses a save panel; downloaded files open through `NSWorkspace`; Enter sends and Shift+Enter inserts a newline in the composer; Escape leaves the field, then unwinds the shell (nested route → thread pane → main pane) |

Known gaps, accepted for the first version: no notifications while the app
is in the background (push is iOS-only and the settings card hides itself);
images upload without the native EXIF/HEIC sanitising step; no Huddles; no
Face ID (Touch ID works through `local_auth_darwin`); no drag-and-drop, hover
states or menu-bar shortcuts beyond the template's.

## Building

Only a Mac with Xcode builds it — in this setup the Intel Mac, which also
does the iPad builds; the relay host has no Xcode.

```sh
just mobile-run-macos      # debug run (first run does pod install)
just mobile-build-macos    # release, universal, zipped for scp
```

`mobile-build-macos` stamps the bundle version as
`0.1.0+<commit count>` (override with `BUZZ_CLIENT_BUILD_NAME` /
`BUZZ_CLIENT_BUILD_NUMBER`) — `pubspec.yaml` only says `0.0.0+1`, which is
what a debug run shows in Settings — and passes
`--dart-define=BUZZ_ALLOW_PRIVATE_RELAY=true` so
pairing accepts a LAN relay (`ws://192.168.x.x`); invite links to private
addresses are still refused by `relay_validation.dart`, so a LAN community is
joined by pairing. It then verifies every Mach-O in the bundle carries both
`x86_64` and `arm64` and that `codesign --verify --deep --strict` passes, and
leaves `mobile/build/macos/BuzzClient.zip` — a `ditto` archive that keeps the
bundle's symlinks. Copy that zip with `scp` (no quarantine attribute) rather
than AirDrop or a browser, or clear it with
`xattr -dr com.apple.quarantine BuzzClient.app`.

### Identity and signing

Tracked defaults (`macos/Flutter/Flutter-Debug.xcconfig` /
`Flutter-Release.xcconfig`):

| Variable | Debug | Release |
|---|---|---|
| `BUNDLE_IDENTIFIER` | `xyz.block.buzz.dogfood.client` | `xyz.block.buzz.client` |
| `APP_DISPLAY_NAME` | Buzz Client | Buzz Client |
| `BUZZ_DEVELOPMENT_TEAM` | JMTDPW9CG3 | EYF346PHUG |
| `BUZZ_CODE_SIGN_IDENTITY` | Apple Development | Apple Development |
| `BUZZ_KEYCHAIN_ACCESS_GROUP` | `$(BUNDLE_IDENTIFIER)` | `$(BUNDLE_IDENTIFIER)` |

A developer overrides them per variable in the gitignored
`mobile/macos/Flutter/AppOverrides.xcconfig`, exactly as for iOS:

```
BUNDLE_IDENTIFIER = dev.example.buzz.client
BUZZ_DEVELOPMENT_TEAM = XXXXXXXXXX
BUZZ_CODE_SIGN_IDENTITY = Apple Development
```

`scripts/mobile-worktree-overrides.sh` additionally writes
`WorktreeOverrides.xcconfig` (Debug only) in a git worktree so several
checkouts install side by side.

Why a real team signature: `flutter_secure_storage` keeps the community list —
including the identity's `nsec` — in the macOS data-protection keychain,
which only works for an app whose provisioning profile grants an application
identifier. That is why both entitlement files carry
`keychain-access-groups = $(AppIdentifierPrefix)$(BUZZ_KEYCHAIN_ACCESS_GROUP)`
and why App Sandbox is **off** (a personal build needs no App Store
entitlements). Without it every keychain call fails with `-34018` and the
app forgets its identity on relaunch — the first thing to check after a
build. A Mac running a development-signed build must be registered as a
device in the team account (Xcode does this for the building Mac; add other
Macs' Provisioning UDIDs by hand).

The first build on a new Mac fails with "No profiles for '…client' were
found", and `xcodebuild -allowProvisioningUpdates` from a terminal answers
"No Accounts" because the command line does not see the Apple ID session.
Open `mobile/macos/Runner.xcworkspace` in Xcode once, select the Runner
target's *Signing & Capabilities* tab and let automatic signing create the
macOS profile; after that `flutter run -d macos` and `just
mobile-build-macos` work from the terminal. Fallback for an unsigned build: set
`BUZZ_CODE_SIGN_IDENTITY = -`, drop the `keychain-access-groups` entitlement,
and construct `FlutterSecureStorage` with
`MacOsOptions(usesDataProtectionKeychain: false)` (login keychain, one
"wants to use your confidential information" prompt per item per build).

### Window

`macos/Runner/MainFlutterWindow.swift` sets the content minimum to 1000×700
so the window can never fall back to the phone UI, opens at 1280×800 the
first time, and remembers its frame (`BuzzClientMainWindow`). `Info.plist`
registers the `buzz://` URL scheme (handled by `app_links`) and the camera,
microphone, photo-library and local-network usage strings; there is no App
Transport Security block because networking goes through `dart:io` and the
sandbox WebView only ever loads `about:blank` from a string.

## Verifying a build

1. Launch, pair with the host by pasting the pairing code (no camera needed).
2. Quit and relaunch: still signed in (keychain works).
3. Resize: the window stops at 1000×700 and never shows the phone tab bar.
4. Composer: Enter sends, Shift+Enter inserts a newline, Enter during Korean
   composition commits the syllable without sending, Escape leaves the
   field, a second Escape closes the thread pane.
5. Attachments: Photos and Files open panels; no Camera/Video/Voice note.
6. Sandboxed app: open an app card and run `docs/sandbox-probe.html` — every
   row must fail. A "hardening not installed" refusal means the Swift hook
   did not install before the engine started.
7. Link previews render and author; images upload; "Save image" shows a
   save panel; a file attachment opens in its default app.
8. `just mobile-build-macos` prints two-slice `lipo` results and `codesign
   OK`; the zip runs on another Mac after `scp`.
