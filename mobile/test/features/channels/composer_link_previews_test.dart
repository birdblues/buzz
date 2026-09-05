import 'dart:async';
import 'dart:typed_data';

import 'package:buzz/features/channels/composer_link_previews.dart';
import 'package:buzz/shared/link_preview/link_preview_fetcher.dart';
import 'package:buzz/shared/link_preview/link_preview_image.dart';
import 'package:buzz/shared/link_preview/link_preview_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

const _url = 'https://example.com/a';
const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _blob = 'https://relay.example/media/$_sha.jpg';
const _debounce = Duration(milliseconds: 10);

class _FakeFetcher extends LinkPreviewFetcher {
  _FakeFetcher(this.handler)
    : super(
        clientFactory: () =>
            http_testing.MockClient((_) async => http.Response('', 404)),
      );

  final Future<LinkPreviewCapture?> Function(Uri url) handler;
  int calls = 0;

  @override
  Future<LinkPreviewCapture?> fetch(Uri url) {
    calls += 1;
    return handler(url);
  }
}

LinkPreviewCapture _capture({bool withImage = true}) => LinkPreviewCapture(
  metadata: const LinkPreviewMetadata(
    title: 'Title',
    siteName: 'Example',
    description: 'Desc',
  ),
  image: withImage
      ? SanitizedLinkPreviewImage(
          bytes: Uint8List.fromList([1, 2, 3]),
          mimeType: 'image/jpeg',
        )
      : null,
);

