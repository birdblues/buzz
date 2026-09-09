import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Orientation policy on iOS (owner decisions, 2026-09-10): the iPad runs
/// landscape only — the wide shell is built for it, and a portrait iPad
/// would fall back to the phone layout — and the iPhone runs portrait only.
/// Other platforms are left alone.
///
/// `Info.plist` cannot express this on its own: the Flutter engine derives
/// its orientation mask from the generic `UISupportedInterfaceOrientations`
/// key (ignoring the `~ipad` variant), and one key cannot say landscape for
/// the iPad and portrait for the iPhone. So the lock is set from Dart.
///
/// The device is identified by asking the runner for its interface idiom
/// (`buzz/device` `isPad`), not by measuring the window: at startup, before
/// the first frame, the window can still report `Size.zero`, and a size test
/// then silently decides "not an iPad" (found on a real iPad, 2026-09-10).
/// Only if the runner cannot answer does the window size decide.
const MethodChannel deviceChannel = MethodChannel('buzz/device');

const double kTabletShortestSide = 600;

/// The orientations an iPad may take.
const List<DeviceOrientation> ipadOrientations = [
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

/// The orientations an iPhone may take (upright only, as phones usually do).
const List<DeviceOrientation> iphoneOrientations = [
  DeviceOrientation.portraitUp,
];

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

/// Applies the orientation policy for this device; a no-op off iOS.
/// Returns the orientations locked, or null when nothing was locked.
Future<List<DeviceOrientation>?> lockOrientationForDevice() async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return null;
  var isPad = await askRunnerIsPad();
  if (isPad == null) {
    // The runner did not answer: decide from the window as laid out now.
    final view = PlatformDispatcher.instance.implicitView;
    if (view == null) return null;
    final size = view.physicalSize / view.devicePixelRatio;
    if (size == Size.zero) return null; // not laid out yet; do not guess
    isPad = isIpadBySize(platform: defaultTargetPlatform, logicalSize: size);
  }
  final orientations = isPad ? ipadOrientations : iphoneOrientations;
  await SystemChrome.setPreferredOrientations(orientations);
  return orientations;
}
