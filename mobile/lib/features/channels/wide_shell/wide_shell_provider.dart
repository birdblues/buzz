import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/community/community_provider.dart';
import '../../../shared/relay/relay_provider.dart';
import '../channel.dart';
import '../channels_provider.dart';
import '../timeline_message.dart';

/// What the wide shell's main pane shows.
enum WideSurface {
  /// The selected channel's timeline (or the empty state when none is
  /// selected).
  channel,

  /// The Activity inbox.
  inbox,

  /// Search.
  search,
}

/// Content of the wide shell's auxiliary (right) pane.
sealed class WideAuxContent {
  const WideAuxContent();

  /// Channel the content belongs to.
  String get channelId;

  /// Stable identity used to key the pane; a new key remounts the pane.
  String get key;
}

/// A message thread opened from a channel timeline.
///
/// Carries the same snapshot a full-screen [ThreadDetailPage] route receives.
/// Membership, archive state, and the current pubkey are deliberately not
/// stored: the pane host derives them live so the composer follows changes
/// while the pane stays open.
final class WideAuxThread extends WideAuxContent {
  /// Creates a thread pane request.
  const WideAuxThread({
    required this.threadHead,
    required this.allMessages,
    required this.channelId,
    this.initialMessageId,
  });

  /// The thread root message.
  final TimelineMessage threadHead;

  /// Timeline snapshot at open time; the page refetches replies itself.
  final List<TimelineMessage> allMessages;

  @override
  final String channelId;

  /// Message to scroll to and highlight once the thread has loaded.
  final String? initialMessageId;

  @override
  String get key => 'thread-${threadHead.id}';
}

/// A forum post opened from a forum channel or a search hit.
final class WideAuxForumThread extends WideAuxContent {
  /// Creates a forum thread pane request.
  const WideAuxForumThread({
    required this.channelId,
    required this.postEventId,
  });

  @override
  final String channelId;

  /// Event id of the forum post.
  final String postEventId;

  @override
  String get key => 'forum-$postEventId';
}

/// Selection state of the wide shell.
class WideShellState {
  /// Creates a shell state.
  const WideShellState({
    this.surface = WideSurface.channel,
    this.selectedChannel,
    this.initialMessageId,
    this.initialThreadRootId,
    this.aux,
    this.mainSession = 0,
    this.auxSession = 0,
  });

  /// What the main pane shows.
  final WideSurface surface;

  /// The selected channel. A snapshot: use [selectedChannelId] for identity
  /// and re-resolve details from `channelsProvider` for fresh data.
  final Channel? selectedChannel;

  /// One-shot message target for the main pane's channel page.
  final String? initialMessageId;

  /// One-shot thread target for the main pane's channel page.
  final String? initialThreadRootId;

  /// Content of the auxiliary pane, or null when it is closed.
  final WideAuxContent? aux;

  /// Bumped whenever the main pane must be remounted with fresh content.
  final int mainSession;

  /// Bumped whenever the auxiliary pane must be remounted.
  final int auxSession;

  /// Id of [selectedChannel].
  String? get selectedChannelId => selectedChannel?.id;

  /// Key identifying the main pane's content; a change remounts the pane.
  String get mainPaneKey =>
      '${surface.name}-${selectedChannelId ?? ''}-$mainSession';

  /// Key identifying the auxiliary pane's content, or null when closed.
  String? get auxPaneKey => aux == null ? null : '${aux!.key}-$auxSession';

  /// Returns a copy with the given fields replaced.
  WideShellState copyWith({
    WideSurface? surface,
    Channel? Function()? selectedChannel,
    String? Function()? initialMessageId,
    String? Function()? initialThreadRootId,
    WideAuxContent? Function()? aux,
    int? mainSession,
    int? auxSession,
  }) {
    return WideShellState(
      surface: surface ?? this.surface,
      selectedChannel: selectedChannel == null
          ? this.selectedChannel
          : selectedChannel(),
      initialMessageId: initialMessageId == null
          ? this.initialMessageId
          : initialMessageId(),
      initialThreadRootId: initialThreadRootId == null
          ? this.initialThreadRootId
          : initialThreadRootId(),
      aux: aux == null ? this.aux : aux(),
      mainSession: mainSession ?? this.mainSession,
      auxSession: auxSession ?? this.auxSession,
    );
  }
}

