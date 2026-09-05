import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/relay/media_image.dart';
import '../../../shared/theme/theme.dart';
import 'link_preview_snapshot.dart';

/// Compact link preview card, the desktop default presentation
/// (`compact-link-preview-attachment.tsx`): a relay-hosted thumbnail on the
/// left when the sender captured one, then hostname, title and description.
/// Tapping anywhere opens the link in the system browser. Everything shown
/// comes from the signed snapshot tag; nothing here talks to the linked site.
class LinkPreviewCard extends StatelessWidget {
  final LinkPreviewSnapshot snapshot;
  final VoidCallback onOpen;

  const LinkPreviewCard({
    super.key,
    required this.snapshot,
    required this.onOpen,
  });

  static const maxWidth = 360.0;
  static const thumbnailWidth = 104.0;
  static const thumbnailHeight = 64.0;
  static const _faviconSize = 12.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final hostname = snapshot.hostname;
    final title = snapshot.title.isEmpty ? hostname : snapshot.title;
    final description = snapshot.description
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final imageUrl = snapshot.imageUrl;
    final faviconUrl = snapshot.faviconUrl;

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (faviconUrl != null) ...[
              SizedBox(
                width: _faviconSize,
                height: _faviconSize,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: MediaImage(
                    key: ValueKey('link-preview-favicon:$faviconUrl'),
                    url: faviconUrl,
                    fit: BoxFit.contain,
                    decodeWidth: _faviconSize,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                hostname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Grid.quarter),
        // One line each, like desktop's compact card, so the text block stays
        // the height of the thumbnail beside it.
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.bodyMedium?.copyWith(
            color: colors.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: Grid.quarter),
          Text(
            description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    final Widget body;
    if (imageUrl == null) {
      // No thumbnail: a quote-style rule on the left, like desktop.
      body = Container(
        padding: const EdgeInsets.symmetric(vertical: Grid.half),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: colors.outlineVariant, width: 3),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: Grid.twelve),
          child: text,
        ),
      );
    } else {
      body = Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Grid.xs),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: thumbnailWidth,
              height: thumbnailHeight,
              child: ColoredBox(
                color: colors.surfaceContainerHighest,
                child: MediaImage(
                  key: ValueKey('link-preview-image:$imageUrl'),
                  url: imageUrl,
                  fit: BoxFit.cover,
                  width: thumbnailWidth,
                  height: thumbnailHeight,
                  semanticLabel: 'Preview image from $hostname',
                  errorBuilder: (context, error, stackTrace) =>
                      _ThumbnailFallback(faviconUrl: faviconUrl),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Grid.xxs,
                  vertical: 6,
                ),
                child: text,
              ),
            ),
          ],
        ),
      );
    }

    // One screen-reader stop for the whole card: it is a single button, so
    // the inner texts must not also announce themselves.
    return Semantics(
      button: true,
      link: true,
      excludeSemantics: true,
      onTap: onOpen,
      label: [
        'Open link: $hostname, $title',
        if (description.isNotEmpty) description,
      ].join('. '),
      child: GestureDetector(
        key: ValueKey('link-preview:${snapshot.canonicalUrl}'),
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: Container(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          margin: const EdgeInsets.symmetric(vertical: Grid.half),
          child: body,
        ),
      ),
    );
  }
}

/// Shown in the thumbnail slot when the image blob cannot be loaded: the
/// favicon if there is one, else a generic broken-image glyph.
class _ThumbnailFallback extends StatelessWidget {
  final String? faviconUrl;

  const _ThumbnailFallback({required this.faviconUrl});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final faviconUrl = this.faviconUrl;
    final icon = Icon(
      LucideIcons.imageOff,
      size: 20,
      color: colors.onSurfaceVariant,
    );
    return Center(
      child: faviconUrl == null
          ? icon
          : SizedBox(
              width: 28,
              height: 28,
              child: MediaImage(
                url: faviconUrl,
                fit: BoxFit.contain,
                decodeWidth: 28,
                errorBuilder: (context, error, stackTrace) => icon,
              ),
            ),
    );
  }
}
