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

  /// The pasteboard types a copied picture can arrive as, best first.
  ///
  /// TIFF is last and handled apart: it is what Preview, Finder and the
  /// screenshot tool leave behind, and it is the one representation the upload
  /// path has no name for.
  private static let clipboardImageTypes: [NSPasteboard.PasteboardType] = [
    .png,
    NSPasteboard.PasteboardType("public.jpeg"),
    NSPasteboard.PasteboardType("public.heic"),
    NSPasteboard.PasteboardType("public.heif"),
    NSPasteboard.PasteboardType("org.webmproject.webp"),
    NSPasteboard.PasteboardType("com.compuserve.gif"),
    .tiff,
  ]

  /// Whether the pasteboard holds a picture, without copying it.
  ///
  /// The composer asks on focus and on activation to decide whether Cmd+V
  /// belongs to an image or to text, so this runs often and must stay cheap.
  static func clipboardHasImage(_ pasteboard: NSPasteboard) -> Bool {
    return pasteboard.availableType(from: clipboardImageTypes) != nil
  }

  /// The pasteboard's picture, in a container the upload path can name.
  ///
  /// Mirrors `AppDelegate.clipboardImageData` in the iOS runner. TIFF is
  /// re-encoded rather than passed on: the upload path names a picture by its
  /// bytes, and calling a TIFF a PNG fails later in the scrubber, which is
  /// exactly the error a reader cannot act on.
  static func clipboardImageData(from pasteboard: NSPasteboard) -> Data? {
    for type in clipboardImageTypes where type != .tiff {
      if let data = pasteboard.data(forType: type) { return data }
    }
    guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
    return try? MediaImageCodec.encodePng(tiff)
  }

  /// Answers the image methods of `buzz/media_upload`.
  ///
  /// Only these four: video transcoding, poster extraction and voice-note
  /// packaging have no macOS implementation, and `hasNativeMediaPipeline`
  /// keeps the composer from offering them. Anything else must fall through to
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
    case "clipboardHasImage":
      result(clipboardHasImage(.general))
    case "readClipboardImage":
      // Reading can mean decoding a TIFF, so it does not belong on the main
      // thread; the answer is nil when the pasteboard holds no picture, which
      // the composer reads as "let this paste be text".
      DispatchQueue.global(qos: .userInitiated).async {
        let data = autoreleasepool { clipboardImageData(from: .general) }
        DispatchQueue.main.async {
          guard let data else {
            result(nil)
            return
          }
          result(FlutterStandardTypedData(bytes: data))
        }
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