/// Owns the wide shell's selection: which surface and channel the main pane
/// shows and what the auxiliary pane holds.
///
/// Scoped like `channelsProvider`: switching community or identity rebuilds
/// this notifier with an empty state. Selection is not persisted.
class WideShellNotifier extends Notifier<WideShellState> {
  @override
  WideShellState build() {
    // Scoped by community and identity, like the channel list, but reset by
    // listening rather than rebuilding: the first resolution of the active
    // community (null -> id) must not wipe a selection made meanwhile, and a
    // same-community refresh keeps its previous value while loading, so only
    // a genuinely different community or identity clears the shell.
    ref.listen(activeCommunityProvider.select((v) => v.value?.id), (
      previous,
      next,
    ) {
      if (previous != null && next != null && previous != next) _reset();
    });
    ref.listen(myPubkeyProvider, (previous, next) {
      if (previous != null && previous != next) _reset();
    });
    ref.listen(channelsProvider, _reconcileWithChannels);
    return const WideShellState();
  }

  void _reset() => state = const WideShellState();

  void _reconcileWithChannels(
    AsyncValue<List<Channel>>? previous,
    AsyncValue<List<Channel>> next,
  ) {
    // AsyncLoading carries the previous value during a refresh; only a
    // settled list is authoritative about what still exists.
    if (next is! AsyncData<List<Channel>>) return;
    final selected = state.selectedChannel;
    if (selected == null) return;
    final fresh = next.value
        .where((channel) => channel.id == selected.id)
        .firstOrNull;
    if (fresh == null) {
      clearSelection();
      return;
    }
    if (!identical(fresh, selected)) {
      state = state.copyWith(selectedChannel: () => fresh);
    }
  }

  /// Shows [channel] in the main pane.
  ///
  /// Re-selecting the current channel without targets is a no-op so the
  /// timeline keeps its scroll position. Selecting a different channel, or
  /// the same channel with a message/thread target (deep link, inbox item),
  /// remounts the pane and closes the auxiliary pane.
  void selectChannel(
    Channel channel, {
    String? initialMessageId,
    String? initialThreadRootId,
  }) {
    final hasTargets = initialMessageId != null || initialThreadRootId != null;
    final sameChannel =
        state.surface == WideSurface.channel &&
        state.selectedChannelId == channel.id;
    if (sameChannel && !hasTargets) return;
    state = state.copyWith(
      surface: WideSurface.channel,
      selectedChannel: () => channel,
      initialMessageId: () => initialMessageId,
      initialThreadRootId: () => initialThreadRootId,
      aux: () => null,
      mainSession: state.mainSession + 1,
    );
  }

  /// Shows the Activity inbox in the main pane.
  void showInbox() => _showSurface(WideSurface.inbox);

  /// Shows Search in the main pane.
  void showSearch() => _showSurface(WideSurface.search);

  void _showSurface(WideSurface surface) {
    if (state.surface == surface) return;
    state = state.copyWith(surface: surface, aux: () => null);
  }

  /// Opens [content] in the auxiliary pane, selecting its channel first when
  /// it belongs to a different one.
  void openAux(WideAuxContent content, {Channel? channel}) {
    if (state.surface != WideSurface.channel ||
        state.selectedChannelId != content.channelId) {
      final target = channel ?? _findChannel(content.channelId);
      if (target != null) {
        state = state.copyWith(
          surface: WideSurface.channel,
          selectedChannel: () => target,
          initialMessageId: () => null,
          initialThreadRootId: () => null,
          mainSession: state.mainSession + 1,
        );
      }
    }
    state = state.copyWith(
      aux: () => content,
      auxSession: state.auxSession + 1,
    );
  }

  /// Closes the auxiliary pane.
  void closeAux() {
    if (state.aux == null) return;
    state = state.copyWith(aux: () => null);
  }

  /// Clears the channel selection, showing the empty main pane.
  void clearSelection() {
    state = state.copyWith(
      surface: WideSurface.channel,
      selectedChannel: () => null,
      initialMessageId: () => null,
      initialThreadRootId: () => null,
      aux: () => null,
    );
  }

  Channel? _findChannel(String id) {
    final channels = ref.read(channelsProvider).value;
    return channels?.where((channel) => channel.id == id).firstOrNull;
  }
}

/// The wide shell's selection state.
final wideShellProvider = NotifierProvider<WideShellNotifier, WideShellState>(
  WideShellNotifier.new,
);
