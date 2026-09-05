import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'link_preview_image.dart';
import 'link_preview_metadata.dart';
import 'link_preview_youtube.dart';

/// Fetches what a link preview is authored from (`docs/link-previews.md`).
///
/// This runs on the sender's device and talks to the linked site once, the
/// way the desktop native command does — with the same guard rails, because
/// the URL comes from the message body and the response from a stranger:
///
/// * https only, no credentials, default port; the host must resolve to
///   public addresses (no loopback, private, link-local, or reserved ranges),
///   and the connection is pinned to those addresses so a DNS answer cannot
///   change between the check and the connect;
/// * redirects are followed by hand (at most [linkPreviewMaxRedirects]),
///   each hop re-checked;
/// * bodies are bounded ([linkPreviewMaxHtmlBytes] of HTML,
///   [linkPreviewMaxImageBytes] per image) and every request has a timeout;
/// * images are re-encoded through [sanitizeLinkPreviewImage]; the raw
///   bytes never reach the relay.
const linkPreviewMaxHtmlBytes = 256 * 1024;
const linkPreviewMaxOEmbedBytes = 64 * 1024;
const linkPreviewRequestTimeout = Duration(seconds: 4);
const linkPreviewTotalTimeout = Duration(seconds: 10);
const linkPreviewMaxRedirects = 3;
const linkPreviewUserAgent = 'Buzz Mobile link preview';

typedef ResolveHostAddresses = Future<List<InternetAddress>> Function(String);
typedef SanitizeLinkPreviewImage =
    Future<SanitizedLinkPreviewImage?> Function(
      Uint8List bytes,
      String declaredMimeType, {
      bool preserveTransparency,
    });

/// Everything a snapshot tag needs, before upload.
@immutable
class LinkPreviewCapture {
  final LinkPreviewMetadata metadata;
  final SanitizedLinkPreviewImage? image;
  final SanitizedLinkPreviewImage? favicon;

  const LinkPreviewCapture({required this.metadata, this.image, this.favicon});
}

/// Thrown for a URL the fetcher must not contact.
class LinkPreviewRejected implements Exception {
  final String message;

  const LinkPreviewRejected(this.message);

  @override
  String toString() => 'LinkPreviewRejected: $message';
}

bool _isPublicV4(List<int> b) {
  final a = b[0];
  final c = b[1];
  if (a == 0 || a == 10 || a == 127) return false;
  if (a == 100 && (c & 0xc0) == 64) return false; // 100.64.0.0/10
  if (a == 169 && c == 254) return false;
  if (a == 172 && (c & 0xf0) == 16) return false;
  if (a == 192 && c == 168) return false;
  if (a == 192 && c == 0 && (b[2] == 0 || b[2] == 2)) return false;
  if (a == 198 && (c == 18 || c == 19)) return false;
  if (a == 198 && c == 51 && b[2] == 100) return false;
  if (a == 203 && c == 0 && b[2] == 113) return false;
  if (a >= 224) return false; // multicast, reserved, broadcast
  return true;
}

/// Whether [address] is global unicast: the only kind a preview may contact.
bool isPublicAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes.length == 4 && _isPublicV4(bytes);
  }
  if (bytes.length != 16) return false;
  bool zeros(int from, int to) {
    for (var i = from; i < to; i++) {
      if (bytes[i] != 0) return false;
    }
    return true;
  }

  if (zeros(0, 10) && bytes[10] == 0xff && bytes[11] == 0xff) {
    return _isPublicV4(bytes.sublist(12)); // ::ffff:a.b.c.d
  }
  if (bytes[0] == 0 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xff &&
      bytes[3] == 0x9b &&
      zeros(4, 12)) {
    return _isPublicV4(bytes.sublist(12)); // 64:ff9b::/96 (NAT64)
  }
  if (zeros(0, 16)) return false; // ::
  if ((bytes[0] & 0xfe) == 0xfc) return false; // fc00::/7
  if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return false; // fe80::/10
  if (bytes[0] == 0xff) return false; // ff00::/8
  if (bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x0d &&
      bytes[3] == 0xb8) {
    return false; // 2001:db8::/32
  }
  if (bytes[0] == 0x01 && zeros(1, 8)) return false; // 100::/64
  return true;
}

