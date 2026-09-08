import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Answers Dart's `isHardeningInstalled` probe (see AppWebViewPage): apps
  /// only run when the WebRTC-removal hook is in place. Kept as a property so
  /// the channel lives as long as the window.
  private var sandboxWebViewChannel: FlutterMethodChannel?

  /// Serves the two image methods of `buzz/media_upload`; see
  /// `MediaImageCodec`. Held for the window's lifetime like the one above.
  private var mediaUploadChannel: FlutterMethodChannel?

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

    mediaUploadChannel = FlutterMethodChannel(
      name: "buzz/media_upload",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    mediaUploadChannel?.setMethodCallHandler { call, result in
      MainFlutterWindow.handleMediaUpload(call, result: result)
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

  /// Answers `sanitizeImageForUpload` and `transcodeImageToJpeg`.
  ///
  /// Only those two: the rest of `buzz/media_upload` — video transcoding,
  /// poster extraction, voice-note packaging, clipboard reads — has no macOS
  /// implementation, and `hasNativeMediaPipeline` keeps the composer from
  /// offering them. Anything else must fall through to
  /// `FlutterMethodNotImplemented` rather than fail silently.
  private static func handleMediaUpload(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "sanitizeImageForUpload":
      guard
        let arguments = call.arguments as? [String: Any],
        let typedData = arguments["bytes"] as? FlutterStandardTypedData,
        let mimeType = arguments["mimeType"] as? String
      else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Expected image bytes and mime type.",
            details: nil
          )
        )
        return
      }
      encode(result: result, code: "sanitize_failed", details: mimeType) {
        try MediaImageCodec.encodeForUpload(typedData.data, mimeType: mimeType)
      }
    case "transcodeImageToJpeg":
      guard let typedData = call.arguments as? FlutterStandardTypedData else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Expected raw image bytes.",
            details: nil
          )
        )
        return
      }
      encode(result: result, code: "transcode_failed", details: nil) {
        try MediaImageCodec.encodeJpeg(typedData.data)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Runs `work` off the main thread and answers on it.
  ///
  /// A full-size photo is tens of megapixels; decoding and redrawing it on the
  /// main thread would freeze the window for as long as it takes.
  private static func encode(
    result: @escaping FlutterResult,
    code: String,
    details: String?,
    _ work: @escaping () throws -> Data
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let outcome: Result<Data, Error> = autoreleasepool {
        do {
          return .success(try work())
        } catch {
          return .failure(error)
        }
      }
      DispatchQueue.main.async {
        switch outcome {
        case .success(let data):
          result(FlutterStandardTypedData(bytes: data))
        case .failure:
          result(
            FlutterError(
              code: code,
              message: "Unable to prepare the picked image.",
              details: details
            )
          )
        }
      }
    }
  }
}
