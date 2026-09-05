import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../shared/relay/media_auth.dart';
import '../../shared/relay/relay_info.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';

/// Whether the sandbox WebView may perform [requested].
///
/// Only the app's own document URL is ever allowed — the first load. Every
/// other request (a link tap, `location=`, `<meta refresh>`, a form post, a
/// subframe load) is refused, so a document cannot carry data out by
/// navigating. This is the mobile half of the navigation lock; the response
/// CSP (`sandbox`, `connect-src 'none'`) is the other.
bool isAllowedAppNavigation({required Uri initial, required String requested}) {
  final uri = Uri.tryParse(requested);
  if (uri == null) return false;
  return uri.toString() == initial.toString();
}

/// Full-screen sandbox for one HTML app blob (`docs/sandboxed-apps.md`).
///
/// Mints a fresh blob-scoped token, loads
/// `{app_content_url}/app/{sha256}.html` with it in the `Authorization`
/// header (never in the URL), and locks navigation to that one request. No
/// JavaScript channels are registered, so the page has no bridge into the
/// app. WebRTC is removed natively before the page's script runs — see
/// `ios/Runner/SandboxWebViewHardening.swift`.
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _controller = null;
    _loading = true;
    _error = null;

    final appContentUrl = ref.read(appContentUrlProvider);
    if (appContentUrl == null) {
      _fail('This relay does not serve sandboxed apps.');
      return;
    }
    final headers = ref
        .read(mediaGetAuthServiceProvider)
        .signAppContentAuth(widget.sha256);
    if (headers == null) {
      _fail('No signing key is available for this community.');
      return;
    }

    final uri = appContentUri(appContentUrl, widget.sha256);
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              isAllowedAppNavigation(initial: uri, requested: request.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _loading = false);
          },
          onHttpError: (error) {
            final status = error.response?.statusCode;
            _fail(
              status == null
                  ? 'The relay refused this app.'
                  : 'The relay refused this app (HTTP $status).',
            );
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            _fail('Could not load this app: ${error.description}');
          },
        ),
      )
      ..loadRequest(uri, headers: headers);
    _controller = controller;
  }

  void _fail(String message) {
    _error = message;
    _loading = false;
    if (mounted) setState(() {});
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
            if (error != null)
              _AppLoadError(message: error, onRetry: () => setState(_load)),
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
