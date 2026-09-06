import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'community_icon_provider.dart' show communityIconHttpClientProvider;

/// The name the relay's stock NIP-11 document carries when no community name
/// has been set. It describes the software, not the community, so it is never
/// adopted as one.
const relayDefaultName = 'Buzz Relay';

/// Reads the community's name from its public NIP-11 relay information
/// document (fork: `communities.name`, set by a relay admin with
/// `buzz community set-name` and served as the standard `name` field).
///
/// Nothing on the relay carried a community name before this, so every client
/// derived one from the relay host. A relay that answers with the stock
/// [relayDefaultName], an empty name, or no document at all yields `null`
/// and the stored name stays as it is. Uses the same HTTP client seam as the
/// icon lookup so tests can answer for the relay.
final communityRelayNameProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, relayUrl) async {
      final uri = relayInfoUri(relayUrl);
      if (uri == null) return null;

      try {
        final response = await ref
            .read(communityIconHttpClientProvider)
            .get(uri, headers: const {'Accept': 'application/nostr+json'})
            .timeout(const Duration(seconds: 5));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return null;
        }
        final document = jsonDecode(utf8.decode(response.bodyBytes));
        if (document is! Map<String, dynamic>) return null;
        return communityNameFromRelayInfo(document);
      } catch (_) {
        return null;
      }
    });

/// The community name a NIP-11 document advertises, or `null` when it only
/// carries the software's default (or nothing usable).
String? communityNameFromRelayInfo(Map<String, dynamic> document) {
  final name = document['name'];
  if (name is! String) return null;
  final trimmed = name.trim();
  if (trimmed.isEmpty || trimmed == relayDefaultName) return null;
  // The relay refuses control characters; a client-side guard keeps a
  // hostile or broken document from putting a newline in the sidebar.
  if (trimmed.runes.any((r) => r < 0x20 || (r >= 0x7f && r <= 0x9f))) {
    return null;
  }
  return trimmed;
}

/// The HTTP URL of a relay's NIP-11 document, or `null` for an unusable URL.
Uri? relayInfoUri(String relayUrl) {
  try {
    final uri = Uri.parse(relayUrl.trim());
    final scheme = switch (uri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      'https' || 'http' => uri.scheme,
      _ => null,
    };
    return scheme == null ? null : uri.replace(scheme: scheme);
  } on FormatException {
    return null;
  }
}
