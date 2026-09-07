import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:buzz/features/profile/presence_cache_provider.dart';
import 'package:buzz/shared/relay/relay.dart';

/// Tests for [PresenceCacheNotifier] in the pure-Nostr world.
///
/// The notifier subscribes to kind:20001 (presence updates) over the relay
/// session and only mutates state for pubkeys registered via
/// [PresenceCacheNotifier.track]. Tracking also fires a one-shot seed query,
/// because a subscription alone only reports the *next* change — see the
/// seed tests below.
void main() {
  test('WS presence event updates cache for tracked pubkey', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    // Initialize the notifier (triggers build → subscribes to WS).
    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    // Track alice, then emit her initial 'online' status.
    container.read(presenceCacheProvider.notifier).track(['alice']);
    relaySession.emit(_presence('alice', 'online'));
    expect(container.read(presenceCacheProvider)['alice'], 'online');

    // Simulate a WS presence event: alice goes away.
    relaySession.emit(_presence('alice', 'away'));
    expect(container.read(presenceCacheProvider)['alice'], 'away');
  });

  test('WS presence event ignores untracked pubkeys', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    // Track only alice.
    container.read(presenceCacheProvider.notifier).track(['alice']);

    // Emit event for bob (untracked).
    relaySession.emit(_presence('bob', 'online'));

    // Bob should NOT appear in the cache.
    expect(container.read(presenceCacheProvider).containsKey('bob'), isFalse);
  });

  test('WS presence event ignores invalid status values', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    container.read(presenceCacheProvider.notifier).track(['alice']);
    relaySession.emit(_presence('alice', 'online'));
    expect(container.read(presenceCacheProvider)['alice'], 'online');

    // Emit event with garbage status — should be rejected.
    relaySession.emit(_presence('alice', 'garbage-status'));

    // Status should remain 'online'.
    expect(container.read(presenceCacheProvider)['alice'], 'online');
  });

  test('WS presence event skips no-op updates', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    container.read(presenceCacheProvider.notifier).track(['alice']);
    relaySession.emit(_presence('alice', 'online'));

    // Listen for state changes after initial setup.
    var stateChangeCount = 0;
    container.listen(presenceCacheProvider, (prev, next) => stateChangeCount++);

    // Emit event with same status as current.
    relaySession.emit(_presence('alice', 'online'));

    // No state change should occur — it's a no-op.
    expect(stateChangeCount, 0);
  });

  test('subscribes to kind:20001 with limit 0', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    // Should have subscribed with the correct filter.
    expect(relaySession.filters, hasLength(1));
    expect(relaySession.filters.single.kinds, [EventKind.presenceUpdate]);
    expect(relaySession.filters.single.limit, 0);
  });

  test('WS event uses pubkey variable, not literal string', () async {
    // Regression test for the map key bug where `{...state, pubkey: status}`
    // used the literal string "pubkey" instead of the variable's value.
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    container.read(presenceCacheProvider.notifier).track([
      'deadbeef',
      'cafebabe',
    ]);

    // Seed cafebabe -> offline, then set deadbeef online.
    relaySession.emit(_presence('cafebabe', 'offline'));
    relaySession.emit(_presence('deadbeef', 'online'));

    final cache = container.read(presenceCacheProvider);
    // deadbeef should be online (the actual pubkey, not a literal "pubkey" key).
    expect(cache['deadbeef'], 'online');
    // cafebabe should still be offline (not clobbered).
    expect(cache['cafebabe'], 'offline');
    // There should be no literal "pubkey" key in the map.
    expect(cache.containsKey('pubkey'), isFalse);
  });

  test(
    'seeds a newly tracked pubkey from the relay, with no live event',
    () async {
      final relaySession = _RecordingRelaySessionNotifier();
      // The relay answers a kind:20001 + authors query with events IT signed,
      // naming the subject in a p tag.
      relaySession.queryResponse = [_relayPresence('alice', 'online')];
      final container = _buildContainer(relaySession: relaySession);
      addTearDown(container.dispose);

      container.read(presenceCacheProvider);
      await _pumpEventQueue();

      container.read(presenceCacheProvider.notifier).track(['alice']);
      expect(container.read(presenceCacheProvider)['alice'], isNull);

      await _settleSeed();

      expect(container.read(presenceCacheProvider)['alice'], 'online');
      final filter = relaySession.queryFilters.single;
      expect(filter.kinds, [EventKind.presenceUpdate]);
      expect(filter.authors, ['alice']);
    },
  );

  test('seed accepts only the subjects it asked about', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    relaySession.queryResponse = [
      _relayPresence('alice', 'online'),
      // A subject that was never requested must not enter the cache, however
      // the p tag got there.
      _relayPresence('mallory', 'online'),
    ];
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    container.read(presenceCacheProvider.notifier).track(['alice']);
    await _settleSeed();

    final cache = container.read(presenceCacheProvider);
    expect(cache['alice'], 'online');
    expect(cache.containsKey('mallory'), isFalse);
  });

  test('coalesces a burst of track() calls into one query', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    // One call per DM tile, as the list builds.
    final notifier = container.read(presenceCacheProvider.notifier);
    notifier.track(['alice']);
    notifier.track(['bob']);
    notifier.track(['alice']); // already tracked — must not re-queue
    await _settleSeed();

    expect(relaySession.queryFilters, hasLength(1));
    expect(relaySession.queryFilters.single.authors, ['alice', 'bob']);
  });

  test('a seed that reports nothing clears a stale entry', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    relaySession.queryResponse = const [];
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    container.read(presenceCacheProvider.notifier).track(['alice']);
    // Believed online from an earlier live event...
    relaySession.emit(_presence('alice', 'online'));
    expect(container.read(presenceCacheProvider)['alice'], 'online');

    // ...but the relay has no presence for her, so the dot must go out.
    await _settleSeed();
    expect(container.read(presenceCacheProvider).containsKey('alice'), isFalse);
  });

  test('a live event that lands mid-query wins over the seed', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    relaySession.queryResponse = [_relayPresence('alice', 'online')];
    final gate = Completer<void>();
    relaySession.queryGate = gate;
    final container = _buildContainer(relaySession: relaySession);
    addTearDown(container.dispose);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    container.read(presenceCacheProvider.notifier).track(['alice']);
    await _settleSeed(); // query is now parked at the gate

    relaySession.emit(_presence('alice', 'away'));
    gate.complete();
    await _pumpEventQueue();

    // The snapshot answered an older question; the live event is newer.
    expect(container.read(presenceCacheProvider)['alice'], 'away');
  });
}

