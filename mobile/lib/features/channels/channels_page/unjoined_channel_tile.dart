part of '../channels_page.dart';

/// At most this many not-yet-joined channels are listed inline in a section;
/// the rest are counted in a trailing row.
const _kMaxUnjoinedRows = 100;

/// A row for an open channel the user has not joined: dimmed, opening the
/// channel read-only on tap, with a Join button that joins in place and then
/// opens it as a member.
class _UnjoinedChannelTile extends HookConsumerWidget {
  final Channel channel;
  final VoidCallback onTap;
  final Future<void> Function(Channel channel) onJoined;

  const _UnjoinedChannelTile({
    required this.channel,
    required this.onTap,
    required this.onJoined,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isJoining = useState(false);
    final joinError = useState<String?>(null);
    final color = navigationPrimaryForeground(context).withValues(alpha: 0.55);

    Future<void> join() async {
      if (isJoining.value) return;
      final actions = ref.read(channelActionsProvider);
      isJoining.value = true;
      joinError.value = null;
      try {
        await actions.joinChannel(channel.id);
      } catch (error) {
        // A successful join refreshes the list, which replaces this row with
        // a member row; only a failure leaves it mounted to report to.
        if (context.mounted) {
          joinError.value = error.toString();
          isJoining.value = false;
        }
        return;
      }
      if (context.mounted) isJoining.value = false;
      await onJoined(channel.copyWith(isMember: true));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: '${channel.name}, not joined',
                excludeSemantics: true,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: InkWell(
                    key: ValueKey('unjoined-channel-${channel.id}'),
                    borderRadius: BorderRadius.circular(Radii.md),
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: _kChannelSectionInset,
                        right: Grid.xxs,
                        top: _kChannelRowVerticalPadding,
                        bottom: _kChannelRowVerticalPadding,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: _kChannelLeadingWidth,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Icon(
                                channelIcon(channel),
                                size: _kChannelIconSize,
                                color: color,
                              ),
                            ),
                          ),
                          const SizedBox(width: _kChannelLabelGap),
                          Expanded(
                            child: Text(
                              channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: contentListTitleTextStyle.copyWith(
                                color: color,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: _kChannelSectionInset),
              child: Semantics(
                button: true,
                label: 'Join ${channel.name}',
                excludeSemantics: true,
                child: FilledButton.tonal(
                  key: ValueKey('join-channel-${channel.id}'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(
                      horizontal: Grid.twelve,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: context.textTheme.labelMedium,
                  ),
                  onPressed: isJoining.value ? null : () => unawaited(join()),
                  child: Text(isJoining.value ? 'Joining…' : 'Join'),
                ),
              ),
            ),
          ],
        ),
        if (joinError.value case final error?)
          Padding(
            padding: const EdgeInsets.only(
              left: _kChannelLabelInset,
              right: _kChannelSectionInset,
              bottom: Grid.half,
            ),
            child: Text(
              error,
              key: ValueKey('join-channel-error-${channel.id}'),
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// Counts the not-yet-joined channels a section leaves out beyond
/// [_kMaxUnjoinedRows].
class _UnjoinedOverflowRow extends StatelessWidget {
  final int hidden;

  const _UnjoinedOverflowRow({required this.hidden});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: _kChannelLabelInset,
        right: _kChannelSectionInset,
        top: Grid.half,
        bottom: Grid.half,
      ),
      child: Text(
        '+$hidden more open channels',
        key: const ValueKey('channels-directory-more'),
        style: contentListBodyTextStyle.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The directory's loading or failure state, shown where the not-yet-joined
/// rows will appear. Idle and loaded-empty render nothing.
class _DirectoryStatusRow extends StatelessWidget {
  final ChannelDirectoryLoadStatus status;
  final VoidCallback? onRetry;

  const _DirectoryStatusRow({required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final style = contentListBodyTextStyle.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return switch (status) {
      ChannelDirectoryLoadStatus.loading => Padding(
        key: const ValueKey('channels-directory-loading'),
        padding: const EdgeInsets.only(
          left: _kChannelLabelInset,
          right: _kChannelSectionInset,
          top: Grid.half,
          bottom: Grid.half,
        ),
        child: Row(
          children: [
            const BuzzLoadingIndicator(
              size: 16,
              semanticLabel: 'Looking for open channels',
            ),
            const SizedBox(width: Grid.xxs),
            Expanded(child: Text('Looking for open channels…', style: style)),
          ],
        ),
      ),
      ChannelDirectoryLoadStatus.error => Padding(
        padding: const EdgeInsets.only(
          left: _kChannelLabelInset,
          right: _kChannelSectionInset,
        ),
        child: Row(
          children: [
            Expanded(child: Text('Couldn’t load open channels.', style: style)),
            TextButton(
              key: const ValueKey('channels-directory-retry'),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
      ChannelDirectoryLoadStatus.idle ||
      ChannelDirectoryLoadStatus.loaded => const SizedBox.shrink(),
    };
  }
}
