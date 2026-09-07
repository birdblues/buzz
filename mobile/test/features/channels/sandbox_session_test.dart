import 'package:buzz/features/channels/sandbox_bridge.dart';
import 'package:buzz/features/channels/sandbox_session.dart';
import 'package:buzz/shared/relay/media_auth.dart';
import 'package:buzz/shared/relay/media_image.dart';
import 'package:buzz/shared/relay/relay_info.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:webview_flutter/webview_flutter.dart';

import 'fake_webview_platform.dart';

const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _door = 'http://relay.example.com:3001';

SandboxBridgeTarget _bridge(String messageId) =>
    SandboxBridgeTarget(channelId: 'chan', messageId: messageId);

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

class _Clock {
  DateTime now = DateTime(2026, 9, 7, 20);

  void advance(Duration by) => now = now.add(by);
}

/// Lets every pending microtask and zero-delay timer run without firing the
/// long expiry timers.
void _settle(FakeAsync async) {
  async.flushMicrotasks();
  async.elapse(Duration.zero);
  async.flushMicrotasks();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebViewPlatform platform;
  late _Clock clock;
  late _RecordingPrefill prefill;

  setUp(() {
    platform = FakeWebViewPlatform.install();
    clock = _Clock();
    prefill = _RecordingPrefill();
  });

  ProviderContainer container({bool hardened = true, int status = 200}) {
    final c = ProviderContainer(
      overrides: [
        appContentUrlProvider.overrideWithValue(_door),
        mediaGetAuthServiceProvider.overrideWithValue(_FakeAuth()),
        sandboxHardeningProbeProvider.overrideWithValue(() async => hardened),
        mediaHttpClientProvider.overrideWithValue(
          http_testing.MockClient(
            (_) async => http.Response(
              '<!doctype html><html><body>app</body></html>',
              status,
              headers: const {'content-type': 'text/html'},
            ),
          ),
        ),
        sandboxSessionClockProvider.overrideWithValue(() => clock.now),
        composerPrefillProvider.overrideWith(() => prefill),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Opens, attaches and finishes loading one app; returns its key. Real
  /// async: the mock HTTP client does not complete under `fakeAsync`, so
  /// only the timer-dependent steps run in a fake zone (a `Timer` belongs
  /// to the zone that created it — `detach` called inside `fakeAsync` is
  /// enough).
  Future<String> openReady(
    ProviderContainer c, {
    String messageId = 'abcdef0123456789',
  }) async {
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = notifier.open(sha256: _sha, bridge: _bridge(messageId));
    notifier.attach(key);
    await pumpEventQueue();
    platform.controllers.last.finishPage();
    return key;
  }

  test('open loads the stamped document once and reports ready', () async {
    final c = container();
    final key = await openReady(c);

    final controller = platform.controllers.single;
    expect(controller.javaScriptMode, JavaScriptMode.unrestricted);
    expect(controller.loadedHtml, hasLength(1));
    expect(controller.loadedHtml.single, contains('Content-Security-Policy'));
    expect(controller.channels.keys, [sandboxBridgeChannelName]);
    final view = c.read(sandboxSessionsProvider)[key]!;
    expect(view.phase, SandboxSessionPhase.ready);
    expect(view.attached, isTrue);
    expect(c.read(sandboxSessionsProvider).isRunning(key), isTrue);
    expect(
      c.read(sandboxSessionsProvider.notifier).controllerOf(key),
      isNotNull,
    );
  });

  test(
    'opening the same app again reuses the session and its controller',
    () async {
      final c = container();
      final notifier = c.read(sandboxSessionsProvider.notifier);
      final key = await openReady(c);
      final controller = notifier.controllerOf(key);
      notifier.detach(key);

      final again = notifier.open(
        sha256: _sha,
        bridge: _bridge('abcdef0123456789'),
      );
      notifier.attach(again);
      await pumpEventQueue();

      expect(again, key);
      expect(platform.controllers, hasLength(1), reason: 'no second load');
      expect(identical(notifier.controllerOf(key), controller), isTrue);
      expect(platform.controllers.single.loadedHtml, hasLength(1));
    },
  );

  test('Back keeps the app; Close blanks the document and drops it', () async {
    final c = container();
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = await openReady(c);
    final controller = platform.controllers.single;

    notifier.detach(key);
    expect(c.read(sandboxSessionsProvider).isRunning(key), isTrue);
    expect(c.read(sandboxSessionsProvider)[key]!.attached, isFalse);
    expect(controller.loadedHtml, hasLength(1), reason: 'not blanked');

    notifier.terminate(key);
    await pumpEventQueue();
    expect(c.read(sandboxSessionsProvider).isRunning(key), isFalse);
    expect(c.read(sandboxSessionsProvider)[key], isNull);
    expect(controller.loadedHtml, hasLength(2));
    expect(controller.loadedHtml.last, sandboxBlankDocument);
    expect(notifier.controllerOf(key), isNull);
  });

  test('a blank load is refused unless the host is terminating', () async {
    final c = container();
    await openReady(c);
    final controller = platform.controllers.single;

    // A second navigation from the app's side: the lock holds.
    controller.loadHtmlString('<html>again</html>');
    await pumpEventQueue();
    expect(controller.loadedHtml, hasLength(1));
  });

  test('a backed-out app ends 24 h later, not before', () async {
    final c = container();
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = await openReady(c);
    final controller = platform.controllers.single;
    fakeAsync((async) {
      notifier.detach(key);

      async.elapse(const Duration(hours: 23, minutes: 59));
      expect(c.read(sandboxSessionsProvider).isRunning(key), isTrue);
      expect(controller.loadedHtml, hasLength(1));

      async.elapse(const Duration(minutes: 2));
      _settle(async);
      expect(c.read(sandboxSessionsProvider).isRunning(key), isFalse);
      expect(controller.loadedHtml.last, sandboxBlankDocument);
    });
  });

  test('re-attaching cancels the expiry clock', () async {
    final c = container();
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = await openReady(c);
    fakeAsync((async) {
      notifier.detach(key);
      async.elapse(const Duration(hours: 23));
      notifier.attach(key);

      async.elapse(const Duration(hours: 2));
      expect(c.read(sandboxSessionsProvider).isRunning(key), isTrue);
      expect(platform.controllers.single.loadedHtml, hasLength(1));
    });
  });

  test('an overdue session is ended when the app resumes', () async {
    final c = container();
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = await openReady(c);
    fakeAsync((async) {
      notifier.detach(key);

      // The device slept: the wall clock moved, the Dart timer did not.
      clock.advance(const Duration(hours: 25));
      expect(c.read(sandboxSessionsProvider).isRunning(key), isTrue);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      _settle(async);
      expect(c.read(sandboxSessionsProvider).isRunning(key), isFalse);
      expect(platform.controllers.single.loadedHtml.last, sandboxBlankDocument);
    });
  });

  test(
    'only three backed-out apps stay alive; the oldest goes first',
    () async {
      final c = container();
      final notifier = c.read(sandboxSessionsProvider.notifier);
      final keys = <String>[];
      for (var i = 0; i < 4; i++) {
        final key = await openReady(c, messageId: 'message-$i');
        keys.add(key);
        clock.advance(const Duration(minutes: 1));
        notifier.detach(key);
      }
      await pumpEventQueue();

      final state = c.read(sandboxSessionsProvider);
      expect(state.isRunning(keys[0]), isFalse, reason: 'oldest evicted');
      expect(keys.sublist(1).map(state.isRunning), everyElement(isTrue));
      expect(platform.controllers[0].loadedHtml.last, sandboxBlankDocument);
      expect(platform.controllers[1].loadedHtml, hasLength(1));
    },
  );

  test(
    'a selection reaches the composer only while a page shows the app',
    () async {
      final c = container();
      final notifier = c.read(sandboxSessionsProvider.notifier);
      final key = await openReady(c);
      final controller = platform.controllers.single;
      const select = '{"kind":"edge","ref":"e4","text":"[인과그래프] 간선 e4"}';

      notifier.detach(key);
      controller.postFromApp(sandboxBridgeChannelName, select);
      expect(prefill.texts, isEmpty, reason: 'hidden apps cannot prefill');
      expect(c.read(sandboxSessionsProvider)[key]!.prefillSeq, 0);

      notifier.attach(key);
      clock.advance(const Duration(seconds: 1));
      controller.postFromApp(sandboxBridgeChannelName, select);
      expect(prefill.texts, ['[인과그래프 #abcdef01] 간선 e4']);
      expect(c.read(sandboxSessionsProvider)[key]!.prefillSeq, 1);
      expect(
        c.read(sandboxSessionsProvider).isRunning(key),
        isTrue,
        reason: 'the app stays alive behind the composer',
      );
    },
  );

  test(
    'a killed content process drops a hidden app and fails a shown one',
    () async {
      final c = container();
      final notifier = c.read(sandboxSessionsProvider.notifier);
      final key = await openReady(c);
      notifier.detach(key);
      platform.controllers.single.killContentProcess();
      await pumpEventQueue();
      expect(c.read(sandboxSessionsProvider)[key], isNull);
      expect(
        platform.controllers.single.loadedHtml,
        hasLength(1),
        reason: 'nothing to blank in a dead process',
      );

      final shown = await openReady(c, messageId: 'other');
      platform.controllers.last.killContentProcess();
      await pumpEventQueue();
      final view = c.read(sandboxSessionsProvider)[shown]!;
      expect(view.phase, SandboxSessionPhase.failed);
      expect(view.error, contains('Could not render'));
      expect(c.read(sandboxSessionsProvider).isRunning(shown), isFalse);

      // Backing out of a failed app drops it: nothing to come back to.
      notifier.detach(shown);
      expect(c.read(sandboxSessionsProvider)[shown], isNull);
    },
  );

  test('retry loads a fresh document in the same session', () async {
    final c = container();
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = await openReady(c);
    platform.controllers.single.killContentProcess();
    await pumpEventQueue();

    notifier.retry(key);
    await pumpEventQueue();
    platform.controllers.last.finishPage();
    expect(platform.controllers, hasLength(2));
    expect(
      c.read(sandboxSessionsProvider)[key]!.phase,
      SandboxSessionPhase.ready,
    );
    expect(
      identical(notifier.controllerOf(key), platform.controllers.last),
      isFalse,
      reason:
          'controllerOf hands out the WebViewController, not the platform one',
    );
    expect(notifier.controllerOf(key)!.platform, platform.controllers.last);
  });

  test(
    'a failed fetch reports the relay status and holds no document',
    () async {
      final c = container(status: 404);
      final notifier = c.read(sandboxSessionsProvider.notifier);
      final key = notifier.open(sha256: _sha, bridge: _bridge('m'));
      notifier.attach(key);
      await pumpEventQueue();

      final view = c.read(sandboxSessionsProvider)[key]!;
      expect(view.phase, SandboxSessionPhase.failed);
      expect(view.error, 'This app is no longer on the relay.');
      expect(view.hasDocument, isFalse);
      expect(platform.controllers, isEmpty);
    },
  );

  test('without the native hardening hook the app never loads', () async {
    final c = container(hardened: false);
    final notifier = c.read(sandboxSessionsProvider.notifier);
    final key = notifier.open(sha256: _sha, bridge: _bridge('m'));
    await pumpEventQueue();

    expect(c.read(sandboxSessionsProvider)[key]!.error, contains('hardening'));
    expect(platform.controllers, isEmpty);
  });
}
