import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;

import 'relay_provider.dart';
import 'relay_session.dart';

/// HTTP client for NIP-11 relay-information lookups. Override in tests.
final relayInfoHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Accepts an advertised app-content origin only when it is a bare http(s)
/// origin on the **same hostname** as the relay and a different origin from
/// the relay itself. Mirrors desktop `validate_app_content_url`: a relay may
/// point at one of its own ports, never at a third party that would then
/// receive a token signed with the user's key. Returns the origin without a
/// trailing slash.
String? validateAppContentUrl(String advertised, String relayBaseUrl) {
  final trimmed = advertised.trim();
  final app = Uri.tryParse(trimmed);
  final relay = Uri.tryParse(relayBaseUrl);
  if (app == null || relay == null) return null;
  if (app.scheme != 'http' && app.scheme != 'https') return null;
  if (app.userInfo.isNotEmpty || app.hasQuery || app.hasFragment) return null;
  if (app.path.isNotEmpty && app.path != '/') return null;
  if (app.host.isEmpty || relay.host.isEmpty) return null;
  if (app.host.toLowerCase() != relay.host.toLowerCase()) return null;
  // Same host, same scheme and port would just be the relay itself, which
  // never serves the app door. Require a distinct origin.
  if (app.scheme == relay.scheme && app.port == relay.port) return null;
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// Reads `app_content_url` from the relay's NIP-11 document and validates it
/// against [relayBaseUrl]. Null when the relay does not advertise a door, the
/// value fails validation, or the document cannot be read.
Future<String?> fetchAppContentUrl(
  String relayBaseUrl, {
  required http.Client client,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final base = Uri.tryParse(relayBaseUrl);
  if (base == null ||
      (base.scheme != 'http' && base.scheme != 'https') ||
      base.host.isEmpty) {
    return null;
  }
  final response = await client
      .get(
        base.resolve('/'),
        headers: const {'Accept': 'application/nostr+json'},
      )
      .timeout(timeout);
  if (response.statusCode != 200) return null;
  final document = jsonDecode(utf8.decode(response.bodyBytes));
  if (document is! Map<String, dynamic>) return null;
  final advertised = document['app_content_url'];
  if (advertised is! String) return null;
  return validateAppContentUrl(advertised, relayBaseUrl);
}

/// One NIP-11 answer, remembered together with the relay it came from so a
/// community switch can never reuse another relay's door.
@immutable
class AppContentDiscovery {
  final String relayBaseUrl;
  final String? appContentUrl;

  const AppContentDiscovery({
    required this.relayBaseUrl,
    required this.appContentUrl,
  });
}

final appContentDiscoveryProvider = FutureProvider<AppContentDiscovery>((
  ref,
) async {
  final baseUrl = ref.watch(relayConfigProvider).baseUrl;
  final client = ref.watch(relayInfoHttpClientProvider);
  // Ask again whenever the session (re)connects: a relay that was unreachable
  // at launch, or restarted with the door switched on, is picked up without
  // polling. The previous answer stays visible while the new one loads.
  ref.listen(relaySessionProvider, (previous, next) {
    if (next.status == SessionStatus.connected &&
        previous?.status != SessionStatus.connected) {
      ref.invalidateSelf();
    }
  });
  String? appContentUrl;
  try {
    appContentUrl = await fetchAppContentUrl(baseUrl, client: client);
  } catch (error) {
    debugPrint('NIP-11 app_content_url lookup failed: $error');
  }
  return AppContentDiscovery(
    relayBaseUrl: baseUrl,
    appContentUrl: appContentUrl,
  );
});

/// The relay's app-content origin, or null while unknown or when the relay
/// does not serve sandboxed apps. HTML attachments render as plain links
/// whenever this is null — the fail-closed default.
final appContentUrlProvider = Provider<String?>((ref) {
  final baseUrl = ref.watch(relayConfigProvider).baseUrl;
  final discovery = ref.watch(appContentDiscoveryProvider).value;
  if (discovery == null || discovery.relayBaseUrl != baseUrl) return null;
  return discovery.appContentUrl;
});

/// `{appContentUrl}/app/{sha256}.html` — the only URL the sandbox page loads.
Uri appContentUri(String appContentUrl, String sha256) =>
    Uri.parse('$appContentUrl/app/$sha256.html');
