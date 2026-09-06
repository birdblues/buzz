import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;

import '../auth/auth_provider.dart';
import '../relay/relay.dart';

/// NIP-IA identity archival (`docs/nips/NIP-IA.md`), client side.
///
/// The relay signs a replaceable `kind:13535` snapshot listing every identity
/// it has archived — retired agent keys, rotated keys, spam. Clients hide those
/// pubkeys from forward-looking discovery (New message, Add members, invites,
/// mention autocomplete, people search) and fold them in member lists, but
/// never rewrite history: old DMs, messages and reactions keep their author.
/// Mirrors desktop `features/identity-archive/hooks.ts`.

/// The pubkeys the latest valid snapshot in [events] archives, lowercase hex.
///
/// Only a `kind:13535` authored by [relaySelf] — the relay's NIP-11 `self`
/// pubkey — counts. The newest `created_at` wins; a same-second tie goes to
/// the lexically lowest id (NIP-01). With [verifySignature] the snapshot's
/// id and Schnorr signature are checked too: relay state the client cannot
/// verify is treated as absent, never as authoritative.
Set<String> archivedIdentityPubkeysFromSnapshot(
  List<NostrEvent> events, {
  required String relaySelf,
  bool verifySignature = true,
}) {
  final signer = relaySelf.toLowerCase();
  NostrEvent? snapshot;
  for (final event in events) {
    if (event.kind != EventKind.identityArchivedList) continue;
    if (event.pubkey.toLowerCase() != signer) continue;
    if (snapshot == null ||
        event.createdAt > snapshot.createdAt ||
        (event.createdAt == snapshot.createdAt &&
            event.id.compareTo(snapshot.id) < 0)) {
      snapshot = event;
    }
  }
  if (snapshot == null) return const {};
  if (verifySignature && !_hasValidSignature(snapshot)) return const {};
  return {
    for (final tag in snapshot.tags)
      if (tag.length >= 2 && tag[0] == 'p' && _isHexPubkey(tag[1]))
        tag[1].toLowerCase(),
  };
}

bool _hasValidSignature(NostrEvent event) {
  try {
    return nostr.Event.fromMap(event.toJson(), verify: false).isValid();
  } catch (_) {
    return false;
  }
}

final _hexPubkey = RegExp(r'^[0-9a-fA-F]{64}$');

bool _isHexPubkey(String value) => _hexPubkey.hasMatch(value);

/// The active relay's archive set.
///
/// Fail-open by design: the set is empty while the relay's `self` pubkey is
/// unknown, while the session has never connected, when the query fails, and
/// when the snapshot does not verify. Hiding nobody is the safe failure — a
/// cold start or a flaky relay must never make everyone disappear. Refetched
/// on reconnect and whenever the relay configuration changes; people pickers
/// refresh it explicitly when they open.
final archivedIdentitiesProvider = FutureProvider<Set<String>>((ref) async {
  ref.watch(relayConfigProvider);
  final session = ref.watch(relaySessionProvider.notifier);
  ref.listen(relaySessionProvider, (previous, next) {
    if (next.status == SessionStatus.connected &&
        previous?.status != SessionStatus.connected) {
      ref.invalidateSelf();
    }
  });
  if (ref.read(relaySessionProvider).status != SessionStatus.connected) {
    return const {};
  }
  final String? relaySelf;
  try {
    relaySelf = await ref.watch(relaySelfPubkeyProvider.future);
  } catch (error) {
    debugPrint('NIP-IA: relay self lookup failed: $error');
    return const {};
  }
  if (relaySelf == null) return const {};
  try {
    final events = await session.queryRelay([
      NostrFilters.archivedIdentities(relaySelf),
    ]);
    return archivedIdentityPubkeysFromSnapshot(events, relaySelf: relaySelf);
  } catch (error) {
    debugPrint('NIP-IA: archive snapshot lookup failed: $error');
    return const {};
  }
});

/// Answers "is this pubkey hidden from discovery on the active relay?".
///
/// Self-exempt by construction: the signed-in user is never hidden from their
/// own client, even when archived. NIP-IA §Self Requests makes archival
/// deliberately non-silent — the archived user has to see it to ask for
/// self-unarchive — and hiding self would build exactly the shadowban the
/// NIP prevents. The exemption lives here so no caller can forget it.
@immutable
class ArchivedIdentityFilter {
  final Set<String> archived;
  final String? selfPubkey;

  const ArchivedIdentityFilter({
    required this.archived,
    required this.selfPubkey,
  });

  /// Hides nobody — the fail-open answer while the snapshot loads.
  static const none = ArchivedIdentityFilter(archived: {}, selfPubkey: null);

  bool get hidesNobody => archived.isEmpty;

  bool hides(String pubkey) {
    final normalized = pubkey.toLowerCase();
    if (normalized == selfPubkey) return false;
    return archived.contains(normalized);
  }

  /// [items] minus the ones [hides], keyed by [pubkeyOf].
  List<T> without<T>(Iterable<T> items, String Function(T item) pubkeyOf) => [
    for (final item in items)
      if (!hides(pubkeyOf(item))) item,
  ];
}

/// The signed-in identity the filter exempts: the signing key, else the
/// active community's credential pubkey.
final _archiveSelfPubkeyProvider = Provider<String?>((ref) {
  final signing = ref.watch(myPubkeyProvider);
  if (signing != null) return signing.toLowerCase();
  final credential = ref.watch(authProvider).value?.community?.pubkey?.trim();
  if (credential != null && credential.isNotEmpty) {
    return credential.toLowerCase();
  }
  return null;
});

/// The discovery filter for the active relay.
///
/// Await `.future` where the first render should already be folded (the
/// people pickers do); read `.value` where a list is already on screen and
/// may fold once the snapshot lands — it is [ArchivedIdentityFilter.none]
/// until then, so loading never hides anyone.
final archivedIdentityFilterProvider = FutureProvider<ArchivedIdentityFilter>((
  ref,
) async {
  final selfPubkey = ref.watch(_archiveSelfPubkeyProvider);
  final archived = await ref.watch(archivedIdentitiesProvider.future);
  return ArchivedIdentityFilter(archived: archived, selfPubkey: selfPubkey);
});
