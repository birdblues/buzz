import 'package:buzz/shared/link_preview/link_preview_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

final _page = Uri.parse('https://example.com/posts/1?x=1');

void main() {
  group('decodeHtmlEntities', () {
    test('decodes named and numeric entities', () {
      expect(
        decodeHtmlEntities('Tom &amp; Jerry &quot;&#39;&#x27;&apos;&lt;&gt;'),
        'Tom & Jerry "\'\'\'<>',
      );
      expect(decodeHtmlEntities('caf&#233; &#x1F41D;'), 'café 🐝');
    });

    test('leaves malformed numeric entities alone', () {
      expect(
        decodeHtmlEntities('&#; &#xZZ; &#99999999;'),
        '&#; &#xZZ; &#99999999;',
      );
      expect(decodeHtmlEntities('&#38'), '&#38');
    });
  });

  group('attributeValue', () {
    test('reads quoted, single-quoted, and bare values case-insensitively', () {
      expect(
        attributeValue('<meta CONTENT="a b" property=og:x>', 'content'),
        'a b',
      );
      expect(attributeValue("<meta content='a b'>", 'content'), 'a b');
      expect(
        attributeValue('<meta content=bare property="x">', 'content'),
        'bare',
      );
    });

    test('does not match a name inside another attribute', () {
      expect(attributeValue('<link hreflang="en" href="/x">', 'rel'), isNull);
      expect(
        attributeValue('<meta data-content="no" content="yes">', 'content'),
        'yes',
      );
    });

    test('decodes entities in the value', () {
      expect(
        attributeValue('<meta content="Tom &amp; Jerry">', 'content'),
        'Tom & Jerry',
      );
    });
  });

  group('extractLinkPreviewMetadata', () {
    test('prefers Open Graph, then Twitter, then the title element', () {
      const html = '''
<html><head>
<title>Fallback title</title>
<meta name="twitter:title" content="Twitter title">
<meta property="og:title" content="OG title">
<meta property="og:site_name" content="Example">
<meta property="og:description" content="Line one&#10;&#10;Line   two">
<meta property="og:image" content="/img/cover.jpg">
<link rel="icon" type="image/png" href="/favicon.png">
</head></html>''';
      final metadata = extractLinkPreviewMetadata(html, _page);
      expect(metadata, isNotNull);
      expect(metadata!.title, 'OG title');
      expect(metadata.siteName, 'Example');
      expect(metadata.description, 'Line one\n\nLine two');
      expect(metadata.imageUrl, Uri.parse('https://example.com/img/cover.jpg'));
      expect(metadata.faviconUrl, Uri.parse('https://example.com/favicon.png'));
    });

    test('falls back to twitter then <title>', () {
      expect(
        extractLinkPreviewMetadata(
          '<meta name="twitter:title" content="TW"><title>T</title>',
          _page,
        )?.title,
        'TW',
      );
      expect(
        extractLinkPreviewMetadata(
          '<html><title> Spaced   title </title>',
          _page,
        )?.title,
        'Spaced title',
      );
    });

    test('yields nothing without a usable title', () {
      expect(extractLinkPreviewMetadata('<p>no title</p>', _page), isNull);
      expect(
        extractLinkPreviewMetadata(
          '<title>Sign in - Google Accounts</title>',
          _page,
        ),
        isNull,
      );
      expect(extractLinkPreviewMetadata('<title>   </title>', _page), isNull);
    });

    test('strips Google suffixes and clips long text', () {
      expect(normalizeMetadataText('My doc - Google Docs'), 'My doc');
      expect(
        normalizeMetadataText('a' * 500)!.length,
        linkPreviewMaxTitleChars,
      );
      expect(
        normalizeMetadataDescription('${'b' * 500}\r\n  c  d '),
        hasLength(linkPreviewMaxDescriptionChars),
      );
      expect(normalizeMetadataDescription('  \n \n'), isNull);
    });

    test('clips titles on grapheme boundaries', () {
      final title = normalizeMetadataText('🐝' * 200)!;
      expect(title.runes.length, linkPreviewMaxTitleChars);
    });
  });

  group('extractImageUrl', () {
    test('resolves relative and protocol-relative images against the page', () {
      expect(
        extractImageUrl(
          '<meta property="og:image" content="//cdn.example.com/a.png">',
          _page,
        ),
        Uri.parse('https://cdn.example.com/a.png'),
      );
      expect(
        extractImageUrl(
          '<meta property="og:image:secure_url" content="b.png">',
          _page,
        ),
        Uri.parse('https://example.com/posts/b.png'),
      );
      expect(
        extractImageUrl(
          '<meta name="twitter:image" content="https://x.example/c.jpg">',
          _page,
        ),
        Uri.parse('https://x.example/c.jpg'),
      );
      expect(
        extractImageUrl('<meta property="og:image" content="  ">', _page),
        isNull,
      );
    });
  });

  group('extractFaviconUrl', () {
    test('prefers a raster icon over an .ico fallback', () {
      const html = '''
<link rel="shortcut icon" href="/favicon.ico">
<link rel="apple-touch-icon" href="/touch.png">''';
      expect(
        extractFaviconUrl(html, _page),
        Uri.parse('https://example.com/touch.png'),
      );
    });

    test('falls back to the first icon of any type', () {
      expect(
        extractFaviconUrl('<link rel="icon" href="/favicon.ico">', _page),
        Uri.parse('https://example.com/favicon.ico'),
      );
      expect(
        extractFaviconUrl('<link rel="stylesheet" href="/a.css">', _page),
        isNull,
      );
    });

    test('honours a declared raster type', () {
      expect(
        extractFaviconUrl(
          '<link rel="icon" type="image/png" href="/icon">',
          _page,
        ),
        Uri.parse('https://example.com/icon'),
      );
    });
  });
}
