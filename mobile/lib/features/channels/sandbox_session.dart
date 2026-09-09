import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../shared/platform/apple_platform.dart';
import '../../shared/relay/app_content.dart';
import '../../shared/relay/media_auth.dart';
import '../../shared/relay/media_image.dart';
import '../../shared/relay/relay_info.dart';
import 'sandbox_app_state.dart';
import 'sandbox_bridge.dart';
import 'sandbox_revision.dart';

/// The only document the sandbox WebView ever navigates to: the app is
/// handed over as a string (`loadHtmlString` without a base URL), which
/// WebKit loads as `about:blank` with an opaque origin.
final appSandboxDocumentUri = Uri.parse('about:blank');

/// Decides one navigation inside the sandbox WebView.
///
/// Exactly one navigation is ever allowed: the first main-frame load of the
/// app document itself ([appSandboxDocumentUri]). Everything else — a
/// reload, `window.open`, a form post, any subframe load, a link tap,
/// `location=`, `<meta refresh>`, `javascript:`/`data:`/`blob:` URLs — is
/// refused, so a document cannot carry data out by navigating. This is the
/// mobile half of the navigation lock; the stamped CSP is the other.
NavigationDecision decideAppNavigation({
  required NavigationRequest request,
  required bool initialPending,
}) {
  if (!initialPending || !request.isMainFrame) {
    return NavigationDecision.prevent;
  }
  final requested = Uri.tryParse(request.url);
  if (requested == null ||
      requested.toString() != appSandboxDocumentUri.toString()) {
    return NavigationDecision.prevent;
  }
  return NavigationDecision.navigate;
}

