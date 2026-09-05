import 'package:flutter/foundation.dart';

import '../../shared/relay/sha256_hex.dart';

/// Media presentation selected for a message attachment URL.
///
/// [app] is a sandboxed HTML app — `m text/html` with a verifiable blob hash
/// (see `docs/sandboxed-apps.md`). It renders as a static preview card and
/// only runs in the sandbox WebView on an explicit tap, never inline.
enum MessageMediaKind { image, video, audio, app }

/// Parsed metadata from a NIP-92 `imeta` tag.
@immutable
class ImetaEntry {
  final String url;
  final String? mimeType;
  final String? dimensions;
  final String? thumb;
  final String? image;
  final String? alt;
  final double? duration;
  final String? filename;
  final int? size;

  /// Blob SHA-256 (`x`) as lowercase hex, or null when absent or malformed.
  final String? sha256;

  /// Fork-local themed preview images for a sandboxed HTML app
  /// (`preview-light` / `preview-dark`). Plain image blobs on the relay;
  /// nothing in them can run.
  final String? previewLight;
  final String? previewDark;

  const ImetaEntry({
    required this.url,
    this.mimeType,
    this.dimensions,
    this.thumb,
    this.image,
    this.alt,
    this.duration,
    this.filename,
    this.size,
    this.sha256,
    this.previewLight,
    this.previewDark,
  });

  bool get isVideo => mimeType?.startsWith('video/') == true;

  bool get isAudio => mimeType?.startsWith('audio/') == true;

  /// A sandboxed HTML app: `text/html` plus the blob hash the app door needs.
  /// Without the hash there is nothing to ask the door for, so the attachment
  /// stays an ordinary link.
  bool get isApp => mimeType == 'text/html' && sha256 != null;

  String? get posterUrl => image ?? thumb;

  double? get aspectRatio {
    final parts = dimensions?.split('x');
    if (parts == null || parts.length != 2) return null;
    final width = double.tryParse(parts[0]);
    final height = double.tryParse(parts[1]);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return width / height;
  }
}

/// Parses NIP-92 `imeta` tags into entries keyed by their attachment URL.
Map<String, ImetaEntry> parseImetaTags(List<List<String>> tags) {
  final byUrl = <String, ImetaEntry>{};
  for (final tag in tags) {
    if (tag.isEmpty || tag.first != 'imeta') continue;

    String? url;
    String? mimeType;
    String? dimensions;
    String? thumb;
    String? image;
    String? alt;
    double? duration;
    String? filename;
    int? size;
    String? sha256;
    String? previewLight;
    String? previewDark;

    for (final part in tag.skip(1)) {
      final separator = part.indexOf(' ');
      if (separator <= 0) continue;
      final key = part.substring(0, separator);
      final value = part.substring(separator + 1);
      switch (key) {
        case 'url':
          url = value;
        case 'm':
          mimeType = value;
        case 'dim':
          dimensions = value;
        case 'thumb':
          thumb = value;
        case 'image':
          image = value;
        case 'alt':
          alt = value;
        case 'duration':
          final parsedDuration = double.tryParse(value);
          duration =
              parsedDuration != null &&
                  parsedDuration.isFinite &&
                  parsedDuration >= 0
              ? parsedDuration
              : null;
        case 'filename':
          filename = value;
        case 'size':
          size = int.tryParse(value);
        case 'x':
          final hash = value.trim().toLowerCase();
          sha256 = isSha256Hex(hash) ? hash : null;
        case 'preview-light':
          previewLight = value;
        case 'preview-dark':
          previewDark = value;
      }
    }

    if (url == null || url.isEmpty) continue;
    byUrl[url] = ImetaEntry(
      url: url,
      mimeType: mimeType,
      dimensions: dimensions,
      thumb: thumb,
      image: image,
      alt: alt,
      duration: duration,
      filename: filename,
      size: size,
      sha256: sha256,
      previewLight: previewLight,
      previewDark: previewDark,
    );
  }
  return byUrl;
}

/// Classifies [url] using authoritative [imeta] before extension fallback.
MessageMediaKind? classifyMediaUrl(String url, {ImetaEntry? imeta}) {
  // Apps are decided by imeta alone: an `.html` URL without a hash is a link.
  if (imeta != null && imeta.isApp) return MessageMediaKind.app;

  final mimeType = imeta?.mimeType;
  if (mimeType != null) {
    final filename = imeta?.filename?.toLowerCase();
    if (mimeType == 'video/mp4' &&
        filename != null &&
        filename.startsWith('voice-note-') &&
        filename.endsWith('.mp4')) {
      return MessageMediaKind.audio;
    }
    // An imeta MIME type is authoritative. The native video player chooses
    // whether the device can decode the specific codec/container; rejecting
    // every non-MP4 video here prevents it from even trying.
    if (mimeType.startsWith('video/')) return MessageMediaKind.video;
    if (mimeType.startsWith('image/')) return MessageMediaKind.image;
    if (mimeType.startsWith('audio/')) return MessageMediaKind.audio;
  }

  final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
  if (path.endsWith(_mp4Extension)) {
    return MessageMediaKind.video;
  }
  if (_imageExtensions.any(path.endsWith)) {
    return MessageMediaKind.image;
  }
  if (path.endsWith('.m4a') || path.endsWith('.aac')) {
    return MessageMediaKind.audio;
  }
  return null;
}

const _imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.bmp',
  '.heic',
  '.heif',
  '.avif',
};

const _mp4Extension = '.mp4';
