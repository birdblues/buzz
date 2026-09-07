import 'dart:convert';

import 'package:buzz/features/channels/message_content.dart';
import 'package:buzz/features/channels/message_content/app_card.dart';
import 'package:buzz/features/channels/sandbox_bridge.dart';
import 'package:buzz/features/channels/sandbox_session.dart';
import 'package:buzz/shared/relay/media_image.dart';
import 'package:buzz/shared/relay/relay_info.dart';
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

const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _url = 'https://relay.example.com/media/$_sha.html';
const _light = 'https://relay.example.com/media/light.png';
const _dark = 'https://relay.example.com/media/dark.png';
const _door = 'http://relay.example.com:3001';

const _appTag = [
  'imeta',
  'url $_url',
  'm text/html',
  'x $_sha',
  'filename sequence.html',
  'size 20480',
  'preview-light $_light',
  'preview-dark $_dark',
];

Widget _testable(
  Widget child, {
  List<Override> overrides = const [],
  ThemeData? theme,
  http.Client? mediaClient,
}) {
  return ProviderScope(
    overrides: [
      mediaHttpClientProvider.overrideWithValue(
        mediaClient ??
            http_testing.MockClient(
              (_) async => http.Response.bytes(_pngBytes, 200),
            ),
      ),
      ...overrides,
    ],
    child: MaterialApp(
      theme: theme ?? AppTheme.light(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('an HTML attachment with a hash renders an app card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testable(
        const MessageContent(
          content: '[sequence.html]($_url)',
          tags: [_appTag],
          authorLabel: 'Ada',
        ),
        overrides: [appContentUrlProvider.overrideWithValue(_door)],
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('app-card:$_sha')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-card-run')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-card-download')), findsNothing);
    expect(find.byKey(const ValueKey('app-card-running')), findsNothing);
    expect(find.text('sequence.html'), findsOneWidget);
    expect(
      find.textContaining('App shared by Ada'),
      findsOneWidget,
      reason: 'the chrome names the sender',
    );
    expect(find.textContaining('20 KB'), findsOneWidget);
    expect(find.textContaining('runs in a sandbox'), findsOneWidget);
    final preview = tester.widget<MediaImage>(find.byType(MediaImage));
    expect(preview.url, _light, reason: 'light theme picks the light preview');
  });

  testWidgets('the dark theme picks the dark preview', (tester) async {
    await tester.pumpWidget(
      _testable(
        const MessageContent(
          content: '[sequence.html]($_url)',
          tags: [_appTag],
        ),
        overrides: [appContentUrlProvider.overrideWithValue(_door)],
        theme: AppTheme.dark(),
      ),
    );
    await tester.pump();

    final preview = tester.widget<MediaImage>(find.byType(MediaImage));
    expect(preview.url, _dark);
    expect(find.textContaining('Shared app'), findsOneWidget);
  });

  testWidgets('without an app door the attachment stays a link', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testable(
        const MessageContent(
          content: '[sequence.html]($_url)',
          tags: [_appTag],
        ),
        overrides: [appContentUrlProvider.overrideWithValue(null)],
      ),
    );
    await tester.pump();

    expect(find.byType(AppCard), findsNothing);
    expect(find.byType(MediaImage), findsNothing);
    expect(
      find.textContaining('sequence.html', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('without a blob hash the attachment stays a link', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testable(
        const MessageContent(
          content: '[sequence.html]($_url)',
          tags: [
            ['imeta', 'url $_url', 'm text/html', 'filename sequence.html'],
          ],
        ),
        overrides: [appContentUrlProvider.overrideWithValue(_door)],
      ),
    );
    await tester.pump();

    expect(find.byType(AppCard), findsNothing);
  });

  testWidgets('clamped previews (search, inbox) never show the card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testable(
        const MessageContent(
          content: '[sequence.html]($_url)',
          tags: [_appTag],
          maxLines: 2,
        ),
        overrides: [appContentUrlProvider.overrideWithValue(_door)],
      ),
    );
    await tester.pump();

    expect(find.byType(AppCard), findsNothing);
  });

  testWidgets('image syntax pointing at an app also renders the card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testable(
        const MessageContent(content: '![app]($_url)', tags: [_appTag]),
        overrides: [appContentUrlProvider.overrideWithValue(_door)],
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('app-card:$_sha')), findsOneWidget);
  });

  testWidgets('image syntax without a door renders an inert link, no fetch', (
    tester,
  ) async {
    var requests = 0;
    await tester.pumpWidget(
      _testable(
        const MessageContent(content: '![app]($_url)', tags: [_appTag]),
        overrides: [appContentUrlProvider.overrideWithValue(null)],
        mediaClient: http_testing.MockClient((_) async {
          requests += 1;
          return http.Response.bytes(_pngBytes, 200);
        }),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(AppCard), findsNothing);
    expect(find.byType(MediaImage), findsNothing);
    expect(find.byKey(const ValueKey('app-link:$_sha')), findsOneWidget);
    expect(find.text('sequence.html'), findsOneWidget);
    expect(requests, 0, reason: 'HTML is never handed to the image decoder');
  });

  testWidgets('allowAppCards: false keeps cropped previews card-free', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testable(
        const MessageContent(
          content: '[sequence.html]($_url)',
          tags: [_appTag],
          allowAppCards: false,
        ),
        overrides: [appContentUrlProvider.overrideWithValue(_door)],
      ),
    );
    await tester.pump();

    expect(find.byType(AppCard), findsNothing);
    expect(find.byType(MediaImage), findsNothing);
    expect(
      find.textContaining('sequence.html', findRichText: true),
      findsWidgets,
    );

    await tester.pumpWidget(
      _testable(
        const MessageContent(
          content: '![app]($_url)',
          tags: [_appTag],
          allowAppCards: false,
        ),
        overrides: [appContentUrlProvider.overrideWithValue(_door)],
      ),
    );
    await tester.pump();

    expect(find.byType(AppCard), findsNothing);
    expect(find.byType(MediaImage), findsNothing);
    expect(find.byKey(const ValueKey('app-link:$_sha')), findsOneWidget);
  });

  testWidgets('a running app shows a green dot on the preview', (tester) async {
    final running = _RunningSessions();
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _testable(
        const MessageContent(
          content: '[sequence.html]($_url)',
          tags: [_appTag],
          appBridge: SandboxBridgeTarget(channelId: 'chan', messageId: 'm1'),
        ),
        overrides: [
          appContentUrlProvider.overrideWithValue(_door),
          sandboxSessionsProvider.overrideWith(() => running),
        ],
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('app-card-running')), findsNothing);

    running.mark(sandboxSessionKey(_sha, 'm1'));
    await tester.pump();
    expect(find.byKey(const ValueKey('app-card-running')), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(AppCard)).label,
      contains('Resume sequence.html, running'),
    );

    // The same blob in another message is a different session.
    running.mark(sandboxSessionKey(_sha, 'm2'), only: true);
    await tester.pump();
    expect(find.byKey(const ValueKey('app-card-running')), findsNothing);
    semantics.dispose();
  });
}

class _RunningSessions extends SandboxSessionsNotifier {
  @override
  SandboxSessionsState build() => SandboxSessionsState.empty;

  void mark(String key, {bool only = false}) {
    const view = SandboxSessionView(
      phase: SandboxSessionPhase.ready,
      error: null,
      attached: false,
      hasDocument: true,
      prefillSeq: 0,
    );
    state = SandboxSessionsState({if (!only) ...state.sessions, key: view});
  }
}
