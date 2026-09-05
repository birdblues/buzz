import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/relay/media_image.dart';
import '../../../shared/theme/theme.dart';

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
/// run script — and two actions: **Run**, which opens the app in the sandbox
/// WebView page, and **Download**. Never auto-runs. The chrome names the
/// sender so a page that imitates Buzz UI is still visibly "an app someone
/// shared".
class AppCard extends StatelessWidget {
  final String sha256;
  final String filename;
  final int? size;
  final String? previewLight;
  final String? previewDark;
  final String? sharedBy;
  final VoidCallback onRun;
  final VoidCallback onDownload;

  const AppCard({
    super.key,
    required this.sha256,
    required this.filename,
    required this.onRun,
    required this.onDownload,
    this.size,
    this.previewLight,
    this.previewDark,
    this.sharedBy,
  });

  static const maxWidth = 360.0;
  static const maxPreviewHeight = 240.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
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

    return Container(
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
            Semantics(
              button: true,
              label: 'Run $filename',
              child: GestureDetector(
                key: const ValueKey('app-card-preview'),
                behavior: HitTestBehavior.opaque,
                onTap: onRun,
                child: ConstrainedBox(
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
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Grid.twelve,
              Grid.xxs,
              Grid.xxs,
              Grid.xxs,
            ),
            child: Row(
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
                const SizedBox(width: Grid.xxs),
                FilledButton.icon(
                  key: const ValueKey('app-card-run'),
                  onPressed: onRun,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(
                      horizontal: Grid.twelve,
                    ),
                  ),
                  icon: const Icon(LucideIcons.play, size: 14),
                  label: const Text('Run'),
                ),
                IconButton(
                  key: const ValueKey('app-card-download'),
                  tooltip: 'Download $filename',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDownload,
                  icon: Icon(
                    LucideIcons.download,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
