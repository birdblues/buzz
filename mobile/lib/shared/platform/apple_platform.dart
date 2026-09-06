import 'package:flutter/foundation.dart';

/// Which native capabilities this build of the app can rely on.
///
/// The Flutter app ships on iPhone/iPad, Android and — as the client-only
/// desktop app — macOS. Most platform branches in the UI ask "is this iOS?"
/// for cosmetic reasons and fall back to Material elsewhere; the getters here
/// are for the few places where the answer changes what the app can *do*.
///
/// Every getter reads [defaultTargetPlatform], so a test can steer them with
/// `debugDefaultTargetPlatformOverride`.

/// iOS or macOS. Both run WebKit, the data-protection keychain,
/// `local_auth_darwin`, and the native `SandboxWebViewHardening` hook.
bool get isApplePlatform =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Sandboxed HTML apps run only where the runner installs the WebRTC-removal
/// user-script hook (`SandboxWebViewHardening.swift` in the iOS and macOS
/// runners). Android has no hook and never runs apps.
bool get supportsSandboxApps => isApplePlatform;

/// Phones and tablets have a camera the app drives itself (the `camera`
/// plugin, `image_picker`'s camera source, animated avatar capture). Desktop
/// builds hide those entry points instead of failing when tapped.
bool get hasCamera =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

/// The native upload pipeline (`buzz/media_upload`: image sanitising, video
/// transcoding, voice-note packaging) exists only in the iOS and Android
/// runners. Without it the composer offers no video or voice-note attachment.
bool get hasNativeMediaPipeline =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

/// The macOS client: a resizable window with a keyboard and pointer, no touch
/// chrome, no photo library, files opened through the Finder/NSWorkspace.
bool get isDesktopHost => defaultTargetPlatform == TargetPlatform.macOS;
