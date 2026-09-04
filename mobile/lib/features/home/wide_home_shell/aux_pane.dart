part of '../wide_home_shell.dart';

/// The right column: a message thread or a forum post.
///
/// Membership, archive state, and the current pubkey are derived live rather
/// than taken from the request, so the composer follows changes made while
/// the pane is open.
class _AuxPane extends ConsumerWidget {
  const _AuxPane({
    required this.content,
    required this.paneKey,
    required this.navigatorKey,
    required this.depth,
  });

  final WideAuxContent content;
  final String paneKey;
  final GlobalKey<NavigatorState> navigatorKey;
  final ValueNotifier<int> depth;

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

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _PaneDivider(),
        SizedBox(
          width: kWideAuxPaneWidth,
          child: PaneNavigator(
            key: ValueKey('wide-aux-$paneKey'),
            kind: PaneKind.aux,
            onClose: close,
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
          ),
        ),
      ],
    );
  }
}
