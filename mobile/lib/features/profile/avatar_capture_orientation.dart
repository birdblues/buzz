import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Locks [controller]'s capture orientation to portrait when the window is
/// portrait, and leaves it alone otherwise.
///
/// Phones present the avatar editor in portrait, where a portrait lock keeps
/// the preview and the captured frame aligned. A landscape window (the iPad
/// shell is landscape-only) must not force portrait, or the capture comes out
/// rotated a quarter turn from the preview; there the plugin follows the
/// device orientation instead.
Future<void> lockAvatarCaptureOrientation(
  CameraController controller,
  Orientation windowOrientation,
) async {
  if (windowOrientation == Orientation.landscape) return;
  await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
}
