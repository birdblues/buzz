import 'package:buzz/features/channels/app_webview_page.dart';
import 'package:buzz/features/channels/sandbox_bridge.dart';
import 'package:buzz/features/channels/sandbox_session.dart';
import 'package:buzz/shared/relay/media_auth.dart';
import 'package:buzz/shared/relay/media_image.dart';
import 'package:buzz/shared/relay/relay_info.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'fake_webview_platform.dart';

const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _door = 'http://relay.example.com:3001';
const _bridge = SandboxBridgeTarget(
  channelId: 'chan',
  messageId: 'abcdef0123456789',
);
final _key = sandboxSessionKey(_sha, _bridge.messageId);

class _FakeAuth extends MediaGetAuthService {
  _FakeAuth() : super(baseUrl: 'https://relay.example', nsec: null);

  @override
  Map<String, String>? signAppContentAuth(String sha256) => const {
    'Authorization': 'Nostr test',
  };
}

class _RecordingPrefill extends ComposerPrefillNotifier {
  final texts = <String>[];

  @override
  void request({
    required String channelId,
    String? threadHeadId,
    required String text,
  }) {
    texts.add(text);
  }
}

/// A home screen with one button that pushes the sandbox page, the way a
/// message card does.
Widget _app(_RecordingPrefill prefill) {
  return ProviderScope(
    overrides: [
      appContentUrlProvider.overrideWithValue(_door),
      mediaGetAuthServiceProvider.overrideWithValue(_FakeAuth()),
      sandboxHardeningProbeProvider.overrideWithValue(() async => true),
      mediaHttpClientProvider.overrideWithValue(
        http_testing.MockClient(
          (_) async => http.Response(
            '<!doctype html><html><body>app</body></html>',
            200,
            headers: const {'content-type': 'text/html'},
          ),
        ),
      ),
      composerPrefillProvider.overrideWith(() => prefill),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open'),
            onPressed: () => Navigator.of(context).push(
              AppWebViewPage.route(
                sha256: _sha,
                filename: 'graph.html',
                bridge: _bridge,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late FakeWebViewPlatform platform;
  late _RecordingPrefill prefill;

  setUp(() {
    platform = FakeWebViewPlatform.install();
    prefill = _RecordingPrefill();
  });

  /// Lets the real-time mock HTTP client finish one load (pumpAndSettle
  /// would spin on the loading indicator instead).
  Future<void> awaitLoad(WidgetTester tester, int before) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 80 && platform.controllers.length <= before; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pump();
  }

  Future<void> open(WidgetTester tester) async {
    final before = platform.controllers.length;
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await awaitLoad(tester, before);
    platform.controllers.last.finishPage();
    // Let the page route's slide-in finish so its chrome is tappable.
    await tester.pump(const Duration(milliseconds: 600));
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(
          // The home route sits offstage behind the pushed page.
          find.byKey(const ValueKey('open'), skipOffstage: false),
        ),
      );

  testWidgets('Back keeps the app running and the next open re-attaches it', (
    tester,
  ) async {
    await tester.pumpWidget(_app(prefill));
    await open(tester);

    expect(find.byType(AppWebViewPage), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-webview')), findsOneWidget);
    expect(find.textContaining('Back keeps it running'), findsOneWidget);
    final controller = platform.controllers.single;

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(AppWebViewPage), findsNothing);
    final state = containerOf(tester).read(sandboxSessionsProvider);
    expect(state.isRunning(_key), isTrue);
    expect(state[_key]!.attached, isFalse);
    expect(controller.loadedHtml, hasLength(1), reason: 'not blanked');

    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('fake-webview')), findsOneWidget);
    expect(platform.controllers, hasLength(1), reason: 'same document');
    expect(
      containerOf(tester).read(sandboxSessionsProvider)[_key]!.attached,
      isTrue,
    );
  });

  testWidgets('Close ends the app', (tester) async {
    await tester.pumpWidget(_app(prefill));
    await open(tester);
    final controller = platform.controllers.single;

    await tester.tap(find.byKey(const ValueKey('app-sandbox-close')));
    await tester.pumpAndSettle();

    expect(find.byType(AppWebViewPage), findsNothing);
    expect(
      containerOf(tester).read(sandboxSessionsProvider).isRunning(_key),
      isFalse,
    );
    expect(controller.loadedHtml.last, sandboxBlankDocument);

    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await awaitLoad(tester, 1);
    expect(platform.controllers, hasLength(2), reason: 'a fresh load');
  });

  testWidgets('a selection from the app pops the page and keeps it alive', (
    tester,
  ) async {
    await tester.pumpWidget(_app(prefill));
    await open(tester);

    platform.controllers.single.postFromApp(
      sandboxBridgeChannelName,
      '{"kind":"edge","ref":"e4","text":"[인과그래프] 간선 e4"}',
    );
    await tester.pumpAndSettle();

    expect(prefill.texts, ['[인과그래프 #abcdef01] 간선 e4']);
    expect(find.byType(AppWebViewPage), findsNothing);
    expect(
      containerOf(tester).read(sandboxSessionsProvider).isRunning(_key),
      isTrue,
    );
  });

  testWidgets('a failed load offers a retry that reloads in place', (
    tester,
  ) async {
    await tester.pumpWidget(_app(prefill));
    await open(tester);
    platform.controllers.single.killContentProcess();
    await tester.pump();

    expect(find.textContaining('Could not render'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await awaitLoad(tester, 1);
    platform.controllers.last.finishPage();
    await tester.pump();

    expect(platform.controllers, hasLength(2));
    expect(find.byKey(const ValueKey('fake-webview')), findsOneWidget);
    expect(find.textContaining('Could not render'), findsNothing);
  });
}
