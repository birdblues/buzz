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
import 'sandbox_bridge.dart';

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

/// One session per app blob per message it was shared in: the same blob in
/// two messages has two bridge targets and therefore two sessions.
String sandboxSessionKey(String sha256, String? messageId) =>
    '$sha256:${messageId ?? ''}';

enum SandboxSessionPhase { loading, ready, failed }

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

  const SandboxSessionView({
    required this.phase,
    required this.error,
    required this.attached,
    required this.hasDocument,
    required this.prefillSeq,
  });

  /// A running app is one the card should mark: loading or ready, not
  /// failed.
  bool get isRunning => phase != SandboxSessionPhase.failed;
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

  _Document(this.controller);
}

class _Session {
  final String sha256;
  final SandboxBridgeTarget? bridge;
  _Document? document;
  SandboxSessionPhase phase = SandboxSessionPhase.loading;
  String? error;
  bool attached = false;
  int generation = 0;
  int prefillSeq = 0;
  DateTime? backgroundedAt;
  Timer? expiry;
  final rate = SandboxBridgeRateLimiter();

  _Session({required this.sha256, required this.bridge});

  SandboxSessionView get view => SandboxSessionView(
    phase: phase,
    error: error,
    attached: attached,
    hasDocument: document != null,
    prefillSeq: prefillSeq,
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
      }
    });
    return SandboxSessionsState.empty;
  }

  DateTime _now() => ref.read(sandboxSessionClockProvider)();

  /// The live controller for [key], if its document exists.
  WebViewController? controllerOf(String key) =>
      _sessions[key]?.document?.controller;

  /// Reuses the session for this blob and message, or starts loading one.
  String open({required String sha256, SandboxBridgeTarget? bridge}) {
    if (!ref.mounted) return '';
    final key = sandboxSessionKey(sha256, bridge?.messageId);
    if (_sessions.containsKey(key)) return key;
    final session = _Session(sha256: sha256, bridge: bridge);
    _sessions[key] = session;
    _publish();
    unawaited(_load(key, session));
    return key;
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

  /// "Try again" on the error state: a fresh load in the same session.
  void retry(String key) {
    if (!ref.mounted) return;
    final session = _sessions[key];
    if (session == null) return;
    unawaited(_blank(session.document));
    session.document = null;
    session.phase = SandboxSessionPhase.loading;
    session.error = null;
    _publish();
    unawaited(_load(key, session));
  }

  void _terminate(String key, {bool blank = true}) {
    if (!ref.mounted) return;
    final session = _sessions.remove(key);
    if (session == null) return;
    session.expiry?.cancel();
    session.expiry = null;
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

  Future<void> _load(String key, _Session session) async {
    final generation = ++session.generation;
    bool stale() =>
        session.generation != generation || _sessions[key] != session;

    final appContentUrl = ref.read(appContentUrlProvider);
    if (appContentUrl == null) {
      _fail(session, stale, 'This relay does not serve sandboxed apps.');
      return;
    }
    final headers = ref
        .read(mediaGetAuthServiceProvider)
        .signAppContentAuth(session.sha256);
    if (headers == null) {
      _fail(session, stale, 'No signing key is available for this community.');
      return;
    }
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

    final String html;
    try {
      html = await fetchAppDocument(
        appContentUri(appContentUrl, session.sha256),
        headers: headers,
        client: ref.read(mediaHttpClientProvider),
      );
    } on AppContentFetchException catch (error) {
      _fail(session, stale, _describeFetchError(error));
      return;
    } catch (error) {
      _fail(session, stale, 'Could not load this app: $error');
      return;
    }
    if (stale()) return;

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    final document = _Document(controller);
    if (session.bridge != null) {
      // Registered — and acknowledged — before the load: the channel's own
      // document-start script must precede the app's script, and the
      // native `__buzzHost` shim keys off its presence.
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
            if (stale() || document.terminating) return;
            session.phase = SandboxSessionPhase.ready;
            _publish();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false || document.terminating) return;
            if (stale()) return;
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
              stale,
              'Could not render this app: ${error.description}',
            );
          },
        ),
      )
      ..loadHtmlString(stampSandboxCsp(html));
    session.document = document;
    _publish();
  }

  NavigationDecision _decide(_Document document, NavigationRequest request) {
    if (document.terminating) {
      final blank =
          request.isMainFrame &&
          Uri.tryParse(request.url)?.toString() ==
              appSandboxDocumentUri.toString();
      return blank ? NavigationDecision.navigate : NavigationDecision.prevent;
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

  void _fail(_Session session, bool Function() stale, String message) {
    if (stale()) return;
    unawaited(_blank(session.document));
    session.document = null;
    session.phase = SandboxSessionPhase.failed;
    session.error = message;
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
