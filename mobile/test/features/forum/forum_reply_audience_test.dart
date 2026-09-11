import 'package:buzz/features/forum/forum_provider.dart';
import 'package:buzz/shared/push/push_subscription.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;

/// A comment on your post has to reach you. Forum comments qualify for push
/// only through an exact `p` tag — the channel-wide subscription covers chat
/// messages alone — so a reply that names nobody notifies nobody.
void main() {
  const channelId = '11111111-1111-4111-8111-111111111111';
  final author = 'a' * 64;
  final other = 'b' * 64;

  Future<NostrEvent> reply({
    List<String> mentionPubkeys = const [],
    Iterable<String> audience = const [],
  }) async {
    final session = _CapturingRelaySession();
    final container = ProviderContainer(
      overrides: [
        relayConfigProvider.overrideWith(_TestRelayConfig.new),
        relaySessionProvider.overrideWith(() => session),
      ],
    );
    addTearDown(container.dispose);
    await ForumEventDelivery.capture(container).createReply(
      channelId: channelId,
      parentEventId: 'post-id',
      content: 'commenting',
      mentionPubkeys: mentionPubkeys,
      mediaTags: const [],
      replyAudiencePubkeys: audience,
    );
    return session.published!;
  }

  List<String> pTags(NostrEvent event) => [
    for (final tag in event.tags)
      if (tag.first == 'p') tag[1],
  ];

  test(
    'a comment addresses the post author and the last other voice',
    () async {
      expect(pTags(await reply(audience: [author, other])), [author, other]);
    },
  );

  test('an explicit mention still comes first, and nobody repeats', () async {
    expect(
      pTags(await reply(mentionPubkeys: [other], audience: [author, other])),
      [other, author],
    );
  });

  test('the audience never crosses the push suppression limit', () async {
    // Two names added on the sender's behalf must not be what silences a
    // comment its author deliberately addressed.
    final crowd = [
      for (var i = 0; i < buzzPushHellthreadParticipantLimit; i++)
        i.toRadixString(16).padLeft(64, '0'),
    ];
    expect(
      pTags(await reply(mentionPubkeys: crowd, audience: [author, other])),
      hasLength(buzzPushHellthreadParticipantLimit),
    );
  });
}

class _TestRelayConfig extends RelayConfigNotifier {
  @override
  RelayConfig build() =>
      RelayConfig(baseUrl: 'ws://relay.test', nsec: nostr.Keys.generate().nsec);
}

class _CapturingRelaySession extends RelaySessionNotifier {
  NostrEvent? published;

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<NostrEvent> publish(
    NostrEvent event, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    published = event;
    return event;
  }
}
