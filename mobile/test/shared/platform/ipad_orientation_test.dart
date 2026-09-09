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

  group('lockOrientationForDevice on iOS', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('an iPad is landscape only, whatever the window measures', () async {
      final calls = captureWith(runnerSaysPad: true);
      expect(await lockOrientationForDevice(), ipadOrientations);
      expect(orientationsIn(calls), [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
    });

    test('an iPhone is upright only', () async {
      final calls = captureWith(runnerSaysPad: false);
      expect(await lockOrientationForDevice(), iphoneOrientations);
      expect(orientationsIn(calls), ['DeviceOrientation.portraitUp']);
    });

    test('without a runner answer the laid-out window decides', () async {
      final calls = captureWith(runnerSaysPad: null);
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1194, 834);
      view.devicePixelRatio = 1;
      addTearDown(view.reset);
      expect(await lockOrientationForDevice(), ipadOrientations);
      expect(orientationsIn(calls), isNotEmpty);
    });
  });

  test('the size fallback is iOS-only, tablet-sized, and never guesses from '
      'an unlaid-out window', () {
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

  test('a non-iOS platform is left alone and never asks the runner', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = captureWith(runnerSaysPad: true);
    expect(await lockOrientationForDevice(), isNull);
    expect(orientationsIn(calls), isEmpty);
  });
}
