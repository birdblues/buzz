import 'package:buzz/shared/platform/apple_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  // (platform, isApple, sandboxApps, camera, nativeMedia, desktopHost)
  const table = <(TargetPlatform, bool, bool, bool, bool, bool)>[
    (TargetPlatform.iOS, true, true, true, true, false),
    (TargetPlatform.macOS, true, true, false, false, true),
    (TargetPlatform.android, false, false, true, true, false),
    (TargetPlatform.linux, false, false, false, false, false),
    (TargetPlatform.windows, false, false, false, false, false),
    (TargetPlatform.fuchsia, false, false, false, false, false),
  ];

  for (final row in table) {
    final (platform, apple, sandbox, camera, media, desktop) = row;
    test('capabilities on $platform', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(isApplePlatform, apple, reason: 'isApplePlatform');
      expect(supportsSandboxApps, sandbox, reason: 'supportsSandboxApps');
      expect(hasCamera, camera, reason: 'hasCamera');
      expect(hasNativeMediaPipeline, media, reason: 'hasNativeMediaPipeline');
      expect(isDesktopHost, desktop, reason: 'isDesktopHost');
    });
  }

  test('covers every TargetPlatform', () {
    expect(
      table.map((row) => row.$1).toSet(),
      TargetPlatform.values.toSet(),
      reason: 'add a row when Flutter gains a platform',
    );
  });
}
