import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../shared/theme/theme.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import 'sandbox_bridge.dart';
import 'sandbox_session.dart';

export 'sandbox_session.dart'
    show
        appSandboxDocumentUri,
        decideAppNavigation,
        sandboxHardeningProbeProvider;

/// Full-screen page for one sandboxed HTML app (`docs/sandboxed-apps.md`).
///
/// The app itself lives in [sandboxSessionsProvider], not here: this page
/// attaches to a session while it is on screen and detaches when it goes.
/// **Back keeps the app running** — the next page for the same app
/// re-attaches the same WebView with its state intact — and the **Close**
/// action in the bar ends it. The session applies the sandbox rules (fresh
/// blob-scoped token, stamped CSP, `about:blank` with an opaque origin,
/// navigation locked to one load, native WebRTC removal) and the expiry
/// rules for backed-out apps.
///
/// The one JavaScript channel, `buzzHost`, exists only when [bridge] names
/// the message the app was shared in. It carries the selection bridge
/// (`sandbox_bridge.dart`): a validated `{ kind, ref, text }` from the app
/// becomes a draft in that message's composer, the page pops, and the user
/// decides what to send. Nothing flows back into the app.
class AppWebViewPage extends HookConsumerWidget {
  final String sha256;
  final String filename;
  final String? sharedBy;
  final SandboxBridgeTarget? bridge;

  const AppWebViewPage({
    super.key,
    required this.sha256,
    required this.filename,
    this.sharedBy,
    this.bridge,
  });

  /// Slides in from the right on the root navigator: the app takes the
  /// whole screen on every layout.
  static Route<void> route({
    required String sha256,
    required String filename,
    String? sharedBy,
    SandboxBridgeTarget? bridge,
  }) {
    return CupertinoPageRoute<void>(
      title: filename,
      builder: (_) => AppWebViewPage(
        sha256: sha256,
        filename: filename,
        sharedBy: sharedBy,
        bridge: bridge,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final sessionKey = sandboxSessionKey(sha256, bridge?.messageId);
    final sessions = ref.read(sandboxSessionsProvider.notifier);

    useEffect(() {
      // Provider writes are refused during build and unmount, so both hops
      // run one microtask later; microtasks keep their order, so a page
      // that mounts and unmounts in one frame still attaches first.
      unawaited(
        Future<void>.microtask(() {
          sessions.open(sha256: sha256, bridge: bridge);
          sessions.attach(sessionKey);
        }),
      );
      return () =>
          unawaited(Future<void>.microtask(() => sessions.detach(sessionKey)));
    }, [sessionKey]);

    // The bridge turned a selection into a draft: leave the reader on the
    // composer. The app stays alive behind Back.
    ref.listen<int?>(
      sandboxSessionsProvider.select((s) => s[sessionKey]?.prefillSeq),
      (previous, next) {
        if (previous != null && next != null && next > previous) {
          Navigator.of(context).maybePop();
        }
      },
    );

    final view = ref.watch(
      sandboxSessionsProvider.select((s) => s[sessionKey]),
    );
    final controller = view?.hasDocument == true
        ? sessions.controllerOf(sessionKey)
        : null;
    final loading = view == null || view.phase == SandboxSessionPhase.loading;
    final error = view?.phase == SandboxSessionPhase.failed
        ? view?.error
        : null;
    final subtitle = [
      if (sharedBy case final sharedBy?) 'Shared by $sharedBy',
      'Runs in a sandbox · no network · Back keeps it running',
    ].join(' · ');

    return FrostedScaffold(
      backgroundColor: colors.surface,
      appBar: FrostedAppBar(
        title: Text(filename, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('app-sandbox-close'),
            tooltip: 'Close app',
            icon: const Icon(LucideIcons.x),
            onPressed: () {
              sessions.terminate(sessionKey);
              Navigator.of(context).maybePop();
            },
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
            if (loading && error == null)
              const Center(
                child: BuzzLoadingIndicator(semanticLabel: 'Loading app'),
              ),
            if (error != null)
              _AppLoadError(
                message: error,
                onRetry: () => sessions.retry(sessionKey),
              ),
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
