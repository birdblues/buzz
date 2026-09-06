import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Answers Dart's `isHardeningInstalled` probe (see AppWebViewPage): apps
  /// only run when the WebRTC-removal hook is in place. Kept as a property so
  /// the channel lives as long as the window.
  private var sandboxWebViewChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    // Before Flutter creates any WKWebView: the hook swizzles
    // `WKWebView.loadHTMLString(_:baseURL:)`, so it must be in place before
    // the engine (and webview_flutter) is initialised below. See
    // SandboxWebViewHardening.swift. The AppDelegate installs it too; the
    // call is idempotent.
    SandboxWebViewHardening.install()

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    sandboxWebViewChannel = FlutterMethodChannel(
      name: "buzz/sandbox_webview",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    sandboxWebViewChannel?.setMethodCallHandler { call, result in
      guard call.method == "isHardeningInstalled" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(SandboxWebViewHardening.isInstalled)
    }

    // The client app is the wide, three-column shell: never let the window
    // shrink below the layout's wide threshold (layout_mode.dart: width >=
    // 1000 and shortest side >= 600, measured on the content view) or it
    // would collapse into the phone UI. The xib's 800x600 default is below
    // that, so pick an initial content size and remember the frame between
    // launches.
    title = "Buzz Client"
    tabbingMode = .disallowed
    contentMinSize = NSSize(width: 1000, height: 700)
    if !setFrameUsingName("BuzzClientMainWindow") {
      setContentSize(NSSize(width: 1280, height: 800))
      center()
    }
    setFrameAutosaveName("BuzzClientMainWindow")

    super.awakeFromNib()
  }
}
