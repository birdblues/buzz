part of '../message_content.dart';

/// Narrowest message body column that gets the mosaic instead of the carousel.
///
/// This is the column beside the avatar, not the window or the pane: roughly
/// the pane width less the row gutters, the avatar and its gap. A thread pane
/// at its 340pt minimum leaves about 246pt here and keeps the carousel; a 14"
/// window with the thread open leaves about 460pt and gets the mosaic.
const _messageMediaMosaicMinWidth = 400.0;

/// Widest the mosaic itself grows, matching desktop's `max-w-lg`.
const _messageMediaMosaicMaxWidth = 512.0;

/// Height of a mosaic cell, and of the whole thing when three images make a
/// triptych. Both match desktop (`h-48` and `h-80`).
const _messageMediaMosaicCellHeight = 192.0;
const _messageMediaMosaicTriptychHeight = 320.0;

const _messageMediaMosaicGap = Grid.half + Grid.quarter;

/// How many cells the mosaic warms up front. All of them are on screen, unlike
/// the carousel's one page, but a very long gallery should not decode at once.
const _messageMediaMosaicPrecacheLimit = 12;

/// Whether a gallery [contentWidth] wide should be laid out as a mosaic.
///
/// Both halves matter. The shell mode keeps a landscape phone — compact by
/// [kWideLayoutMinShortestSide] even though its body column is wide — on the
/// carousel. The width keeps a narrow pane inside a wide shell on the carousel
/// too, because a pane overrides `MediaQuery` with its own width and can be as
/// slim as [kWideAuxPaneWidth].
bool _useMessageMediaMosaic(BuildContext context, double contentWidth) {
  return LayoutModeScope.isWide(context) &&
      contentWidth >= _messageMediaMosaicMinWidth;
}

/// A message's images as a two-column mosaic, the way the desktop client draws
/// them (`desktop/src/shared/ui/markdown/ImageMosaic.tsx`).
///
/// Cells crop to fill, so a portrait screenshot shows its middle rather than
/// all of itself. That is deliberate and matches desktop: the gallery is a set
/// of thumbnails, and the full image is one tap away in the viewer, which
/// decodes at full resolution once it has settled.
class _MessageImageMosaic extends HookConsumerWidget {
  final List<_MessageGalleryItem> items;

  /// Owned by the caller so the tags survive a resize between the two layouts:
  /// a viewer opened from one of them must still find its source afterwards.
  final List<Object> heroTags;
  final double width;
  final VoidCallback? onReply;
  final MediaViewerMoreAction? onMore;

