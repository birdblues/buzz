import 'package:buzz/shared/community/community.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Community.nameFromUrl', () {
    test('takes the first label of a subdomain', () {
      expect(Community.nameFromUrl('wss://buzz.example.com'), 'buzz');
      expect(Community.nameFromUrl('wss://relay.buzz.example.com'), 'relay');
    });

    test('keeps a bare domain whole', () {
      expect(Community.nameFromUrl('wss://example.com'), 'example.com');
      expect(Community.nameFromUrl('https://relay.test'), 'relay.test');
    });

    test('never splits an IP address', () {
      // Used to come out as "192": the octets looked like subdomain labels.
      expect(Community.nameFromUrl('ws://192.168.1.99:3000'), '192.168.1.99');
      expect(Community.nameFromUrl('ws://10.0.0.7'), '10.0.0.7');
      expect(Community.nameFromUrl('ws://[fe80::1]:3000'), 'fe80::1');
    });

    test('labels loopback as the local dev relay', () {
      expect(Community.nameFromUrl('ws://localhost:3000'), 'Local Dev');
      expect(Community.nameFromUrl('ws://127.0.0.1:3000'), 'Local Dev');
    });

    test('falls back on an unparseable URL', () {
      expect(Community.nameFromUrl('::not a url::'), 'Community');
    });
  });

  group('Community.fromJson name migration', () {
    Community read(String name, String relayUrl) => Community.fromJson({
      'id': 'one',
      'name': name,
      'relayUrl': relayUrl,
      'addedAt': '2026-08-05T00:00:00.000Z',
    });

    test('replaces the first-octet name an older build stored', () {
      expect(read('192', 'ws://192.168.1.99:3000').name, '192.168.1.99');
    });

    test('keeps a name the user or an invite chose', () {
      expect(read('슈퍼지구', 'ws://192.168.1.99:3000').name, '슈퍼지구');
      expect(read('buzz', 'wss://buzz.example.com').name, 'buzz');
      // A domain's first label is a legitimate derivation, not the bug.
      expect(read('relay', 'wss://relay.example.com').name, 'relay');
    });

    test('round-trips through toJson unchanged', () {
      final community = read('192.168.1.99', 'ws://192.168.1.99:3000');
      expect(Community.fromJson(community.toJson()).name, '192.168.1.99');
    });
  });
}
