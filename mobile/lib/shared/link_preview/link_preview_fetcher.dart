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
///   global unicast addresses (`isPublicAddress`, the classifier shared with
///   the relay and desktop), and the connection is pinned to those addresses
///   so a DNS answer cannot change between the check and the connect;
/// * redirects are followed by hand (at most [linkPreviewMaxRedirects]),
///   each hop re-checked;
/// * bodies are bounded ([linkPreviewMaxHtmlBytes] of HTML,
///   [linkPreviewMaxImageBytes] per image), every request has a timeout,
///   and each fetch owns one client that is closed when the fetch ends, so
///   a stalled or trickling response is torn down rather than left reading;
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

bool _isPublicV4(List<int> o) {
  final a = o[0];
  final b = o[1];
  final c = o[2];
  final d = o[3];
  if (a == 0 || a == 10 || a == 127) {
    return false; // this net, private, loopback
  }
  if (a == 100 && (b & 0xc0) == 64) return false; // 100.64.0.0/10 CGNAT
  if (a == 169 && b == 254) return false; // link-local
  if (a == 172 && (b & 0xf0) == 16) return false; // 172.16.0.0/12
  if (a == 192 && b == 168) return false;
  // 192.0.0.0/24 IETF assignments, except the PCP/TURN anycasts .9/.10.
  if (a == 192 && b == 0 && c == 0 && d != 9 && d != 10) return false;
  if (a == 192 && b == 0 && c == 2) return false; // TEST-NET-1
  if (a == 192 && b == 88 && c == 99) return false; // 6to4 relay anycast
  if (a == 198 && (b & 0xfe) == 18) return false; // 198.18.0.0/15 benchmarking
  if (a == 198 && b == 51 && c == 100) return false; // TEST-NET-2
  if (a == 203 && b == 0 && c == 113) return false; // TEST-NET-3
  if (a >= 224) return false; // 224/4 multicast, 240/4 reserved, broadcast
  return true;
}

int _segment(Uint8List bytes, int index) =>
    (bytes[index * 2] << 8) | bytes[index * 2 + 1];

bool _hasPrefix(Uint8List bytes, List<int> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

const _ipv4Compatible = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]; // ::a.b.c.d
const _ipv4Mapped = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff];
const _nat64WellKnown = [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0];
const _ipv4Translated = [0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0]; // SIIT

/// Whether [address] is global unicast: the only kind a preview may contact.
/// Mirrors `buzz_core::network::is_not_global_unicast`, the classifier the
/// desktop native command and the relay's own outbound checks use, including
/// the IANA special-purpose registries' IPv6 ranges.
bool isPublicAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes.length == 4 && _isPublicV4(bytes);
  }
  if (bytes.length != 16) return false;
  // Addresses that carry an IPv4 payload follow the IPv4 rules.
  for (final prefix in [
    _ipv4Compatible,
    _ipv4Mapped,
    _nat64WellKnown,
    _ipv4Translated,
  ]) {
    if (_hasPrefix(bytes, prefix)) return _isPublicV4(bytes.sublist(12));
  }
  final s = [for (var i = 0; i < 8; i++) _segment(bytes, i)];
  if (address.isLoopback || bytes.every((b) => b == 0)) return false;
  // 2001::/23 IETF protocol assignments: non-global except the carve-outs.
  if (s[0] == 0x2001 && (s[1] >> 9) == 0) {
    final anycast =
        s[1] == 1 &&
        s[2] == 0 &&
        s[3] == 0 &&
        s[4] == 0 &&
        s[5] == 0 &&
        s[6] == 0 &&
        s[7] >= 1 &&
        s[7] <= 3; // PCP, TURN, DNS-SD SRP
    final exception =
        anycast ||
        s[1] == 3 || // 2001:3::/32 AMT
        (s[1] == 4 && s[2] == 0x0112) || // 2001:4:112::/48 AS112-v6
        (s[1] >> 4) == 0x0002 || // 2001:20::/28 ORCHIDv2
        (s[1] >> 4) == 0x0003; // 2001:30::/28 DETs
    if (!exception) return false;
  }
  if ((s[0] & 0xfe00) == 0xfc00) return false; // fc00::/7 ULA
  if ((s[0] & 0xffc0) == 0xfe80) return false; // fe80::/10 link-local
  if ((s[0] & 0xffc0) == 0xfec0) return false; // fec0::/10 site-local
  if ((s[0] & 0xff00) == 0xff00) return false; // ff00::/8 multicast
  if (s[0] == 0x0064 && s[1] == 0xff9b && s[2] == 1) {
    return false; // 64:ff9b:1::/48 local-use NAT64
  }
  if (s[0] == 0x0100 && s[1] == 0 && s[2] == 0 && (s[3] == 0 || s[3] == 1)) {
    return false; // 100::/64 discard, 100:0:0:1::/64 dummy
  }
  if (s[0] == 0x2001 && s[1] == 0x0db8) return false; // documentation
  if (s[0] == 0x2002) return false; // 6to4
  if (s[0] == 0x3fff && (s[1] >> 12) == 0) return false; // 3fff::/20 docs
  if (s[0] == 0x5f00) return false; // SRv6 SIDs
  return true;
}

Future<List<InternetAddress>> lookupHostAddresses(String host) =>
    InternetAddress.lookup(host);

