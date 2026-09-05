import 'dart:async';
import 'dart:convert';

import 'package:buzz/shared/relay/app_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

const _meta =
    '<meta http-equiv="Content-Security-Policy" content="$appSandboxCsp">';
final _uri = Uri.parse('http://192.168.1.99:3001/app/${'a' * 64}.html');
const _headers = {'Authorization': 'Nostr abc'};

void main() {
  group('stampSandboxCsp', () {
    test('goes right after a leading doctype so standards mode survives', () {
      expect(
        stampSandboxCsp('<!DOCTYPE html><html><head></head></html>'),
        '<!DOCTYPE html>$_meta<html><head></head></html>',
      );
      expect(
        stampSandboxCsp('\n  <!doctype HTML>\n<html>'),
        '\n  <!doctype HTML>$_meta\n<html>',
      );
    });

    test('skips leading comments but nothing else', () {
      expect(
        stampSandboxCsp('<!-- x --> <!DOCTYPE html><p>hi'),
        '<!-- x --> <!DOCTYPE html>$_meta<p>hi',
      );
      // A script before the doctype must not run ahead of the policy.
      expect(
        stampSandboxCsp('<script>1</script><!DOCTYPE html>'),
        '$_meta<script>1</script><!DOCTYPE html>',
      );
    });

    test('leads a document without a doctype', () {
      expect(stampSandboxCsp('<html><body>x'), '$_meta<html><body>x');
      expect(stampSandboxCsp(''), _meta);
    });

    test('the policy has no sandbox directive and no network source', () {
      expect(appSandboxCsp, isNot(contains('sandbox')));
      expect(appSandboxCsp, contains("default-src 'none'"));
      expect(appSandboxCsp, contains("connect-src 'none'"));
      expect(appSandboxCsp, contains("form-action 'none'"));
      expect(appSandboxCsp, contains("base-uri 'none'"));
      expect(appSandboxCsp, isNot(contains('http')));
    });
  });

  group('fetchAppDocument', () {
    test(
      'returns the document and forwards the token without redirects',
      () async {
        late http.Request seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            '<!DOCTYPE html><p>안녕</p>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        });
        expect(
          await fetchAppDocument(_uri, headers: _headers, client: client),
          '<!DOCTYPE html><p>안녕</p>',
        );
        expect(seen.method, 'GET');
        expect(seen.url, _uri);
        expect(seen.headers['Authorization'], 'Nostr abc');
        expect(seen.followRedirects, isFalse);
      },
    );

    test('treats a redirect as a failure instead of following it', () async {
      final client = http_testing.MockClient(
        (_) async => http.Response(
          '',
          302,
          headers: {'location': 'https://evil.example/collect'},
        ),
      );
      expect(
        () => fetchAppDocument(_uri, headers: _headers, client: client),
        throwsA(
          isA<AppContentFetchException>().having(
            (e) => e.statusCode,
            'statusCode',
            302,
          ),
        ),
      );
    });

    test('surfaces the relay status code', () async {
      for (final status in [401, 403, 404, 413]) {
        final client = http_testing.MockClient(
          (_) async => http.Response('no', status),
        );
        expect(
          () => fetchAppDocument(_uri, headers: _headers, client: client),
          throwsA(
            isA<AppContentFetchException>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
          reason: '$status',
        );
      }
    });

    test('refuses non-HTML bodies', () async {
      final client = http_testing.MockClient(
        (_) async =>
            http.Response('PNG', 200, headers: {'content-type': 'image/png'}),
      );
      expect(
        () => fetchAppDocument(_uri, headers: _headers, client: client),
        throwsA(isA<AppContentFetchException>()),
      );
    });

    test('refuses documents over the size cap, declared or streamed', () async {
      final declared = http_testing.MockClient(
        (_) async =>
            http.Response('xx', 200, headers: {'content-type': 'text/html'}),
      );
      expect(
        () => fetchAppDocument(
          _uri,
          headers: _headers,
          client: declared,
          maxBytes: 1,
        ),
        throwsA(isA<AppContentFetchException>()),
      );

      final streamed = http_testing.MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          Stream.fromIterable([utf8.encode('abc'), utf8.encode('def')]),
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      expect(
        () => fetchAppDocument(
          _uri,
          headers: _headers,
          client: streamed,
          maxBytes: 4,
        ),
        throwsA(isA<AppContentFetchException>()),
      );
      expect(
        await fetchAppDocument(
          _uri,
          headers: _headers,
          client: streamed,
          maxBytes: 6,
        ),
        'abcdef',
      );
    });

    test('times out instead of hanging on a silent relay', () async {
      final client = http_testing.MockClient(
        (_) => Completer<http.Response>().future,
      );
      expect(
        () => fetchAppDocument(
          _uri,
          headers: _headers,
          client: client,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
