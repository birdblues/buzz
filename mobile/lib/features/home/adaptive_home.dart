import 'package:flutter/material.dart';

import '../../shared/layout/layout_mode.dart';
import 'home_page.dart';
import 'wide_home_shell.dart';

/// Chooses the authenticated home for the current window size.
///
/// Compact windows (phones) get the tabbed [HomePage]; wide windows (iPad
/// landscape, large tablets) get the three-column [WideHomeShell]. The chosen
/// [LayoutMode] is published so navigation can decide between pushing a
/// route and selecting a pane.
class AdaptiveHome extends StatelessWidget {
  /// Creates the adaptive home.
  const AdaptiveHome({
    required this.settingsPageBuilder,
    required this.hasUnreadInbox,
    super.key,
  });

  /// Builds the Settings page when the user opens it.
  final WidgetBuilder settingsPageBuilder;

  /// Whether the Activity inbox has unread items.
  final bool hasUnreadInbox;

  @override
  Widget build(BuildContext context) {
    final mode = layoutModeForSize(MediaQuery.sizeOf(context));
    return LayoutModeScope(
      mode: mode,
      child: switch (mode) {
        LayoutMode.compact => HomePage(
          settingsPageBuilder: settingsPageBuilder,
          hasUnreadInbox: hasUnreadInbox,
        ),
        LayoutMode.wide => WideHomeShell(
          settingsPageBuilder: settingsPageBuilder,
          hasUnreadInbox: hasUnreadInbox,
        ),
      },
    );
  }
}
