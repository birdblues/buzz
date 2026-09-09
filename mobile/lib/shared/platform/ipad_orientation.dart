import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The iPad runs landscape only (owner decision, 2026-09-10): the wide shell
/// is built for it, and a portrait iPad would fall back to the phone layout.
///
/// `Info.plist` already says so with `UISupportedInterfaceOrientations~ipad`,
/// but the Flutter engine derives its orientation mask from the generic
/// `UISupportedInterfaceOrientations` key (which the iPhone needs to keep
/// portrait), so the plist alone leaves the iPad rotating. The lock is set
/// from Dart instead, for iOS devices whose shortest side is tablet-sized.
const double kTabletShortestSide = 600;

/// Whether the device running on [platform] with [logicalSize] is an iPad.
bool isIpad({required TargetPlatform platform, required Size logicalSize}) =>
    platform == TargetPlatform.iOS &&
    logicalSize.shortestSide >= kTabletShortestSide;

/// Locks an iPad to landscape; a no-op everywhere else.
Future<void> lockIpadToLandscape() async {
  final view = PlatformDispatcher.instance.implicitView;
  if (view == null) return;
  final logicalSize = view.physicalSize / view.devicePixelRatio;
  if (!isIpad(platform: defaultTargetPlatform, logicalSize: logicalSize)) {
    return;
  }
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
}
