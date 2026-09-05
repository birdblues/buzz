import 'package:buzz/shared/link_preview/link_preview_youtube.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isYouTubeVideoUrl', () {
    test('recognises the video URL shapes', () {
      for (final url in [
        'https://youtu.be/abc123',
        'https://www.youtube.com/watch?v=abc123',
        'https://m.youtube.com/watch?v=abc123&t=10',
        'https://music.youtube.com/watch?v=abc123',
        'https://www.youtube.com/shorts/abc123',
        'https://www.youtube.com/live/abc123',
        'https://www.youtube.com/embed/abc123',
      ]) {
        expect(isYouTubeVideoUrl(Uri.parse(url)), isTrue, reason: url);
      }
    });

    test('rejects channels, playlists, and other hosts', () {
      for (final url in [
        'https://youtu.be/',
        'https://www.youtube.com/',
        'https://www.youtube.com/watch',
        'https://www.youtube.com/watch?v=',
        'https://www.youtube.com/@channel',
        'https://www.youtube.com/playlist?list=PL1',
        'https://www.youtube.com/shorts/',
        'https://notyoutube.com/watch?v=abc',
      ]) {
        expect(isYouTubeVideoUrl(Uri.parse(url)), isFalse, reason: url);
      }
    });
  });

  group('youTubeOEmbedUri', () {
    test('wraps the video URL', () {
      final oembed = youTubeOEmbedUri(Uri.parse('https://youtu.be/abc123'))!;
      expect(oembed.origin, 'https://www.youtube.com');
      expect(oembed.path, '/oembed');
      expect(oembed.queryParameters, {
        'format': 'json',
        'url': 'https://youtu.be/abc123',
      });
    });

    test('canonicalises embed URLs and rejects bad ids', () {
      final oembed = youTubeOEmbedUri(
        Uri.parse('https://www.youtube.com/embed/abc_-1?autoplay=1'),
      )!;
      expect(
        oembed.queryParameters['url'],
        'https://www.youtube.com/watch?v=abc_-1',
      );
      expect(
        youTubeOEmbedUri(Uri.parse('https://www.youtube.com/embed/a%20b')),
        isNull,
      );
    });
  });

  group('metadataFromYouTubeOEmbed', () {
    test('maps title, provider, author, and thumbnail', () {
      final parsed = metadataFromYouTubeOEmbed({
        'title': '  A video  ',
        'author_name': 'Some Channel',
        'provider_name': 'YouTube',
        'thumbnail_url': 'https://i.ytimg.com/vi/abc/hqdefault.jpg',
      })!;
      expect(parsed.metadata.title, 'A video');
      expect(parsed.metadata.siteName, 'YouTube');
      expect(parsed.metadata.description, 'Some Channel');
      expect(
        parsed.thumbnailUrl,
        Uri.parse('https://i.ytimg.com/vi/abc/hqdefault.jpg'),
      );
    });

    test('defaults the provider and tolerates missing fields', () {
      final parsed = metadataFromYouTubeOEmbed({'title': 'A video'})!;
      expect(parsed.metadata.siteName, 'YouTube');
      expect(parsed.metadata.description, isNull);
      expect(parsed.thumbnailUrl, isNull);
      expect(metadataFromYouTubeOEmbed({'title': ''}), isNull);
      expect(metadataFromYouTubeOEmbed({'author_name': 'x'}), isNull);
    });
  });
}
