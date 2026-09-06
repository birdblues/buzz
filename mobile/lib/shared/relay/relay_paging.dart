import 'package:flutter/foundation.dart';

import 'nostr_models.dart';
import 'relay_session.dart';

/// Page size for relay people listings (the empty-query kind:0 directory and
/// the prefix search behind it).
const relayDirectoryPageSize = 50;

/// Upper bound on pages one listing walks. 20 × [relayDirectoryPageSize] is
/// the relay's advertised NIP-11 `max_limit` (1000), so a listing can never
/// hold more than a single maximal query would.
const relayDirectoryMaxPages = 20;

/// Walks a bridge query page by page until the directory is exhausted.
///
/// The bridge honors a 1-based `page` extension on both the plain kind:0
/// listing and the search path (`extract_page_offset` / `extract_search_page`
/// in `crates/buzz-relay/src/api/bridge.rs`). Pages stop when one comes back
/// short, when a page adds nothing new (a relay that ignores `page` would
/// otherwise repeat its first page forever), or at [maxPages].
///
/// A failed page fails the whole listing. Returning the pages fetched so far
/// would turn a transport failure into an authoritative "complete" list; the
/// caller sees the error and keeps its retry.
Future<List<NostrEvent>> queryRelayPages(
  RelaySessionNotifier session,
  NostrFilter filter, {
  int maxPages = relayDirectoryMaxPages,
}) async {
  assert(filter.limit > 0, 'paging needs a positive page size');
  final collected = <NostrEvent>[];
  final seenIds = <String>{};
  for (var page = 1; page <= maxPages; page++) {
    final events = await session.queryRelay([
      filter.copyWith(extensions: {...filter.extensions, 'page': page}),
    ]);
    var added = 0;
    for (final event in events) {
      if (seenIds.add(event.id)) {
        collected.add(event);
        added++;
      }
    }
    if (events.length < filter.limit || added == 0) {
      return collected;
    }
  }
  debugPrint(
    'relay listing stopped at the $maxPages-page ceiling; '
    'later entries are not shown',
  );
  return collected;
}
