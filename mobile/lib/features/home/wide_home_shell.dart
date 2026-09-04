import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/layout/layout_mode.dart';
import '../../shared/layout/pane_navigator.dart';
import '../../shared/layout/pane_scope.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../../shared/widgets/mobile_tab_footer_backdrop.dart';
import '../activity/activity_page.dart';
import '../channels/channel_detail_page.dart';
import '../channels/channels_page.dart';
import '../channels/channels_provider.dart';
import '../channels/thread_detail_page.dart';
import '../channels/wide_shell/wide_shell_provider.dart';
import '../channels/wide_shell/wide_sidebar_collapsed_provider.dart';
import '../forum/forum_thread_page.dart';
import '../profile/profile_provider.dart';
import '../search/search_page.dart';

part 'wide_home_shell/aux_pane.dart';
part 'wide_home_shell/empty_state.dart';
part 'wide_home_shell/main_pane.dart';
part 'wide_home_shell/sidebar_column.dart';
part 'wide_home_shell/sidebar_nav_rows.dart';
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
    // One navigator key and depth notifier per pane instance. A global key
    // shared across instances would move the old navigator, and its stale
    // initial route, into the re-keyed pane instead of mounting fresh content;
    // a shared depth notifier would let the old pane's teardown clobber the
    // count reported by its replacement.
    final mainNavigatorKey = useMemoized(GlobalKey<NavigatorState>.new, [
      shell.mainPaneKey,
    ]);
    final auxNavigatorKey = useMemoized(GlobalKey<NavigatorState>.new, [
      shell.auxPaneKey,
    ]);
    final mainDepth = useMemoized(() => ValueNotifier<int>(0), [
      shell.mainPaneKey,
    ]);
    final auxDepth = useMemoized(() => ValueNotifier<int>(0), [
      shell.auxPaneKey,
    ]);
    useListenable(mainDepth);
    useListenable(auxDepth);
    final auxContent = shell.aux;
    final canPopShell =
        auxDepth.value <= 1 && auxContent == null && mainDepth.value <= 1;

    return PopScope(
      canPop: canPopShell,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // System back (Android tablets) unwinds innermost-first: nested
        // routes in the auxiliary pane, then the pane itself, then routes in
        // the main pane. Only then does the pop reach the system.
        final auxNavigator = auxNavigatorKey.currentState;
        if (auxNavigator != null && auxNavigator.canPop()) {
          auxNavigator.pop();
          return;
        }
        if (shell.aux != null) {
          notifier.closeAux();
          return;
        }
        final mainNavigator = mainNavigatorKey.currentState;
        if (mainNavigator != null && mainNavigator.canPop()) {
          mainNavigator.pop();
        }
      },
      child: ColoredBox(
        color: context.colors.surface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SidebarColumn(
              settingsPageBuilder: settingsPageBuilder,
              hasUnreadInbox: hasUnreadInbox,
            ),
            Expanded(
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
            if (auxContent != null)
              _AuxPane(
                content: auxContent,
                paneKey: shell.auxPaneKey!,
                navigatorKey: auxNavigatorKey,
                depth: auxDepth,
              ),
          ],
        ),
      ),
    );
  }
}

/// A hairline between shell columns.
class _PaneDivider extends StatelessWidget {
  const _PaneDivider();

  @override
  Widget build(BuildContext context) {
    return VerticalDivider(
      width: 1,
      thickness: 1,
      color: context.colors.outlineVariant.withValues(alpha: 0.5),
    );
  }
}
