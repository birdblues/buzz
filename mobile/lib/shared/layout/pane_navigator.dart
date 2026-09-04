import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import 'pane_scope.dart';

/// Hosts one column of the wide shell on its own nested [Navigator].
///
/// The nested navigator makes `Navigator.canPop` false at the pane root, so
/// existing pages show no back button there, while pages they push (channel
/// details, nested threads, the media viewer) stack inside the pane.
///
/// `onGenerateRoute` runs once, so [child] is captured by the initial route.
/// Hosts must give this widget a new [key] whenever the content changes.
///
/// `MediaQuery.size.width` is overridden with the pane's width so content that
/// sizes itself from the window width (inline media, banners) fits the pane;
/// height, padding, and view insets keep their window values.
class PaneNavigator extends HookWidget {
  /// Creates a pane hosting [child] as its root route.
  const PaneNavigator({
    super.key,
    required this.kind,
    required this.onClose,
    required this.child,
    this.headerLeading,
    this.headerTrailing,
    this.navigatorKey,
    this.depth,
  });

  /// Which column this pane is.
  final PaneKind kind;

  /// Called when the root content asks to be dismissed.
  final VoidCallback onClose;

  /// Root route content.
  final Widget child;

  /// See [PaneScope.headerLeading].
  final Widget? headerLeading;

  /// See [PaneScope.headerTrailing].
  final Widget? headerTrailing;

  /// Key for the nested navigator, so the host can pop it programmatically.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Receives the nested navigator's route count, so a host can decide
  /// whether a system back should pop inside this pane.
  final ValueNotifier<int>? depth;

  @override
  Widget build(BuildContext context) {
    final routeObserver = useMemoized(RouteObserver<ModalRoute<void>>.new);
    final heroController = useMemoized(
      MaterialApp.createMaterialHeroController,
    );
    useEffect(() => heroController.dispose, [heroController]);
    final depthObserver = useMemoized(() => _PaneDepthObserver(depth), [depth]);

    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            size: Size(constraints.maxWidth, mediaQuery.size.height),
          ),
          child: PaneScope(
            kind: kind,
            close: onClose,
            routeObserver: routeObserver,
            headerLeading: headerLeading,
            headerTrailing: headerTrailing,
            child: HeroControllerScope(
              controller: heroController,
              // Each pane keeps its own messenger. One messenger shows a
              // snackbar in every root Scaffold registered with it, and the
              // shell's columns are sibling Scaffolds — so a single failed
              // send would otherwise report itself once per visible pane.
              child: ScaffoldMessenger(
                child: Navigator(
                  key: navigatorKey,
                  observers: [routeObserver, depthObserver],
                  onGenerateRoute: (_) =>
                      MaterialPageRoute<void>(builder: (_) => child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Mirrors a navigator's route count into a [ValueNotifier].
class _PaneDepthObserver extends NavigatorObserver {
  _PaneDepthObserver(this.depth);

  final ValueNotifier<int>? depth;
  int _count = 0;

  void _set(int count) {
    _count = count;
    final notifier = depth;
    if (notifier == null) return;
    // The initial route is reported while the navigator mounts, i.e. during
    // the build phase, where notifying a listening ancestor is illegal.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        notifier.value = _count;
      });
      return;
    }
    notifier.value = count;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(_count + 1);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(_count - 1);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(_count - 1);
}