/// A presence event as the relay answers a seed query: relay-signed, subject
/// in a p tag.
NostrEvent _relayPresence(String subject, String status) => NostrEvent(
  id: 'seed-$subject-$status',
  pubkey: 'relay-pubkey',
  createdAt: 1000,
  kind: EventKind.presenceUpdate,
  tags: [
    ['p', subject],
  ],
  content: status,
  sig: 'sig',
);

/// Waits past the seed debounce and lets the query future settle.
Future<void> _settleSeed() async {
  await Future<void>.delayed(const Duration(milliseconds: 80));
  await _pumpEventQueue();
}

NostrEvent _presence(String pubkey, String status) => NostrEvent(
  id: 'evt-$pubkey-$status',
  pubkey: pubkey,
  createdAt: 1000,
  kind: EventKind.presenceUpdate,
  tags: const [],
  content: status,
  sig: 'sig',
);

Future<void> _pumpEventQueue() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

ProviderContainer _buildContainer({
  required _RecordingRelaySessionNotifier relaySession,
}) {
  return ProviderContainer(
    overrides: [
      appLifecycleProvider.overrideWith(() => _FakeAppLifecycleNotifier()),
      relaySessionProvider.overrideWith(() => relaySession),
    ],
  );
}

class _RecordingRelaySessionNotifier extends RelaySessionNotifier {
  final List<NostrFilter> filters = [];
  final List<NostrFilter> queryFilters = [];
  final List<void Function(NostrEvent)> _listeners = [];

  /// What the relay answers a presence seed query with.
  List<NostrEvent> queryResponse = const [];

  /// When set, a query parks here until the test completes it.
  Completer<void>? queryGate;

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    queryFilters.addAll(filters);
    final gate = queryGate;
    if (gate != null) await gate.future;
    return queryResponse;
  }

  @override
  Future<void Function()> subscribe(
    NostrFilter filter,
    void Function(NostrEvent) onEvent, {
    void Function(String message)? onClosed,
  }) async {
    filters.add(filter);
    _listeners.add(onEvent);
    return () {
      filters.remove(filter);
      _listeners.remove(onEvent);
    };
  }

  /// Emit an event synchronously to all live subscribers.
  void emit(NostrEvent event) {
    for (final listener in List.of(_listeners)) {
      listener(event);
    }
  }
}

class _FakeAppLifecycleNotifier extends AppLifecycleNotifier {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;
}
