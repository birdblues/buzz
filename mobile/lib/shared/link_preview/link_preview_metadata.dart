import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

/// Page metadata a link preview is authored from (`docs/link-previews.md`).
///
/// Extraction mirrors the desktop native command
/// (`desktop/src-tauri/src/commands/link_preview.rs`): Open Graph first,
/// Twitter cards second, the `<title>` element last; the same character
/// limits; the same tolerant, regex-free tag scanning so an odd page never
/// needs a full HTML parser to preview.
const linkPreviewMaxTitleChars = 180;
const linkPreviewMaxDescriptionChars = 280;

@immutable
class LinkPreviewMetadata {
  final String title;
  final String? siteName;
  final String? description;

  /// `og:image` (or Twitter) resolved against the page, before any fetch.
  final Uri? imageUrl;

  /// `<link rel="icon">` resolved against the page, before any fetch.
  final Uri? faviconUrl;

  const LinkPreviewMetadata({
    required this.title,
    this.siteName,
    this.description,
    this.imageUrl,
    this.faviconUrl,
  });

  @override
  bool operator ==(Object other) =>
      other is LinkPreviewMetadata &&
      other.title == title &&
      other.siteName == siteName &&
      other.description == description &&
      other.imageUrl == imageUrl &&
      other.faviconUrl == faviconUrl;

  @override
  int get hashCode =>
      Object.hash(title, siteName, description, imageUrl, faviconUrl);
}

/// Decodes the handful of entities that appear in `<meta content>` values.
String decodeHtmlEntities(String value) {
  final named = value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  final buffer = StringBuffer();
  var index = 0;
  while (true) {
    final start = named.indexOf('&#', index);
    if (start < 0) {
      buffer.write(named.substring(index));
      break;
    }
    final end = named.indexOf(';', start);
    if (end < 0) {
      buffer.write(named.substring(index));
      break;
    }
    final entity = named.substring(start + 2, end);
    final code = entity.startsWith('x') || entity.startsWith('X')
        ? int.tryParse(entity.substring(1), radix: 16)
        : int.tryParse(entity);
    if (code == null ||
        code < 0 ||
        code > 0x10ffff ||
        (code >= 0xd800 && code <= 0xdfff)) {
      buffer.write(named.substring(index, end + 1));
      index = end + 1;
      continue;
    }
    buffer
      ..write(named.substring(index, start))
      ..writeCharCode(code);
    index = end + 1;
  }
  return buffer.toString();
}

final _attributeNameChar = RegExp(r'[a-z0-9_-]');
final _unquotedValueEnd = RegExp(r'[\s>]');

/// The value of [attr] inside one `<tag …>` string, entities decoded.
String? attributeValue(String tag, String attr) {
  final lower = tag.toLowerCase();
  final name = attr.toLowerCase();
  var from = 0;
  while (true) {
    final nameStart = lower.indexOf(name, from);
    if (nameStart < 0) return null;
    final nameEnd = nameStart + name.length;
    final before = nameStart == 0 ? null : lower[nameStart - 1];
    final after = nameEnd >= lower.length ? null : lower[nameEnd];
    if ((before != null && _attributeNameChar.hasMatch(before)) ||
        (after != null && _attributeNameChar.hasMatch(after))) {
      from = nameEnd;
      continue;
    }
    final rest = tag.substring(nameEnd);
    final equals = rest.indexOf('=');
    if (equals < 0) return null;
    final value = rest.substring(equals + 1).trimLeft();
    if (value.isEmpty) return null;
    final quote = value[0];
    if (quote == '"' || quote == "'") {
      final body = value.substring(1);
      final end = body.indexOf(quote);
      if (end < 0) return null;
      return decodeHtmlEntities(body.substring(0, end));
    }
    final end = _unquotedValueEnd.firstMatch(value)?.start ?? value.length;
    return decodeHtmlEntities(value.substring(0, end));
  }
}

Iterable<String> _tags(String html, String opener) sync* {
  final lower = html.toLowerCase();
  var from = 0;
  while (true) {
    final start = lower.indexOf(opener, from);
    if (start < 0) return;
    final end = lower.indexOf('>', start);
    if (end < 0) return;
    yield html.substring(start, end + 1);
    from = end + 1;
  }
}

/// `content` of the first `<meta [keyAttr]="[keyValue]">`.
String? extractMetaContent(String html, String keyAttr, String keyValue) {
  for (final tag in _tags(html, '<meta')) {
    final key = attributeValue(tag, keyAttr);
    if (key != null && key.toLowerCase() == keyValue.toLowerCase()) {
      final content = attributeValue(tag, 'content');
      if (content != null) return content;
    }
  }
  return null;
}

