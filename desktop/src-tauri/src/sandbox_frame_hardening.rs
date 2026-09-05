//! Subframe hardening for sandboxed HTML apps.
//!
//! The app-content CSP says `connect-src 'none'; webrtc 'block'`, but WebKit
//! does not implement the `webrtc` directive, so an app inside the sandbox
//! iframe could still open an `RTCPeerConnection` and reach the network over
//! ICE/STUN (observed live: srflx candidates from a public STUN server).
//! `navigator.sendBeacon` likewise reports "queued" even when CSP later drops
//! the request, which makes the sandbox probe hard to read.
//!
//! This user script runs at document start in *every* frame (Tauri's
//! all-frames initialization script → `WKUserScript` with
//! `forMainFrameOnly = false`). It leaves the main frame alone — the desktop's
//! huddle feature legitimately uses WebRTC there — and in any subframe it
//! removes the WebRTC constructors and neuters `sendBeacon` before the page's
//! own scripts run. The properties are re-defined as non-configurable so the
//! page cannot restore them; new child frames (about:blank, srcdoc) get the
//! same script, so they are not an escape hatch either.

pub(crate) const SCRIPT: &str = r#"(function () {
  try { if (window.top === window) return; } catch (e) { /* cross-origin top: still a subframe */ }
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
})();"#;

#[cfg(test)]
mod tests {
    use super::SCRIPT;

    #[test]
    fn script_guards_main_frame_and_removes_webrtc() {
        assert!(SCRIPT.contains("window.top === window"));
        for name in [
            "RTCPeerConnection",
            "webkitRTCPeerConnection",
            "RTCDataChannel",
            "WebTransport",
            "webkitGetUserMedia",
        ] {
            assert!(SCRIPT.contains(name), "missing {name}");
        }
        assert!(SCRIPT.contains("sendBeacon"));
        assert!(SCRIPT.contains("configurable: false"));
    }
}
