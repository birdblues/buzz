import 'dart:convert';

import 'package:buzz/features/channels/sandbox_bridge.dart';
import 'package:buzz/features/channels/sandbox_revision.dart';
import 'package:buzz/features/channels/sandbox_session.dart';
import 'package:buzz/shared/relay/media_auth.dart';
import 'package:buzz/shared/relay/media_image.dart';
import 'package:buzz/shared/relay/relay_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:webview_flutter/webview_flutter.dart';

import 'fake_webview_platform.dart';

const _sha1 =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _sha2 =
    '2222222222222222222222222222222222222222222222222222222222222222';
const _sha3 =
    '3333333333333333333333333333333333333333333333333333333333333333';
const _door = 'http://relay.example.com:3001';
const _message = 'abcdef0123456789';

const _bridge = SandboxBridgeTarget(channelId: 'chan', messageId: _message);

/// The state an app exports, as its runtime's `_export` would serialise it.
final _exported = jsonEncode({
  'v': 1,
  'view': 'compressed',
  't': 4,
  'collapsed': ['g_a'],
  'sel': ['n1'],
  'includeFeedback': false,
  'cam': {
    'zoom': 2,
    'pan': {'x': 10, 'y': 20},
  },
  'moved': {
    'n1': {'x': 100, 'y': 60},
  },
});

class _FakeAuth extends MediaGetAuthService {
  _FakeAuth() : super(baseUrl: 'https://relay.example', nsec: null);

  @override
  Map<String, String>? signAppContentAuth(String sha256) => const {
    'Authorization': 'Nostr test',
  };
}

class _RecordingPrefill extends ComposerPrefillNotifier {
  final keys = <String?>[];

  @override
  void request({
    required String channelId,
    String? threadHeadId,
    required String text,
  }) {
    keys.add(threadHeadId);
  }
}

/// The revision the message's edits currently point at; tests move it.
class _RevisionSource extends Notifier<AppRevision?> {
  @override
  AppRevision? build() => null;

  void set(AppRevision? revision) => state = revision;
}

final _revisionSource = NotifierProvider<_RevisionSource, AppRevision?>(
  _RevisionSource.new,
);

