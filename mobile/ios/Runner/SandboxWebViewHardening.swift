import Foundation
import ObjectiveC
import WebKit
import os.log

/// Removes WebRTC and `navigator.sendBeacon` from sandboxed app documents
/// before any of their own script runs.
///
/// The app door's CSP says `connect-src 'none'; webrtc 'block'`, but WebKit
/// does not implement the `webrtc` directive: on the desktop the probe page
/// reached a public STUN server over UDP from inside the sandbox until a
/// document-start user script removed the constructors. This is the iOS
/// counterpart of `desktop/src-tauri/src/sandbox_frame_hardening.rs`.
///
/// `webview_flutter` exposes no user-script API, so the hook is
/// `WKWebView.load(_:)`: when the request targets the app door path
/// (`/app/<sha256>.html`) the script is registered on that web view's
/// user content controller — for every frame — before the navigation starts.
/// The script itself no-ops for any top-level document outside that path, so
/// even an unrelated web view that picked it up would be left alone; nested
/// frames (about:blank, srcdoc) are always hardened because they inherit the
/// app's sandbox and would otherwise be an escape hatch.
enum SandboxWebViewHardening {
  static let script = #"""
  (function () {
    var isTop = true;
    try { isTop = (window.top === window); } catch (e) { isTop = false; }
    if (isTop && !/^\/app\/[0-9a-f]{64}\.html$/.test(location.pathname)) return;
    var kill = [
      'RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCSessionDescription',
      'RTCIceCandidate', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver', 'RTCDtlsTransport',
      'RTCIceTransport', 'RTCSctpTransport', 'RTCCertificate'
    ];
    for (var i = 0; i < kill.length; i++) {
      try { Object.defineProperty(window, kill[i], { value: undefined, writable: false, configurable: false, enumerable: false }); } catch (e) {}
    }
    try { Object.defineProperty(Navigator.prototype, 'sendBeacon', { value: function () { return false; }, writable: false, configurable: false }); } catch (e) {}
    try { Object.defineProperty(Navigator.prototype, 'mediaDevices', { value: undefined, configurable: false }); } catch (e) {}
  })();
  """#

  private static let log = OSLog(subsystem: "dev.birdblues.buzz", category: "sandbox-webview")
  private static var installed = false

  /// Swizzles `WKWebView.load(_:)` once per process. Call from
  /// `application(_:didFinishLaunchingWithOptions:)`, before Flutter creates
  /// any web view.
  static func install() {
    guard !installed else { return }
    installed = true
    guard
      let original = class_getInstanceMethod(WKWebView.self, #selector(WKWebView.load(_:))),
      let replacement = class_getInstanceMethod(
        WKWebView.self, #selector(WKWebView.buzz_sandboxHardenedLoad(_:)))
    else {
      os_log(.fault, log: log, "could not install sandbox hardening: WKWebView.load(_:) not found")
      return
    }
    method_exchangeImplementations(original, replacement)
  }

  /// `GET {origin}/app/{64-hex}.html` — the only request the app page makes.
  static func isAppDoorRequest(_ request: URLRequest) -> Bool {
    guard let path = request.url?.path else { return false }
    return path.range(of: "^/app/[0-9a-f]{64}\\.html$", options: .regularExpression) != nil
  }

  /// Registers the document-start script on [webView]'s content controller
  /// (idempotent: a second load of the same web view does not stack scripts).
  static func harden(_ webView: WKWebView) {
    let controller = webView.configuration.userContentController
    if controller.userScripts.contains(where: { $0.source == script }) { return }
    controller.addUserScript(
      WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    os_log(.info, log: log, "sandbox hardening registered for %{public}@", webView.description)
  }
}

extension WKWebView {
  @objc dynamic fileprivate func buzz_sandboxHardenedLoad(_ request: URLRequest) -> WKNavigation? {
    if SandboxWebViewHardening.isAppDoorRequest(request) {
      SandboxWebViewHardening.harden(self)
    }
    // After the swizzle this selector resolves to the original `load(_:)`.
    return buzz_sandboxHardenedLoad(request)
  }
}
