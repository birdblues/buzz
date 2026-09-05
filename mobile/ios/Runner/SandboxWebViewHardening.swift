import Foundation
import ObjectiveC
import WebKit
import os.log

/// Removes WebRTC and `navigator.sendBeacon` from sandboxed app documents
/// before any of their own script runs.
///
/// The stamped CSP says `connect-src 'none'; webrtc 'block'`, but WebKit does
/// not implement the `webrtc` directive: on the desktop the probe page reached
/// a public STUN server over UDP from inside the sandbox until a
/// document-start user script removed the constructors. This is the iOS
/// counterpart of `desktop/src-tauri/src/sandbox_frame_hardening.rs`.
///
/// `webview_flutter` exposes no user-script API, so the hook is
/// `WKWebView.loadHTMLString(_:baseURL:)` — the one entry point the sandbox
/// page uses (the document is fetched in Dart and handed over as a string, so
/// the web view never navigates to the network). The script is registered on
/// that web view's user content controller, for every frame, before the load
/// starts; nested frames (about:blank, srcdoc) inherit the sandbox and would
/// otherwise be an escape hatch. Nothing else in this app calls
/// `loadHTMLString`, so the script needs no gate of its own.
enum SandboxWebViewHardening {
  static let script = #"""
  (function () {
    var kill = [
      'RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCSessionDescription',
      'RTCIceCandidate', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver', 'RTCDtlsTransport',
      'RTCIceTransport', 'RTCSctpTransport', 'RTCCertificate', 'WebTransport'
    ];
    for (var i = 0; i < kill.length; i++) {
      try { Object.defineProperty(window, kill[i], { value: undefined, writable: false, configurable: false, enumerable: false }); } catch (e) {}
    }
    try { Object.defineProperty(Navigator.prototype, 'sendBeacon', { value: function () { return false; }, writable: false, configurable: false }); } catch (e) {}
    try { Object.defineProperty(Navigator.prototype, 'mediaDevices', { value: undefined, configurable: false }); } catch (e) {}
    try { Object.defineProperty(Navigator.prototype, 'webkitGetUserMedia', { value: undefined, writable: false, configurable: false }); } catch (e) {}
  })();
  """#

  private static let log = OSLog(subsystem: "dev.birdblues.buzz", category: "sandbox-webview")
  private static var installed = false

  /// True once the `loadHTMLString` hook is in place. Dart asks for this over
  /// the `buzz/sandbox_webview` channel before running an app and fails
  /// closed when it is false, so a hook that could not be installed never
  /// ships an app with WebRTC available.
  static var isInstalled: Bool { installed }

  /// Swizzles `WKWebView.loadHTMLString(_:baseURL:)` once per process. Call
  /// from `application(_:didFinishLaunchingWithOptions:)`, before Flutter
  /// creates any web view. Safe to call again after a failure.
  static func install() {
    guard !installed else { return }
    guard
      let original = class_getInstanceMethod(
        WKWebView.self, #selector(WKWebView.loadHTMLString(_:baseURL:))),
      let replacement = class_getInstanceMethod(
        WKWebView.self, #selector(WKWebView.buzz_sandboxHardenedLoadHTMLString(_:baseURL:)))
    else {
      os_log(.fault, log: log, "could not install sandbox hardening: loadHTMLString(_:baseURL:) not found")
      assertionFailure("SandboxWebViewHardening: WKWebView.loadHTMLString(_:baseURL:) not found")
      return
    }
    method_exchangeImplementations(original, replacement)
    installed = true
  }

  /// Registers the document-start script on [webView]'s content controller
  /// (idempotent: a second load of the same web view does not stack scripts).
  /// `WKUserContentController` is shared by reference with the live page —
  /// `webview_flutter` itself adds its JavaScript-channel scripts the same
  /// way after creation.
  static func harden(_ webView: WKWebView) {
    let controller = webView.configuration.userContentController
    if controller.userScripts.contains(where: { $0.source == script }) { return }
    controller.addUserScript(
      WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    os_log(.info, log: log, "sandbox hardening registered for %{public}@", webView.description)
  }
}

extension WKWebView {
  @objc dynamic fileprivate func buzz_sandboxHardenedLoadHTMLString(
    _ string: String, baseURL: URL?
  ) -> WKNavigation? {
    SandboxWebViewHardening.harden(self)
    // After the swizzle this selector resolves to the original implementation.
    return buzz_sandboxHardenedLoadHTMLString(string, baseURL: baseURL)
  }
}
