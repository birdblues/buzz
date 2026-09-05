import 'package:buzz/features/channels/message_content/link_preview_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const _relay = 'https://relay.example.com';
const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _otherSha =
    'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const _url = 'https://www.example.com/post';
const _image = '$_relay/media/$_sha.png';
const _favicon = '$_relay/media/$_otherSha.webp';

List<String> _tag({
  String version = '1',
  String url = _url,
  String title = 'Example post',
  String site = 'Example',
  String description = 'A short description.',
  String image = '',
  String imageSha = '',
  String favicon = '',
  String faviconSha = '',
}) => [
  'link-preview',
  'snapshot',
  version,
  url,
  title,
  site,
  description,
  image,
  imageSha,
  favicon,
  faviconSha,
];

List<LinkPreviewSnapshot> _parse(
  List<List<String>> tags, {
  String content = 'Read $_url today',
  String relay = _relay,
}) => parseLinkPreviewSnapshots(tags, content, relayBaseUrl: relay);

void main() {
  group('parseLinkPreviewSnapshots', () {
    test('parses a full snapshot with relay-hosted image and favicon', () {
      final previews = _parse([
        _tag(
          image: _image,
          imageSha: _sha,
          favicon: _favicon,
          faviconSha: _otherSha,
        ),
      ]);

      expect(previews, hasLength(1));
      final preview = previews.single;
      expect(preview.canonicalUrl, _url);
      expect(preview.title, 'Example post');
      expect(preview.siteName, 'Example');
      expect(preview.description, 'A short description.');
      expect(preview.imageUrl, _image);
      expect(preview.faviconUrl, _favicon);
      expect(preview.hostname, 'example.com');
    });

    test('an empty media pair means no image', () {
      final preview = _parse([_tag()]).single;
      expect(preview.imageUrl, isNull);
      expect(preview.faviconUrl, isNull);
    });

    test('a suppression tag hides every preview', () {
      expect(
        _parse([
          ['link-preview', 'none'],
          _tag(),
        ]),
        isEmpty,
      );
      expect(
        hasLinkPreviewSuppression([
          ['link-preview', 'none'],
        ]),
        isTrue,
      );
      expect(hasLinkPreviewSuppression([_tag()]), isFalse);
      expect(
        hasLinkPreviewSuppression([
          ['link-preview', 'none', 'extra'],
        ]),
        isFalse,
      );
    });

    test('ignores malformed tags', () {
      expect(_parse([_tag(version: '2')]), isEmpty);
      expect(_parse([_tag()..removeLast()]), isEmpty);
      expect(_parse([_tag()..add('extra')]), isEmpty);
      expect(
        _parse([
          ['link-preview', 'other'],
        ]),
        isEmpty,
      );
      expect(
        _parse([
          ['link-preview'],
        ]),
        isEmpty,
      );
    });

    test('requires an https canonical URL without credentials or fragment', () {
      const http = 'http://www.example.com/post';
      const fragment = '$_url#section';
      const userinfo = 'https://user:pw@www.example.com/post';
      expect(_parse([_tag(url: http)], content: http), isEmpty);
      expect(_parse([_tag(url: fragment)], content: fragment), isEmpty);
      expect(_parse([_tag(url: userinfo)], content: userinfo), isEmpty);
      expect(_parse([_tag(url: 'not a url')], content: 'not a url'), isEmpty);
    });

    test('matches whole links, never substrings of another link', () {
      const bank = 'https://bank.example';
      expect(
        _parse([_tag(url: bank)], content: 'see https://bank.example.evil/x'),
        isEmpty,
      );
      expect(_parse([_tag(url: bank)], content: 'see $bank now'), hasLength(1));
      expect(_parse([_tag(url: bank)], content: 'abc$bank'), isEmpty);
    });

    test('requires the URL to appear in the visible body', () {
      expect(_parse([_tag()], content: 'no link here'), isEmpty);
      expect(_parse([_tag()], content: '```\n$_url\n```'), isEmpty);
      expect(_parse([_tag()], content: 'see `$_url`'), isEmpty);
      expect(_parse([_tag()], content: '    $_url'), isEmpty);
      expect(_parse([_tag()], content: '![alt]($_url)'), isEmpty);
      expect(_parse([_tag()], content: '[label]($_url)'), hasLength(1));
      expect(_parse([_tag()], content: '$_url.'), hasLength(1));
    });

    test('enforces the relay text limits', () {
      final longTitle = 'a' * 301;
      final longSite = 'b' * 101;
      final longDescription = 'c' * 1001;
      expect(_parse([_tag(title: longTitle)]), isEmpty);
      expect(_parse([_tag(site: longSite)]), isEmpty);
      expect(_parse([_tag(description: longDescription)]), isEmpty);
      expect(_parse([_tag(title: 'a' * 300)]), hasLength(1));
      // Limits are in UTF-8 bytes, like the relay.
      expect(_parse([_tag(title: '한' * 101)]), isEmpty);
      expect(_parse([_tag(title: '한' * 100)]), hasLength(1));
    });

    test('rejects control characters except newlines in the description', () {
      expect(_parse([_tag(title: 'bad\ntitle')]), isEmpty);
      expect(_parse([_tag(title: 'bad\u007ftitle')]), isEmpty);
      expect(_parse([_tag(site: 'bad\u001bsite')]), isEmpty);
      expect(_parse([_tag(description: 'line one\nline two')]), hasLength(1));
      expect(_parse([_tag(description: 'bad\ttab')]), isEmpty);
      // C1 controls too, as the relay's `char::is_control`.
      expect(_parse([_tag(title: 'bad\u0080title')]), isEmpty);
      expect(_parse([_tag(title: 'bad\u009ftitle')]), isEmpty);
      expect(_parse([_tag(title: 'fine\u00a0title')]), hasLength(1));
    });

    test('accepts only matching image blobs on this relay', () {
      List<LinkPreviewSnapshot> withImage(String image, String sha) =>
          _parse([_tag(image: image, imageSha: sha)]);

      expect(withImage(_image, _sha), hasLength(1));
      expect(withImage('$_relay/media/$_sha.jpg', _sha), hasLength(1));
      expect(
        withImage('https://relay.example.com:443/media/$_sha.png', _sha),
        hasLength(1),
      );
      expect(
        withImage('https://elsewhere.example/media/$_sha.png', _sha),
        isEmpty,
      );
      expect(
        withImage('http://relay.example.com/media/$_sha.png', _sha),
        isEmpty,
      );
      // The port defaults per scheme: https on :80 is not this relay.
      expect(
        withImage('https://relay.example.com:80/media/$_sha.png', _sha),
        isEmpty,
      );
      expect(
        withImage('https://RELAY.example.com/media/$_sha.png', _sha),
        hasLength(1),
      );
      expect(withImage('$_relay/media/$_sha.svg', _sha), isEmpty);
      expect(withImage('$_relay/media/$_sha.html', _sha), isEmpty);
      expect(withImage(_image, _otherSha), isEmpty);
      expect(withImage('$_image?x=1', _sha), isEmpty);
      expect(withImage('$_relay/other/$_sha.png', _sha), isEmpty);
      expect(withImage('', _sha), isEmpty);
      expect(withImage(_image, ''), isEmpty);
      expect(withImage(_image, _sha.toUpperCase()), isEmpty);
    });

    test('the favicon pair is validated the same way', () {
      expect(
        _parse([
          _tag(favicon: 'https://elsewhere.example/f.png', faviconSha: _sha),
        ]),
        isEmpty,
      );
      expect(
        _parse([_tag(favicon: _favicon, faviconSha: _otherSha)]),
        hasLength(1),
      );
    });

    test('deduplicates by canonical URL and caps at eight', () {
      expect(_parse([_tag(), _tag(title: 'dup')]), hasLength(1));

      final urls = [for (var i = 0; i < 9; i++) 'https://example.com/p$i'];
      final previews = _parse([
        for (final url in urls) _tag(url: url),
      ], content: urls.join(' '));
      expect(previews, hasLength(linkPreviewMaxSnapshots));
      expect(previews.map((p) => p.canonicalUrl), urls.take(8));
    });

    test('orders previews by where the link appears in the body', () {
      const first = 'https://example.com/first';
      const second = 'https://example.com/second';
      final previews = _parse([
        _tag(url: second),
        _tag(url: first),
      ], content: '$first then $second');
      expect(previews.map((p) => p.canonicalUrl), [first, second]);
    });

    test('returns nothing without a relay base URL', () {
      expect(_parse([_tag()], relay: ''), isEmpty);
    });
  });

  group('maskHiddenLinkPreviewContent', () {
    test('blanks code and image syntax but keeps offsets', () {
      const content = 'a `x` b\n```\ncode\n```\n![i](u) c';
      final masked = maskHiddenLinkPreviewContent(content);
      expect(masked.length, content.length);
      expect(masked, 'a     b\n   \n    \n   \n        c');
    });
  });

  group('LinkPreviewSnapshot.hostname', () {
    test('strips a leading www.', () {
      const preview = LinkPreviewSnapshot(
        canonicalUrl: 'https://www.example.com/',
        title: '',
        siteName: '',
        description: '',
      );
      expect(preview.hostname, 'example.com');
    });
  });
}
