import 'dart:convert';

import 'package:buzz/shared/relay/media_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;

const _relayBase = 'https://relay.example.com';
const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, dynamic> _decode(Map<String, String> headers) {
  final token = headers['Authorization']!;
  expect(token, startsWith('Nostr '));
  final payload = token.substring('Nostr '.length);
  final json = utf8.decode(base64Url.decode(base64Url.normalize(payload)));
  return jsonDecode(json) as Map<String, dynamic>;
}

void main() {
  group('signAppContentAuth', () {
    test('mints a blob-scoped 300 s token without a server tag', () {
      final keys = nostr.Keys.generate();
      final now = DateTime.utc(2026, 9, 5, 12);
      final auth = MediaGetAuthService(
        baseUrl: _relayBase,
        nsec: keys.nsec,
        now: () => now,
      );

      final event = _decode(auth.signAppContentAuth(_sha)!);
      expect(event['kind'], 24242);
      expect(event['pubkey'], keys.public);
      expect(event['content'], 'Get buzz-app');
      final tags = (event['tags'] as List).cast<List>();
      expect(tags, contains(equals(['t', 'get'])));
      expect(tags, contains(equals(['x', _sha])));
      expect(
        tags,
        contains(
          equals([
            'expiration',
            '${now.millisecondsSinceEpoch ~/ 1000 + appContentAuthLifetimeSeconds}',
          ]),
        ),
      );
      expect(tags.any((tag) => tag.first == 'server'), isFalse);
      expect(appContentAuthLifetimeSeconds, 300);
    });

    test('is never memoized: each call reflects the current clock', () {
      var now = DateTime.utc(2026, 9, 5, 12);
      final auth = MediaGetAuthService(
        baseUrl: _relayBase,
        nsec: nostr.Keys.generate().nsec,
        now: () => now,
      );
      final first = _decode(auth.signAppContentAuth(_sha)!);
      now = now.add(const Duration(minutes: 11));
      final second = _decode(auth.signAppContentAuth(_sha)!);
      String expiration(Map<String, dynamic> event) =>
          (event['tags'] as List).cast<List>().firstWhere(
                (tag) => tag.first == 'expiration',
              )[1]
              as String;
      expect(
        int.parse(expiration(second)) - int.parse(expiration(first)),
        11 * 60,
      );
    });

    test('refuses to sign without a key or for a malformed hash', () {
      expect(
        MediaGetAuthService(
          baseUrl: _relayBase,
          nsec: null,
        ).signAppContentAuth(_sha),
        isNull,
      );
      final auth = MediaGetAuthService(
        baseUrl: _relayBase,
        nsec: nostr.Keys.generate().nsec,
      );
      expect(auth.signAppContentAuth(_sha.toUpperCase()), isNull);
      expect(auth.signAppContentAuth('deadbeef'), isNull);
      expect(auth.signAppContentAuth('${_sha}0'), isNull);
    });

    test('leaves the server-scoped media header untouched', () {
      final auth = MediaGetAuthService(
        baseUrl: _relayBase,
        nsec: nostr.Keys.generate().nsec,
      );
      final media = _decode(auth.headersFor('$_relayBase/media/abc.png'));
      final tags = (media['tags'] as List).cast<List>();
      expect(tags.any((tag) => tag.first == 'server'), isTrue);
      expect(tags.any((tag) => tag.first == 'x'), isFalse);
    });
  });
}
