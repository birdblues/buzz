import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/features/channels/send_message_provider.dart';
import 'package:buzz/shared/relay/relay.dart';

void main() {
  test(
    'adds the signed message locally before relay acknowledgement',
    () async {
      final session = _PendingPublishRelaySession();
      final localMessages = <NostrEvent>[];
      final removedIds = <String>[];
      final completedIds = <String>[];
      final animatedIds = <String>[];
      final send = SendMessage(
        signedEventRelay: SignedEventRelay(
          session: session,
          nsec: nostr.Keys.generate().nsec,
        ),
        fetchMembers: (_) async => const [],
        readUserCache: () => const {},
        addLocalMessage: (_, event) => localMessages.add(event),
        markLocalMessageForAnimation: (_, eventId) => animatedIds.add(eventId),
        completeLocalMessage: (_, eventId) => completedIds.add(eventId),
        removeLocalMessage: (_, eventId) => removedIds.add(eventId),
      );

      final result = send(channelId: _channelId, content: 'hello');
      await session.published;

      expect(localMessages, hasLength(1));
      expect(localMessages.single.id, session.event.id);
      expect(localMessages.single.content, 'hello');
      expect(localMessages.single.channelId, _channelId);
      expect(animatedIds, [localMessages.single.id]);
      expect(removedIds, isEmpty);

      session.accept();
      await result;
      expect(completedIds, [localMessages.single.id]);
      expect(removedIds, isEmpty);
    },
  );

  test('addresses the people a keyed mention names', () async {
    // The composer only turns its own @name chips into p tags, so a
    // `nostr:npub…` typed into the body used to reach nobody — while the same
    // mention from an agent did, because the SDK extracts it. A chip that
    // looks like a delivered mention has to be one.
    const npub =
        'npub1x6q8zruqrdfzqv05c4vkaray859e75z44fjful0qs6vqxfk2lffs0jdr3f';
    const hex =
        '3680710f801b522031f4c5596e8fa43d0b9f5055aa649e7de086980326cafa53';
    final session = _PendingPublishRelaySession();
    final chipped = 'b' * 64;
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(
        session: session,
        nsec: nostr.Keys.generate().nsec,
      ),
      fetchMembers: (_) async => const [],
      readUserCache: () => const {},
      addLocalMessage: (_, _) {},
      completeLocalMessage: (_, _) {},
      removeLocalMessage: (_, _) {},
    );

    final result = send(
      channelId: _channelId,
      content: 'ping nostr:$npub and `nostr:$npub` in code',
      // The composer's own chip still addresses its person: the body cannot
      // express what the chip map knows, and the chip map does not read text.
      mentionPubkeys: [chipped],
    );
    await session.published;

    expect(session.event.tags.where((tag) => tag.first == 'p').toList(), [
      ['p', chipped],
      ['p', hex],
    ]);

    session.accept();
    await result;
  });

  test('a keyed mention written as code addresses nobody', () async {
    const npub =
        'npub1x6q8zruqrdfzqv05c4vkaray859e75z44fjful0qs6vqxfk2lffs0jdr3f';
    final session = _PendingPublishRelaySession();
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(
        session: session,
        nsec: nostr.Keys.generate().nsec,
      ),
      fetchMembers: (_) async => const [],
      readUserCache: () => const {},
      addLocalMessage: (_, _) {},
      completeLocalMessage: (_, _) {},
      removeLocalMessage: (_, _) {},
    );

    final result = send(
      channelId: _channelId,
      content: 'look at this\n\n```\nnostr:$npub\n```',
      mentionPubkeys: const [],
    );
    await session.published;

    expect(session.event.tags.where((tag) => tag.first == 'p'), isEmpty);

    session.accept();
    await result;
  });

  test('rolls back the signed local message when publish fails', () async {
    final session = _PendingPublishRelaySession();
    final localMessages = <NostrEvent>[];
    final completedIds = <String>[];
    final removedIds = <String>[];
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(
        session: session,
        nsec: nostr.Keys.generate().nsec,
      ),
      fetchMembers: (_) async => const [],
      readUserCache: () => const {},
      addLocalMessage: (_, event) => localMessages.add(event),
      completeLocalMessage: (_, eventId) => completedIds.add(eventId),
      removeLocalMessage: (_, eventId) => removedIds.add(eventId),
    );

    final result = send(channelId: _channelId, content: 'hello');
    await session.published;
    session.reject();

    await expectLater(result, throwsException);
    expect(completedIds, isEmpty);
    expect(removedIds, [localMessages.single.id]);
  });

  test('final signed event addresses the current DM agent member', () async {
    final session = _PendingPublishRelaySession();
    final signingKey = nostr.Keys.generate().nsec;
    final sender = nostr.Keys(
      nostr.Nip19.decode(payload: signingKey).data,
    ).public;
    final staleAgent = 'a' * 64;
    final activeAgent = 'c' * 64;
    final human = 'b' * 64;
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: signingKey),
      fetchMembers: (_) async => [
        _member(sender),
        _member(activeAgent),
        _member(human),
      ],
      readUserCache: () => const {},
      addLocalMessage: (_, _) {},
      completeLocalMessage: (_, _) {},
      removeLocalMessage: (_, _) {},
    );

    final result = send(
      channelId: _channelId,
      content: 'hello without a visible mention',
      // Metadata still names the replaced agent. Delivery must follow the
      // authoritative current membership snapshot instead.
      channel: _dmChannel([sender, staleAgent, human]),
      mentionPubkeys: const [],
    );
    await session.published;

    expect(session.event.content, 'hello without a visible mention');
    expect(session.event.tags.where((tag) => tag.first == 'p').toList(), [
      ['p', activeAgent],
      ['p', human],
    ]);

    session.accept();
    await result;
  });

  test('final signed event addresses a human DM recipient', () async {
    final session = _PendingPublishRelaySession();
    final signingKey = nostr.Keys.generate().nsec;
    final sender = nostr.Keys(
      nostr.Nip19.decode(payload: signingKey).data,
    ).public;
    final human = 'b' * 64;
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: signingKey),
      fetchMembers: (_) async => [_member(sender), _member(human)],
      readUserCache: () => const {},
      addLocalMessage: (_, _) {},
      completeLocalMessage: (_, _) {},
      removeLocalMessage: (_, _) {},
    );

    final result = send(
      channelId: _channelId,
      content: 'hello human',
      channel: _dmChannel([sender, human]),
      mentionPubkeys: const [],
    );
    await session.published;

    expect(session.event.tags.where((tag) => tag.first == 'p').toList(), [
      ['p', human],
    ]);

    session.accept();
    await result;
  });

  test(
    'falls back to metadata DM recipients when membership is empty',
    () async {
      final session = _PendingPublishRelaySession();
      final signingKey = nostr.Keys.generate().nsec;
      final sender = nostr.Keys(
        nostr.Nip19.decode(payload: signingKey).data,
      ).public;
      final recipient = 'b' * 64;
      final send = SendMessage(
        signedEventRelay: SignedEventRelay(session: session, nsec: signingKey),
        fetchMembers: (_) async => const [],
        readUserCache: () => const {},
        addLocalMessage: (_, _) {},
        completeLocalMessage: (_, _) {},
        removeLocalMessage: (_, _) {},
      );

      final result = send(
        channelId: _channelId,
        content: 'hello from an unavailable roster',
        channel: _dmChannel([sender, recipient]),
        mentionPubkeys: const [],
      );
      await session.published;

      expect(session.event.tags.where((tag) => tag.first == 'p').toList(), [
        ['p', recipient],
      ]);

      session.accept();
      await result;
    },
  );

  test('falls back to metadata DM recipients when membership fails', () async {
    final session = _PendingPublishRelaySession();
    final signingKey = nostr.Keys.generate().nsec;
    final sender = nostr.Keys(
      nostr.Nip19.decode(payload: signingKey).data,
    ).public;
    final recipientOne = 'b' * 64;
    final recipientTwo = 'c' * 64;
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: signingKey),
      fetchMembers: (_) async => throw StateError('membership unavailable'),
      readUserCache: () => const {},
      addLocalMessage: (_, _) {},
      completeLocalMessage: (_, _) {},
      removeLocalMessage: (_, _) {},
    );

    final result = send(
      channelId: _channelId,
      content: 'hello group',
      channel: _dmChannel([sender, recipientOne, recipientTwo]),
      mentionPubkeys: [recipientOne.toUpperCase()],
    );
    await session.published;

    expect(session.event.tags.where((tag) => tag.first == 'p').toList(), [
      ['p', recipientOne],
      ['p', recipientTwo],
    ]);

    session.accept();
    await result;
  });

  test('cancels delivery after the active community changes', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://first.example');
    final send = container.read(sendMessageProvider);

    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://second.example');

    await expectLater(
      send(channelId: _channelId, content: 'old community draft'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('active community changed'),
        ),
      ),
    );
  });
}

const _channelId = '11111111-1111-4111-8111-111111111111';

Channel _dmChannel(List<String> participantPubkeys) => Channel(
  id: _channelId,
  name: 'DM',
  channelType: 'dm',
  visibility: 'private',
  description: '',
  createdBy: participantPubkeys.first,
  createdAt: DateTime(2025),
  memberCount: participantPubkeys.length,
  participantPubkeys: participantPubkeys,
  isMember: true,
);

ChannelMember _member(String pubkey, {String role = 'member'}) =>
    ChannelMember(pubkey: pubkey, role: role, joinedAt: DateTime(2025));

class _PendingPublishRelaySession extends RelaySessionNotifier {
  final Completer<NostrEvent> _result = Completer<NostrEvent>();
  final Completer<void> _published = Completer<void>();
  late NostrEvent event;

  Future<void> get published => _published.future;

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<NostrEvent> publish(
    NostrEvent event, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    this.event = event;
    _published.complete();
    return _result.future;
  }

  void accept() => _result.complete(event);

  void reject() => _result.completeError(Exception('relay rejected event'));
}
