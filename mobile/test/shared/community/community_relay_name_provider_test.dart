import 'dart:convert';

import 'package:buzz/shared/community/community_icon_provider.dart';
import 'package:buzz/shared/community/community_relay_name_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  Future<String?> readName(String relayUrl, http.Client client) {
    final container = ProviderContainer(
      overrides: [communityIconHttpClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    return container.read(communityRelayNameProvider(relayUrl).future);
  }

  test('reads the community name from the NIP-11 document', () async {
    late http.Request captured;
    final client = http_testing.MockClient((request) async {
      captured = request;
      // Bytes, not code units: the relay answers UTF-8 and the provider
      // must decode it as such for a Korean name to survive.
      return http.Response.bytes(
        utf8.encode('{"name":"슈퍼지구","icon":"data:image/png;base64,x"}'),
        200,
      );
    });

    final name = await readName('ws://192.168.1.99:3000', client);

    expect(captured.url, Uri.parse('http://192.168.1.99:3000'));
    expect(captured.headers['Accept'], 'application/nostr+json');
    expect(name, '슈퍼지구');
  });

  test('never adopts the relay software default or an empty name', () async {
    for (final body in ['{"name":"Buzz Relay"}', '{"name":""}', '{}']) {
      final client = http_testing.MockClient(
        (_) async => http.Response(body, 200),
      );
      expect(await readName('wss://relay.example.com', client), isNull);
    }
  });

  test('is null when the relay cannot be read', () async {
    final client = http_testing.MockClient(
      (_) async => http.Response('unavailable', 503),
    );
    expect(await readName('wss://relay.example.com', client), isNull);
  });

  group('communityNameFromRelayInfo', () {
    test('trims and keeps unicode', () {
      expect(communityNameFromRelayInfo({'name': '  슈퍼지구  '}), '슈퍼지구');
      expect(
        communityNameFromRelayInfo({'name': 'Team — Buzz'}),
        'Team — Buzz',
      );
    });

    test(
      'rejects the default, blanks, non-strings, and control characters',
      () {
        expect(communityNameFromRelayInfo({'name': relayDefaultName}), isNull);
        expect(communityNameFromRelayInfo({'name': '   '}), isNull);
        expect(communityNameFromRelayInfo({'name': 42}), isNull);
        expect(communityNameFromRelayInfo({'name': 'two\nlines'}), isNull);
        expect(communityNameFromRelayInfo({'name': 'c1x'}), isNull);
        expect(communityNameFromRelayInfo({}), isNull);
      },
    );
  });

  test('relayInfoUri maps the websocket scheme to HTTP', () {
    expect(
      relayInfoUri('wss://relay.example.com'),
      Uri.parse('https://relay.example.com'),
    );
    expect(
      relayInfoUri('ws://192.168.1.99:3000'),
      Uri.parse('http://192.168.1.99:3000'),
    );
    expect(relayInfoUri('ftp://relay.example.com'), isNull);
  });
}
