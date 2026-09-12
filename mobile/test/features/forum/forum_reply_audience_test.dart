import 'package:buzz/features/forum/forum_provider.dart';
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
    String content = 'commenting',
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
      mentionPubkeys: mentionPubkeys,
      mediaTags: const [],
      replyAudiencePubkeys: audience,
      content: content,
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

  test('a keyed mention alone is also the author choosing', () async {
    const npub =
        'npub1x6q8zruqrdfzqv05c4vkaray859e75z44fjful0qs6vqxfk2lffs0jdr3f';
    const hex =
        '3680710f801b522031f4c5596e8fa43d0b9f5055aa649e7de086980326cafa53';
    expect(
      pTags(await reply(content: 'for nostr:$npub', audience: [author, other])),
      [hex],
    );
  });

  test('a mention makes the author the judge of the audience', () async {
    // Naming someone is choosing who the comment is for; nobody is added on
    // the author's behalf on top of that.
    expect(
      pTags(await reply(mentionPubkeys: [other], audience: [author, other])),
      [other],
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