/// Polls until [ready] holds; the controller works on real timers, so tests
/// wait for state instead of for a fixed delay.
Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met in time');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Lets the debounce and any queued microtasks run.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  setUp(clearComposerLinkPreviewCache);

  test(
    'previews a link after the debounce and tags it with its blob',
    () async {
      final fetcher = _FakeFetcher((_) async => _capture());
      final uploads = <String>[];
      final controller = ComposerLinkPreviewsController(
        fetcher: fetcher,
        upload: (bytes, mimeType) async {
          uploads.add(mimeType);
          return (url: _blob, sha256: _sha);
        },
        debounce: _debounce,
      );
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.updateContent('see $_url');
      expect(controller.previews, isEmpty);
      await _until(
        () =>
            controller.previews.length == 1 &&
            controller.previews.single.status ==
                ComposerLinkPreviewStatus.ready,
      );

      final preview = controller.previews.single;
      expect(preview.status, ComposerLinkPreviewStatus.ready);
      expect(preview.metadata?.title, 'Title');
      expect(preview.imageBytes, [1, 2, 3]);
      expect(preview.tag, [
        'link-preview',
        'snapshot',
        '1',
        _url,
        'Title',
        'Example',
        'Desc',
        _blob,
        _sha,
        '',
        '',
      ]);
      expect(uploads, ['image/jpeg']);
      expect(notifications, greaterThan(0));
      expect(await controller.tagsForSend('see $_url'), [preview.tag]);
    },
  );

  test('uses the hostname as the site name when the page has none', () async {
    final fetcher = _FakeFetcher(
      (_) async => const LinkPreviewCapture(
        metadata: LinkPreviewMetadata(title: 'Title'),
      ),
    );
    final controller = ComposerLinkPreviewsController(
      fetcher: fetcher,
      upload: (_, _) async => throw StateError('no media to upload'),
      debounce: _debounce,
    );
    addTearDown(controller.dispose);
    controller.updateContent('https://www.example.com/x');
    await _until(() => controller.previews.singleOrNull?.tag != null);
    expect(controller.previews.single.tag?[5], 'example.com');
    expect(controller.previews.single.tag?[6], '');
  });

  test('a failed capture marks the preview failed and sends no tag', () async {
    final fetcher = _FakeFetcher((_) async => null);
    final controller = ComposerLinkPreviewsController(
      fetcher: fetcher,
      upload: (_, _) async => (url: _blob, sha256: _sha),
      debounce: _debounce,
    );
    addTearDown(controller.dispose);
    controller.updateContent(_url);
    await _until(
      () =>
          controller.previews.singleOrNull?.status ==
          ComposerLinkPreviewStatus.failed,
    );
    expect(controller.previews.single.status, ComposerLinkPreviewStatus.failed);
    expect(await controller.tagsForSend(_url), isEmpty);
  });

  test('an upload failure leaves a media-less tag', () async {
    final fetcher = _FakeFetcher((_) async => _capture());
    final controller = ComposerLinkPreviewsController(
      fetcher: fetcher,
      upload: (_, _) async => throw Exception('relay down'),
      debounce: _debounce,
    );
    addTearDown(controller.dispose);
    controller.updateContent(_url);
    await _until(() => controller.previews.singleOrNull?.tag != null);
    final tag = controller.previews.single.tag!;
    expect(tag.sublist(7), ['', '', '', '']);
    expect(controller.previews.single.status, ComposerLinkPreviewStatus.ready);
  });

  test(
    'a link that leaves the draft drops at once; its late capture is ignored',
    () async {
      final gate = Completer<LinkPreviewCapture?>();
      final fetcher = _FakeFetcher((_) => gate.future);
      final controller = ComposerLinkPreviewsController(
        fetcher: fetcher,
        upload: (_, _) async => (url: _blob, sha256: _sha),
        debounce: _debounce,
      );
      addTearDown(controller.dispose);
      controller.updateContent(_url);
      await _until(() => controller.previews.length == 1);
      expect(
        controller.previews.single.status,
        ComposerLinkPreviewStatus.loading,
      );

      controller.updateContent('nothing here');
      await _until(() => controller.previews.isEmpty);

      gate.complete(_capture());
      await _settle();
      expect(controller.previews, isEmpty);
      expect(await controller.tagsForSend('nothing here'), isEmpty);
    },
  );

  test('suppressing sends the none marker until the links leave', () async {
    final fetcher = _FakeFetcher((_) async => _capture());
    final controller = ComposerLinkPreviewsController(
      fetcher: fetcher,
      upload: (_, _) async => (url: _blob, sha256: _sha),
      debounce: _debounce,
    );
    addTearDown(controller.dispose);
    controller.updateContent(_url);
    await _until(() => controller.previews.length == 1);
    controller.suppress();
    expect(controller.suppressed, isTrue);
    expect(await controller.tagsForSend(_url), [
      ['link-preview', 'none'],
    ]);
    // No links in the body: nothing to suppress, nothing to send.
    expect(await controller.tagsForSend('plain'), isEmpty);
    controller.updateContent('plain');
    await _until(() => !controller.suppressed);
    expect(controller.suppressed, isFalse);
  });

  test('tagsForSend waits for work in flight, within its budget', () async {
    final fetcher = _FakeFetcher((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return _capture(withImage: false);
    });
    final controller = ComposerLinkPreviewsController(
      fetcher: fetcher,
      upload: (_, _) async => (url: _blob, sha256: _sha),
      debounce: const Duration(seconds: 30),
    );
    addTearDown(controller.dispose);
    controller.updateContent(_url);
    final tags = await controller.tagsForSend(_url);
    expect(tags, hasLength(1));
    expect(tags.single[3], _url);
  });

  test('tagsForSend sends without stragglers after the budget', () async {
    final fetcher = _FakeFetcher(
      (_) => Completer<LinkPreviewCapture?>().future,
    );
    final controller = ComposerLinkPreviewsController(
      fetcher: fetcher,
      upload: (_, _) async => (url: _blob, sha256: _sha),
      debounce: _debounce,
    );
    addTearDown(controller.dispose);
    final tags = await controller.tagsForSend(
      _url,
      budget: const Duration(milliseconds: 20),
    );
    expect(tags, isEmpty);
  });

  test('a captured snapshot is reused when the link comes back', () async {
    final fetcher = _FakeFetcher((_) async => _capture());
    final controller = ComposerLinkPreviewsController(
      fetcher: fetcher,
      upload: (_, _) async => (url: _blob, sha256: _sha),
      debounce: _debounce,
    );
    addTearDown(controller.dispose);
    controller.updateContent(_url);
    await _until(() => controller.previews.singleOrNull?.tag != null);
    controller.clear();
    expect(controller.previews, isEmpty);

    controller.updateContent('again $_url');
    await _until(() => controller.previews.length == 1);
    expect(controller.previews.single.status, ComposerLinkPreviewStatus.ready);
    expect(fetcher.calls, 1);
  });

  test('the snapshot cache is bounded, oldest first', () async {
    final fetcher = _FakeFetcher((_) async => _capture(withImage: false));
    final controller = ComposerLinkPreviewsController(
      fetcher: fetcher,
      upload: (_, _) async => (url: _blob, sha256: _sha),
      debounce: _debounce,
    );
    addTearDown(controller.dispose);
    const first = 'https://example.com/first';
    controller.updateContent(first);
    await _until(() => controller.previews.singleOrNull?.tag != null);
    // Enough other links to push the first one out (8 per draft).
    for (var batch = 0; batch < composerLinkPreviewCacheLimit ~/ 8; batch++) {
      final urls = [
        for (var i = 0; i < 8; i++) 'https://example.com/b$batch-$i',
      ];
      controller.updateContent(urls.join(' '));
      await _until(
        () =>
            controller.previews.map((p) => p.url).join(' ') == urls.join(' ') &&
            controller.previews.every((p) => p.tag != null),
      );
    }
    final callsBefore = fetcher.calls;
    controller.updateContent(first);
    await _until(() => controller.previews.singleOrNull?.tag != null);
    expect(fetcher.calls, callsBefore + 1);
  });

  test('keeps previews in body order and caps them', () async {
    final fetcher = _FakeFetcher((_) async => _capture(withImage: false));
    final controller = ComposerLinkPreviewsController(
      fetcher: fetcher,
      upload: (_, _) async => (url: _blob, sha256: _sha),
      debounce: _debounce,
    );
    addTearDown(controller.dispose);
    final urls = [for (var i = 0; i < 10; i++) 'https://example.com/p$i'];
    controller.updateContent(urls.join(' '));
    await _until(() => controller.previews.length == 8);
    expect(controller.previews.map((p) => p.url), urls.take(8));
  });
}
