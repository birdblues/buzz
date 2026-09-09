import Cocoa
import os

/// The application object (Info.plist `NSPrincipalClass`).
///
/// It exists for one reason: to keep window managers from tearing Flutter's
/// accessibility bridge down mid-keystroke.
///
/// macOS marks an app as having an assistive client by setting the private
/// `AXEnhancedUserInterface` attribute on it. Tiling and snapping window
/// managers (AeroSpace, yabai, Amethyst, Rectangle, Phoenix) are such clients,
/// and because the flag also slows window animations they switch it *off* for
/// the duration of every move or resize and back *on* afterwards (AeroSpace
/// `MacApp.swift`, `disableAnimations`). Flutter's macOS engine takes the flag
/// as the only signal for whether semantics are wanted: off destroys the
/// accessibility bridge, on rebuilds it (`FlutterEngine.mm`
/// `onAccessibilityStatusChanged:`). With the bridge goes the `NSTextField` the
/// engine keeps behind every focused text field, and removing a field that is
/// being edited ends editing on the window — which takes first-responder
/// status away from the engine's `FlutterTextInputPlugin`. Every key after
/// that lands on the window and beeps. `MainFlutterWindow` recovers the
/// responder when that happens; this class keeps it from happening.
///
/// Chromium and Electron intercept the same write on their application object
/// and debounce it, for the same reason. A request to turn the flag off is
/// held for `settleDelay`; a request to turn it on inside that window cancels
/// it, so a manager's off-then-on never reaches AppKit — nor the engine, which
/// listens to the notification AppKit posts from its own setter. Turning the
/// flag on is forwarded at once: VoiceOver still lights the semantics tree the
/// moment it looks at the app. Only turning it off is late, by two seconds.
///
/// `accessibilitySetValue(_:forAttribute:)` is the deprecated informal protocol,
/// kept on purpose: it is the entry point the accessibility server still calls
/// on the application object for this attribute, and the one Chromium hooks.
@objc(BuzzApplication)
final class BuzzApplication: NSApplication {
  /// How long an "off" must stand unopposed before it is applied. Chromium's
  /// value; a window operation takes well under a second.
  static let settleDelay: TimeInterval = 2

  private static let enhancedUserInterface = NSAccessibility.Attribute(
    rawValue: "AXEnhancedUserInterface"
  )
  // `OSLog` + `os_log`, not `Logger`: the deployment target is 10.15 and the
  // structured API needs 11.0.
  private static let log = OSLog(subsystem: "xyz.buzz.client", category: "accessibility")

  private var pendingDisable: DispatchWorkItem?

  override func accessibilitySetValue(
    _ value: Any?,
    forAttribute attribute: NSAccessibility.Attribute
  ) {
    guard attribute == Self.enhancedUserInterface else {
      super.accessibilitySetValue(value, forAttribute: attribute)
      return
    }
    let enable = (value as? NSNumber)?.boolValue ?? false
    if let pending = pendingDisable {
      pending.cancel()
      pendingDisable = nil
      os_log(
        "AXEnhancedUserInterface: pending off cancelled by %{public}s",
        log: Self.log, type: .debug, enable ? "on" : "another off"
      )
    }
    if enable {
      os_log("AXEnhancedUserInterface: on, forwarded", log: Self.log, type: .debug)
      super.accessibilitySetValue(value, forAttribute: attribute)
      return
    }
    os_log(
      "AXEnhancedUserInterface: off, held for %.1fs",
      log: Self.log, type: .debug, Self.settleDelay
    )
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingDisable = nil
      os_log("AXEnhancedUserInterface: off, applied", log: Self.log, type: .debug)
      self.forwardAccessibilityValue(value, forAttribute: attribute)
    }
    pendingDisable = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
  }

  /// `super` is not reachable from inside the work item, so the deferred
  /// write goes through here.
  private func forwardAccessibilityValue(
    _ value: Any?,
    forAttribute attribute: NSAccessibility.Attribute
  ) {
    super.accessibilitySetValue(value, forAttribute: attribute)
  }
}
