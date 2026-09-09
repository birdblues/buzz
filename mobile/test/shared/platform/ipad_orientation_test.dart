import 'dart:ui';

import 'package:buzz/shared/platform/ipad_orientation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only an iOS device with a tablet-sized short side is an iPad', () {
    expect(
      isIpad(platform: TargetPlatform.iOS, logicalSize: const Size(1194, 834)),
      isTrue,
    );
    expect(
      isIpad(platform: TargetPlatform.iOS, logicalSize: const Size(834, 1194)),
      isTrue,
      reason: 'portrait at launch still counts',
    );
    expect(
      isIpad(platform: TargetPlatform.iOS, logicalSize: const Size(430, 932)),
      isFalse,
      reason: 'iPhone Pro Max keeps rotating',
    );
    expect(
      isIpad(platform: TargetPlatform.iOS, logicalSize: const Size(932, 430)),
      isFalse,
    );
    expect(
      isIpad(
        platform: TargetPlatform.macOS,
        logicalSize: const Size(1280, 800),
      ),
      isFalse,
    );
    expect(
      isIpad(
        platform: TargetPlatform.android,
        logicalSize: const Size(1280, 800),
      ),
      isFalse,
    );
  });
}
