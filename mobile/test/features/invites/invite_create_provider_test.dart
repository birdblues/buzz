import 'dart:convert';

import 'package:buzz/features/invites/invite_create_provider.dart';
import 'package:buzz/shared/community/community_membership_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:nostr/nostr.dart' as nostr;

void main() {
  test('accepts hex and npub inputs but rejects other NIP-19 values', () {
    final keys = nostr.Keys.generate();

    expect(parseCommunityInvitePubkey(keys.public), keys.public);
    expect(parseCommunityInvitePubkey(keys.public.toUpperCase()), keys.public);
    expect(parseCommunityInvitePubkey(keys.npub), keys.public);
    expect(parseCommunityInvitePubkey(keys.nsec), isNull);
    expect(parseCommunityInvitePubkey('not-a-pubkey'), isNull);
  });

  test('builds the desktop-compatible kind:9030 role tags', () {
    const pubkey =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    expect(
      buildCommunityMemberInviteTags(
        pubkey: pubkey.toUpperCase(),
        role: CommunityMemberRole.admin,
      ),
      [
        ['p', pubkey],
        ['role', 'admin'],
      ],
    );
  });

  test(
    'valid npub falls back to its pubkey when profile metadata is absent',
    () async {
      final keys = nostr.Keys.generate();
      final session = _ProfileRelaySession(const []);
      final container = ProviderContainer(
        overrides: [
          relayConfigProvider.overrideWith(_TestRelayConfigNotifier.new),
          relaySessionProvider.overrideWith(() => session),
        ],
      );
      addTearDown(container.dispose);

      final invitee = await container.read(
        communityInviteProfileProvider(keys.npub).future,
      );

      expect(invitee?.pubkey, keys.public);
      expect(invitee?.displayName, isNull);
      expect(session.queryCount, 1);
    },
  );

  test('mints an unlimited invite with exact NIP-98 request shape', () async {
    final keys = nostr.Keys.generate();
    late http.Request captured;
    final client = http_testing.MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'code': 'invite-code',
          'expires_at': 12345,
          'url': 'https://relay.example.com/invite/invite-code',
          'max_uses': null,
          'uses_remaining': null,
        }),
        200,
      );
    });
    final service = RelayCommunityInviteActions(
      httpClient: client,
      baseUrl: 'https://relay.example.com',
      nsec: keys.nsec,
      signedEventRelay: SignedEventRelay(
        session: _UnusedRelaySession(),
        nsec: keys.nsec,
      ),
      isCommunityActive: () => true,
    );

    final invite = await service.mintInvite(
      ttlSeconds: defaultCommunityInviteTtlSeconds,
      maxUses: null,
    );

    expect(captured.method, 'POST');
    expect(captured.url, Uri.parse('https://relay.example.com/api/invites'));
    expect(captured.headers['content-type'], 'application/json');
    expect(captured.headers['authorization'], startsWith('Nostr '));
    expect(jsonDecode(captured.body), {
      'ttl_secs': defaultCommunityInviteTtlSeconds,
    });
    expect(invite.code, 'invite-code');
    expect(invite.maxUses, isNull);
    expect(invite.usesRemaining, isNull);
  });

  test('includes a selected maximum-use limit', () async {
    final keys = nostr.Keys.generate();
    late http.Request captured;
    final client = http_testing.MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'code': 'limited',
          'expires_at': 12345,
          'url': 'https://relay.example.com/invite/limited',
          'max_uses': 5,
          'uses_remaining': 5,
        }),
        200,
      );
    });
    final service = RelayCommunityInviteActions(
      httpClient: client,
      baseUrl: 'https://relay.example.com',
      nsec: keys.nsec,
      signedEventRelay: SignedEventRelay(
        session: _UnusedRelaySession(),
        nsec: keys.nsec,
      ),
      isCommunityActive: () => true,
    );

    await service.mintInvite(ttlSeconds: 86400, maxUses: 5);

    expect(jsonDecode(captured.body), {'ttl_secs': 86400, 'max_uses': 5});
  });

  group('communityInviteDirectoryProvider', () {
    final relayKeys = nostr.Keys.generate();

    NostrEvent profile(String pubkey, String name) => NostrEvent(
      id: '$pubkey-profile',
      pubkey: pubkey,
      createdAt: 1700000000,
      kind: 0,
      tags: const [],
      content: '{"display_name":"$name"}',
      sig: 'sig',
    );

    NostrEvent archiveSnapshot(List<String> archived) {
      final event = nostr.Event.from(
        kind: EventKind.identityArchivedList,
        content: '',
        secretKey: relayKeys.secret,
        tags: [
          ['-'],
          for (final pubkey in archived) ['p', pubkey],
        ],
      );
      return NostrEvent.fromJson(
        jsonDecode(event.toJson()) as Map<String, dynamic>,
      );
    }

    ProviderContainer buildContainer(_DirectoryRelaySession session) {
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          relayConfigProvider.overrideWith(_TestRelayConfigNotifier.new),
          relaySessionProvider.overrideWith(() => session),
          relaySelfPubkeyProvider.overrideWith((ref) async => relayKeys.public),
          myPubkeyProvider.overrideWithValue('me'),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('walks every directory page', () async {
      final session = _DirectoryRelaySession(
        profileEvents: [
          for (var i = 0; i < 120; i++)
            profile('pubkey-${i.toString().padLeft(3, '0')}', 'Person $i'),
        ],
      );
      final container = buildContainer(session);

      final users = await container.read(
        communityInviteDirectoryProvider.future,
      );

      expect(users, hasLength(120));
      expect(session.requestedPages, [1, 2, 3]);
    });

    test('hides relay-archived identities', () async {
      final bob = 'b' * 64;
      final session = _DirectoryRelaySession(
        profileEvents: [profile('alice', 'Alice'), profile(bob, 'Bob')],
        archiveEvents: [
          archiveSnapshot([bob]),
        ],
      );
      final container = buildContainer(session);

      final users = await container.read(
        communityInviteDirectoryProvider.future,
      );
      final matches = await container.read(
        communityInviteDirectorySearchProvider('b').future,
      );

      expect(users.map((user) => user.label), ['Alice']);
      expect(matches.map((user) => user.label), ['Alice']);
    });

    test('lists everyone when the archive snapshot cannot be read', () async {
      final bob = 'b' * 64;
      final session = _DirectoryRelaySession(
        profileEvents: [profile('alice', 'Alice'), profile(bob, 'Bob')],
        archiveError: StateError('snapshot unavailable'),
      );
      final container = buildContainer(session);

      final users = await container.read(
        communityInviteDirectoryProvider.future,
      );

      expect(users.map((user) => user.label), ['Alice', 'Bob']);
    });
  });
}

