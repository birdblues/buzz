import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/layout/layout_mode.dart';
import '../../shared/layout/pane_navigator.dart';
import '../../shared/layout/pane_scope.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../activity/activity_page.dart';
import '../channels/channel_detail_page.dart';
import '../channels/channels_page.dart';
import '../channels/app_sandbox_body.dart';
import '../channels/channels_provider.dart';
import '../channels/sandbox_session.dart';
import '../channels/thread_detail_page.dart';
import '../channels/wide_shell/wide_shell_provider.dart';
import '../channels/wide_shell/wide_sidebar_collapsed_provider.dart';
import '../forum/forum_thread_page.dart';
import '../profile/profile_provider.dart';
import '../search/search_page.dart';
import 'home_nav_rows.dart';

part 'wide_home_shell/app_pane.dart';
part 'wide_home_shell/aux_pane.dart';
part 'wide_home_shell/empty_state.dart';
part 'wide_home_shell/main_pane.dart';
part 'wide_home_shell/sidebar_column.dart';
part 'wide_home_shell/sidebar_toggle_button.dart';

const _kSidebarMotionDuration = Duration(milliseconds: 200);
const _kSidebarMotionCurve = Curves.easeOutCubic;

/// Desktop-style three-column home for wide windows: a collapsible sidebar
/// (community header, Activity/Search rows, channel list), a main pane, and an
/// auxiliary pane for threads.
///
/// Selection lives in [wideShellProvider]; each content pane runs on its own
/// nested navigator (see [PaneNavigator]).
class WideHomeShell extends HookConsumerWidget {
  /// Creates the wide shell.
  const WideHomeShell({
    required this.settingsPageBuilder,
    required this.hasUnreadInbox,
    super.key,
  });

  /// Builds the Settings page when the user opens it.
  final WidgetBuilder settingsPageBuilder;

  /// Whether the Activity inbox has unread items.
  final bool hasUnreadInbox;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(wideShellProvider);
    final notifier = ref.read(wideShellProvider.notifier);
    final auxContent = shell.aux;
    // Keep the last thread mounted while its pane animates closed.
    final retainedAux = useState<({WideAuxContent content, String key})?>(null);
    if (auxContent != null && shell.auxPaneKey != retainedAux.value?.key) {
      retainedAux.value = (content: auxContent, key: shell.auxPaneKey!);
    }
    final auxKey = shell.auxPaneKey ?? retainedAux.value?.key;
    // Keep the last app mounted while its layer slides out; one WebView per
    // session, so the layer is the only place the app is shown.
    final appPane = shell.appPane;
    final retainedApp = useState<WideAppPane?>(null);
    if (appPane != null && appPane.key != retainedApp.value?.key) {
      retainedApp.value = appPane;
    }
    // One navigator key and depth notifier per pane instance. A global key
    // shared across instances would move the old navigator, and its stale
    // initial route, into the re-keyed pane instead of mounting fresh content;
    // a shared depth notifier would let the old pane's teardown clobber the
    // count reported by its replacement.
    final mainNavigatorKey = useMemoized(GlobalKey<NavigatorState>.new, [
      shell.mainPaneKey,
    ]);
    final auxNavigatorKey = useMemoized(GlobalKey<NavigatorState>.new, [
      auxKey,
    ]);
    final mainDepth = useMemoized(() => ValueNotifier<int>(0), [
      shell.mainPaneKey,
    ]);
    final auxDepth = useMemoized(() => ValueNotifier<int>(0), [auxKey]);
    useListenable(mainDepth);
    useListenable(auxDepth);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final motion = reducedMotion ? Duration.zero : _kSidebarMotionDuration;
    final appMotion = useAnimationController(duration: motion);
    final shellFocus = useFocusNode(skipTraversal: true);
    useEffect(() {
      if (appPane != null) {
        // The covered main pane must not keep focus: a focused composer
        // there would swallow Escape and the keyboard. Focus moves to the
        // shell's own node rather than nowhere — with no focus at all, key
        // events never reach the handler below.
        shellFocus.requestFocus();
        appMotion.forward();
        return null;
      }
      if (retainedApp.value == null) return null;
      var cancelled = false;
      appMotion.reverse().whenComplete(() {
        if (!cancelled && context.mounted) retainedApp.value = null;
      });
      return () => cancelled = true;
    }, [appPane?.key]);
    final canPopShell =
        auxDepth.value <= 1 &&
        auxContent == null &&
        appPane == null &&
        mainDepth.value <= 1;

