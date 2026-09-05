import 'dart:convert';
import 'dart:io';

import 'package:buzz/shared/link_preview/link_preview_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Binds the production seam: `pinnedLinkPreviewHttpClient` must negotiate
/// TLS itself (a `connectionFactory` disables dart:io's own upgrade) and
/// must verify the certificate against the URL's host while connecting to
/// the resolved address. A local https server with a throwaway certificate
/// proves both; the certificate is minted per run because Apple's trust
/// evaluation refuses server certificates valid for more than 825 days,
/// which rules out a committed fixture.
late Directory _dir;
late String _certPath;
late String _keyPath;
late HttpServer _server;
var _requests = 0;

Future<void> _mintCertificate() async {
  final result = await Process.run('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    _keyPath,
    '-out',
    _certPath,
    '-days',
    '800',
    '-subj',
    '/CN=localhost',
    '-addext',
    'subjectAltName=DNS:localhost',
    '-addext',
    'extendedKeyUsage=serverAuth',
    '-addext',
    'basicConstraints=CA:FALSE',
  ]);
  if (result.exitCode != 0) {
    fail('openssl could not mint the test certificate: ${result.stderr}');
  }
}

Future<List<InternetAddress>> _loopbackByName(String host) async {
  final answers = await InternetAddress.lookup(host);
  return answers.where((a) => a.type == InternetAddressType.IPv4).toList();
}

http.Client _client(ResolveHostAddresses resolveHost) =>
    pinnedLinkPreviewHttpClient(
      resolveHost: resolveHost,
      securityContext: SecurityContext()..setTrustedCertificates(_certPath),
    );

void main() {
  setUpAll(() async {
    _dir = await Directory.systemTemp.createTemp('buzz-link-preview-tls');
    _certPath = '${_dir.path}/cert.pem';
    _keyPath = '${_dir.path}/key.pem';
    await _mintCertificate();
    _server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(_certPath)
        ..usePrivateKey(_keyPath),
    );
    _server.listen((request) {
      _requests += 1;
      request.response
        ..headers.contentType = ContentType.text
        ..write('ok');
      request.response.close();
    });
  });

  tearDownAll(() async {
    await _server.close(force: true);
    await _dir.delete(recursive: true);
  });

  test(
    'connects over TLS to the resolved address, verified as the URL host',
    () async {
      final asked = <String>[];
      final client = _client((host) {
        asked.add(host);
        return _loopbackByName(host);
      });
      addTearDown(client.close);
      final response = await client.get(
        Uri.parse('https://localhost:${_server.port}/page'),
      );
      expect(response.statusCode, 200);
      expect(utf8.decode(response.bodyBytes), 'ok');
      expect(asked, ['localhost']);
    },
  );

  test('an address without its name fails host verification', () async {
    // The same socket target, but the name TLS verifies against is now the
    // literal, which the certificate does not cover: the handshake fails.
    final client = _client((_) async => [InternetAddress('127.0.0.1')]);
    addTearDown(client.close);
    await expectLater(
      client.get(Uri.parse('https://localhost:${_server.port}/page')),
      throwsA(anyOf(isA<HandshakeException>(), isA<http.ClientException>())),
    );
  });

  test('plain http never opens a socket', () async {
    final before = _requests;
    final client = _client(_loopbackByName);
    addTearDown(client.close);
    await expectLater(
      client.get(Uri.parse('http://localhost:${_server.port}/page')),
      throwsA(anyOf(isA<SocketException>(), isA<http.ClientException>())),
    );
    expect(_requests, before);
  });

  test(
    'the default resolver refuses private answers and skips DNS for literals',
    () async {
      await expectLater(
        resolvePublicHostAddresses('localhost'),
        throwsA(isA<SocketException>()),
      );
      final literal = await resolvePublicHostAddresses('93.184.216.34');
      expect(literal.single.address, '93.184.216.34');
      await expectLater(
        resolvePublicHostAddresses('192.168.1.99'),
        throwsA(isA<SocketException>()),
      );
    },
  );
}
