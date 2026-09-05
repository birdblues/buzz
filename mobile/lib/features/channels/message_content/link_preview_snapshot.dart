import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../shared/relay/media_auth.dart' show extractServerAuthority;
import '../../../shared/relay/sha256_hex.dart';

/// Sender-authored link previews (`docs/link-previews.md`).
///
/// A message that links to an external page may carry
/// `["link-preview","snapshot","1",canonicalUrl,title,siteName,description,
/// imageUrl,imageSha256,faviconUrl,faviconSha256]` tags. The sender fetched
/// the page once and re-hosted its image and favicon as relay blobs; readers
/// render the tag only and never contact the external site. `["link-preview",
/// "none"]` says the sender removed every preview.
///
/// This mirrors desktop `linkPreviewSnapshot.ts` and the relay's ingest
/// validation: a tag that fails any check below is dropped silently, so a
/// crafted tag can never make the card show a URL, text, or image that the
/// relay would not have accepted from a real sender.
const linkPreviewSnapshotVersion = '1';
const linkPreviewMaxSnapshots = 8;
const _maxTitleBytes = 300;
const _maxSiteNameBytes = 100;
const _maxDescriptionBytes = 1000;
const _imageExtensions = {'jpg', 'png', 'gif', 'webp'};

final _relayMediaPath = RegExp(r'^/media/([0-9a-f]{64})\.([a-z0-9]{1,8})$');
final _fencedCode = RegExp(r'```[\s\S]*?```|~~~[\s\S]*?~~~');
final _inlineCode = RegExp(r'`[^`\n]*`');
final _indentedCode = RegExp(r'^(?: {4}|\t).*$', multiLine: true);
final _markdownImage = RegExp(r'!\[[^\]\n]*\]\([^)\s]*\)');

@immutable
class LinkPreviewSnapshot {
  /// The https URL the sender previewed. Always present verbatim in the
  /// message body outside code, so the card never describes a hidden link.
  final String canonicalUrl;
  final String title;
  final String siteName;
  final String description;

  /// Relay-hosted image blob (`/media/<sha>.<ext>`), or null for no image.
  final String? imageUrl;

  /// Relay-hosted favicon blob, or null.
  final String? faviconUrl;

  const LinkPreviewSnapshot({
    required this.canonicalUrl,
    required this.title,
    required this.siteName,
    required this.description,
    this.imageUrl,
    this.faviconUrl,
  });

  /// Host shown above the title, without a leading `www.`; the site name is
  /// a display hint the sender chose and must not stand in for the host.
  String get hostname {
    final host = Uri.tryParse(canonicalUrl)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  @override
  bool operator ==(Object other) =>
      other is LinkPreviewSnapshot &&
      other.canonicalUrl == canonicalUrl &&
      other.title == title &&
      other.siteName == siteName &&
      other.description == description &&
      other.imageUrl == imageUrl &&
      other.faviconUrl == faviconUrl;

  @override
  int get hashCode => Object.hash(
    canonicalUrl,
    title,
    siteName,
    description,
    imageUrl,
    faviconUrl,
  );
}

/// The tag a sender attaches to send a message without any preview.
const linkPreviewSuppressionTag = ['link-preview', 'none'];

/// [value] cut to [maxBytes] of UTF-8 on a character boundary, with control
/// characters (newlines too, unless [allowNewlines]) replaced by spaces —
/// the shape the relay accepts, applied before signing.
String sanitizeLinkPreviewText(
  String value,
  int maxBytes, {
  bool allowNewlines = false,
}) {
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    final safe = _isControl(rune, allowNewline: allowNewlines) ? 0x20 : rune;
    final length = utf8.encode(String.fromCharCode(safe)).length;
    if (bytes + length > maxBytes) break;
    buffer.writeCharCode(safe);
    bytes += length;
  }
  return buffer.toString();
}

/// The snapshot tag for one link, or null when [canonicalUrl] is not a
/// valid canonical URL. Media pairs are passed through as the relay
/// returned them; the relay re-validates them on ingest.
List<String>? buildLinkPreviewSnapshotTag({
  required String canonicalUrl,
  required String title,
  required String siteName,
  required String description,
  String imageUrl = '',
  String imageSha256 = '',
  String faviconUrl = '',
  String faviconSha256 = '',
}) {
  if (!isValidLinkPreviewCanonicalUrl(canonicalUrl)) return null;
  return [
    'link-preview',
    'snapshot',
    linkPreviewSnapshotVersion,
    canonicalUrl,
    sanitizeLinkPreviewText(title, _maxTitleBytes),
    sanitizeLinkPreviewText(siteName, _maxSiteNameBytes),
    sanitizeLinkPreviewText(
      description,
      _maxDescriptionBytes,
      allowNewlines: true,
    ),
    imageUrl,
    imageSha256,
    faviconUrl,
    faviconSha256,
  ];
}