    // System back (Android tablets) and Escape (a keyboard on the Mac
    // client or an iPad) unwind innermost-first: nested routes in the
    // auxiliary pane, then the pane itself, then routes in the main pane.
    // Only then does a back gesture reach the system.
    bool unwindOnce() {
      final auxNavigator = auxNavigatorKey.currentState;
      if (auxNavigator != null && auxNavigator.canPop()) {
        auxNavigator.pop();
        return true;
      }
      // The app beside the thread goes first, on its own: one Escape must
      // not take the thread with it.
      if (shell.appPane != null) {
        notifier.hideAppPane();
        return true;
      }
      if (shell.aux != null) {
        notifier.closeAux();
        return true;
      }
      final mainNavigator = mainNavigatorKey.currentState;
      if (mainNavigator != null && mainNavigator.canPop()) {
        mainNavigator.pop();
        return true;
      }
      return false;
    }

    // Escape is handled as a raw key event rather than through WidgetsApp's
    // DismissIntent: each pane's nested route wraps its content in a (disabled)
    // modal dismiss action, and `Actions.invoke` stops at the nearest action
    // for the intent instead of looking past a disabled one, so an intent
    // would never reach this widget. Key events do bubble up the focus tree
    // from whatever holds focus inside the shell.
    KeyEventResult handleKey(FocusNode _, KeyEvent event) {
      if (event is! KeyDownEvent ||
          event.logicalKey != LogicalKeyboardKey.escape) {
        return KeyEventResult.ignored;
      }
      // A focused text field owns Escape (the composer unfocuses on it).
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null &&
          focused.findAncestorWidgetOfExactType<EditableText>() != null) {
        return KeyEventResult.ignored;
      }
      return unwindOnce() ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    return Focus(
      skipTraversal: true,
      canRequestFocus: false,
      onKeyEvent: handleKey,
      child: Focus(
        // Something inside the shell must hold focus for a key event to
        // reach the handler above when no field or route does.
        focusNode: shellFocus,
        autofocus: true,
        child: PopScope(
          canPop: canPopShell,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            unwindOnce();
          },
          child: ColoredBox(
            color: context.colors.surface,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The app split folds the sidebar away for its duration; the
                // preference itself is untouched. Computed once here and
                // handed to the column so the two never disagree.
                final appSplit = appPane != null;
                final sidebarCollapsed =
                    ref.watch(wideSidebarCollapsedProvider) || appSplit;
                final sidebarWidth = sidebarCollapsed ? 0.0 : kWideSidebarWidth;
                final contentWidth = constraints.maxWidth - sidebarWidth;
                final auxOpen = auxContent != null;
                final auxFocused = auxOpen && shell.auxFocused && !appSplit;
                final sideWidth = wideAuxPaneWidthFor(contentWidth);
                final focusWidth = contentWidth - kWideAuxFocusGutter;
                final auxTargetWidth = !auxOpen
                    ? 0.0
                    : auxFocused
                    ? focusWidth
                    : sideWidth;
                final retained = retainedAux.value;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SidebarColumn(
                      settingsPageBuilder: settingsPageBuilder,
                      hasUnreadInbox: hasUnreadInbox,
                      collapsed: sidebarCollapsed,
                    ),
                    Expanded(
                      // The split is measured on the stack's own width: the
                      // sidebar keeps its row space while it animates, and
                      // a window-based split would overlap it meanwhile.
                      child: LayoutBuilder(
                        builder: (context, stackConstraints) {
                          final stackWidth = stackConstraints.maxWidth;
                          final threadWidth = wideAppSplitThreadWidthFor(
                            stackWidth,
                          );
                          final appWidth = stackWidth - threadWidth;
                          final retainedApp_ = retainedApp.value;
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              // The main pane yields room to a side panel and reclaims
                              // it under a focus drawer, both animated. Under an app
                              // split it is covered: no pointer, no semantics, no
                              // focus. The wrappers are always present so toggling
                              // the split never remounts the pane.
                              IgnorePointer(
                                ignoring: appSplit,
                                child: ExcludeSemantics(
                                  excluding: appSplit,
                                  child: ExcludeFocus(
                                    excluding: appSplit,
                                    child: AnimatedPadding(
                                      duration: motion,
                                      curve: _kSidebarMotionCurve,
                                      padding: EdgeInsets.only(
                                        right:
                                            auxOpen && !auxFocused && !appSplit
                                            ? sideWidth
                                            : 0,
                                      ),
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          minWidth: kWideMainPaneMinWidth,
                                        ),
                                        child: _MainPane(
                                          navigatorKey: mainNavigatorKey,
                                          depth: mainDepth,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // Focus mode: a scrim over the strip of channel left
                              // visible beside the drawer; tapping it docks the
                              // thread back as a side panel.
                              Positioned.fill(
                                child: IgnorePointer(
                                  ignoring: !auxFocused,
                                  child: AnimatedOpacity(
                                    duration: motion,
                                    curve: _kSidebarMotionCurve,
                                    opacity: auxFocused ? 1 : 0,
                                    child: GestureDetector(
                                      key: const ValueKey(
                                        'wide-aux-focus-scrim',
                                      ),
                                      behavior: HitTestBehavior.opaque,
                                      onTap: notifier.toggleAuxFocus,
                                      child: ColoredBox(
                                        color: context.colors.scrim.withValues(
                                          alpha: 0.32,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // The drawer keeps this stack slot whether docked on
                              // the right or pinned on the left under an app split:
                              // only its Positioned parent data changes, so the
                              // thread's navigator and composer keep their state.
                              if (retained != null)
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  left: appSplit ? 0 : null,
                                  right: appSplit ? null : 0,
                                  child: _AuxDrawer(
                                    content: retained.content,
                                    paneKey: retained.key,
                                    navigatorKey: auxNavigatorKey,
                                    depth: auxDepth,
                                    width: appSplit
                                        ? threadWidth
                                        : auxTargetWidth,
                                    // Content keeps its final width while the drawer
                                    // reveals it, like the sidebar. Under a split the
                                    // two are equal: the drawer jumps to its slot.
                                    contentWidth: appSplit
                                        ? threadWidth
                                        : auxFocused
                                        ? focusWidth
                                        : sideWidth,
                                    focused: auxFocused,
                                    focusEnabled: !appSplit,
                                    duration: appSplit ? Duration.zero : motion,
                                    onMotionEnd: () {
                                      if (ref.read(wideShellProvider).aux ==
                                          null) {
                                        retainedAux.value = null;
                                      }
                                    },
                                  ),
                                ),
                              // Appended last so the drawer's slot never shifts.
                              if (retainedApp_ != null)
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  right: 0,
                                  width: appWidth,
                                  child: SlideTransition(
                                    position:
                                        Tween<Offset>(
                                          begin: const Offset(1, 0),
                                          end: Offset.zero,
                                        ).animate(
                                          CurvedAnimation(
                                            parent: appMotion,
                                            curve: _kSidebarMotionCurve,
                                          ),
                                        ),
                                    child: _AppPaneColumn(
                                      key: ValueKey(
                                        'wide-app-${retainedApp_.key}',
                                      ),
                                      pane: retainedApp_,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
