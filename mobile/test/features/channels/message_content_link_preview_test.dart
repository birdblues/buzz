import 'dart:convert';

import 'package:buzz/features/channels/message_content.dart';
import 'package:buzz/features/channels/message_content/link_preview_card.dart';
import 'package:buzz/features/channels/message_content/link_preview_snapshot.dart';
import 'package:buzz/shared/relay/media_image.dart';
import 'package:buzz/shared/relay/relay_provider.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

// Minimal valid 1x1 transparent PNG.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

const _relay = 'https://relay.example.com';
const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _url = 'https://www.example.com/post';
const _image = '$_relay/media/$_sha.png';

List<String> _tag({
  String url = _url,
  String title = 'Example post',
  String description = 'A short description.',
  String image = '',
  String imageSha = '',
}) => [
  'link-preview',
  'snapshot',
  '1',
  url,
  title,
  'Example',
  description,
  image,
  imageSha,
  '',
  '',
];

class _RelayConfigNotifier extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: _relay);
}

Widget _testable(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: [
      relayConfigProvider.overrideWith(_RelayConfigNotifier.new),
      mediaHttpClientProvider.overrideWithValue(
        http_testing.MockClient(
          (_) async => http.Response.bytes(_pngBytes, 200),
        ),
      ),
      ...overrides,
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: child),
    ),
  );
}

Finder _card() => find.byKey(const ValueKey('link-preview:$_url'));

void main() {
  testWidgets('a snapshot tag renders a compact card below the body', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testable(
        MessageContent(
          content: 'Read $_url today',
          tags: [_tag(image: _image, imageSha: _sha)],
        ),
      ),
    );
    await tester.pump();

    expect(_card(), findsOneWidget);
    expect(find.text('Example post'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('A short description.'), findsOneWidget);
    final image = tester.widget<MediaImage>(
      find.byKey(const ValueKey('link-preview-image:$_image')),
    );
    expect(image.url, _image);
  });

  testWidgets('a snapshot without an image has no thumbnail', (tester) async {
    await tester.pumpWidget(
      _testable(MessageContent(content: 'Read $_url today', tags: [_tag()])),
    );
    await tester.pump();

    expect(_card(), findsOneWidget);
    expect(find.byType(MediaImage), findsNothing);
  });

  testWidgets('an empty title falls back to the hostname', (tester) async {
    await tester.pumpWidget(
      _testable(
        MessageContent(
          content: 'Read $_url today',
          tags: [_tag(title: '')],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('example.com'), findsNWidgets(2));
  });

  testWidgets('cropped surfaces show no preview card', (tester) async {
    await tester.pumpWidget(
      _testable(
        MessageContent(
          content: 'Read $_url today',
          tags: [_tag()],
          maxLines: 2,
        ),
      ),
    );
    await tester.pump();

    expect(_card(), findsNothing);
  });

  testWidgets('box-cropped surfaces (allowAppCards false) show no card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testable(
        MessageContent(
          content: 'Read $_url today',
          tags: [_tag()],
          allowAppCards: false,
        ),
      ),
    );
    await tester.pump();

    expect(_card(), findsNothing);
  });

  testWidgets('a suppression tag hides the card', (tester) async {
    await tester.pumpWidget(
      _testable(
        MessageContent(
          content: 'Read $_url today',
          tags: [
            ['link-preview', 'none'],
            _tag(),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(_card(), findsNothing);
  });

  testWidgets('a tag whose URL is not in the body is ignored', (tester) async {
    await tester.pumpWidget(
      _testable(
        MessageContent(content: 'No link in this message', tags: [_tag()]),
      ),
    );
    await tester.pump();

    expect(_card(), findsNothing);
    expect(find.text('Example post'), findsNothing);
  });

  testWidgets('a foreign image host drops the whole snapshot', (tester) async {
    await tester.pumpWidget(
      _testable(
        MessageContent(
          content: 'Read $_url today',
          tags: [
            _tag(
              image: 'https://elsewhere.example/media/$_sha.png',
              imageSha: _sha,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(_card(), findsNothing);
    expect(find.byType(MediaImage), findsNothing);
  });

  testWidgets('the card follows a trailing image gallery', (tester) async {
    const attachment = '$_relay/media/$_sha.jpg';
    await tester.pumpWidget(
      _testable(
        MessageContent(
          content: 'Read $_url today\n\n![photo]($attachment)',
          tags: [
            ['imeta', 'url $attachment', 'm image/jpeg'],
            _tag(),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(_card(), findsOneWidget);
    // Body, then the attached image, then the preview card.
    final gallery = find.byKey(
      const ValueKey('message-media-image-preview:$attachment'),
    );
    expect(gallery, findsOneWidget);
    expect(
      tester.getTopLeft(_card()).dy,
      greaterThan(tester.getBottomLeft(gallery).dy - 1),
    );
  });

  testWidgets('tapping the card opens the link', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _testable(
        LinkPreviewCard(
          snapshot: const LinkPreviewSnapshot(
            canonicalUrl: _url,
            title: 'Example post',
            siteName: 'Example',
            description: 'One\n\nTwo',
          ),
          onOpen: () => opened += 1,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Example post'));
    expect(opened, 1);
    // Newlines collapse in the compact card, and every line clamps to one
    // like desktop's compact card so the block matches the thumbnail height.
    expect(find.text('One Two'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Example post')).maxLines, 1);
    expect(tester.widget<Text>(find.text('One Two')).maxLines, 1);
    expect(tester.widget<Text>(find.text('example.com')).maxLines, 1);
  });
}
