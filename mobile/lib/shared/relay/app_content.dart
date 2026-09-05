import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Upper bound for one app document, matching the relay's default
/// `BUZZ_APP_CONTENT_MAX_BYTES`. Executable content is far smaller than the
/// general file cap; anything bigger is refused before it is decoded.
const appContentMaxBytes = 8 * 1024 * 1024;

/// The sandbox policy every app document carries, stamped **by this client**
/// into the document before it reaches the WebView, so isolation never
/// depends on the relay's response headers surviving a plain-HTTP LAN.
///
/// This is the relay/desktop `APP_CONTENT_CSP` minus `sandbox allow-scripts`:
/// a `<meta>` policy cannot express `sandbox`, so the opaque origin comes from
/// loading the document as `about:blank` (`loadHtmlString` without a base
/// URL) instead — no storage, no same-origin anything. `navigate-to` and
/// `webrtc` are kept for parity even though WebKit ignores them; the
/// navigation delegate and the native user script cover those.
const appSandboxCsp =
    "default-src 'none'; script-src 'unsafe-inline'; "
    "style-src 'unsafe-inline'; img-src data: blob:; font-src data:; "
    "connect-src 'none'; form-action 'none'; base-uri 'none'; "
    "object-src 'none'; navigate-to 'none'; webrtc 'block'";

final _leadingDoctype = RegExp(
  r'^\s*(?:<!--[\s\S]*?-->\s*)*<!doctype[^>]*>',
  caseSensitive: false,
);

/// Inserts the [appSandboxCsp] `<meta>` so it is the first element the parser
/// sees — right after a leading doctype (keeping standards mode), otherwise at
/// the very start. Either way the parser opens the implicit `<head>` for it,
/// which is where a policy `<meta>` must live to be enforced, and no script
/// can precede it.
String stampSandboxCsp(String html) {
  const meta =
      '<meta http-equiv="Content-Security-Policy" content="$appSandboxCsp">';
  final doctype = _leadingDoctype.firstMatch(html);
  if (doctype == null) return '$meta$html';
  return '${html.substring(0, doctype.end)}$meta${html.substring(doctype.end)}';
}

class AppContentFetchException implements Exception {
  final int? statusCode;
  final String message;

  const AppContentFetchException(this.message, {this.statusCode});

  @override
  String toString() => 'AppContentFetchException: $message';
}

/// Fetches one app document from the app door with the blob-scoped
/// [headers], the way the desktop proxy does: **no redirects** (a 3xx is a
/// failure — a custom `Authorization` header must never follow a redirect),
/// `text/html` only, and at most [maxBytes]. Returns the document as text.
Future<String> fetchAppDocument(
  Uri uri, {
  required Map<String, String> headers,
  required http.Client client,
  int maxBytes = appContentMaxBytes,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final request = http.Request('GET', uri)
    ..headers.addAll(headers)
    ..followRedirects = false;
  final response = await client.send(request).timeout(timeout);
  if (response.statusCode != 200) {
    throw AppContentFetchException(
      'The relay answered HTTP ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }
  final contentType = (response.headers['content-type'] ?? '').toLowerCase();
  if (!contentType.startsWith('text/html')) {
    throw AppContentFetchException('Not an HTML document ($contentType)');
  }
  if ((response.contentLength ?? 0) > maxBytes) {
    throw AppContentFetchException('App is larger than $maxBytes bytes');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.stream.timeout(timeout)) {
    bytes.add(chunk);
    if (bytes.length > maxBytes) {
      throw AppContentFetchException('App is larger than $maxBytes bytes');
    }
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}
