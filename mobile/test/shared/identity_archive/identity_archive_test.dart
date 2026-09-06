import 'dart:convert';

import 'package:buzz/shared/identity_archive/identity_archive.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;

void main() {
  final relayKeys = nostr.Keys.generate();
  final otherKeys = nostr.Keys.generate();
  final alice = 'a' * 64;
  final bob = 'b' * 64;
  final carol = 'c' * 64;

  /// A relay-signed kind:13535 snapshot, exactly as the relay publishes it.
  NostrEvent snapshot(
    List<String> archived, {
    nostr.Keys? signer,
    int? createdAt,
  }) {
    final keys = signer ?? relayKeys;
    final event = nostr.Event.from(
      kind: EventKind.identityArchivedList,
      content: '',
      secretKey: keys.secret,
      createdAt: createdAt,
      tags: [
        ['-'],
        for (final pubkey in archived) ['p', pubkey],
      ],
    );
    return NostrEvent.fromJson(
      jsonDecode(event.toJson()) as Map<String, dynamic>,
    );
  }

  group('archivedIdentityPubkeysFromSnapshot', () {
    test('reads the p tags of the relay-signed snapshot', () {
      final archived = archivedIdentityPubkeysFromSnapshot([
        snapshot([alice, bob.toUpperCase()]),
      ], relaySelf: relayKeys.public.toUpperCase());

      expect(archived, {alice, bob});
    });

    test('ignores snapshots from any other signer', () {
      final archived = archivedIdentityPubkeysFromSnapshot([
        snapshot([alice], signer: otherKeys),
      ], relaySelf: relayKeys.public);

      expect(archived, isEmpty);
    });

    test('takes the newest snapshot and ignores other kinds', () {
      final archived = archivedIdentityPubkeysFromSnapshot([
        snapshot([alice], createdAt: 1700000000),
        snapshot([bob], createdAt: 1700000100),
        NostrEvent(
          id: 'profile',
          pubkey: relayKeys.public,
          createdAt: 1700000200,
          kind: 0,
          tags: [
            ['p', carol],
          ],
          content: '{}',
          sig: 'sig',
        ),
      ], relaySelf: relayKeys.public);

      expect(archived, {bob});
    });

    test('rejects a snapshot whose signature does not verify', () {
      final genuine = snapshot([alice]);
      final tampered = NostrEvent(
        id: genuine.id,
        pubkey: genuine.pubkey,
        createdAt: genuine.createdAt,
        kind: genuine.kind,
        tags: [
          ...genuine.tags,
          ['p', bob],
        ],
        content: genuine.content,
        sig: genuine.sig,
      );

      expect(
        archivedIdentityPubkeysFromSnapshot([
          tampered,
        ], relaySelf: relayKeys.public),
        isEmpty,
      );
      expect(
        archivedIdentityPubkeysFromSnapshot(
          [tampered],
          relaySelf: relayKeys.public,
          verifySignature: false,
        ),
        {alice, bob},
      );
    });

    test('skips malformed p tags', () {
      final archived = archivedIdentityPubkeysFromSnapshot([
        snapshot([alice, 'not-a-pubkey', '']),
      ], relaySelf: relayKeys.public);

      expect(archived, {alice});
    });
  });

  group('ArchivedIdentityFilter', () {
    test('hides archived pubkeys case-insensitively but never self', () {
      final filter = ArchivedIdentityFilter(
        archived: {alice, bob},
        selfPubkey: bob,
      );

      expect(filter.hides(alice.toUpperCase()), isTrue);
      expect(filter.hides(bob), isFalse);
      expect(filter.hides(carol), isFalse);
      expect(filter.without([alice, bob, carol], (pubkey) => pubkey), [
        bob,
        carol,
      ]);
    });

    test('the empty filter hides nobody', () {
      expect(ArchivedIdentityFilter.none.hides(alice), isFalse);
      expect(ArchivedIdentityFilter.none.hidesNobody, isTrue);
    });
  });

  group('archivedIdentitiesProvider', () {
    ProviderContainer buildContainer(
      _ArchiveRelaySession session, {
      String? relaySelf,
      Future<String?>? relaySelfFuture,
      String? myPubkey,
    }) {
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          relaySessionProvider.overrideWith(() => session),
          relaySelfPubkeyProvider.overrideWith(
            (ref) => relaySelfFuture ?? Future.value(relaySelf),
          ),
          myPubkeyProvider.overrideWithValue(myPubkey),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('queries the snapshot from the relay self and folds it', () async {
      final session = _ArchiveRelaySession(
        events: [
          snapshot([alice, bob]),
        ],
      );
      final container = buildContainer(
        session,
        relaySelf: relayKeys.public,
        myPubkey: bob,
      );

      final filter = await container.read(
        archivedIdentityFilterProvider.future,
      );

      expect(filter.hides(alice), isTrue);
      expect(filter.hides(bob), isFalse, reason: 'self is exempt');
      final sent = session.filters.single.single;
      expect(sent.kinds, [EventKind.identityArchivedList]);
      expect(sent.authors, [relayKeys.public]);
      expect(sent.limit, 1);
    });

    test('is empty without a relay self pubkey', () async {
      final session = _ArchiveRelaySession(
        events: [
          snapshot([alice]),
        ],
      );
      final container = buildContainer(session, relaySelf: null);

      expect(await container.read(archivedIdentitiesProvider.future), isEmpty);
      expect(session.filters, isEmpty, reason: 'nothing to verify against');
    });

    test('fails open when the snapshot query fails', () async {
      final session = _ArchiveRelaySession(
        events: const [],
        error: StateError('relay unavailable'),
      );
      final container = buildContainer(session, relaySelf: relayKeys.public);

      expect(await container.read(archivedIdentitiesProvider.future), isEmpty);
    });

    test('fails open when the relay self lookup fails', () async {
      final session = _ArchiveRelaySession(
        events: [
          snapshot([alice]),
        ],
      );
      final container = buildContainer(
        session,
        relaySelfFuture: Future.error(StateError('nip11 unreachable')),
      );

      expect(await container.read(archivedIdentitiesProvider.future), isEmpty);
    });

    test('is empty while the session has never connected', () async {
      final session = _ArchiveRelaySession(
        events: [
          snapshot([alice]),
        ],
        initialStatus: SessionStatus.disconnected,
      );
      final container = buildContainer(session, relaySelf: relayKeys.public);

      expect(await container.read(archivedIdentitiesProvider.future), isEmpty);
      expect(session.filters, isEmpty);
    });

    test('refetches after the session reconnects', () async {
      final session = _ArchiveRelaySession(
        events: [
          snapshot([alice]),
        ],
      );
      final container = buildContainer(session, relaySelf: relayKeys.public);
      final subscription = container.listen(
        archivedIdentitiesProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);

      expect(await container.read(archivedIdentitiesProvider.future), {alice});
      session.events = [
        snapshot([alice, bob]),
      ];
      session.setStatus(SessionStatus.disconnected);
      session.setStatus(SessionStatus.connected);
      await container.pump();

      expect(await container.read(archivedIdentitiesProvider.future), {
        alice,
        bob,
      });
      expect(session.filters, hasLength(2));
    });
  });
}

class _ArchiveRelaySession extends RelaySessionNotifier {
  _ArchiveRelaySession({
    required this.events,
    this.error,
    this.initialStatus = SessionStatus.connected,
  });

  List<NostrEvent> events;
  final Object? error;
  final SessionStatus initialStatus;
  final filters = <List<NostrFilter>>[];

  @override
  SessionState build() => SessionState(status: initialStatus);

  void setStatus(SessionStatus status) {
    state = SessionState(status: status);
  }

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    this.filters.add(filters);
    if (error != null) throw error!;
    return events;
  }
}
