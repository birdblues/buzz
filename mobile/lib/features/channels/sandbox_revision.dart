import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/relay/relay.dart';
import 'channel_event_order.dart';
import 'channel_messages_provider.dart';
import 'message_media.dart';
import 'sandbox_bridge.dart';
import 'timeline_message.dart';

/// The blob a message's app card currently shows once its edits are folded
/// (`docs/sandboxed-apps.md`, "New versions").
///
/// An agent republishes a graph by editing the message that carries it
/// (kind 40003 with a fresh `text/html` imeta), so the message keeps its id
/// and the card swaps its blob. This is the same folding the timeline does,
/// applied to one message so a running session can follow it.
@immutable
class AppRevision {
  final String sha256;
  final String? filename;

  /// Event id of the edit that carries this blob.
  final String editId;

  /// `created_at` of that edit, in seconds.
  final int createdAt;

  const AppRevision({
    required this.sha256,
    required this.filename,
    required this.editId,
    required this.createdAt,
  });

  @override
  bool operator ==(Object other) =>
      other is AppRevision &&
      other.sha256 == sha256 &&
      other.filename == filename &&
      other.editId == editId &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(sha256, filename, editId, createdAt);
}

/// Picks the revision from [events]: the standing edit of [messageId] and
/// its single `text/html` attachment. Null when the message has never been
/// edited, or when the standing edit carries no app (or more than one) —
/// the card is gone then, and a session must not climb back to an older
/// blob that still has one.
AppRevision? appRevisionFrom(Iterable<NostrEvent> events, String messageId) {
  final edit = latestEditFor(events, messageId);
  if (edit == null) return null;
  final apps = parseImetaTags(
    edit.tags,
  ).values.where((entry) => entry.isApp).toList();
  if (apps.length != 1) return null;
  final app = apps.single;
  return AppRevision(
    sha256: app.sha256!,
    filename: app.filename,
    editId: edit.id,
    createdAt: edit.createdAt,
  );
}

/// What a revision is looked up by: the message, not where its card sits.
/// A channel bubble and a thread row of the same message share one lookup.
typedef AppRevisionKey = ({String channelId, String messageId});

/// [AppRevisionKey] for [target].
AppRevisionKey appRevisionKeyFor(SandboxBridgeTarget target) =>
    (channelId: target.channelId, messageId: target.messageId);

/// Edits of one message fetched once from the relay.
///
/// The channel's live subscription carries edits made while the client is
/// connected, and the channel window carries edits of its top-level rows,
/// but a deep link, the legacy history fallback and thread history all
/// query content kinds only. This one query closes the gap: an app edited
/// before this device opened it still comes up on its latest blob.
final _appEditsProvider = FutureProvider.autoDispose
    .family<List<NostrEvent>, AppRevisionKey>((ref, target) async {
      // A fetch that failed while the socket was down must not stand as an
      // authoritative empty history; ask again once the session recovers.
      ref.listen(relaySessionProvider, (previous, next) {
        if (previous?.status != SessionStatus.connected &&
            next.status == SessionStatus.connected) {
          ref.invalidateSelf();
        }
      });
      final session = ref.read(relaySessionProvider.notifier);
      const deletionKinds = [EventKind.deletion, EventKind.nip29DeleteEvent];
      final edits = await session.queryRelay([
        NostrFilter(
          kinds: const [EventKind.streamMessageEdit, ...deletionKinds],
          tags: {
            '#e': [target.messageId],
            '#h': [target.channelId],
          },
          limit: 100,
        ),
      ]);
      // A deletion of an edit references the edit's id, not the message's:
      // a second query, for the edits found, so a retracted edit does not
      // stand.
      final editIds = [
        for (final event in edits)
          if (event.kind == EventKind.streamMessageEdit) event.id,
      ];
      if (editIds.isEmpty) return edits;
      final retractions = await session.queryRelay([
        NostrFilter(
          kinds: deletionKinds,
          tags: {
            '#e': editIds,
            '#h': [target.channelId],
          },
          limit: 100,
        ),
      ]);
      return [...edits, ...retractions];
    });

/// The revision a session keyed to [target] should show, from the channel's
/// live events merged with a one-shot fetch of the message's edits.
final appRevisionProvider = Provider.autoDispose
    .family<AppRevision?, AppRevisionKey>((ref, target) {
      final live =
          ref.watch(channelMessagesProvider(target.channelId)).value ??
          const <NostrEvent>[];
      final fetched =
          ref.watch(_appEditsProvider(target)).value ?? const <NostrEvent>[];
      final seen = <String>{};
      final events = <NostrEvent>[
        for (final event in live)
          if (seen.add(event.id)) event,
        for (final event in fetched)
          if (seen.add(event.id)) event,
      ];
      // Folding keeps the first of two edits with the same created_at, so
      // the order must be the timeline's, not the order the sources came in.
      events.sort(compareChannelTimelineEventsChronologically);
      return appRevisionFrom(events, target.messageId);
    });
