import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../shared/theme/theme.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import 'sandbox_bridge.dart';
import 'sandbox_session.dart';

/// The running app itself, shared by the full-screen page and the wide
/// shell's app pane: attaches to the session while mounted, shows its
/// WebView, its loading state, its error state with retry, and the strip
/// that reports a new version that could not be shown.
///
/// The session (`sandbox_session.dart`) owns the WebView; this widget only
/// borrows it, so the same controller re-attaches wherever the app is
/// shown next. Exactly one of these may show a session at a time.
class AppSandboxBody extends HookConsumerWidget {
  final String sha256;
  final SandboxBridgeTarget? bridge;

  const AppSandboxBody({super.key, required this.sha256, this.bridge});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionKey = sandboxSessionKeyFor(sha256, bridge);
    final sessions = ref.read(sandboxSessionsProvider.notifier);

    useEffect(() {
      // Provider writes are refused during build and unmount, so both hops
      // run one microtask later; microtasks keep their order, so a widget
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
    final updateError = view?.updateError;

    return Stack(
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
        if (updateError != null && error == null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: _UpdateErrorStrip(
              key: const ValueKey('app-sandbox-update-error'),
              message: updateError,
              onRetry: () => sessions.retryUpdate(sessionKey),
            ),
          ),
      ],
    );
  }
}

/// A new version arrived but could not be shown; the previous one keeps
/// running underneath.
class _UpdateErrorStrip extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _UpdateErrorStrip({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Grid.sm,
          vertical: Grid.xxs,
        ),
        child: Row(
          children: [
            Icon(
              LucideIcons.refreshCw,
              size: 16,
              color: colors.onErrorContainer,
            ),
            const SizedBox(width: Grid.xxs),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.bodySmall?.copyWith(
                  color: colors.onErrorContainer,
                ),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
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

/// "Updated 14:32" for the version the session shows, or null when the
/// message was never edited.
String? sandboxRevisionLabel(BuildContext context, int? revisionAt) {
  if (revisionAt == null) return null;
  final when = DateTime.fromMillisecondsSinceEpoch(revisionAt * 1000);
  final time = MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay.fromDateTime(when), alwaysUse24HourFormat: true);
  return 'Updated $time';
}
