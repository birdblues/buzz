part of '../wide_home_shell.dart';

/// The right column: a message thread or a forum post.
///
/// Membership, archive state, and the current pubkey are derived live rather
/// than taken from the request, so the composer follows changes made while
/// the pane is open.
class _AuxDrawer extends ConsumerWidget {
  const _AuxDrawer({
    required this.content,
    required this.paneKey,
    required this.navigatorKey,
    required this.depth,
    required this.width,
    required this.contentWidth,
    required this.focused,
    required this.duration,
    required this.onMotionEnd,
  });

  final WideAuxContent content;
  final String paneKey;
  final GlobalKey<NavigatorState> navigatorKey;
  final ValueNotifier<int> depth;

  /// Animated column width: 0 when closed, the side-panel share when docked,
  /// the content area minus the gutter when focused.
  final double width;

  /// Width the content is laid out at; stays fixed while [width] animates.
  final double contentWidth;

  /// Whether the drawer currently covers the main pane.
  final bool focused;

  /// Motion duration for width, chrome, and scrim changes.
  final Duration duration;

  /// Called when a width animation settles; the host drops a closed thread.
  final VoidCallback onMotionEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(wideShellProvider.notifier);
    final channel = ref
        .watch(channelsProvider)
        .value
        ?.where((candidate) => candidate.id == content.channelId)
        .firstOrNull;
    final currentPubkey = ref
        .watch(profileProvider)
        .whenData((value) => value?.pubkey)
        .value;
    final isMember = channel?.isMember ?? false;
    final isArchived = channel?.isArchived ?? false;
    final page = switch (content) {
      WideAuxThread(
        :final threadHead,
        :final allMessages,
        :final initialMessageId,
      ) =>
        ThreadDetailPage(
          threadHead: threadHead,
          allMessages: allMessages,
          channelId: content.channelId,
          currentPubkey: currentPubkey,
          isMember: isMember,
          isArchived: isArchived,
          initialMessageId: initialMessageId,
        ),
      WideAuxForumThread(:final postEventId) => ForumThreadPage(
        channelId: content.channelId,
        postEventId: postEventId,
        currentPubkey: currentPubkey,
        isMember: isMember,
        isArchived: isArchived,
      ),
    };

    void close() {
      FocusManager.instance.primaryFocus?.unfocus();
      notifier.closeAux();
    }

    final pane = PaneNavigator(
      key: ValueKey('wide-aux-$paneKey'),
      kind: PaneKind.aux,
      onClose: close,
      headerLeading: SizedBox(
        width: 48,
        height: 48,
        child: IconButton(
          key: const ValueKey('wide-aux-focus'),
          onPressed: notifier.toggleAuxFocus,
          color: context.colors.primary,
          tooltip: focused ? 'Show as side panel' : 'Focus thread',
          icon: Icon(
            focused ? LucideIcons.panelRight : LucideIcons.panelLeft,
            size: 22,
          ),
        ),
      ),
      headerTrailing: IconButton(
        key: const ValueKey('wide-aux-close'),
        onPressed: close,
        color: context.colors.primary,
        tooltip: 'Close thread',
        icon: const Icon(LucideIcons.x, size: 22),
      ),
      navigatorKey: navigatorKey,
      depth: depth,
      child: page,
    );

    final radius = Radius.circular(focused ? Radii.container : 0);
    final divider = context.colors.outlineVariant.withValues(alpha: 0.5);
    return AnimatedContainer(
      key: const ValueKey('wide-aux-drawer'),
      duration: duration,
      curve: _kSidebarMotionCurve,
      onEnd: onMotionEnd,
      width: width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.horizontal(left: radius),
        border: Border(
          left: BorderSide(color: focused ? Colors.transparent : divider),
        ),
        boxShadow: [
          BoxShadow(
            color: context.colors.shadow.withValues(alpha: focused ? 0.24 : 0),
            blurRadius: 32,
            offset: const Offset(-8, 0),
          ),
        ],
      ),
      child: OverflowBox(
        alignment: Alignment.centerRight,
        minWidth: contentWidth,
        maxWidth: contentWidth,
        child: pane,
      ),
    );
  }
}