String? extractTitleTag(String html) {
  final lower = html.toLowerCase();
  final start = lower.indexOf('<title');
  if (start < 0) return null;
  final open = lower.indexOf('>', start);
  if (open < 0) return null;
  final close = lower.indexOf('</title>', open + 1);
  if (close < 0) return null;
  return decodeHtmlEntities(html.substring(open + 1, close));
}

const _googleTitleSuffixes = [
  ' - Google Docs',
  ' - Google Sheets',
  ' - Google Slides',
  ' - Google Drive',
];
const _placeholderTitles = {
  '',
  'Sign in - Google Accounts',
  'Google Docs',
  'Google Sheets',
  'Google Slides',
};
final _whitespace = RegExp(r'\s+');

/// One line, entities decoded, Google's suffix and sign-in placeholders
/// dropped, clipped to [linkPreviewMaxTitleChars]; null when nothing is left.
String? normalizeMetadataText(String raw) {
  var normalized = decodeHtmlEntities(
    raw,
  ).split(_whitespace).where((part) => part.isNotEmpty).join(' ');
  for (final suffix in _googleTitleSuffixes) {
    if (normalized.endsWith(suffix)) {
      normalized = normalized
          .substring(0, normalized.length - suffix.length)
          .trim();
      break;
    }
  }
  if (_placeholderTitles.contains(normalized)) return null;
  return normalized.characters.take(linkPreviewMaxTitleChars).toString();
}

/// Paragraph text: line breaks kept, runs of whitespace collapsed per line,
/// clipped to [linkPreviewMaxDescriptionChars]; null when empty.
String? normalizeMetadataDescription(String raw) {
  final normalized = decodeHtmlEntities(raw)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map(
        (line) =>
            line.split(_whitespace).where((part) => part.isNotEmpty).join(' '),
      )
      .join('\n')
      .trim();
  if (normalized.isEmpty) return null;
  return normalized.characters.take(linkPreviewMaxDescriptionChars).toString();
}

Uri? _resolve(Uri page, String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) return null;
  try {
    return page.resolveUri(parsed);
  } on FormatException {
    return null;
  }
}

/// `og:image`, then `og:image:secure_url`, then `twitter:image`.
Uri? extractImageUrl(String html, Uri page) {
  final raw =
      extractMetaContent(html, 'property', 'og:image') ??
      extractMetaContent(html, 'property', 'og:image:secure_url') ??
      extractMetaContent(html, 'name', 'twitter:image');
  return raw == null ? null : _resolve(page, raw);
}

const _rasterFaviconTypes = {'image/jpeg', 'image/png', 'image/webp'};
const _rasterFaviconExtensions = {'jpg', 'jpeg', 'png', 'webp'};

/// The first `<link rel="icon">` (or `apple-touch-icon`) that is declared or
/// named as a raster image, else the first icon at all.
Uri? extractFaviconUrl(String html, Uri page) {
  Uri? fallback;
  for (final tag in _tags(html, '<link')) {
    final rel = attributeValue(tag, 'rel');
    if (rel == null) continue;
    final isIcon = rel.split(_whitespace).any((token) {
      final lower = token.toLowerCase();
      return lower == 'icon' || lower == 'apple-touch-icon';
    });
    if (!isIcon) continue;
    final href = attributeValue(tag, 'href');
    if (href == null) continue;
    final url = _resolve(page, href);
    if (url == null) continue;
    final declaredType = attributeValue(tag, 'type')?.toLowerCase();
    final extension = url.path.contains('.')
        ? url.path.substring(url.path.lastIndexOf('.') + 1).toLowerCase()
        : '';
    if (_rasterFaviconTypes.contains(declaredType) ||
        _rasterFaviconExtensions.contains(extension)) {
      return url;
    }
    fallback ??= url;
  }
  return fallback;
}

/// The preview a page yields, or null when it has no usable title.
LinkPreviewMetadata? extractLinkPreviewMetadata(String html, Uri page) {
  final rawTitle =
      extractMetaContent(html, 'property', 'og:title') ??
      extractMetaContent(html, 'name', 'twitter:title') ??
      extractTitleTag(html);
  final title = rawTitle == null ? null : normalizeMetadataText(rawTitle);
  if (title == null) return null;
  final rawSite = extractMetaContent(html, 'property', 'og:site_name');
  final rawDescription =
      extractMetaContent(html, 'property', 'og:description') ??
      extractMetaContent(html, 'name', 'twitter:description');
  return LinkPreviewMetadata(
    title: title,
    siteName: rawSite == null ? null : normalizeMetadataText(rawSite),
    description: rawDescription == null
        ? null
        : normalizeMetadataDescription(rawDescription),
    imageUrl: extractImageUrl(html, page),
    faviconUrl: extractFaviconUrl(html, page),
  );
}