  const _MessageImageMosaic({
    required this.items,
    required this.heroTags,
    required this.width,
    required this.onReply,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaAuth = ref.watch(mediaGetAuthServiceProvider);
    final mediaClient = ref.watch(mediaHttpClientProvider);

    final mosaicWidth = math.min(width, _messageMediaMosaicMaxWidth);
    final isTriptych = items.length == 3;
    final hasOddTail = items.length > 3 && items.length.isOdd;
    final columnWidth = math.max(
      1.0,
      (mosaicWidth - _messageMediaMosaicGap) / 2,
    );

    // The tail spans both columns, and the triptych's first cell spans both
    // rows, so a cell's decode width is not the column width everywhere.
    final cellWidths = [
      for (var index = 0; index < items.length; index++)
        hasOddTail && index == items.length - 1 ? mosaicWidth : columnWidth,
    ];
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final previewProviders = [
      for (var index = 0; index < items.length; index++)
        ResizeImage.resizeIfNeeded(
          (cellWidths[index] * devicePixelRatio).ceil(),
          null,
          MediaImageProvider(
            url: items[index].url,
            auth: mediaAuth,
            client: mediaClient,
          ),
        ),
    ];
    final viewerItems = [
      for (var index = 0; index < items.length; index++)
        MediaViewerImage(
          url: items[index].url,
          heroTag: heroTags[index],
          semanticLabel: items[index].semanticLabel,
          previewDecodeWidth: cellWidths[index],
          aspectRatio: items[index].aspectRatio,
          preloadProvider: previewProviders[index],
        ),
    ];

    void openAt(int index) {
      openImageViewer(
        context,
        imageUrl: items[index].url,
        heroTag: heroTags[index],
        semanticLabel: items[index].semanticLabel,
        previewDecodeWidth: cellWidths[index],
        aspectRatio: items[index].aspectRatio,
        galleryItems: viewerItems,
        initialIndex: index,
        onReply: onReply,
        onMore: onMore,
      );
    }

    Widget cell(int index, {required double width, required double height}) {
      return _MessageMosaicCell(
        item: items[index],
        heroTag: heroTags[index],
        width: width,
        height: height,
        onTap: () => openAt(index),
      );
    }

    final rows = <Widget>[];
    if (isTriptych) {
      // Desktop gives the first image the full height of a two-row block.
      final stackedHeight = math.max(
        1.0,
        (_messageMediaMosaicTriptychHeight - _messageMediaMosaicGap) / 2,
      );
      rows.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cell(
              0,
              width: columnWidth,
              height: _messageMediaMosaicTriptychHeight,
            ),
            const SizedBox(width: _messageMediaMosaicGap),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                cell(1, width: columnWidth, height: stackedHeight),
                const SizedBox(height: _messageMediaMosaicGap),
                cell(2, width: columnWidth, height: stackedHeight),
              ],
            ),
          ],
        ),
      );
    } else {
      final pairCount = hasOddTail ? items.length - 1 : items.length;
      for (var index = 0; index < pairCount; index += 2) {
        if (rows.isNotEmpty) {
          rows.add(const SizedBox(height: _messageMediaMosaicGap));
        }
        rows.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              cell(
                index,
                width: columnWidth,
                height: _messageMediaMosaicCellHeight,
              ),
              if (index + 1 < pairCount) ...[
                const SizedBox(width: _messageMediaMosaicGap),
                cell(
                  index + 1,
                  width: columnWidth,
                  height: _messageMediaMosaicCellHeight,
                ),
              ],
            ],
          ),
        );
      }
      if (hasOddTail) {
        if (rows.isNotEmpty) {
          rows.add(const SizedBox(height: _messageMediaMosaicGap));
        }
        rows.add(
          cell(
            items.length - 1,
            width: mosaicWidth,
            height: _messageMediaMosaicCellHeight,
          ),
        );
      }
    }

    // The caller already draws the "N images" label above this.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        key: const ValueKey('message-media-mosaic'),
        width: mosaicWidth,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: rows,
            ),
            _MessageGalleryPrecache(
              providers: previewProviders,
              focusedIndex: 0,
              radius: math.min(items.length, _messageMediaMosaicPrecacheLimit),
            ),
          ],
        ),
      ),
    );
  }
}

/// One mosaic cell: a cropped thumbnail that opens the viewer.
///
/// The tap action lives on the semantics node rather than only on the gesture
/// detector below it, so a screen reader can actually activate what it
/// announces as a button. Long press is deliberately absent — the message's
/// own actions come from [_MessageMediaShell] above.
class _MessageMosaicCell extends StatelessWidget {
  final _MessageGalleryItem item;
  final Object heroTag;
  final double width;
  final double height;
  final VoidCallback onTap;

  const _MessageMosaicCell({
    required this.item,
    required this.heroTag,
    required this.width,
    required this.height,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open ${item.semanticLabel}',
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('message-media-mosaic-item:${item.url}'),
        onTap: onTap,
        child: Container(
          width: width,
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: context.colors.outlineVariant),
          ),
          child: MediaViewerHero(
            tag: heroTag,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.md),
              child: MediaImage(
                url: item.url,
                decodeWidth: width,
                fit: BoxFit.cover,
                semanticLabel: item.semanticLabel,
                errorBuilder: (_, _, _) => const _MediaPreviewFallback(
                  icon: LucideIcons.imageOff,
                  label: 'Image unavailable',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
