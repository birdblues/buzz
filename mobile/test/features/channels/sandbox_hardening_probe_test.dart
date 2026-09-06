import 'package:buzz/features/channels/app_webview_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The probe that gates sandboxed apps: it must ask the runner on the Apple
/// platforms that install `SandboxWebViewHardening` (iOS and the macOS
/// client) and answer "no" everywhere else without asking.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('buzz/sandbox_webview');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<bool> probe() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container.read(sandboxHardeningProbeProvider)();
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    test('asks the runner on $platform and trusts its answer', () async {
      debugDefaultTargetPlatformOverride = platform;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return true;
      });

      expect(await probe(), isTrue);
      expect(calls, ['isHardeningInstalled']);
    });

    test('fails closed on $platform when the runner says no', () async {
      debugDefaultTargetPlatformOverride = platform;
      messenger.setMockMethodCallHandler(channel, (call) async => false);

      expect(await probe(), isFalse);
    });
  }

  test('fails closed on macOS when the runner has no hook at all', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    // No handler registered: the platform side never answers.
    expect(await probe(), isFalse);
  });

  test('never asks on Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });

    expect(await probe(), isFalse);
    expect(calls, isEmpty);
  });
}
