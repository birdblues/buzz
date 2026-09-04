import 'package:flutter/widgets.dart';

/// How the top-level shell is laid out for the current window size.
enum LayoutMode {
  /// Single-column phone layout: full-screen pages pushed on one navigator.
  compact,

  /// Desktop-style multi-column layout: sidebar, main pane, auxiliary pane.
  wide,
}

/// Minimum window width for [LayoutMode.wide].
///
/// The smallest iPad (mini) is 1024pt wide in landscape and must fit
/// [kWideSidebarWidth] + [kWideMainPaneMinWidth] + [kWideAuxPaneWidth].
const double kWideLayoutMinWidth = 1000;

/// Minimum shortest side for [LayoutMode.wide]. Keeps landscape phones
/// (iPhone Pro Max is 956x440) on the compact layout.
const double kWideLayoutMinShortestSide = 600;

/// Width of the wide-layout sidebar column when expanded.
const double kWideSidebarWidth = 280;

/// Width of the wide-layout auxiliary (thread) pane.
const double kWideAuxPaneWidth = 340;

/// Smallest width the wide-layout main pane may be given.
const double kWideMainPaneMinWidth = 360;

/// Maximum width of a modal bottom sheet in the wide layout.
const double kWideSheetMaxWidth = 560;

/// Chooses the [LayoutMode] for a window of [size].
LayoutMode layoutModeForSize(Size size) {
  if (size.width >= kWideLayoutMinWidth &&
      size.shortestSide >= kWideLayoutMinShortestSide) {
    return LayoutMode.wide;
  }
  return LayoutMode.compact;
}

/// Publishes the shell's [LayoutMode] to its subtree.
///
/// Panes override `MediaQuery.size.width` with their own width, so code inside
/// a pane must read the mode from this scope rather than from the window size.
/// Outside the scope (root-navigator sheets, the deep-link dispatcher) the
/// window size is the right answer, so [of] falls back to it.
class LayoutModeScope extends InheritedWidget {
  /// Creates a scope publishing [mode].
  const LayoutModeScope({super.key, required this.mode, required super.child});

  /// The layout mode chosen by the shell.
  final LayoutMode mode;

  /// Returns the nearest scoped mode, or derives it from the window size.
  static LayoutMode of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LayoutModeScope>();
    if (scope != null) return scope.mode;
    return layoutModeForSize(MediaQuery.sizeOf(context));
  }

  /// Whether the nearest layout mode is [LayoutMode.wide].
  static bool isWide(BuildContext context) => of(context) == LayoutMode.wide;

  @override
  bool updateShouldNotify(LayoutModeScope oldWidget) => mode != oldWidget.mode;
}
