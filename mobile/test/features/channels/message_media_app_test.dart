import 'package:buzz/features/channels/message_media.dart';
import 'package:flutter_test/flutter_test.dart';

const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _url = 'https://relay.example.com/media/$_sha.html';

void main() {
  group('parseImetaTags (sandboxed apps)', () {
    test('reads the blob hash and themed previews', () {
      final entries = parseImetaTags([
        [
          'imeta',
          'url $_url',
          'm text/html',
          'x $_sha',
          'filename sequence.html',
          'preview-light https://relay.example.com/media/light.png',
          'preview-dark https://relay.example.com/media/dark.png',
        ],
      ]);
      final entry = entries[_url]!;
      expect(entry.sha256, _sha);
      expect(entry.previewLight, 'https://relay.example.com/media/light.png');
      expect(entry.previewDark, 'https://relay.example.com/media/dark.png');
      expect(entry.isApp, isTrue);
    });

    test('lowercases the hash and drops malformed ones', () {
      final upper = parseImetaTags([
        ['imeta', 'url $_url', 'm text/html', 'x ${_sha.toUpperCase()}'],
      ])[_url]!;
      expect(upper.sha256, _sha);
      expect(upper.isApp, isTrue);

      for (final bad in ['deadbeef', '${_sha}0', 'x' * 64, '']) {
        final entry = parseImetaTags([
          ['imeta', 'url $_url', 'm text/html', 'x $bad'],
        ])[_url]!;
        expect(entry.sha256, isNull, reason: bad);
        expect(entry.isApp, isFalse, reason: bad);
      }
    });

    test('a hash on a non-HTML attachment is not an app', () {
      final entry = parseImetaTags([
        ['imeta', 'url $_url', 'm image/png', 'x $_sha'],
      ])[_url]!;
      expect(entry.sha256, _sha);
      expect(entry.isApp, isFalse);
    });
  });

  group('classifyMediaUrl (sandboxed apps)', () {
    test('text/html with a blob hash is an app', () {
      expect(
        classifyMediaUrl(
          _url,
          imeta: const ImetaEntry(
            url: _url,
            mimeType: 'text/html',
            sha256: _sha,
          ),
        ),
        MessageMediaKind.app,
      );
    });

    test('text/html without a hash stays an ordinary link', () {
      expect(
        classifyMediaUrl(
          _url,
          imeta: const ImetaEntry(url: _url, mimeType: 'text/html'),
        ),
        isNull,
      );
      expect(classifyMediaUrl(_url), isNull);
    });
  });
}
