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
/// from Dart instead.
///
/// The device is identified by asking the runner for its interface idiom
/// (`buzz/device` `isPad`), not by measuring the window: at startup, before
/// the first frame, the window can still report `Size.zero`, and a size test
/// then silently decides "not an iPad" (found on a real iPad, 2026-09-10).
/// Only if the runner cannot answer does the window size decide, after the
/// first frame.
const MethodChannel deviceChannel = MethodChannel('buzz/device');

const double kTabletShortestSide = 600;

/// Whether an iOS device with [logicalSize] is tablet-sized — the fallback
/// used only when the runner does not answer.
bool isIpadBySize({
  required TargetPlatform platform,
  required Size logicalSize,
}) =>
    platform == TargetPlatform.iOS &&
    logicalSize.shortestSide >= kTabletShortestSide;

/// Asks the runner whether this is an iPad; null when it cannot say.
Future<bool?> askRunnerIsPad() async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return false;
  try {
    return await deviceChannel.invokeMethod<bool>('isPad');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Locks an iPad to landscape; a no-op everywhere else. Returns whether the
/// lock was applied.
Future<bool> lockIpadToLandscape() async {
  final isPad = await askRunnerIsPad();
  if (isPad == true) {
    await _lock();
    return true;
  }
  if (isPad == false) return false;
  // The runner did not answer: decide from the window once it is laid out.
  final view = PlatformDispatcher.instance.implicitView;
  if (view == null) return false;
  final size = view.physicalSize / view.devicePixelRatio;
  if (isIpadBySize(platform: defaultTargetPlatform, logicalSize: size)) {
    await _lock();
    return true;
  }
  return false;
}

Future<void> _lock() => SystemChrome.setPreferredOrientations(const [
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
]);