AppRevision _revision(String sha, int at) => AppRevision(
  sha256: sha,
  filename: 'app.html',
  editId: 'edit-$at',
  createdAt: at,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebViewPlatform platform;
  late _RecordingPrefill prefill;

  setUp(() {
    platform = FakeWebViewPlatform.install();
    prefill = _RecordingPrefill();
  });

  ProviderContainer container({Set<String> missing = const {}}) {
    final c = ProviderContainer(
      overrides: [
        appContentUrlProvider.overrideWithValue(_door),
        mediaGetAuthServiceProvider.overrideWithValue(_FakeAuth()),
        sandboxHardeningProbeProvider.overrideWithValue(() async => true),
        mediaHttpClientProvider.overrideWithValue(
          http_testing.MockClient((request) async {
            final sha = request.url.pathSegments.last.split('.').first;
            if (missing.contains(sha)) return http.Response('', 404);
            return http.Response(
              '<!doctype html><html><body>app $sha</body></html>',
              200,
              headers: const {'content-type': 'text/html'},
            );
          }),
        ),
        appRevisionProvider.overrideWith(
          (ref, target) => ref.watch(_revisionSource),
        ),
        composerPrefillProvider.overrideWith(() => prefill),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<String> openReady(
    ProviderContainer c, {
    SandboxBridgeTarget bridge = _bridge,
    bool attach = true,
  }) async {
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = notifier.open(sha256: _sha1, bridge: bridge);
    if (attach) notifier.attach(key);
    await pumpEventQueue();
    platform.controllers.last.finishPage();
    await pumpEventQueue();
    return key;
  }

  test('keys: one per message with a single app, else per blob', () {
    expect(sandboxSessionKey(_sha1, _message), 'msg:$_message');
    expect(sandboxSessionKey(_sha1, null), 'sha:$_sha1');
    expect(sandboxSessionKey(_sha1, _message, htmlCount: 2), 'sha:$_sha1');
    expect(sandboxSessionKeyFor(_sha1, _bridge), 'msg:$_message');
    expect(
      sandboxSessionKeyFor(_sha1, _bridge.copyWith(htmlAttachmentCount: 2)),
      'sha:$_sha1',
    );
  });

  test('a new revision swaps the document in place with its state', () async {
    final c = container();
    final key = await openReady(c);
    platform.controllers.single.evaluate = (js) =>
        js.contains('__APP_READY__') ? 'true|false' : _exported;
    expect(c.read(sandboxSessionsProvider)[key]!.revisionAt, isNull);

    c.read(_revisionSource.notifier).set(_revision(_sha2, 1_700_000_000));
    await pumpEventQueue();
    // Fetched, exported, navigated — the page has not finished yet.
    expect(platform.controllers.single.loadedHtml, hasLength(2));
    expect(platform.controllers.single.loadedHtml.last, contains('app $_sha2'));
    expect(
      platform.controllers.single.loadedHtml.last,
      contains('Content-Security-Policy'),
    );
    expect(
      platform.controllers.single.evaluatedScripts.first,
      sandboxExportStateScript,
    );
    var view = c.read(sandboxSessionsProvider)[key]!;
    expect(view.phase, SandboxSessionPhase.updating);
    expect(view.isRunning, isTrue);
    expect(
      platform.controllers.single.ranScripts,
      isEmpty,
      reason: 'not before ready',
    );

    platform.controllers.single.finishPage();
    await pumpEventQueue();
    view = c.read(sandboxSessionsProvider)[key]!;
    expect(view.phase, SandboxSessionPhase.ready);
    expect(view.revisionAt, 1_700_000_000);
    expect(view.updateError, isNull);
    expect(
      platform.controllers.single.evaluatedScripts.last,
      sandboxReadyProbeScript,
    );
    expect(platform.controllers.single.ranScripts, hasLength(1));
    final expected = base64Encode(
      utf8.encode(jsonEncode(jsonDecode(_exported))),
    );
    expect(
      platform.controllers.single.ranScripts.single,
      sandboxImportStateScript(expected),
    );
    expect(platform.controllers.single.channels.keys, [
      sandboxBridgeChannelName,
    ]);
    expect(platform.controllers, hasLength(1), reason: 'same WebView');
  });

  test('the same blob only stamps the revision time', () async {
    final c = container();
    final key = await openReady(c);
    c.read(_revisionSource.notifier).set(_revision(_sha1, 42));
    await pumpEventQueue();
    expect(platform.controllers.single.loadedHtml, hasLength(1));
    expect(c.read(sandboxSessionsProvider)[key]!.revisionAt, 42);
  });

  test('a swap runs while the app is backed out', () async {
    final c = container();
    final key = await openReady(c, attach: false);
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    platform.controllers.single.finishPage();
    await pumpEventQueue();
    expect(platform.controllers.single.loadedHtml, hasLength(2));
    expect(c.read(sandboxSessionsProvider)[key]!.revisionAt, 1);
  });

  test('a blob the relay lacks leaves the old document untouched', () async {
    final c = container(missing: {_sha2});
    final key = await openReady(c);
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    expect(platform.controllers.single.loadedHtml, hasLength(1));
    expect(
      platform.controllers.single.evaluatedScripts,
      isEmpty,
      reason: 'fetch comes first',
    );
    final view = c.read(sandboxSessionsProvider)[key]!;
    expect(view.phase, SandboxSessionPhase.ready);
    expect(view.updateError, contains('no longer on the relay'));
    expect(view.revisionAt, isNull);
  });

  test('a version that fails to boot is rolled back with the state', () async {
    final c = container();
    final key = await openReady(c);
    var probes = 0;
    platform.controllers.single.evaluate = (js) {
      if (!js.contains('__APP_READY__')) return _exported;
      // The new version reports a boot error; the reloaded previous one is fine.
      probes += 1;
      return probes == 1 ? 'true|true' : 'true|false';
    };
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    platform.controllers.single
        .finishPage(); // v2 finished loading, then reports an error
    await pumpEventQueue();
    expect(platform.controllers.single.loadedHtml, hasLength(3));
    expect(platform.controllers.single.loadedHtml.last, contains('app $_sha1'));
    platform.controllers.single.finishPage(); // the rollback load
    await pumpEventQueue();
    final view = c.read(sandboxSessionsProvider)[key]!;
    expect(view.phase, SandboxSessionPhase.ready);
    expect(view.updateError, contains('previous one'));
    expect(view.revisionAt, isNull, reason: 'still on the first blob');
    expect(
      platform.controllers.single.ranScripts,
      hasLength(1),
      reason: 'state re-injected',
    );
  });

  test('the reload lock is one-shot', () async {
    final c = container();
    await openReady(c);
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    platform.controllers.single.finishPage();
    await pumpEventQueue();
    expect(platform.controllers.single.loadedHtml, hasLength(2));
    // The app tries to navigate on its own: refused, as before the swap.
    await platform.controllers.single.loadHtmlString('<html>escape</html>');
    expect(platform.controllers.single.loadedHtml, hasLength(2));
  });

  test('an export that is not a JSON string is not handed over', () async {
    final c = container();
    final key = await openReady(c);
    platform.controllers.single.evaluate = (js) =>
        js.contains('__APP_READY__') ? 'true|false' : 7;
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    platform.controllers.single.finishPage();
    await pumpEventQueue();
    expect(c.read(sandboxSessionsProvider)[key]!.revisionAt, 1);
    expect(platform.controllers.single.ranScripts, isEmpty);
  });

  test('revisions that arrive during a swap coalesce to the newest', () async {
    final c = container();
    final key = await openReady(c);
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    expect(platform.controllers.single.loadedHtml, hasLength(2));
    // v3 lands while v2 is still loading.
    c.read(_revisionSource.notifier).set(_revision(_sha3, 2));
    await pumpEventQueue();
    expect(
      platform.controllers.single.loadedHtml,
      hasLength(2),
      reason: 'queued, not raced',
    );
    platform.controllers.single.finishPage(); // v2 up → v3 starts
    await pumpEventQueue();
    expect(platform.controllers.single.loadedHtml, hasLength(3));
    expect(platform.controllers.single.loadedHtml.last, contains('app $_sha3'));
    platform.controllers.single.finishPage();
    await pumpEventQueue();
    expect(c.read(sandboxSessionsProvider)[key]!.revisionAt, 2);
  });

  test('a session keyed to the blob never follows revisions', () async {
    final c = container();
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = notifier.open(
      sha256: _sha1,
      bridge: _bridge.copyWith(htmlAttachmentCount: 2),
    );
    notifier.attach(key);
    await pumpEventQueue();
    platform.controllers.single.finishPage();
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    expect(key, startsWith('sha:'));
    expect(platform.controllers.single.loadedHtml, hasLength(1));
  });

  test('closing the app stops following its message', () async {
    final c = container();
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = await openReady(c);
    notifier.terminate(key);
    await pumpEventQueue();
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    expect(platform.controllers, hasLength(1));
    expect(platform.controllers.single.loadedHtml.last, sandboxBlankDocument);
  });

  test('Try again after a failure loads the newest blob', () async {
    final c = container(missing: {_sha1});
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = notifier.open(sha256: _sha1, bridge: _bridge);
    notifier.attach(key);
    await pumpEventQueue();
    expect(
      c.read(sandboxSessionsProvider)[key]!.phase,
      SandboxSessionPhase.failed,
    );
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    notifier.retry(key);
    await pumpEventQueue();
    platform.controllers.last.finishPage();
    await pumpEventQueue();
    final view = c.read(sandboxSessionsProvider)[key]!;
    expect(view.phase, SandboxSessionPhase.ready);
    expect(view.revisionAt, 1);
    expect(platform.controllers.last.loadedHtml.single, contains('app $_sha2'));
  });

  test('a main-frame error while the new version loads rolls back', () async {
    final c = container();
    final key = await openReady(c);
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    expect(platform.controllers.single.loadedHtml, hasLength(2));
    platform.controllers.single.delegate!.onWebResourceError!(
      const WebResourceError(
        errorCode: 1,
        description: 'boom',
        errorType: WebResourceErrorType.unknown,
        isForMainFrame: true,
      ),
    );
    await pumpEventQueue();
    // Rolled back to the previous blob instead of failing the session.
    expect(platform.controllers.single.loadedHtml, hasLength(3));
    expect(platform.controllers.single.loadedHtml.last, contains('app $_sha1'));
    platform.controllers.single.finishPage();
    await pumpEventQueue();
    final view = c.read(sandboxSessionsProvider)[key]!;
    expect(view.phase, SandboxSessionPhase.ready);
    expect(view.updateError, contains('previous one'));
    expect(c.read(sandboxSessionsProvider).isRunning(key), isTrue);
  });

  test(
    'Try again on the update strip re-attempts the failed version',
    () async {
      final missing = <String>{_sha2};
      final c = container(missing: missing);
      final key = await openReady(c);
      c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
      await pumpEventQueue();
      expect(c.read(sandboxSessionsProvider)[key]!.updateError, isNotNull);
      expect(platform.controllers.single.loadedHtml, hasLength(1));

      missing.clear(); // the relay caught up
      c.read(sandboxSessionsProvider.notifier).retryUpdate(key);
      await pumpEventQueue();
      expect(platform.controllers.single.loadedHtml, hasLength(2));
      expect(
        platform.controllers.single.loadedHtml.last,
        contains('app $_sha2'),
      );
      platform.controllers.single.finishPage();
      await pumpEventQueue();
      final view = c.read(sandboxSessionsProvider)[key]!;
      expect(view.revisionAt, 1);
      expect(view.updateError, isNull);
    },
  );

  test('a new place for the same app refreshes where selections go', () async {
    final c = container();
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = await openReady(c);
    final again = notifier.open(
      sha256: _sha1,
      bridge: _bridge.copyWith(threadHeadId: 'root'),
    );
    expect(again, key);
    expect(platform.controllers, hasLength(1));
    platform.controllers.single.postFromApp(
      sandboxBridgeChannelName,
      '{"v":1,"kind":"node","ref":"n1","text":"[인과그래프] 변수 x"}',
    );
    expect(prefill.keys, ['root'], reason: 'routed to the thread composer');
  });

  test('closing the app mid-swap stops the swap cleanly', () async {
    final c = container();
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = await openReady(c);
    c.read(_revisionSource.notifier).set(_revision(_sha2, 1));
    await pumpEventQueue();
    expect(platform.controllers.single.loadedHtml, hasLength(2));
    notifier.terminate(key);
    await pumpEventQueue();
    platform.controllers.single.finishPage();
    await pumpEventQueue();
    expect(c.read(sandboxSessionsProvider)[key], isNull);
    expect(platform.controllers.single.loadedHtml.last, sandboxBlankDocument);
    expect(platform.controllers.single.ranScripts, isEmpty);
  });
}
