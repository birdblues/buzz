import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buzz/shared/link_preview/link_preview_fetcher.dart';
import 'package:buzz/shared/link_preview/link_preview_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:image/image.dart' as img;

final _public = InternetAddress('93.184.216.34');
final _private = InternetAddress('10.0.0.5');

Future<List<InternetAddress>> _resolve(String host) async {
  if (host == 'internal.example' || host == 'redirect-target.internal') {
    return [_private];
  }
  if (host == 'nowhere.example') return [];
  return [_public];
}

Future<SanitizedLinkPreviewImage?> _sanitize(
  Uint8List bytes,
  String mime, {
  bool preserveTransparency = false,
}) async => sanitizeLinkPreviewImage(
  bytes,
  mime,
  preserveTransparency: preserveTransparency,
);

Uint8List _png() {
  final image = img.Image(width: 4, height: 4);
  img.fill(image, color: image.getColor(10, 20, 30));
  return img.encodePng(image);
}

const _html = '''
<html><head>
<meta property="og:title" content="A page">
<meta property="og:site_name" content="Example">
<meta property="og:description" content="About the page">
<meta property="og:image" content="/cover.png">
<link rel="icon" type="image/png" href="/favicon.png">
</head></html>''';

LinkPreviewFetcher _fetcher(http_testing.MockClientHandler handler) =>
    LinkPreviewFetcher(
      client: http_testing.MockClient(handler),
      resolveHost: _resolve,
      sanitize: _sanitize,
    );

http.Response _htmlResponse([String body = _html]) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

http.Response _pngResponse() =>
    http.Response.bytes(_png(), 200, headers: {'content-type': 'image/png'});

