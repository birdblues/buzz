import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Limits for a page image fetched to author a link preview. Mirrors the
/// desktop native command: what a third-party page hands us is never
/// re-hosted as-is — it is decoded within safe bounds, re-encoded, and
/// downscaled, so the relay only ever stores pixels we produced.
const linkPreviewMaxImageBytes = 2 * 1024 * 1024;
const linkPreviewMaxImageDimension = 4096;
const linkPreviewMaxImagePixels = 16000000;
const linkPreviewMaxSanitizedDimension = 1200;
const linkPreviewImageMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};

@immutable
class SanitizedLinkPreviewImage {
  final Uint8List bytes;
  final String mimeType;

  const SanitizedLinkPreviewImage({
    required this.bytes,
    required this.mimeType,
  });
}

/// The image type the leading bytes declare, or null for anything else.
String? sniffImageMimeType(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return 'image/png';
  }
  if (bytes.length >= 12 &&
      _ascii(bytes, 0, 'RIFF') &&
      _ascii(bytes, 8, 'WEBP')) {
    return 'image/webp';
  }
  return null;
}

bool _ascii(Uint8List bytes, int offset, String text) {
  if (bytes.length < offset + text.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (bytes[offset + i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

bool _containsAscii(Uint8List bytes, String text) {
  for (var i = 0; i + text.length <= bytes.length; i++) {
    if (_ascii(bytes, i, text)) return true;
  }
  return false;
}

/// Whether a PNG or WebP declares animation (APNG `acTL`, WebP `ANIM` or the
/// VP8X animation flag). Animated previews are refused, not flattened.
bool declaresAnimation(Uint8List bytes, String mimeType) {
  switch (mimeType) {
    case 'image/png':
      return _containsAscii(bytes, 'acTL');
    case 'image/webp':
      return bytes.length >= 21 &&
          ((_ascii(bytes, 12, 'VP8X') && (bytes[20] & 0x02) != 0) ||
              _containsAscii(bytes, 'ANIM'));
    default:
      return false;
  }
}

/// Decodes [bytes] within safe limits and re-encodes them for the relay.
///
/// Returns null when the bytes do not match [declaredMimeType], declare
/// animation, are malformed, or exceed the dimension limits. The result is
/// a JPEG (quality 82) at most [linkPreviewMaxSanitizedDimension] on its
/// longest side — or a PNG when [preserveTransparency] is set and the image
/// has an alpha channel (favicons), as on desktop.
SanitizedLinkPreviewImage? sanitizeLinkPreviewImage(
  Uint8List bytes,
  String declaredMimeType, {
  bool preserveTransparency = false,
}) {
  final sniffed = sniffImageMimeType(bytes);
  if (sniffed == null || sniffed != declaredMimeType) return null;
  if (declaresAnimation(bytes, sniffed)) return null;
  final img.Decoder decoder = switch (sniffed) {
    'image/jpeg' => img.JpegDecoder(),
    'image/png' => img.PngDecoder(),
    _ => img.WebPDecoder(),
  };
  final img.DecodeInfo? info;
  try {
    info = decoder.startDecode(bytes);
  } catch (_) {
    return null;
  }
  if (info == null) return null;
  final width = info.width;
  final height = info.height;
  if (width <= 0 ||
      height <= 0 ||
      width > linkPreviewMaxImageDimension ||
      height > linkPreviewMaxImageDimension ||
      width * height > linkPreviewMaxImagePixels) {
    return null;
  }
  img.Image? decoded;
  try {
    decoded = decoder.decode(bytes);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  final longest = math.max(image.width, image.height);
  if (longest > linkPreviewMaxSanitizedDimension) {
    image = image.width >= image.height
        ? img.copyResize(
            image,
            width: linkPreviewMaxSanitizedDimension,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            image,
            height: linkPreviewMaxSanitizedDimension,
            interpolation: img.Interpolation.average,
          );
  }
  if (preserveTransparency && image.hasAlpha) {
    return SanitizedLinkPreviewImage(
      bytes: img.encodePng(image),
      mimeType: 'image/png',
    );
  }
  return SanitizedLinkPreviewImage(
    bytes: img.encodeJpg(image, quality: 82),
    mimeType: 'image/jpeg',
  );
}

SanitizedLinkPreviewImage? _sanitizeInIsolate(
  (Uint8List, String, bool) request,
) {
  return sanitizeLinkPreviewImage(
    request.$1,
    request.$2,
    preserveTransparency: request.$3,
  );
}

/// [sanitizeLinkPreviewImage] off the UI isolate.
Future<SanitizedLinkPreviewImage?> sanitizeLinkPreviewImageInBackground(
  Uint8List bytes,
  String declaredMimeType, {
  bool preserveTransparency = false,
}) {
  return compute(_sanitizeInIsolate, (
    bytes,
    declaredMimeType,
    preserveTransparency,
  ));
}
