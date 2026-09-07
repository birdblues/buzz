import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/relay/relay.dart';

/// In-memory cache of other users' presence.
///
/// Two sources feed it:
///
///  * a live kind:20001 subscription, for changes as they happen, and
///  * a one-shot seed query per newly tracked pubkey.
///
/// The seed exists because a subscription only reports the *next* change.
/// Someone who published "online" before this app opened stayed grey until
/// their next heartbeat — up to a minute of a wrong dot on every cold start,
/// and longer for a device that had been backgrounded. The relay answers a
/// `kind:20001 + authors` query with the current state, so ask once per
/// pubkey and let the subscription take it from there.
class PresenceCacheNotifier extends Notifier<Map<String, String>> {
  /// The DM list calls [track] once per tile as it builds. Coalesce that burst
  /// into a single query instead of one round trip per row.
  static const _seedDebounce = Duration(milliseconds: 50);

  final Set<String> _tracked = {};
  final Set<String> _pendingSeed = {};
  Timer? _seedTimer;
  void Function()? _presenceUnsub;
  int _subscriptionVersion = 0;

  /// Monotonic clock for live updates, used to keep a slow seed response from
  /// overwriting a live event that landed while it was in flight.
  int _revision = 0;
  final Map<String, int> _lastLiveRevision = {};

  @override
  Map<String, String> build() {
    final sessionState = ref.watch(relaySessionProvider);

    ref.onDispose(() {
      _presenceUnsub?.call();
      _presenceUnsub = null;
      _seedTimer?.cancel();
      _seedTimer = null;
    });

    if (sessionState.status == SessionStatus.connected) {
      _subscribePresenceUpdates();
      // A reconnect resets this cache and may have missed changes while the
      // socket was down, so re-seed everything tracked, not just new pubkeys.
      _scheduleSeed(_tracked);
    }

    return {};
  }

  /// Track presence for [pubkeys].
  ///
  /// Newly seen pubkeys are queued for a seed query; the tracked set also
  /// filters incoming live events so the cache doesn't grow unbounded.
  void track(List<String> pubkeys) {
    final added = <String>{};
    for (final pubkey in pubkeys) {
      final normalized = pubkey.toLowerCase();
      if (normalized.isEmpty) continue;
      if (_tracked.add(normalized)) added.add(normalized);
    }
    if (added.isNotEmpty) _scheduleSeed(added);
  }

  void _scheduleSeed(Iterable<String> pubkeys) {
    _pendingSeed.addAll(pubkeys);
    if (_pendingSeed.isEmpty) return;
    _seedTimer?.cancel();
    _seedTimer = Timer(_seedDebounce, _seedPending);
  }

  /// Ask the relay for the current status of every queued pubkey.
  Future<void> _seedPending() async {
    _seedTimer = null;
    if (_pendingSeed.isEmpty) return;
    final requested = _pendingSeed.toList()..sort();
    _pendingSeed.clear();
    final startedAt = _revision;

    final List<NostrEvent> events;
    try {
      events = await ref.read(relaySessionProvider.notifier).queryRelay([
        NostrFilter(
          kinds: const [EventKind.presenceUpdate],
          authors: requested,
          limit: requested.length,
        ),
      ]);
    } catch (error) {
      // Best effort: the live subscription still delivers the next change.
      debugPrint('[PresenceCacheNotifier] presence seed failed: $error');
      return;
    }

    final requestedSet = requested.toSet();
    final seeded = <String, String>{};
    for (final event in events) {
      if (event.kind != EventKind.presenceUpdate) continue;
      final subject = _seedSubject(event);
      if (subject == null || !requestedSet.contains(subject)) continue;
      if (!_isPresenceStatus(event.content)) continue;
      seeded[subject] = event.content;
    }

    final updated = Map<String, String>.from(state);
    var changed = false;
    for (final pubkey in requested) {
      // A live event that landed after this query went out is newer than the
      // snapshot it answered with.
      if ((_lastLiveRevision[pubkey] ?? -1) > startedAt) continue;
      final status = seeded[pubkey];
      if (status == null) {
        // The relay omits pubkeys it has no presence for, so an absent subject
        // means "not online" — drop a stale entry rather than leave a dot lit.
        if (updated.remove(pubkey) != null) changed = true;
      } else if (updated[pubkey] != status) {
        updated[pubkey] = status;
        changed = true;
      }
    }
    if (changed) state = updated;
  }

  /// The subject of a presence event the relay answered a query with.
  ///
  /// `POST /query` for kind:20001 with authors is intercepted by the relay,
  /// which replies with events **it** signed, naming the subject in a `p` tag
  /// (`synthesize_presence`, crates/buzz-relay/src/api/bridge.rs). A `p` tag on
  /// a *live* event proves nothing — any member can sign one naming someone
  /// else — so this is only ever applied to query results, and the caller
  /// additionally discards subjects it never asked about.
  static String? _seedSubject(NostrEvent event) {
    for (final tag in event.tags) {
      if (tag.length >= 2 && tag[0] == 'p' && tag[1].isNotEmpty) {
        return tag[1].toLowerCase();
      }
    }
    return event.pubkey.isEmpty ? null : event.pubkey.toLowerCase();
  }

  static bool _isPresenceStatus(String status) =>
      status == 'online' || status == 'away' || status == 'offline';

  /// Subscribe to kind:20001 presence events over WebSocket.
  Future<void> _subscribePresenceUpdates() async {
    _presenceUnsub?.call();
    _presenceUnsub = null;
    _subscriptionVersion++;
    final version = _subscriptionVersion;

    final session = ref.read(relaySessionProvider.notifier);
    try {
      final unsub = await session.subscribe(
        const NostrFilter(kinds: [EventKind.presenceUpdate], limit: 0),
        _handlePresenceEvent,
      );
      // Guard: if build() re-fired while we were awaiting, discard this
      // subscription to avoid leaking it.
      if (version != _subscriptionVersion) {
        unsub();
        return;
      }
      _presenceUnsub = unsub;
    } catch (error) {
      debugPrint(
        '[PresenceCacheNotifier] presence subscription failed: $error',
      );
    }
  }

  void _handlePresenceEvent(NostrEvent event) {
    // Live events are self-signed: the subject is always the author.
    final pubkey = event.pubkey.toLowerCase();
    if (!_tracked.contains(pubkey)) return;
    final status = event.content;
    if (!_isPresenceStatus(status)) return;
    _lastLiveRevision[pubkey] = ++_revision;
    if (state[pubkey] == status) return;
    final updated = Map<String, String>.from(state);
    updated[pubkey] = status;
    state = updated;
  }
}

final presenceCacheProvider =
    NotifierProvider<PresenceCacheNotifier, Map<String, String>>(
      PresenceCacheNotifier.new,
    );