/// Whether the sender suppressed link previews for this message.
bool hasLinkPreviewSuppression(List<List<String>> tags) {
  return tags.any(
    (tag) => tag.length == 2 && tag[0] == 'link-preview' && tag[1] == 'none',
  );
}

/// Whether [value] is a valid snapshot canonical URL: https, no credentials,
/// no fragment. Mirrors `isValidLinkPreviewSnapshotCanonicalUrl`.
bool isValidLinkPreviewCanonicalUrl(String value) {
  if (value.contains('#')) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment;
}

/// Whether ([url], [sha256]) names an image blob on this relay, or is the
/// empty pair meaning "no image". Mirrors the relay's
/// `validate_local_image_media_pair`, so a snapshot can only ever point the
/// image loader at a relay blob whose hash the sender committed to.
bool isRelayImageMediaPair(String url, String sha256, String relayBaseUrl) {
  if (url.isEmpty && sha256.isEmpty) return true;
  if (url.isEmpty || !isSha256Hex(sha256)) return false;
  final uri = Uri.tryParse(url);
  final base = Uri.tryParse(relayBaseUrl);
  if (uri == null || base == null) return false;
  if (uri.scheme != base.scheme ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  final mediaAuthority = extractServerAuthority(
    '${uri.scheme}://${uri.authority}',
  );
  final relayAuthority = extractServerAuthority(relayBaseUrl);
  if (mediaAuthority == null ||
      relayAuthority == null ||
      mediaAuthority != relayAuthority) {
    return false;
  }
  final match = _relayMediaPath.firstMatch(uri.path);
  return match != null &&
      match[1] == sha256 &&
      _imageExtensions.contains(match[2]);
}

bool _isControl(int rune, {bool allowNewline = false}) {
  if (allowNewline && rune == 0x0a) return false;
  return rune <= 0x1f || rune == 0x7f;
}

bool _validText(String value, int maxBytes, {bool allowNewlines = false}) {
  if (utf8.encode(value).length > maxBytes) return false;
  for (final rune in value.runes) {
    if (_isControl(rune, allowNewline: allowNewlines)) return false;
  }
  return true;
}

/// Blanks the parts of [content] that desktop never previews (code, and
/// markdown image syntax whose URL is an attachment, not a link), keeping
/// offsets so callers can order previews by where the link appears. The
/// composer uses the same mask to decide which links to preview.
String maskHiddenLinkPreviewContent(String content) {
  String blank(Match match) => match[0]!.replaceAll(RegExp(r'[^\n]'), ' ');
  return content
      .replaceAllMapped(_fencedCode, blank)
      .replaceAllMapped(_inlineCode, blank)
      .replaceAllMapped(_indentedCode, blank)
      .replaceAllMapped(_markdownImage, blank);
}

/// Parses the snapshot tags of one message into previews, in the order their
/// links appear in [content]. Returns nothing when the sender suppressed
/// previews or [relayBaseUrl] is unknown.
List<LinkPreviewSnapshot> parseLinkPreviewSnapshots(
  List<List<String>> tags,
  String content, {
  required String relayBaseUrl,
}) {
  if (relayBaseUrl.isEmpty || hasLinkPreviewSuppression(tags)) {
    return const [];
  }
  final visible = maskHiddenLinkPreviewContent(content);
  final seen = <String>{};
  final ordered = <(int, LinkPreviewSnapshot)>[];
  for (final tag in tags) {
    if (tag.length < 2 || tag[0] != 'link-preview' || tag[1] != 'snapshot') {
      continue;
    }
    if (ordered.length >= linkPreviewMaxSnapshots ||
        tag.length != 11 ||
        tag[2] != linkPreviewSnapshotVersion) {
      continue;
    }
    final canonicalUrl = tag[3];
    if (!isValidLinkPreviewCanonicalUrl(canonicalUrl) ||
        seen.contains(canonicalUrl)) {
      continue;
    }
    final position = visible.indexOf(canonicalUrl);
    if (position < 0) continue;
    final title = tag[4];
    final siteName = tag[5];
    final description = tag[6];
    if (!_validText(title, _maxTitleBytes) ||
        !_validText(siteName, _maxSiteNameBytes) ||
        !_validText(description, _maxDescriptionBytes, allowNewlines: true)) {
      continue;
    }
    if (!isRelayImageMediaPair(tag[7], tag[8], relayBaseUrl) ||
        !isRelayImageMediaPair(tag[9], tag[10], relayBaseUrl)) {
      continue;
    }
    seen.add(canonicalUrl);
    ordered.add((
      position,
      LinkPreviewSnapshot(
        canonicalUrl: canonicalUrl,
        title: title,
        siteName: siteName,
        description: description,
        imageUrl: tag[7].isEmpty ? null : tag[7],
        faviconUrl: tag[9].isEmpty ? null : tag[9],
      ),
    ));
  }
  ordered.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final entry in ordered) entry.$2];
}
