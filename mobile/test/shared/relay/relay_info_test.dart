import 'dart:convert';

import 'package:buzz/shared/relay/relay_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

const _relay = 'http://192.168.1.99:3000';
const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  group('validateAppContentUrl', () {
    test('accepts a bare origin on the relay host with another port', () {
      expect(
        validateAppContentUrl('http://192.168.1.99:3001/', _relay),
        'http://192.168.1.99:3001',
      );
      expect(
        validateAppContentUrl(' HTTP://192.168.1.99:3001 ', _relay),
        'HTTP://192.168.1.99:3001',
      );
      expect(
        validateAppContentUrl('https://192.168.1.99:3000', _relay),
        'https://192.168.1.99:3000',
        reason: 'same port but a different scheme is a distinct origin',
      );
    });

    test('rejects other hosts, the relay itself, and anything non-bare', () {
      for (final bad in [
        'http://evil.example:3001', // other host
        'http://192.168.1.99:3000', // the relay itself
        'http://192.168.1.99:3001/x', // path
        'http://192.168.1.99:3001/?q', // query
        'http://192.168.1.99:3001/#f', // fragment
        'http://u:p@192.168.1.99:3001', // credentials
        'ws://192.168.1.99:3001', // scheme
        '192.168.1.99:3001', // not a URL
        '',
      ]) {
        expect(validateAppContentUrl(bad, _relay), isNull, reason: bad);
      }
    });

    test('treats default ports as the relay origin', () {
      expect(
        validateAppContentUrl(
          'https://relay.example.com',
          'https://relay.example.com:443',
        ),
        isNull,
      );
      expect(
        validateAppContentUrl(
          'https://relay.example.com:8443',
          'https://relay.example.com',
        ),
        'https://relay.example.com:8443',
      );
    });
  });

  group('fetchAppContentUrl', () {
    test('reads and validates app_content_url from NIP-11', () async {
      late http.Request seen;
      final client = http_testing.MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'name': 'buzz',
            'app_content_url': 'http://192.168.1.99:3001',
          }),
          200,
          headers: {'content-type': 'application/nostr+json'},
        );
      });
      expect(
        await fetchAppContentUrl(_relay, client: client),
        'http://192.168.1.99:3001',
      );
      expect(seen.url, Uri.parse('$_relay/'));
      expect(seen.headers['Accept'], 'application/nostr+json');
    });

    test('is null without a door or with an invalid one', () async {
      Future<String?> withDocument(Map<String, Object?> document) {
        return fetchAppContentUrl(
          _relay,
          client: http_testing.MockClient(
            (_) async => http.Response(jsonEncode(document), 200),
          ),
        );
      }

      expect(await withDocument({'name': 'buzz'}), isNull);
      expect(await withDocument({'app_content_url': 42}), isNull);
      expect(
        await withDocument({'app_content_url': 'http://evil.example:3001'}),
        isNull,
      );
    });

    test('is null on a non-200 answer or a non-http relay URL', () async {
      final client = http_testing.MockClient(
        (_) async => http.Response('nope', 503),
      );
      expect(await fetchAppContentUrl(_relay, client: client), isNull);
      expect(await fetchAppContentUrl('not a url', client: client), isNull);
    });
  });

  group('relaySelfFromRelayInfo', () {
    const self =
        '3ac253597655d56103bf79071cf108d75a784f7d0d6ca2073fe4722699d47561';

    test('reads a well-formed self pubkey, normalized to lowercase', () {
      expect(relaySelfFromRelayInfo({'self': self.toUpperCase()}), self);
      expect(relaySelfFromRelayInfo({'self': ' $self '}), self);
    });

    test('is null when self is absent or malformed', () {
      expect(relaySelfFromRelayInfo(null), isNull);
      expect(relaySelfFromRelayInfo({}), isNull);
      expect(relaySelfFromRelayInfo({'self': 42}), isNull);
      expect(relaySelfFromRelayInfo({'self': 'npub1abc'}), isNull);
      expect(relaySelfFromRelayInfo({'self': self.substring(1)}), isNull);
    });
  });

  group('fetchRelaySelfPubkey', () {
    const self =
        '3ac253597655d56103bf79071cf108d75a784f7d0d6ca2073fe4722699d47561';

    test('reads self from the NIP-11 document', () async {
      Uri? requested;
      String? accept;
      final client = http_testing.MockClient((request) async {
        requested = request.url;
        accept = request.headers['Accept'];
        return http.Response(jsonEncode({'self': self}), 200);
      });

      expect(await fetchRelaySelfPubkey(_relay, client: client), self);
      expect(requested, Uri.parse('$_relay/'));
      expect(accept, 'application/nostr+json');
    });

    test('is null on a non-200 answer or a document without self', () async {
      expect(
        await fetchRelaySelfPubkey(
          _relay,
          client: http_testing.MockClient(
            (_) async => http.Response('nope', 503),
          ),
        ),
        isNull,
      );
      expect(
        await fetchRelaySelfPubkey(
          _relay,
          client: http_testing.MockClient(
            (_) async => http.Response(jsonEncode({'name': 'Buzz'}), 200),
          ),
        ),
        isNull,
      );
    });
  });

  test('appContentUri targets the app door path', () {
    expect(
      appContentUri('http://192.168.1.99:3001', _sha),
      Uri.parse('http://192.168.1.99:3001/app/$_sha.html'),
    );
  });
}
