import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/relay/media_image.dart';
import '../../../shared/theme/theme.dart';
import '../sandbox_session.dart';

/// Which themed preview to show for [brightness]: the matching one, falling
/// back to whichever exists. Mirrors desktop `AppCard`.
String? pickThemedPreview({
  required Brightness brightness,
  required String? light,
  required String? dark,
}) {
  return (brightness == Brightness.dark ? dark : light) ?? light ?? dark;
}

String formatAppFileSize(int bytes) {
  if (bytes < 0) return '';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var size = bytes / 1024;
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  final digits = size < 10 ? size.toStringAsFixed(1) : size.round().toString();
  return '$digits ${units[unit]}';
}

/// Card for a sandboxed HTML app attachment (`docs/sandboxed-apps.md`).
///
/// Shows a static, theme-matched preview — a plain image; nothing here can
/// run script — and is one tap surface: tapping anywhere runs the app in
/// the sandbox page, or returns to it when it is already running (a green
/// dot on the preview says so). Never auto-runs. The chrome names the
/// sender so a page that imitates Buzz UI is still visibly "an app someone
/// shared".
class AppCard extends ConsumerWidget {
  final String sha256;
  final String filename;

  /// Id of the message carrying the attachment — the session key's second
  /// half, so the same blob shared twice shows two independent dots.
  final String? messageId;
  final int? size;
  final String? previewLight;
  final String? previewDark;
  final String? sharedBy;
  final VoidCallback onRun;

  const AppCard({
    super.key,
    required this.sha256,
    required this.filename,
    required this.onRun,
    this.messageId,
    this.size,
    this.previewLight,
    this.previewDark,
    this.sharedBy,
  });

  static const maxWidth = 360.0;
  static const maxPreviewHeight = 240.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final running = ref.watch(
      sandboxSessionsProvider.select(
        (s) => s.isRunning(sandboxSessionKey(sha256, messageId)),
      ),
    );
    final preview = pickThemedPreview(
      brightness: Theme.of(context).brightness,
      light: previewLight,
      dark: previewDark,
    );
    final sizeLabel = size == null ? null : formatAppFileSize(size!);
    final subtitle = [
      sharedBy == null ? 'Shared app' : 'App shared by $sharedBy',
      if (sizeLabel != null && sizeLabel.isNotEmpty) sizeLabel,
      'runs in a sandbox',
    ].join(' · ');
    final dot = _RunningDot(
      fill: context.appColors.success,
      ring: colors.surface,
    );

    // One screen-reader stop for the whole card: the label carries the
    // action and the chrome, so no child needs semantics of its own.
    return Semantics(
      button: true,
      label: [
        running ? 'Resume $filename, running' : 'Run $filename',
        subtitle,
      ].join(', '),
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('app-card-run'),
        behavior: HitTestBehavior.opaque,
        onTap: onRun,
        child: Container(
          key: ValueKey('app-card:$sha256'),
          constraints: const BoxConstraints(maxWidth: maxWidth),
          margin: const EdgeInsets.symmetric(vertical: Grid.half),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Grid.xs),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview != null)
                Stack(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: maxPreviewHeight,
                      ),
                      child: ColoredBox(
                        color: colors.surface,
                        child: MediaImage(
                          url: preview,
                          fit: BoxFit.contain,
                          width: double.infinity,
                          semanticLabel: 'Preview of $filename',
                          errorBuilder: (context, error, stackTrace) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    if (running)
                      Positioned(right: Grid.xxs, bottom: Grid.xxs, child: dot),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Grid.twelve,
                  Grid.xxs,
                  Grid.twelve,
                  Grid.xxs,
                ),
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            LucideIcons.appWindow,
                            size: 18,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        // The dot lives on the preview; the icon carries it
                        // only when there is no preview to put it on.
                        if (running && preview == null)
                          Positioned(right: -2, bottom: -2, child: dot),
                      ],
                    ),
                    const SizedBox(width: Grid.twelve),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "This app is running": a small green dot with a surface-coloured ring so
/// it reads on any preview.
class _RunningDot extends StatelessWidget {
  final Color fill;
  final Color ring;

  const _RunningDot({required this.fill, required this.ring});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('app-card-running'),
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: Border.all(color: ring, width: 2),
      ),
    );
  }
}