Future<List<InternetAddress>> lookupHostAddresses(String host) =>
    InternetAddress.lookup(host);

/// An HTTP client whose every connection goes to an address that passed
/// [isPublicAddress] at connect time, so the resolution the fetcher checked
/// is the one the socket uses. TLS still validates against the URL's host.
http.Client pinnedLinkPreviewHttpClient({
  ResolveHostAddresses resolveHost = lookupHostAddresses,
}) {
  final inner = HttpClient()
    ..connectionTimeout = linkPreviewRequestTimeout
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (url, proxyHost, proxyPort) async {
      final addresses = await resolveHost(url.host);
      final address = addresses.firstWhere(
        isPublicAddress,
        orElse: () => throw const SocketException(
          'link preview host did not resolve to a public address',
        ),
      );
      return Socket.startConnect(address, url.port);
    };
  return IOClient(inner);
}

final linkPreviewFetcherProvider = Provider<LinkPreviewFetcher>((ref) {
  final client = pinnedLinkPreviewHttpClient();
  ref.onDispose(client.close);
  return LinkPreviewFetcher(client: client);
});

class LinkPreviewFetcher {
  final http.Client _client;
  final ResolveHostAddresses _resolveHost;
  final SanitizeLinkPreviewImage _sanitize;

  LinkPreviewFetcher({
    required http.Client client,
    ResolveHostAddresses resolveHost = lookupHostAddresses,
    SanitizeLinkPreviewImage sanitize = sanitizeLinkPreviewImageInBackground,
  }) : _client = client,
       _resolveHost = resolveHost,
       _sanitize = sanitize;

  /// The capture for [url], or null when the page yields no preview, the
  /// URL is not one the fetcher may contact, or anything times out. Never
  /// throws: a preview is optional decoration on a message.
  Future<LinkPreviewCapture?> fetch(Uri url) async {
    try {
      return await _fetch(url).timeout(linkPreviewTotalTimeout);
    } catch (_) {
      return null;
    }
  }

  Future<void> _validatePublicHttps(Uri url) async {
    if (url.scheme != 'https' || url.userInfo.isNotEmpty) {
      throw const LinkPreviewRejected(
        'link previews require an HTTPS URL without credentials',
      );
    }
    if (url.hasPort && url.port != 443) {
      throw const LinkPreviewRejected(
        'link previews require the default HTTPS port',
      );
    }
    final host = url.host;
    if (host.isEmpty) throw const LinkPreviewRejected('URL has no host');
    final literal = InternetAddress.tryParse(host);
    final addresses = literal != null ? [literal] : await _resolveHost(host);
    if (addresses.isEmpty) {
      throw const LinkPreviewRejected('DNS resolution returned no addresses');
    }
    if (!addresses.every(isPublicAddress)) {
      throw const LinkPreviewRejected(
        'host resolved to a private or reserved address',
      );
    }
  }

