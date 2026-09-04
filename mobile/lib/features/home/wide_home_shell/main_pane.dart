part of '../wide_home_shell.dart';

/// The centre column: the selected channel, the Activity inbox, Search, or
/// the empty state.
class _MainPane extends ConsumerWidget {
  const _MainPane({required this.navigatorKey, required this.depth});

  final GlobalKey<NavigatorState> navigatorKey;
  final ValueNotifier<int> depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(wideShellProvider);
    final notifier = ref.read(wideShellProvider.notifier);
    final channel = shell.selectedChannel;
    final content = switch (shell.surface) {
      WideSurface.inbox => const ActivityPage(),
      WideSurface.search => const SearchPage(),
      WideSurface.channel when channel != null => ChannelDetailPage(
        channel: channel,
        initialMessageId: shell.initialMessageId,
        initialThreadRootId: shell.initialThreadRootId,
      ),
      WideSurface.channel => const _EmptyMainPane(),
    };
    return PaneNavigator(
      key: ValueKey('wide-main-${shell.mainPaneKey}'),
      kind: PaneKind.main,
      onClose: notifier.clearSelection,
      headerLeading: const _SidebarToggleButton(),
      navigatorKey: navigatorKey,
      depth: depth,
      child: content,
    );
  }
}
