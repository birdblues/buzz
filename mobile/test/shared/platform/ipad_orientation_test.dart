import 'package:buzz/shared/platform/ipad_orientation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Captures what the lock asks the platform for, and plays the runner's
  /// answer to `isPad` ([runnerSaysPad]; null = the runner has no handler).
  List<MethodCall> captureWith({required bool? runnerSaysPad}) {
    final platformCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(
      deviceChannel,
      runnerSaysPad == null
          ? null
          : (call) async => call.method == 'isPad' ? runnerSaysPad : null,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(deviceChannel, null);
    });
    return platformCalls;
  }

  List<String> orientationsIn(List<MethodCall> calls) => [
    for (final call in calls)
      if (call.method == 'SystemChrome.setPreferredOrientations')
        ...(call.arguments as List).cast<String>(),
  ];

  group('lockIpadToLandscape', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test(
      'locks when the runner says iPad, whatever the window measures',
      () async {
        final calls = captureWith(runnerSaysPad: true);
        expect(await lockIpadToLandscape(), isTrue);
        expect(orientationsIn(calls), [
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ]);
      },
    );

    test('leaves an iPhone alone', () async {
      final calls = captureWith(runnerSaysPad: false);
      expect(await lockIpadToLandscape(), isFalse);
      expect(orientationsIn(calls), isEmpty);
    });

    test('without a runner answer it falls back to the window size', () async {
      // The test window is phone-sized (800x600 logical at ratio 1 in this
      // harness reports a short side of 600, so pin it explicitly).
      final calls = captureWith(runnerSaysPad: null);
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1194, 834);
      view.devicePixelRatio = 1;
      addTearDown(view.reset);
      expect(await lockIpadToLandscape(), isTrue);
      expect(orientationsIn(calls), isNotEmpty);
    });
  });

  test('the size fallback is iOS-only and tablet-sized', () {
    expect(
      isIpadBySize(
        platform: TargetPlatform.iOS,
        logicalSize: const Size(834, 1194),
      ),
      isTrue,
    );
    expect(
      isIpadBySize(
        platform: TargetPlatform.iOS,
        logicalSize: const Size(430, 932),
      ),
      isFalse,
    );
    expect(
      isIpadBySize(platform: TargetPlatform.iOS, logicalSize: Size.zero),
      isFalse,
      reason: 'the pre-first-frame window that broke the size-only lock',
    );
    expect(
      isIpadBySize(
        platform: TargetPlatform.macOS,
        logicalSize: const Size(1280, 800),
      ),
      isFalse,
    );
  });

  test('a non-iOS platform never asks the runner', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = captureWith(runnerSaysPad: true);
    expect(await lockIpadToLandscape(), isFalse);
    expect(orientationsIn(calls), isEmpty);
  });
}
