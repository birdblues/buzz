import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    // Belt and braces: MainFlutterWindow.awakeFromNib installs the hook
    // before creating the Flutter view controller, which is the ordering
    // that matters; installing here as well covers any future code path that
    // creates a WKWebView before the main window loads. Idempotent.
    SandboxWebViewHardening.install()
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