class _UnusedRelaySession extends RelaySessionNotifier {}

/// Serves paged kind:0 listings and the NIP-IA snapshot like the bridge.
class _DirectoryRelaySession extends RelaySessionNotifier {
  _DirectoryRelaySession({
    required this.profileEvents,
    this.archiveEvents = const [],
    this.archiveError,
  });

  final List<NostrEvent> profileEvents;
  final List<NostrEvent> archiveEvents;
  final Object? archiveError;
  final requestedPages = <int>[];

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final filter = filters.single;
    if (filter.kinds.contains(EventKind.identityArchivedList)) {
      if (archiveError != null) throw archiveError!;
      return archiveEvents;
    }
    final page = (filter.extensions['page'] as int?) ?? 1;
    requestedPages.add(page);
    final start = (page - 1) * filter.limit;
    if (start >= profileEvents.length) return const [];
    return profileEvents.sublist(
      start,
      (start + filter.limit).clamp(0, profileEvents.length),
    );
  }
}

class _TestRelayConfigNotifier extends RelayConfigNotifier {
  @override
  RelayConfig build() =>
      const RelayConfig(baseUrl: 'https://relay.example.com');
}

class _ProfileRelaySession extends RelaySessionNotifier {
  _ProfileRelaySession(this.events);

  final List<NostrEvent> events;
  int queryCount = 0;

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    queryCount++;
    return events;
  }
}