  Future<http.StreamedResponse> _send(Uri url, String accept) {
    final request = http.Request('GET', url)
      ..followRedirects = false
      ..headers['accept'] = accept
      ..headers['user-agent'] = linkPreviewUserAgent;
    return _client.send(request).timeout(linkPreviewRequestTimeout);
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static String? _mimeType(http.StreamedResponse response) {
    final value = response.headers['content-type'];
    if (value == null) return null;
    return value.split(';').first.trim().toLowerCase();
  }

  /// Sends [url] and follows redirects by hand, re-checking each hop.
  /// Returns null when the redirect budget runs out or a hop is malformed.
  Future<(http.StreamedResponse, Uri)?> _get(Uri url, String accept) async {
    var current = url;
    for (var hop = 0; hop <= linkPreviewMaxRedirects; hop++) {
      await _validatePublicHttps(current);
      final response = await _send(current, accept);
      if (!_isRedirect(response.statusCode)) return (response, current);
      unawaited(response.stream.drain<void>().catchError((_) {}));
      if (hop == linkPreviewMaxRedirects) return null;
      final location = response.headers['location'];
      if (location == null) return null;
      final next = Uri.tryParse(location);
      if (next == null) return null;
      current = current.resolveUri(next);
    }
    return null;
  }

  static Future<Uint8List> _readPrefix(
    http.StreamedResponse response,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      final remaining = limit - builder.length;
      if (remaining <= 0) break;
      builder.add(
        chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
      );
      if (builder.length >= limit) break;
    }
    return builder.takeBytes();
  }

  static Future<Uint8List?> _readLimited(
    http.StreamedResponse response,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (builder.length + chunk.length > limit) return null;
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<LinkPreviewCapture?> _fetch(Uri url) async {
    await _validatePublicHttps(url);
    if (isYouTubeVideoUrl(url)) return _fetchYouTube(url);

    final page = await _get(url, 'text/html,application/xhtml+xml;q=0.9');
    if (page == null) return null;
    final (response, finalUrl) = page;
    final mime = _mimeType(response);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        (mime != 'text/html' && mime != 'application/xhtml+xml')) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      return null;
    }
    final body = utf8.decode(
      await _readPrefix(response, linkPreviewMaxHtmlBytes),
      allowMalformed: true,
    );
    final metadata = extractLinkPreviewMetadata(body, finalUrl);
    if (metadata == null) return null;
    final (image, favicon) = await (
      _fetchImageOrNull(metadata.imageUrl, preserveTransparency: false),
      _fetchImageOrNull(metadata.faviconUrl, preserveTransparency: true),
    ).wait;
    return LinkPreviewCapture(
      metadata: metadata,
      image: image,
      favicon: favicon,
    );
  }

  Future<LinkPreviewCapture?> _fetchYouTube(Uri video) async {
    final oembed = youTubeOEmbedUri(video);
    if (oembed == null) return null;
    final result = await _get(oembed, 'application/json');
    if (result == null) return null;
    final (response, _) = result;
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        _mimeType(response) != 'application/json') {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      return null;
    }
    final bytes = await _readLimited(response, linkPreviewMaxOEmbedBytes);
    if (bytes == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final parsed = metadataFromYouTubeOEmbed(decoded);
    if (parsed == null) return null;
    final image = await _fetchImageOrNull(
      parsed.thumbnailUrl,
      preserveTransparency: false,
    );
    return LinkPreviewCapture(metadata: parsed.metadata, image: image);
  }

  Future<SanitizedLinkPreviewImage?> _fetchImageOrNull(
    Uri? url, {
    required bool preserveTransparency,
  }) async {
    if (url == null) return null;
    try {
      return await _fetchImage(
        url,
        preserveTransparency: preserveTransparency,
      ).timeout(linkPreviewRequestTimeout * 2);
    } catch (_) {
      return null;
    }
  }

  Future<SanitizedLinkPreviewImage?> _fetchImage(
    Uri url, {
    required bool preserveTransparency,
  }) async {
    final result = await _get(url, 'image/jpeg,image/png,image/webp');
    if (result == null) return null;
    final (response, _) = result;
    final mime = _mimeType(response);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        mime == null ||
        !linkPreviewImageMimeTypes.contains(mime) ||
        (response.contentLength ?? 0) > linkPreviewMaxImageBytes) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      return null;
    }
    final bytes = await _readLimited(response, linkPreviewMaxImageBytes);
    if (bytes == null || bytes.isEmpty) return null;
    return _sanitize(bytes, mime, preserveTransparency: preserveTransparency);
  }
}
