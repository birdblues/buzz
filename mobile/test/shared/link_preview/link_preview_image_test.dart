import 'dart:typed_data';

import 'package:buzz/shared/link_preview/link_preview_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _png({int width = 4, int height = 4, bool alpha = false}) {
  final image = img.Image(
    width: width,
    height: height,
    numChannels: alpha ? 4 : 3,
  );
  img.fill(image, color: image.getColor(200, 30, 30, alpha ? 128 : 255));
  return img.encodePng(image);
}

Uint8List _jpg({int width = 4, int height = 4}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: image.getColor(30, 30, 200));
  return img.encodeJpg(image);
}

void main() {
  group('sniffImageMimeType', () {
    test('recognises jpeg, png, and webp by magic bytes', () {
      expect(sniffImageMimeType(_jpg()), 'image/jpeg');
      expect(sniffImageMimeType(_png()), 'image/png');
      final webp = Uint8List.fromList([
        ...'RIFF'.codeUnits,
        0,
        0,
        0,
        0,
        ...'WEBP'.codeUnits,
      ]);
      expect(sniffImageMimeType(webp), 'image/webp');
      expect(sniffImageMimeType(Uint8List.fromList('<svg>'.codeUnits)), isNull);
    });
  });

  group('declaresAnimation', () {
    test('flags APNG and animated WebP', () {
      expect(
        declaresAnimation(
          Uint8List.fromList([..._png(), ...'acTL'.codeUnits]),
          'image/png',
        ),
        isTrue,
      );
      expect(declaresAnimation(_png(), 'image/png'), isFalse);
      final vp8x = Uint8List.fromList([
        ...'RIFF'.codeUnits,
        0,
        0,
        0,
        0,
        ...'WEBP'.codeUnits,
        ...'VP8X'.codeUnits,
        0,
        0,
        0,
        0,
        0x02,
      ]);
      expect(declaresAnimation(vp8x, 'image/webp'), isTrue);
      expect(declaresAnimation(_jpg(), 'image/jpeg'), isFalse);
    });
  });

  group('sanitizeLinkPreviewImage', () {
    test('re-encodes a page image as JPEG', () {
      final result = sanitizeLinkPreviewImage(_png(alpha: true), 'image/png');
      expect(result, isNotNull);
      expect(result!.mimeType, 'image/jpeg');
      expect(sniffImageMimeType(result.bytes), 'image/jpeg');
    });

    test('keeps a transparent favicon as PNG when asked to', () {
      final result = sanitizeLinkPreviewImage(
        _png(alpha: true),
        'image/png',
        preserveTransparency: true,
      );
      expect(result!.mimeType, 'image/png');
      final opaque = sanitizeLinkPreviewImage(
        _png(),
        'image/png',
        preserveTransparency: true,
      );
      expect(opaque!.mimeType, 'image/jpeg');
    });

    test('downscales to the sanitized bound', () {
      final result = sanitizeLinkPreviewImage(
        _jpg(width: 2400, height: 600),
        'image/jpeg',
      );
      final decoded = img.decodeJpg(result!.bytes)!;
      expect(decoded.width, linkPreviewMaxSanitizedDimension);
      expect(decoded.height, 300);
    });

    test('rejects a content type that does not match the bytes', () {
      expect(sanitizeLinkPreviewImage(_png(), 'image/jpeg'), isNull);
      expect(
        sanitizeLinkPreviewImage(
          Uint8List.fromList('<svg/>'.codeUnits),
          'image/svg+xml',
        ),
        isNull,
      );
    });

    test('rejects animation, oversize dimensions, and malformed data', () {
      expect(
        sanitizeLinkPreviewImage(
          Uint8List.fromList([..._png(), ...'acTL'.codeUnits]),
          'image/png',
        ),
        isNull,
      );
      expect(
        sanitizeLinkPreviewImage(
          _png(width: linkPreviewMaxImageDimension + 1, height: 1),
          'image/png',
        ),
        isNull,
      );
      final truncated = _jpg().sublist(0, 20);
      expect(sanitizeLinkPreviewImage(truncated, 'image/jpeg'), isNull);
    });
  });
}