/// Asks the native side whether the WebRTC-removal user script hook is
/// installed (`SandboxWebViewHardening.swift` in the iOS and macOS runners).
/// Apps only run when it is: WebKit ignores the CSP `webrtc 'block'`
/// directive, so without the hook a page could reach the network over ICE.
/// Android has no hook yet and therefore never runs apps. Override in tests.
final sandboxHardeningProbeProvider = Provider<Future<bool> Function()>((ref) {
  return () async {
    if (!supportsSandboxApps) return false;
    try {
      const channel = MethodChannel('buzz/sandbox_webview');
      return await channel.invokeMethod<bool>('isHardeningInstalled') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  };
});

/// How long an app the reader backed out of stays alive before the host
/// ends it on its own.
const sandboxSessionTtl = Duration(hours: 24);

/// How many backed-out apps stay alive at once. A hidden WKWebView still
/// holds its content process and tens of megabytes; beyond this the one
/// backed out of longest ago is ended.
const sandboxSessionBackgroundCap = 3;

/// What an ended app's WebView is left showing: a script-free document that
/// replaces the app's, so its timers and callbacks die with it. (An empty
/// string is refused by `loadHtmlString`.)
const sandboxBlankDocument =
    '<!doctype html><html><head><meta charset="utf-8"><title></title>'
    '</head><body></body></html>';

/// Wall clock for the expiry rules; overridden in tests.
final sandboxSessionClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// One session per message an app was shared in, so a new version of the
/// app (an edit of that message with a fresh blob) swaps into the running
/// session instead of starting another. Without a message — or with several
/// HTML attachments in one message, where the message alone cannot name the
/// app — the session is keyed to the blob and never swaps.
String sandboxSessionKey(
  String sha256,
  String? messageId, {
  int htmlCount = 1,
}) => messageId != null && htmlCount == 1 ? 'msg:$messageId' : 'sha:$sha256';

/// [sandboxSessionKey] for the message described by [bridge].
String sandboxSessionKeyFor(String sha256, SandboxBridgeTarget? bridge) =>
    sandboxSessionKey(
      sha256,
      bridge?.messageId,
      htmlCount: bridge?.htmlAttachmentCount ?? 1,
    );

/// `updating` is a ready session loading a new version of its app into the
/// same WebView: the old document stays on screen until the new one is ready.
enum SandboxSessionPhase { loading, ready, updating, failed }

/// Host-owned script that reads the running app's view state
/// (`sandbox_app_state.dart`). It stringifies and caps inside the page so a
/// page that redefined its bridge object cannot hand back an oversized
/// value; the host caps again.
const sandboxExportStateScript =
    '(function(){try{var b=window.buzzBridge;'
    'var s=JSON.stringify(b&&b._export?b._export():null);'
    "return typeof s==='string'&&s.length<=65536?s:'null'}"
    "catch(e){return 'null'}})()";

/// Readiness probe for a freshly loaded document: `true|false` once the app
/// has booted without error, `true|true` when its boot failed.
const sandboxReadyProbeScript =
    "String(!!window.__APP_READY__)+'|'+String(!!window.__APP_ERROR__)";

/// Hands [stateBase64] (base64 of canonical JSON, so no character in it can
/// break out of the literal) to the new document.
String sandboxImportStateScript(String stateBase64) =>
    '(function(){var b=window.buzzBridge;'
    "if(b&&b._importB64)b._importB64('$stateBase64')})()";

/// How long a new version may take to boot before the previous one is
/// reloaded.
const sandboxSwapReadyTimeout = Duration(seconds: 10);
const sandboxSwapLoadTimeout = Duration(seconds: 15);
const sandboxSwapExportTimeout = Duration(seconds: 2);

/// What widgets see of one session. The controller itself is handed out by
/// [SandboxSessionsNotifier.controllerOf]; it is not state.
@immutable
class SandboxSessionView {
  final SandboxSessionPhase phase;
  final String? error;

  /// True while a page shows this session.
  final bool attached;

  /// True once a WebView document exists to attach a widget to.
  final bool hasDocument;

  /// Bumped every time a selection from the app became a composer draft.
  /// The page pops when it sees it grow.
  final int prefillSeq;

  /// Why the last new version could not be shown, while the app keeps
  /// running on the previous one. Cleared by the next successful swap.
  final String? updateError;

  /// `created_at` (seconds) of the edit whose blob the app is showing, or
  /// null when the message was never edited.
  final int? revisionAt;

  const SandboxSessionView({
    required this.phase,
    required this.error,
    required this.attached,
    required this.hasDocument,
    required this.prefillSeq,
    this.updateError,
    this.revisionAt,
  });

  /// A running app is one the card should mark: loading, ready or updating,
  /// not failed.
  bool get isRunning => phase != SandboxSessionPhase.failed;

  bool get isUpdating => phase == SandboxSessionPhase.updating;
}

@immutable
class SandboxSessionsState {
  final Map<String, SandboxSessionView> sessions;

  const SandboxSessionsState(this.sessions);

  static const empty = SandboxSessionsState({});

  SandboxSessionView? operator [](String key) => sessions[key];

  bool isRunning(String key) => sessions[key]?.isRunning ?? false;
}

/// One loaded document. A session replaces it on retry; a replaced or
/// ended document is blanked so its script stops right away rather than
/// whenever the Dart finalizer gets to the native view.
class _Document {
  final WebViewController controller;
  bool initialPending = true;
  bool terminating = false;

  /// Set for exactly one navigation while a new version is loaded into this
  /// document; consumed by the first main-frame `about:blank` request.
  int? reloadToken;

  /// Completes when the load carrying [reloadToken] finishes.
  Completer<void>? loadDone;

  /// True while a new version is being loaded: page-finished must not mark
  /// the session ready before the state handoff.
  bool swapping = false;

  _Document(this.controller);
}

class _Session {
  /// The blob the document shows; moves forward with every swap.
  String sha256;
  final SandboxBridgeTarget? bridge;
  _Document? document;
  SandboxSessionPhase phase = SandboxSessionPhase.loading;
  String? error;
  String? updateError;
  int? revisionAt;
  bool attached = false;
  int generation = 0;
  int prefillSeq = 0;
  DateTime? backgroundedAt;
  Timer? expiry;
  final rate = SandboxBridgeRateLimiter();

  /// The newest revision seen that the document does not show yet.
  AppRevision? pending;
  bool swapping = false;
  ProviderSubscription<AppRevision?>? revisionSub;

  _Session({required this.sha256, required this.bridge});

  SandboxSessionView get view => SandboxSessionView(
    phase: phase,
    error: error,
    attached: attached,
    hasDocument: document != null,
    prefillSeq: prefillSeq,
    updateError: updateError,
    revisionAt: revisionAt,
  );
}

/// Owns every running sandboxed app so a page can come and go without the
/// app restarting (`docs/sandboxed-apps.md`, "Sessions").
///
/// Back keeps the app: the page detaches, the WebView keeps its document,
/// and the next page for the same key re-attaches the same controller.
/// Close ends it: the document is blanked and the session dropped. A
/// backed-out session ends on its own after [sandboxSessionTtl] (a timer,
/// re-checked when the app resumes because iOS does not run Dart timers in
/// the background), when more than [sandboxSessionBackgroundCap] are backed
/// out, or when the OS kills its content process.
///
/// Selection bridge messages are honoured only while a page is attached:
/// a hidden app cannot reach the composer.
///
/// A session keyed to a message follows that message's edits
/// (`sandbox_revision.dart`): when the standing edit carries a different
/// blob, the new document is fetched first, the running app's view state is
/// read back, the new document is loaded into the same controller, and the
/// state is handed to it once it reports ready. If the new version fails to
/// boot, the previous blob is reloaded with the same state. This happens
/// whether or not a page is attached, so an app backed out of comes back on
/// its newest version.
class SandboxSessionsNotifier extends Notifier<SandboxSessionsState> {
  final _sessions = <String, _Session>{};

  @override
  SandboxSessionsState build() {
    // iOS does not run Dart timers while the app is suspended, so overdue
    // sessions are re-checked whenever the app comes back.
    final lifecycle = AppLifecycleListener(onResume: _expireOverdue);
    ref.onDispose(() {
      lifecycle.dispose();
      for (final session in _sessions.values) {
        session.expiry?.cancel();
        session.revisionSub?.close();
      }
    });
    return SandboxSessionsState.empty;
  }

  DateTime _now() => ref.read(sandboxSessionClockProvider)();

  /// The live controller for [key], if its document exists.
  WebViewController? controllerOf(String key) =>
      _sessions[key]?.document?.controller;

  /// Reuses the session for this message (or blob), or starts loading one.
  /// An existing session is never re-pointed at [sha256]: which blob it
  /// shows is decided by the message's edits, not by the card that opened
  /// it, so a stale card cannot roll a session back.
  String open({required String sha256, SandboxBridgeTarget? bridge}) {
    if (!ref.mounted) return '';
    final key = sandboxSessionKeyFor(sha256, bridge);
    if (_sessions.containsKey(key)) return key;
    final session = _Session(sha256: sha256, bridge: bridge);
    _sessions[key] = session;
    if (bridge != null && key.startsWith('msg:')) {
      _followRevisions(key, session, bridge);
    }
    _publish();
    unawaited(_load(key, session));
    return key;
  }

  /// Keeps [session] on the blob its message's standing edit carries.
  ///
  /// Subscribed through the container, not this notifier's `ref`: Riverpod
  /// pauses a provider's own listeners while nothing listens to it, and an
  /// app the reader backed out of has no widget watching this provider —
  /// exactly when a new version must still be picked up.
  void _followRevisions(
    String key,
    _Session session,
    SandboxBridgeTarget bridge,
  ) {
    session.revisionSub = ref.container.listen<AppRevision?>(
      appRevisionProvider(bridge),
      (previous, next) {
        if (next == null || _sessions[key] != session) return;
        if (next.sha256 == session.sha256) {
          if (session.revisionAt != next.createdAt) {
            session.revisionAt = next.createdAt;
            _publish();
          }
          return;
        }
        session.pending = next;
        unawaited(_swap(key, session));
      },
      fireImmediately: true,
    );
  }

  /// A page now shows [key]: no expiry while it is on screen.
  void attach(String key) {
    if (!ref.mounted) return;
    final session = _sessions[key];
    if (session == null) return;
    session.attached = true;
    session.backgroundedAt = null;
    session.expiry?.cancel();
    session.expiry = null;
    _publish();
  }

  /// The page showing [key] went away (Back, or the bridge popped it). The
  /// app stays alive under the expiry rules; a failed one is dropped, since
  /// there is nothing to come back to.
  void detach(String key) {
    if (!ref.mounted) return;
    final session = _sessions[key];
    if (session == null || !session.attached) return;
    session.attached = false;
    if (session.phase == SandboxSessionPhase.failed) {
      _terminate(key);
      return;
    }
    session.backgroundedAt = _now();
    session.expiry?.cancel();
    session.expiry = Timer(sandboxSessionTtl, () => _terminate(key));
    _evictBeyondCap();
    _publish();
  }

  /// Close: end the app now.
  void terminate(String key) => _terminate(key);

  /// "Try again" on the error state: a fresh load in the same session, of
  /// the newest blob known for it.
  void retry(String key) {
    if (!ref.mounted) return;
    final session = _sessions[key];
    if (session == null) return;
    unawaited(_blank(session.document));
    session.document = null;
    final pending = session.pending;
    if (pending != null) {
      session.sha256 = pending.sha256;
      session.revisionAt = pending.createdAt;
      session.pending = null;
    }
    session.phase = SandboxSessionPhase.loading;
    session.error = null;
    session.updateError = null;
    _publish();
    unawaited(_load(key, session));
  }

  void _terminate(String key, {bool blank = true}) {
    if (!ref.mounted) return;
    final session = _sessions.remove(key);
    if (session == null) return;
    session.expiry?.cancel();
    session.expiry = null;
    session.revisionSub?.close();
    session.revisionSub = null;
    if (blank) unawaited(_blank(session.document));
    session.document = null;
    _publish();
  }

  void _evictBeyondCap() {
    final backgrounded =
        _sessions.entries.where((entry) => !entry.value.attached).toList()
          ..sort(
            (a, b) => (a.value.backgroundedAt ?? DateTime(0)).compareTo(
              b.value.backgroundedAt ?? DateTime(0),
            ),
          );
    final excess = backgrounded.length - sandboxSessionBackgroundCap;
    for (var i = 0; i < excess; i++) {
      _terminate(backgrounded[i].key);
    }
  }

  void _expireOverdue() {
    final now = _now();
    for (final key in _sessions.keys.toList()) {
      final session = _sessions[key]!;
      final since = session.backgroundedAt;
      if (session.attached || since == null) continue;
      if (!now.isBefore(since.add(sandboxSessionTtl))) _terminate(key);
    }
  }

  /// Tears the document down: while `terminating` the navigation delegate
  /// lets exactly this one `about:blank` load through.
  Future<void> _blank(_Document? document) async {
    if (document == null || document.terminating) return;
    document.terminating = true;
    try {
      await document.controller.loadHtmlString(sandboxBlankDocument);
    } on PlatformException {
      // The native view is already gone; nothing left to stop.
    }
  }

  /// Fetches the stamped-ready HTML of [sha256] with a fresh blob token.
  Future<({String? html, String? error})> _fetchHtml(String sha256) async {
    final appContentUrl = ref.read(appContentUrlProvider);
    if (appContentUrl == null) {
      return (html: null, error: 'This relay does not serve sandboxed apps.');
    }
    final headers = ref
        .read(mediaGetAuthServiceProvider)
        .signAppContentAuth(sha256);
    if (headers == null) {
      return (
        html: null,
        error: 'No signing key is available for this community.',
      );
    }
    try {
      final html = await fetchAppDocument(
        appContentUri(appContentUrl, sha256),
        headers: headers,
        client: ref.read(mediaHttpClientProvider),
      );
      return (html: html, error: null);
    } on AppContentFetchException catch (error) {
      return (html: null, error: _describeFetchError(error));
    } catch (error) {
      return (html: null, error: 'Could not load this app: $error');
    }
  }

  Future<void> _load(String key, _Session session) async {
    final generation = ++session.generation;
    bool stale() =>
        session.generation != generation || _sessions[key] != session;

    final hardened = await ref.read(sandboxHardeningProbeProvider)();
    if (stale()) return;
    if (!hardened) {
      _fail(
        session,
        stale,
        'Sandbox hardening is unavailable on this device, so apps cannot run.',
      );
      return;
    }

    final fetched = await _fetchHtml(session.sha256);
    if (stale()) return;
    final html = fetched.html;
    if (html == null) {
      _fail(session, stale, fetched.error ?? 'Could not load this app.');
      return;
    }

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    final document = _Document(controller);
    // The delegate outlives this load: a swap bumps the generation but keeps
    // the document, so its callbacks check the document, not the generation.
    bool live() => _sessions[key] == session && session.document == document;
    if (session.bridge != null) {
      // Registered — and acknowledged — before the load: the channel's own
      // document-start script must precede the app's script, and the
      // native `__buzzHost` shim keys off its presence. Never registered
      // again: the channel lives on the controller across reloads, and a
      // second registration throws.
      await controller.addJavaScriptChannel(
        sandboxBridgeChannelName,
        onMessageReceived: (message) =>
            _onBridgeMessage(key, document, message.message),
      );
      if (stale()) return;
    }
    controller
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => _decide(document, request),
          onPageFinished: (_) {
            if (!live() || document.terminating) return;
            final done = document.loadDone;
            if (done != null && !done.isCompleted) done.complete();
            if (document.swapping) return;
            session.phase = SandboxSessionPhase.ready;
            _publish();
            if (session.pending != null) unawaited(_swap(key, session));
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false || document.terminating) return;
            if (!live()) return;
            if (error.errorType ==
                    WebResourceErrorType.webContentProcessTerminated &&
                !session.attached) {
              // The OS reclaimed a hidden app; nothing to blank, nothing
              // to show. The card's dot goes out.
              _terminate(key, blank: false);
              return;
            }
            _fail(
              session,
              live,
              'Could not render this app: ${error.description}',
              negate: true,
            );
          },
        ),
      )
      ..loadHtmlString(stampSandboxCsp(html));
    session.document = document;
    _publish();
  }

  /// Loads a new version of the app into the running document.
  ///
  /// Fetch first, so a relay hiccup leaves the old document untouched; then
  /// read the old document's state; then navigate. A version that does not
  /// boot is rolled back by reloading the previous blob with the same
  /// state. Revisions that arrive meanwhile are coalesced: only the newest
  /// is loaded once the current pass ends.
  Future<void> _swap(String key, _Session session) async {
    if (session.swapping) return;
    final document = session.document;
    if (document == null || session.phase == SandboxSessionPhase.failed) {
      return;
    }
    if (session.phase == SandboxSessionPhase.loading) return;
    session.swapping = true;
    document.swapping = true;
    try {
      while (true) {
        final target = session.pending;
        session.pending = null;
        if (target == null || target.sha256 == session.sha256) break;
        final generation = ++session.generation;
        bool stale() =>
            session.generation != generation ||
            _sessions[key] != session ||
            session.document != document ||
            document.terminating;
        session.phase = SandboxSessionPhase.updating;
        session.updateError = null;
        _publish();

        final previousSha = session.sha256;
        final fetched = await _fetchHtml(target.sha256);
        if (stale()) return;
        final html = fetched.html;
        if (html == null) {
          session.phase = SandboxSessionPhase.ready;
          session.updateError = fetched.error;
          _publish();
          continue;
        }

        final state = await _exportState(document);
        if (stale()) return;

        final loaded = await _loadInto(
          document,
          html,
          state,
          generation,
          stale,
        );
        if (stale()) return;
        if (loaded) {
          session.sha256 = target.sha256;
          session.revisionAt = target.createdAt;
          session.phase = SandboxSessionPhase.ready;
          session.updateError = null;
          _publish();
          continue;
        }

        // Roll back: the previous blob is still on the relay.
        final previous = await _fetchHtml(previousSha);
        if (stale()) return;
        final previousHtml = previous.html;
        if (previousHtml == null) {
          _fail(session, stale, previous.error ?? 'Could not reload this app.');
          return;
        }
        final restored = await _loadInto(
          document,
          previousHtml,
          state,
          generation,
          stale,
        );
        if (stale()) return;
        if (!restored) {
          _fail(session, stale, 'Could not reload this app.');
          return;
        }
        session.phase = SandboxSessionPhase.ready;
        session.updateError =
            'The new version did not start; showing the previous one.';
        _publish();
      }
    } finally {
      session.swapping = false;
      document.swapping = false;
    }
  }

  /// The running app's view state as base64 canonical JSON, or null when
  /// there is none to carry (a page that has not booted, a page that
  /// returned anything but a valid state, a slow page).
  Future<String?> _exportState(_Document document) async {
    final Object? result;
    try {
      result = await document.controller
          .runJavaScriptReturningResult(sandboxExportStateScript)
          .timeout(sandboxSwapExportTimeout);
    } catch (_) {
      return null;
    }
    return sandboxAppStateToBase64(result);
  }

  /// Navigates [document] to [html] (one token-gated load), waits for it to
  /// finish and for the app to report ready, then hands it [stateBase64].
  /// False when the load did not finish, the app reported a boot error, or
  /// readiness timed out.
  Future<bool> _loadInto(
    _Document document,
    String html,
    String? stateBase64,
    int generation,
    bool Function() stale,
  ) async {
    final done = Completer<void>();
    document.loadDone = done;
    document.reloadToken = generation;
    try {
      await document.controller.loadHtmlString(stampSandboxCsp(html));
    } on PlatformException {
      return false;
    }
    try {
      await done.future.timeout(sandboxSwapLoadTimeout);
    } on TimeoutException {
      return false;
    }
    if (stale()) return false;
    final deadline = DateTime.now().add(sandboxSwapReadyTimeout);
    while (true) {
      Object? probe;
      try {
        probe = await document.controller.runJavaScriptReturningResult(
          sandboxReadyProbeScript,
        );
      } catch (_) {
        probe = null;
      }
      if (stale()) return false;
      if (probe == 'true|false') break;
      if (probe == 'true|true') return false;
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (stale()) return false;
    }
    if (stateBase64 != null) {
      try {
        await document.controller.runJavaScript(
          sandboxImportStateScript(stateBase64),
        );
      } catch (_) {
        // The state is a convenience; the new version is up either way.
      }
    }
    return true;
  }

  NavigationDecision _decide(_Document document, NavigationRequest request) {
    final blank =
        request.isMainFrame &&
        Uri.tryParse(request.url)?.toString() ==
            appSandboxDocumentUri.toString();
    if (document.terminating) {
      return blank ? NavigationDecision.navigate : NavigationDecision.prevent;
    }
    // A new version: exactly one main-frame load, then the lock is back on.
    if (document.reloadToken != null) {
      if (!blank) return NavigationDecision.prevent;
      document.reloadToken = null;
      return NavigationDecision.navigate;
    }
    final decision = decideAppNavigation(
      request: request,
      initialPending: document.initialPending,
    );
    if (decision == NavigationDecision.navigate) {
      document.initialPending = false;
    }
    return decision;
  }

  /// One selection from the app. Everything the app sent is re-checked
  /// (shape, size, rate) and only honoured while a page shows the app; what
  /// passes becomes a draft in the composer of the message this app came
  /// from. The app id tag comes from [SandboxBridgeTarget], never from the
  /// payload.
  void _onBridgeMessage(String key, _Document document, String raw) {
    final session = _sessions[key];
    if (session == null || session.document != document) return;
    if (!session.attached || document.terminating) return;
    final bridge = session.bridge;
    if (bridge == null) return;
    if (!session.rate.allow(_now())) return;
    final select = parseSandboxSelect(raw);
    if (select == null) return;
    ref
        .read(composerPrefillProvider.notifier)
        .request(
          channelId: bridge.channelId,
          threadHeadId: bridge.threadHeadId,
          text: sandboxBridgePrefillText(
            select: select,
            messageId: bridge.messageId,
          ),
        );
    session.prefillSeq += 1;
    _publish();
  }

  /// Marks [session] failed unless [guard] says the call is out of date:
  /// [guard] is a staleness check by default, or a liveness check when
  /// [negate] is set.
  void _fail(
    _Session session,
    bool Function() guard,
    String message, {
    bool negate = false,
  }) {
    if (negate ? !guard() : guard()) return;
    unawaited(_blank(session.document));
    session.document = null;
    session.phase = SandboxSessionPhase.failed;
    session.error = message;
    session.updateError = null;
    _publish();
  }

  String _describeFetchError(AppContentFetchException error) {
    return switch (error.statusCode) {
      401 => 'The relay rejected the app token. Try again.',
      403 => 'You are not allowed to open this app on this relay.',
      404 => 'This app is no longer on the relay.',
      413 => 'This app is too large to run.',
      final status? => 'The relay refused this app (HTTP $status).',
      null => error.message,
    };
  }

  void _publish() {
    if (!ref.mounted) return;
    state = SandboxSessionsState(
      Map.unmodifiable({
        for (final entry in _sessions.entries) entry.key: entry.value.view,
      }),
    );
  }
}

final sandboxSessionsProvider =
    NotifierProvider<SandboxSessionsNotifier, SandboxSessionsState>(
      SandboxSessionsNotifier.new,
    );
