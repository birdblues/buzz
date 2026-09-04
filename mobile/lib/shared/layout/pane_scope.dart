import 'package:flutter/widgets.dart';

/// Which column of the wide shell a pane occupies.
enum PaneKind {
  /// The centre column: channel timeline, inbox, or search.
  main,

  /// The right column: a thread or forum post opened from the main pane.
  aux,
}

/// Describes the pane a widget subtree is rendered in.
///
/// Wraps each pane's nested navigator, so every route in the pane can find it.
/// [FrostedAppBar] reads [headerLeading] and [headerTrailing] to inject pane
/// chrome (sidebar toggle, close button) without page-level changes:
/// [headerLeading] is used only at the pane's root route, where no back button
/// is implied; [headerTrailing] is always appended to the actions.
class PaneScope extends InheritedWidget {
  /// Creates a scope for one pane.
  const PaneScope({
    super.key,
    required this.kind,
    required this.close,
    required this.routeObserver,
    this.headerLeading,
    this.headerTrailing,
    required super.child,
  });

  /// Which column this pane is.
  final PaneKind kind;

  /// Dismisses the pane's root content (clears the selection or closes the
  /// auxiliary pane). Replaces `Navigator.pop()` on a full-screen page.
  final VoidCallback close;

  /// Route observer attached to the pane's navigator. A [RouteObserver] can
  /// only be attached to one navigator, so pane content must subscribe here
  /// instead of the root observer.
  final RouteObserver<ModalRoute<void>> routeObserver;

  /// Leading widget for the pane root's app bar, e.g. the sidebar toggle.
  final Widget? headerLeading;

  /// Trailing widget appended to the pane's app bar actions, e.g. close.
  final Widget? headerTrailing;

  /// The nearest pane scope, or null outside the wide shell.
  static PaneScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaneScope>();

  @override
  bool updateShouldNotify(PaneScope oldWidget) =>
      kind != oldWidget.kind ||
      close != oldWidget.close ||
      routeObserver != oldWidget.routeObserver ||
      headerLeading != oldWidget.headerLeading ||
      headerTrailing != oldWidget.headerTrailing;
}
