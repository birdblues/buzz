part of '../compose_bar.dart';

/// The previews being authored for the draft's links, above the editor:
/// one compact card per link (desktop's composer card), and one control to
/// send the message without any preview.
class _LinkPreviewStrip extends StatelessWidget {
  final List<ComposerLinkPreview> previews;
  final VoidCallback onSuppress;

  const _LinkPreviewStrip({required this.previews, required this.onSuppress});

  static const cardHeight = 56.0;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('composer-link-previews'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SizedBox(
            height: cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: previews.length,
              separatorBuilder: (_, _) => const SizedBox(width: Grid.xxs),
              itemBuilder: (context, index) =>
                  _ComposerLinkPreviewCard(preview: previews[index]),
            ),
          ),
        ),
        const SizedBox(width: Grid.half),
        IconButton(
          key: const ValueKey('composer-hide-link-previews'),
          tooltip: 'Send without link previews',
          visualDensity: VisualDensity.compact,
          onPressed: onSuppress,
          icon: Icon(
            LucideIcons.x,
            size: 18,
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ComposerLinkPreviewCard extends StatelessWidget {
  final ComposerLinkPreview preview;

  const _ComposerLinkPreviewCard({required this.preview});

  static const width = 240.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final metadata = preview.metadata;
    final loading = preview.status == ComposerLinkPreviewStatus.loading;
    final failed = preview.status == ComposerLinkPreviewStatus.failed;
    final title = metadata?.title ?? preview.hostname;
    final subtitle = metadata?.siteName ?? preview.hostname;
    final imageBytes = preview.imageBytes;

    final Widget thumbnail;
    if (imageBytes != null) {
      thumbnail = Image.memory(
        imageBytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    } else if (loading && metadata == null) {
      thumbnail = const SizedBox.expand();
    } else {
      thumbnail = Icon(
        failed ? LucideIcons.link2Off : LucideIcons.link,
        size: 18,
        color: colors.onSurfaceVariant,
      );
    }

    return Semantics(
      label: failed
          ? 'No preview for ${preview.hostname}'
          : loading && metadata == null
          ? 'Loading link preview for ${preview.hostname}'
          : 'Link preview: $title, $subtitle',
      excludeSemantics: true,
      child: Container(
        key: ValueKey('composer-link-preview:${preview.url}'),
        width: width,
        height: _LinkPreviewStrip.cardHeight,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Grid.twelve),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          children: [
            SizedBox(
              width: _LinkPreviewStrip.cardHeight,
              height: _LinkPreviewStrip.cardHeight,
              child: ColoredBox(
                color: colors.surfaceContainerHighest,
                child: Center(child: thumbnail),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Grid.xxs),
                child: loading && metadata == null
                    ? const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonBar(width: 120, height: 10),
                          SizedBox(height: 6),
                          SkeletonBar(width: 72, height: 8),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            failed ? preview.hostname : title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.textTheme.bodySmall?.copyWith(
                              color: colors.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            failed ? 'No preview available' : subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
