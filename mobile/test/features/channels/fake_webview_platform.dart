import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A `webview_flutter` platform that records what the app asked of it and
/// lets a test play the platform's side: fire page-finished, deliver a
/// bridge message "from the app", or kill the content process.
class FakeWebViewPlatform extends WebViewPlatform {
  final controllers = <FakePlatformWebViewController>[];

  /// Installs a fresh fake as the platform for the current test and removes
  /// it at teardown.
  static FakeWebViewPlatform install() {
    final platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    return platform;
  }

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = FakePlatformWebViewController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => FakePlatformNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => FakePlatformWebViewWidget(params);
}

class FakePlatformWebViewController extends PlatformWebViewController {
  FakePlatformWebViewController(super.params) : super.implementation();

  /// Every `loadHtmlString` in order: the app document first, `''` when the
  /// host blanks the view.
  final loadedHtml = <String>[];
  final channels = <String, JavaScriptChannelParams>{};
  FakePlatformNavigationDelegate? delegate;
  JavaScriptMode? javaScriptMode;

  /// Every `runJavaScript` in order (what the host pushed into the page).
  final ranScripts = <String>[];

  /// Every `runJavaScriptReturningResult` in order.
  final evaluatedScripts = <String>[];

  /// Plays the page's side of `runJavaScriptReturningResult`. The default
  /// answers a readiness probe with "ready, no error" and anything else with
  /// the JSON string `null` (an app with nothing to export).
  Object Function(String javaScript) evaluate = defaultEvaluate;

  static Object defaultEvaluate(String javaScript) =>
      javaScript.contains('__APP_READY__') ? 'true|false' : 'null';

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    // The platform asks the delegate first, as WebKit does for
    // `loadHTMLString`; a refused load is not recorded.
    final decide = delegate?.onNavigationRequest;
    if (decide != null) {
      final decision = await decide(
        NavigationRequest(url: 'about:blank', isMainFrame: true),
      );
      if (decision == NavigationDecision.prevent) return;
    }
    loadedHtml.add(html);
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {
    this.javaScriptMode = javaScriptMode;
  }

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {
    channels[javaScriptChannelParams.name] = javaScriptChannelParams;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    delegate = handler as FakePlatformNavigationDelegate;
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    ranScripts.add(javaScript);
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    evaluatedScripts.add(javaScript);
    return evaluate(javaScript);
  }

  /// The app's script finished loading.
  void finishPage() => delegate?.onPageFinished?.call('about:blank');

  /// The app posted [message] on [channel] (what `__buzzHost.select` does).
  void postFromApp(String channel, String message) {
    channels[channel]!.onMessageReceived(JavaScriptMessage(message: message));
  }

  /// The OS reclaimed the content process.
  void killContentProcess() {
    delegate?.onWebResourceError?.call(
      const WebResourceError(
        errorCode: 2,
        description: 'WebContent process terminated',
        errorType: WebResourceErrorType.webContentProcessTerminated,
        isForMainFrame: true,
      ),
    );
  }
}

class FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  FakePlatformNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageFinished;
  WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    this.onNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    this.onWebResourceError = onWebResourceError;
  }
}

class FakePlatformWebViewWidget extends PlatformWebViewWidget {
  FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-webview'));
}
