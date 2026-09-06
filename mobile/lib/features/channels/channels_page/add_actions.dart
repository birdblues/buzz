part of '../channels_page.dart';

BoxConstraints _addSheetConstraints(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  return BoxConstraints(
    maxHeight: mediaQuery.size.height - mediaQuery.viewPadding.top - Grid.sm,
  );
}

/// Opens the create sheet for a stream channel or a forum from a section
/// header's `+`, then opens what it created.
Future<void> _createChannelFromHeader(
  BuildContext context, {
  required String channelType,
}) async {
  unawaited(HapticFeedback.lightImpact());
  final created = await showBuzzModalBottomSheet<Channel>(
    context: context,
    title: channelType == 'forum'
        ? 'Create a new forum'
        : 'Create a new channel',
    constraints: _addSheetConstraints(context),
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CreateChannelSheet(channelType: channelType),
  );
  if (created != null && context.mounted) {
    await openChannelDetail(context, channel: created);
  }
}

/// Opens the new-message sheet from the DMs header's `+`, then opens the
/// conversation it started.
Future<void> _newDirectMessageFromHeader(
  BuildContext context,
  WidgetRef ref,
) async {
  unawaited(HapticFeedback.lightImpact());
  final currentPubkey = ref.read(currentPubkeyProvider);
  // A people picker opens with a fresh NIP-IA snapshot, the way desktop's
  // query refetches on mount, so an identity archived since the last fetch
  // is folded before the list renders (the directory awaits the filter).
  ref.invalidate(archivedIdentitiesProvider);
  final opened = await showBuzzModalBottomSheet<Channel>(
    context: context,
    title: 'New message',
    constraints: _addSheetConstraints(context),
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _NewDirectMessageSheet(currentPubkey: currentPubkey),
  );
  if (opened != null && context.mounted) {
    await openChannelDetail(context, channel: opened);
  }
}
