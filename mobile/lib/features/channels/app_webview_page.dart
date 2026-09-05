import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../shared/relay/app_content.dart';
import '../../shared/relay/media_auth.dart';
import '../../shared/relay/media_image.dart';
import '../../shared/relay/relay_info.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';

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
/// installed (`ios/Runner/SandboxWebViewHardening.swift`). Apps only run when
/// it is: WebKit ignores the CSP `webrtc 'block'` directive, so without the
/// hook a page could reach the network over ICE. Android has no hook yet and
/// therefore never runs apps. Override in tests.
final sandboxHardeningProbeProvider = Provider<Future<bool> Function()>((ref) {
  return () async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
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

/// Full-screen sandbox for one HTML app blob (`docs/sandboxed-apps.md`).
///
/// The page never lets the WebView touch the network: the document is
/// fetched here with a fresh blob-scoped token in the `Authorization` header
/// (no redirects, size-capped — see [fetchAppDocument]), the sandbox CSP is
/// stamped into it ([stampSandboxCsp]), and the result is loaded as
/// `about:blank` with an opaque origin. Navigation is locked to that one
/// load, no JavaScript channels are registered, and WebRTC is removed
/// natively before the page's script runs.
class AppWebViewPage extends ConsumerStatefulWidget {
  final String sha256;
  final String filename;
  final String? sharedBy;

  const AppWebViewPage({
    super.key,
    required this.sha256,
    required this.filename,
    this.sharedBy,
  });

  /// Slides in from the right — the same direction as the desktop auxiliary
  /// drawer. Inside the wide shell this stacks in the current pane.
  static Route<void> route({
    required String sha256,
    required String filename,
    String? sharedBy,
  }) {
    return CupertinoPageRoute<void>(
      title: filename,
      builder: (_) => AppWebViewPage(
        sha256: sha256,
        filename: filename,
        sharedBy: sharedBy,
      ),
    );
  }

  @override
  ConsumerState<AppWebViewPage> createState() => _AppWebViewPageState();
}

class _AppWebViewPageState extends ConsumerState<AppWebViewPage> {
  WebViewController? _controller;
  bool _loading = true;
  String? _error;

  /// Bumped on every (re)load. Work started for an older generation — the
  /// fetch, the WebView callbacks — checks it and drops out once stale, so a
  /// late error or finish can never overwrite the current load's state.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    // Off the initState stack: the first steps can fail synchronously and
    // report through setState.
    unawaited(Future<void>.microtask(_load));
  }

  void _retry() {
    setState(() {
      _controller = null;
      _loading = true;
      _error = null;
    });
    unawaited(_load());
  }

  bool _stale(int generation) => generation != _generation || !mounted;

  Future<void> _load() async {
    final generation = ++_generation;

    final appContentUrl = ref.read(appContentUrlProvider);
    if (appContentUrl == null) {
      _fail(generation, 'This relay does not serve sandboxed apps.');
      return;
    }
    final headers = ref
        .read(mediaGetAuthServiceProvider)
        .signAppContentAuth(widget.sha256);
    if (headers == null) {
      _fail(generation, 'No signing key is available for this community.');
      return;
    }
    final hardened = await ref.read(sandboxHardeningProbeProvider)();
    if (_stale(generation)) return;
    if (!hardened) {
      _fail(
        generation,
        'Sandbox hardening is unavailable on this device, so apps cannot run.',
      );
      return;
    }

    final String html;
    try {
      html = await fetchAppDocument(
        appContentUri(appContentUrl, widget.sha256),
        headers: headers,
        client: ref.read(mediaHttpClientProvider),
      );
    } on AppContentFetchException catch (error) {
      _fail(generation, _describeFetchError(error));
      return;
    } catch (error) {
      _fail(generation, 'Could not load this app: $error');
      return;
    }
    if (_stale(generation)) return;

    var initialPending = true;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final decision = decideAppNavigation(
              request: request,
              initialPending: initialPending,
            );
            if (decision == NavigationDecision.navigate) {
              initialPending = false;
            }
            return decision;
          },
          onPageFinished: (_) {
            if (_stale(generation)) return;
            setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            _fail(
              generation,
              'Could not render this app: ${error.description}',
            );
          },
        ),
      )
      ..loadHtmlString(stampSandboxCsp(html));
    setState(() => _controller = controller);
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

  void _fail(int generation, String message) {
    if (_stale(generation)) return;
    setState(() {
      _controller = null;
      _error = message;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final controller = _controller;
    final error = _error;
    final subtitle = [
      if (widget.sharedBy case final sharedBy?) 'Shared by $sharedBy',
      'Runs in a sandbox · no network',
    ].join(' · ');

    return FrostedScaffold(
      backgroundColor: colors.surface,
      appBar: FrostedAppBar(
        title: Text(
          widget.filename,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const ValueKey('app-sandbox-close'),
            tooltip: 'Close',
            icon: const Icon(LucideIcons.x),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
        bottom: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Grid.xs),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
        bottomHeight: Grid.gutter,
      ),
      // The frosted bar floats over the body; keep the app below it so the
      // page never shows through a translucent bar.
      body: Padding(
        padding: EdgeInsets.only(
          top: frostedAppBarHeight(context, bottomHeight: Grid.gutter),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null && error == null)
              WebViewWidget(controller: controller),
            if (_loading && error == null)
              const Center(
                child: BuzzLoadingIndicator(semanticLabel: 'Loading app'),
              ),
            if (error != null) _AppLoadError(message: error, onRetry: _retry),
          ],
        ),
      ),
    );
  }
}

class _AppLoadError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _AppLoadError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Grid.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.shieldAlert, color: colors.onSurfaceVariant),
            const SizedBox(height: Grid.xxs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Grid.xxs),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