/// The addresses a preview may connect to for [host]: the literal itself,
/// or the DNS answers, keeping only those that pass [isPublicAddress] and
/// listing IPv4 first (dart:io tries one address, and IPv4 is the one a
/// phone can most reliably reach). Throws when nothing public is left.
///
/// Answers from `InternetAddress.lookup` carry the name they were looked up
/// by in `InternetAddress.host`; the pinned client relies on that for TLS.
Future<List<InternetAddress>> resolvePublicHostAddresses(String host) async {
  final literal = InternetAddress.tryParse(host);
  final addresses = literal != null
      ? [literal]
      : await lookupHostAddresses(host);
  final public = addresses.where(isPublicAddress).toList()
    ..sort(
      (a, b) => a.type == b.type
          ? 0
          : a.type == InternetAddressType.IPv4
          ? -1
          : 1,
    );
  if (public.isEmpty) {
    throw const SocketException(
      'link preview host did not resolve to a public address',
    );
  }
  return public;
}

/// An HTTP client that connects only to addresses [resolveHost] returned,
/// so the answer the fetcher checked is the one the socket goes to (no DNS
/// rebinding between check and connect), while TLS still verifies the
/// certificate and sends SNI for the URL's host.
///
/// `HttpClient.connectionFactory` hands back a plain socket as-is — with a
/// factory set, dart:io never upgrades a direct https connection itself
/// (`http_impl.dart`, `_getConnectionTarget`) — so the factory must do the
/// handshake. `SecureSocket.startConnect` given the looked-up
/// [InternetAddress] connects to that address and verifies against
/// `address.host`, the name it was resolved from (`secure_socket.dart`
/// `secure`, `socket.address.host`). Plain http never reaches a socket:
/// previews are https only. Closing the client force-closes its sockets.
http.Client pinnedLinkPreviewHttpClient({
  ResolveHostAddresses resolveHost = resolvePublicHostAddresses,
  SecurityContext? securityContext,
}) {
  final inner = HttpClient(context: securityContext)
    ..connectionTimeout = linkPreviewRequestTimeout
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (url, proxyHost, proxyPort) async {
      if (url.scheme != 'https') {
        throw const SocketException('link previews connect over https only');
      }
      final address = (await resolveHost(url.host)).first;
      return SecureSocket.startConnect(
        address,
        url.port,
        context: securityContext,
      );
    };
  return IOClient(inner);
}

final linkPreviewFetcherProvider = Provider<LinkPreviewFetcher>(
  (ref) => LinkPreviewFetcher(clientFactory: pinnedLinkPreviewHttpClient),
);

class LinkPreviewFetcher {
  final http.Client Function() _newClient;
  final ResolveHostAddresses _resolveHost;
  final SanitizeLinkPreviewImage _sanitize;

  /// [clientFactory] builds one client per [fetch]. Closing it when the
  /// fetch ends — success, failure or timeout — is what tears the sockets
  /// down: `Future.timeout` alone would leave a stalled or trickling
  /// response reading in the background.
  LinkPreviewFetcher({
    required http.Client Function() clientFactory,
    ResolveHostAddresses resolveHost = lookupHostAddresses,
    SanitizeLinkPreviewImage sanitize = sanitizeLinkPreviewImageInBackground,
  }) : _newClient = clientFactory,
       _resolveHost = resolveHost,
       _sanitize = sanitize;

  /// The capture for [url], or null when the page yields no preview, the
  /// URL is not one the fetcher may contact, or anything times out. Never
  /// throws: a preview is optional decoration on a message.
  Future<LinkPreviewCapture?> fetch(Uri url) async {
    final client = _newClient();
    try {
      return await _Fetch(
        client: client,
        resolveHost: _resolveHost,
        sanitize: _sanitize,
      ).run(url).timeout(linkPreviewTotalTimeout);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}

/// One fetch: every request on one client that the caller closes.
class _Fetch {
  final http.Client _client;
  final ResolveHostAddresses _resolveHost;
  final SanitizeLinkPreviewImage _sanitize;

  _Fetch({
    required http.Client client,
    required ResolveHostAddresses resolveHost,
    required SanitizeLinkPreviewImage sanitize,
  }) : _client = client,
       _resolveHost = resolveHost,
       _sanitize = sanitize;

  Future<LinkPreviewCapture?> run(Uri url) async {
    await _validatePublicHttps(url);
    if (isYouTubeVideoUrl(url)) return _fetchYouTube(url);

    final page = await _get(url, 'text/html,application/xhtml+xml;q=0.9');
    if (page == null) return null;
    final (response, finalUrl) = page;
    final mime = _mimeType(response);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        (mime != 'text/html' && mime != 'application/xhtml+xml')) {
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
  /// Unread bodies are dropped with the client when the fetch ends.
  Future<(http.StreamedResponse, Uri)?> _get(Uri url, String accept) async {
    var current = url;
    for (var hop = 0; hop <= linkPreviewMaxRedirects; hop++) {
      await _validatePublicHttps(current);
      final response = await _send(current, accept);
      if (!_isRedirect(response.statusCode)) return (response, current);
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

  Future<LinkPreviewCapture?> _fetchYouTube(Uri video) async {
    final oembed = youTubeOEmbedUri(video);
    if (oembed == null) return null;
    final result = await _get(oembed, 'application/json');
    if (result == null) return null;
    final (response, _) = result;
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        _mimeType(response) != 'application/json') {
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
      return null;
    }
    final bytes = await _readLimited(response, linkPreviewMaxImageBytes);
    if (bytes == null || bytes.isEmpty) return null;
    return _sanitize(bytes, mime, preserveTransparency: preserveTransparency);
  }
}