void main() {
  group('isPublicAddress', () {
    test('rejects loopback, private, link-local, and reserved ranges', () {
      for (final ip in [
        '127.0.0.1',
        '0.0.0.0',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.99',
        '169.254.1.1',
        '100.64.0.1',
        '192.0.2.1',
        '192.88.99.1',
        '198.18.0.1',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '255.255.255.255',
        '::1',
        '::',
        'fe80::1',
        'fc00::1',
        'fd12::1',
        'ff02::1',
        '2001:db8::1',
        '::ffff:10.0.0.1',
        '64:ff9b::a00:1',
      ]) {
        expect(isPublicAddress(InternetAddress(ip)), isFalse, reason: ip);
      }
    });

    test('accepts global unicast', () {
      for (final ip in [
        '1.1.1.1',
        '8.8.8.8',
        '93.184.216.34',
        '2606:4700::1',
        '::ffff:1.1.1.1',
      ]) {
        expect(isPublicAddress(InternetAddress(ip)), isTrue, reason: ip);
      }
    });
  });

  group('LinkPreviewFetcher', () {
    test('captures metadata, image, and favicon from a page', () async {
      final requests = <Uri>[];
      final fetcher = _fetcher((request) async {
        requests.add(request.url);
        expect(request.headers['user-agent'], linkPreviewUserAgent);
        switch (request.url.path) {
          case '/post':
            return _htmlResponse();
          case '/cover.png':
          case '/favicon.png':
            return _pngResponse();
        }
        return http.Response('', 404);
      });

      final capture = await fetcher.fetch(
        Uri.parse('https://example.com/post'),
      );
      expect(capture, isNotNull);
      expect(capture!.metadata.title, 'A page');
      expect(capture.metadata.siteName, 'Example');
      expect(capture.metadata.description, 'About the page');
      expect(capture.image?.mimeType, 'image/jpeg');
      expect(capture.favicon, isNotNull);
      expect(
        requests.map((u) => u.path),
        containsAll(['/post', '/cover.png', '/favicon.png']),
      );
    });

    test(
      'refuses http, credentials, non-default ports, and private hosts',
      () async {
        var called = false;
        final fetcher = _fetcher((_) async {
          called = true;
          return _htmlResponse();
        });
        for (final url in [
          'http://example.com/post',
          'https://user:pw@example.com/post',
          'https://example.com:8443/post',
          'https://internal.example/post',
          'https://10.0.0.1/post',
          'https://nowhere.example/post',
        ]) {
          expect(await fetcher.fetch(Uri.parse(url)), isNull, reason: url);
        }
        expect(called, isFalse);
      },
    );

    test('follows redirects by hand and re-checks each hop', () async {
      final paths = <String>[];
      final fetcher = _fetcher((request) async {
        paths.add(request.url.toString());
        if (request.url.path == '/old') {
          return http.Response('', 301, headers: {'location': '/new'});
        }
        if (request.url.path == '/new') return _htmlResponse();
        if (request.url.path == '/leak') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://redirect-target.internal/x'},
          );
        }
        return http.Response('', 404);
      });

      final capture = await fetcher.fetch(Uri.parse('https://example.com/old'));
      expect(capture?.metadata.title, 'A page');
      expect(paths, contains('https://example.com/new'));

      expect(
        await fetcher.fetch(Uri.parse('https://example.com/leak')),
        isNull,
      );
      expect(paths, isNot(contains('https://redirect-target.internal/x')));
    });

    test('gives up after the redirect budget', () async {
      var hops = 0;
      final fetcher = _fetcher((request) async {
        hops += 1;
        return http.Response('', 302, headers: {'location': '/hop$hops'});
      });
      expect(await fetcher.fetch(Uri.parse('https://example.com/a')), isNull);
      expect(hops, linkPreviewMaxRedirects + 1);
    });

    test('ignores non-HTML and failed responses', () async {
      final fetcher = _fetcher((request) async {
        if (request.url.path == '/json') {
          return http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          _html,
          500,
          headers: {'content-type': 'text/html'},
        );
      });
      expect(
        await fetcher.fetch(Uri.parse('https://example.com/json')),
        isNull,
      );
      expect(await fetcher.fetch(Uri.parse('https://example.com/err')), isNull);
    });

    test('reads only the HTML prefix', () async {
      final tail = '<meta property="og:title" content="late">';
      final body = '<html>${' ' * linkPreviewMaxHtmlBytes}$tail';
      final fetcher = _fetcher((_) async => _htmlResponse(body));
      expect(await fetcher.fetch(Uri.parse('https://example.com/big')), isNull);
    });

    test(
      'drops an image whose type or size is wrong but keeps the text',
      () async {
        final fetcher = _fetcher((request) async {
          switch (request.url.path) {
            case '/post':
              return _htmlResponse();
            case '/cover.png':
              return http.Response.bytes(
                _png(),
                200,
                headers: {'content-type': 'image/svg+xml'},
              );
            case '/favicon.png':
              return http.Response.bytes(
                Uint8List(linkPreviewMaxImageBytes + 1),
                200,
                headers: {'content-type': 'image/png'},
              );
          }
          return http.Response('', 404);
        });
        final capture = await fetcher.fetch(
          Uri.parse('https://example.com/post'),
        );
        expect(capture?.metadata.title, 'A page');
        expect(capture?.image, isNull);
        expect(capture?.favicon, isNull);
      },
    );

    test('previews YouTube videos through oEmbed', () async {
      final paths = <String>[];
      final fetcher = _fetcher((request) async {
        paths.add(request.url.toString());
        if (request.url.host == 'www.youtube.com' &&
            request.url.path == '/oembed') {
          expect(request.url.queryParameters['url'], 'https://youtu.be/abc123');
          return http.Response(
            jsonEncode({
              'title': 'A video',
              'author_name': 'Channel',
              'thumbnail_url': 'https://i.ytimg.com/vi/abc123/hqdefault.jpg',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.host == 'i.ytimg.com') return _pngResponse();
        return http.Response('', 404);
      });
      final capture = await fetcher.fetch(Uri.parse('https://youtu.be/abc123'));
      expect(capture?.metadata.title, 'A video');
      expect(capture?.metadata.siteName, 'YouTube');
      expect(capture?.metadata.description, 'Channel');
      expect(capture?.image, isNotNull);
      expect(paths.any((p) => p.startsWith('https://youtu.be/')), isFalse);
    });

    test('never throws', () async {
      final fetcher = _fetcher(
        (_) async => throw const SocketException('down'),
      );
      expect(
        await fetcher.fetch(Uri.parse('https://example.com/post')),
        isNull,
      );
    });
  });
}
